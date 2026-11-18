// Wire DTOs of the camera control protocol: builders return the exact maps
// (key order matters, compact JSON via jsonEncode) and parsers throw
// TapoProtocolError, never a cast error. Shared by the local client and the
// cloud passthrough. Spec: hc.dto.*.

import 'tapo_errors.dart';

Map<String, dynamic> _req(String method, Map<String, dynamic> params) =>
    {'method': method, 'params': params};

Object? _dig(Object? obj, List<String> keys) {
  var cur = obj;
  for (final key in keys) {
    if (cur is! Map || !cur.containsKey(key)) {
      throw TapoProtocolError("Camera reply is missing '$key'");
    }
    cur = cur[key];
  }
  return cur;
}

Map<String, dynamic> _digMap(Object? obj, List<String> keys) {
  final v = _dig(obj, keys);
  if (v is! Map) throw TapoProtocolError("'${keys.last}' is not an object");
  return Map<String, dynamic>.from(v);
}

List<dynamic> _digList(Object? obj, List<String> keys) {
  final v = _dig(obj, keys);
  if (v is! List) throw TapoProtocolError("'${keys.last}' is not a list");
  return v;
}

bool _onOff(Object? value, String what) {
  if (value == 'on') return true;
  if (value == 'off') return false;
  throw TapoProtocolError("$what must be 'on' or 'off'");
}

int _toInt(Object? value, String what) {
  if (value is int) return value;
  if (value is String) {
    final p = int.tryParse(value.trim());
    if (p != null) return p;
  }
  throw TapoProtocolError('$what is not an integer');
}

String _text(Object? value) => value is String ? value : '';

/// One normalised item of a `multipleRequest` reply.
class ControlItem {
  const ControlItem({this.method, this.result = const {}, this.errorCode = 0});

  /// Items from a reply: `{method, result, error_code}`. `error_code` may be an
  /// int or an integer string (bools are rejected); a non-map `result` becomes
  /// `{}`. Throws `TapoProtocolError` on unusable data.
  factory ControlItem.normalize(Object? raw) {
    if (raw is! Map) throw TapoProtocolError('Camera reply item is not an object');
    final method = raw['method'];
    final result = raw['result'];
    return ControlItem(
      method: method is String ? method : null,
      result: result is Map ? Map<String, dynamic>.from(result) : <String, dynamic>{},
      errorCode: raw.containsKey('error_code') ? _toInt(raw['error_code'], 'error_code') : 0,
    );
  }

  final String? method;
  final Map<String, dynamic> result;
  final int errorCode;
  bool get ok => errorCode == 0;

  /// Throws `TapoDeviceError(code, method)` when [errorCode] != 0.
  void ensureOk() {
    if (errorCode != 0) {
      throw TapoDeviceError('Camera answered error $errorCode${method != null ? ' for $method' : ''}',
          code: errorCode, method: method);
    }
  }
}

/// `{"method":"multipleRequest","params":{"requests":[...]}}`; order kept, an
/// empty list is allowed.
Map<String, dynamic> buildMultipleRequest(List<Map<String, dynamic>> requests) =>
    _req('multipleRequest', {'requests': List<Map<String, dynamic>>.of(requests)});

/// Items of a decoded reply `{error_code, result:{responses:[...]}}`.
/// Top-level `error_code != 0` throws `TapoDeviceError('multipleRequest')`.
List<ControlItem> parseMultipleResponse(Object? reply) {
  if (reply is! Map) throw TapoProtocolError('Camera reply is not an object');
  final code = reply.containsKey('error_code') ? _toInt(reply['error_code'], 'error_code') : 0;
  if (code != 0) {
    throw TapoDeviceError('Camera answered error $code', code: code, method: 'multipleRequest');
  }
  final responses = _digList(reply, ['result', 'responses']);
  return [for (final item in responses) ControlItem.normalize(item)];
}

// ---- device info ---------------------------------------------------------

class DeviceInfo {
  const DeviceInfo({
    required this.deviceModel,
    this.deviceAlias = '',
    this.swVersion = '',
    this.hwVersion = '',
    this.mac = '',
    this.devId = '',
    this.raw = const {},
  });
  final String deviceModel;
  final String deviceAlias;
  final String swVersion;
  final String hwVersion;
  final String mac;
  final String devId;
  final Map<String, dynamic> raw;
}

Map<String, dynamic> buildGetDeviceInfo() => _req('getDeviceInfo', {
      'device_info': {
        'name': ['basic_info'],
      },
    });

/// Parses `result.device_info.basic_info`; `device_model` must be non-empty.
DeviceInfo parseDeviceInfo(Map<String, dynamic> result) {
  final info = _digMap(result, ['device_info', 'basic_info']);
  final model = info['device_model'];
  if (model is! String || model.isEmpty) {
    throw TapoProtocolError('basic_info.device_model is missing');
  }
  return DeviceInfo(
    deviceModel: model,
    deviceAlias: _text(info['device_alias']),
    swVersion: _text(info['sw_version']),
    hwVersion: _text(info['hw_version']),
    mac: _text(info['mac']),
    devId: _text(info['dev_id']),
    raw: info,
  );
}

Map<String, dynamic> buildGetAppComponentList() => _req('getAppComponentList', {
      'app_component': {
        'name': ['app_component_list'],
      },
    });

/// `result.app_component.app_component_list[]` -> name -> int version
/// (version may be an int or a string).
Map<String, int> parseAppComponents(Map<String, dynamic> result) {
  final out = <String, int>{};
  for (final item in _digList(result, ['app_component', 'app_component_list'])) {
    if (item is! Map || item['name'] is! String) {
      throw TapoProtocolError('app_component_list item has no name');
    }
    out[item['name'] as String] = _toInt(item['version'], 'component version');
  }
  return out;
}

// ---- privacy (lens mask) --------------------------------------------------

Map<String, dynamic> buildGetPrivacy() => _req('getLensMaskConfig', {
      'lens_mask': {
        'name': ['lens_mask_info'],
      },
    });

Map<String, dynamic> buildSetPrivacy(bool on) => _req('setLensMaskConfig', {
      'lens_mask': {
        'lens_mask_info': {'enabled': on ? 'on' : 'off'},
      },
    });

/// `'on'` -> true, `'off'` -> false, anything else `TapoProtocolError`.
bool parsePrivacy(Map<String, dynamic> result) =>
    _onOff(_dig(result, ['lens_mask', 'lens_mask_info', 'enabled']), 'lens_mask_info.enabled');

// ---- PTZ --------------------------------------------------------------------

/// `motorMove` with signed integer strings; dx > 0 pans right.
Map<String, dynamic> buildMotorMove(int x, int y) => _req('motorMove', {
      'motor': {
        'move': {'x_coord': '$x', 'y_coord': '$y'},
      },
    });

/// `singalMove` (sic). [direction] must be 0, 90, 180 or 270 else ArgumentError.
Map<String, dynamic> buildMotorStep(int direction) {
  if (direction != 0 && direction != 90 && direction != 180 && direction != 270) {
    throw ArgumentError.value(direction, 'direction', 'must be 0, 90, 180 or 270');
  }
  return _req('singalMove', {
    'motor': {
      'movestep': {'direction': '$direction'},
    },
  });
}

/// `stopMove` with the STRING `'null'`.
Map<String, dynamic> buildStopMove() => _req('stopMove', {
      'motor': {'stop': 'null'},
    });

class PtzPreset {
  const PtzPreset({
    required this.id,
    required this.name,
    this.positionPan = '',
    this.positionTilt = '',
    this.readOnly = false,
  });
  final String id;
  final String name;
  final String positionPan;
  final String positionTilt;
  final bool readOnly;
}

Map<String, dynamic> buildGetPresets() => _req('getPresetConfig', {
      'preset': {
        'name': ['preset'],
      },
    });

/// Parallel arrays `result.preset.preset {id, name, position_pan, ...}`.
List<PtzPreset> parsePresets(Map<String, dynamic> result) {
  final table = _digMap(result, ['preset', 'preset']);
  final ids = _digList(table, ['id']);
  final names = _digList(table, ['name']);
  if (names.length != ids.length) throw TapoProtocolError('preset.name does not match preset.id');
  List<dynamic>? column(String key) {
    final c = table[key];
    if (c == null) return null;
    if (c is! List || c.length != ids.length) {
      throw TapoProtocolError('preset.$key does not match preset.id');
    }
    return c;
  }

  final pan = column('position_pan');
  final tilt = column('position_tilt');
  final readOnly = column('read_only');
  final out = <PtzPreset>[];
  for (var i = 0; i < ids.length; i++) {
    final id = ids[i], name = names[i];
    if ((id is! String && id is! int) || name is! String) {
      throw TapoProtocolError('preset id/name has the wrong type');
    }
    out.add(PtzPreset(
      id: '$id',
      name: name,
      positionPan: pan == null ? '' : '${pan[i]}',
      positionTilt: tilt == null ? '' : '${tilt[i]}',
      readOnly: readOnly != null && _toInt(readOnly[i], 'read_only') != 0,
    ));
  }
  return out;
}

Map<String, dynamic> buildGotoPreset(String id) => _req('motorMoveToPreset', {
      'preset': {
        'goto_preset': {'id': id},
      },
    });

/// `addMotorPostion` (sic) with `save_ptz: '1'`.
Map<String, dynamic> buildAddPreset(String name) => _req('addMotorPostion', {
      'preset': {
        'set_preset': {'name': name, 'save_ptz': '1'},
      },
    });

Map<String, dynamic> buildDeletePreset(String id) => _req('deletePreset', {
      'preset': {
        'remove_preset': {
          'id': [id],
        },
      },
    });

// ---- night vision / day-night -------------------------------------------------

enum DayNightMode { auto, on, off }

/// `getDayNightModeConfig` with `image: {name: 'common'}` (a STRING).
Map<String, dynamic> buildGetDayNight() => _req('getDayNightModeConfig', {
      'image': {'name': 'common'},
    });

Map<String, dynamic> buildSetDayNight(DayNightMode mode) => _req('setDayNightModeConfig', {
      'image': {
        'common': {'inf_type': mode.name},
      },
    });

/// `result.image.common.inf_type`; unknown values are a `TapoProtocolError`.
DayNightMode parseDayNight(Map<String, dynamic> result) {
  final value = _dig(result, ['image', 'common', 'inf_type']);
  for (final m in DayNightMode.values) {
    if (m.name == value) return m;
  }
  throw TapoProtocolError('image.common.inf_type has an unknown value');
}

// ---- LED, siren, motion detection ----------------------------------------------

Map<String, dynamic> buildGetLed() => _req('getLedStatus', {
      'led': {
        'name': ['config'],
      },
    });

Map<String, dynamic> buildSetLed(bool on) => _req('setLedStatus', {
      'led': {
        'config': {'enabled': on ? 'on' : 'off'},
      },
    });

bool parseLed(Map<String, dynamic> result) =>
    _onOff(_dig(result, ['led', 'config', 'enabled']), 'led.config.enabled');

/// `doManualAlarm` with action `start` / `stop`.
Map<String, dynamic> buildManualAlarm(bool start) => _req('doManualAlarm', {
      'msg_alarm': {
        'manual_alarm': {'action': start ? 'start' : 'stop'},
      },
    });

class MotionConfig {
  const MotionConfig({required this.enabled, this.sensitivity});
  final bool enabled;
  final int? sensitivity;
}

Map<String, dynamic> buildGetMotion() => _req('getDetectionConfig', {
      'motion_detection': {
        'name': ['motion_det'],
        'table': ['region_info'],
      },
    });

/// [sensitivity] must be 20, 60 or 80 (else ArgumentError); sent as a string.
Map<String, dynamic> buildSetMotion(bool enabled, {int? sensitivity}) {
  final det = <String, dynamic>{'enabled': enabled ? 'on' : 'off'};
  if (sensitivity != null) {
    if (sensitivity != 20 && sensitivity != 60 && sensitivity != 80) {
      throw ArgumentError.value(sensitivity, 'sensitivity', 'must be 20, 60 or 80');
    }
    det['digital_sensitivity'] = '$sensitivity';
  }
  return _req('setDetectionConfig', {
    'motion_detection': {'motion_det': det},
  });
}

MotionConfig parseMotion(Map<String, dynamic> result) {
  final det = _digMap(result, ['motion_detection', 'motion_det']);
  final raw = det['digital_sensitivity'];
  return MotionConfig(
    enabled: _onOff(det['enabled'], 'motion_det.enabled'),
    sensitivity: raw == null ? null : _toInt(raw, 'digital_sensitivity'),
  );
}

// ---- rename ---------------------------------------------------------------------

/// `setDeviceAlias`; [alias] must already be valid (see camera_names.dart).
Map<String, dynamic> buildSetDeviceAlias(String alias) => _req('setDeviceAlias', {
      'system': {
        'sys': {'dev_alias': alias},
      },
    });

// ---- alarms ---------------------------------------------------------------------

Map<String, dynamic> buildGetLastAlarmInfo() => _req('getLastAlarmInfo', {
      'system': {
        'name': ['last_alarm_info'],
      },
    });

class LastAlarmInfo {
  const LastAlarmInfo({this.time, this.type});

  /// `last_alarm_time` as sent (epoch seconds string) or null.
  final String? time;

  /// `last_alarm_type` (motion, person, ...) or null.
  final String? type;
}

/// `result.system.last_alarm_info`.
LastAlarmInfo parseLastAlarmInfo(Map<String, dynamic> result) {
  final info = _digMap(result, ['system', 'last_alarm_info']);
  final time = info['last_alarm_time'];
  final type = info['last_alarm_type'];
  return LastAlarmInfo(
    time: time == null ? null : '$time',
    type: type is String && type.isNotEmpty ? type : null,
  );
}

// ---- clip search (SD playback lane) -----------------------------------------------

/// `searchVideoWithUTC`; `id: 1` unless [playerId] is given (then `player_id`).
Map<String, dynamic> buildSearchVideoWithUtc({
  required int startTime,
  required int endTime,
  required int startIndex,
  required int endIndex,
  String? playerId,
}) =>
    _req('searchVideoWithUTC', {
      'playback': {
        'search_video_with_utc': {
          if (playerId != null && playerId.isNotEmpty) 'player_id': playerId else 'id': 1,
          'channel': 0,
          'start_time': startTime,
          'end_time': endTime,
          'start_index': startIndex,
          'end_index': endIndex,
        },
      },
    });
