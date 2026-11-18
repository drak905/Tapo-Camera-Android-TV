// Mutable state of the mock camera plus the multipleRequest command dispatcher.
// Port of tests/fixtures/mock_tapo_server/{shadow,dispatcher}.py of the Windows app.
import 'dart:math';

const int panLimit = 180;
const int tiltLimit = 90;
const int maxPresets = 8;
const int ptzStep = 10;
const int maxAliasBytes = 32;

const int errMissing = -40211;
const int errInvalid = -40210;
const int errUnsupported = -40106;

class CommandError implements Exception {
  CommandError(this.code);
  final int code;
  @override
  String toString() => 'CommandError($code)';
}

class Recording {
  Recording(this.start, this.end, this.eventType);
  final DateTime start;
  final DateTime end;
  final int eventType;
  int get startEpoch => start.millisecondsSinceEpoch ~/ 1000;
  int get endEpoch => end.millisecondsSinceEpoch ~/ 1000;
}

class Preset {
  Preset(this.name, this.x, this.y, {this.readOnly = false});
  String name;
  int x;
  int y;
  bool readOnly;
}

/// 3 clips today (UTC) and 1 clip yesterday, sorted by start.
List<Recording> defaultRecordings([DateTime? now]) {
  final n = (now ?? DateTime.now()).toUtc();
  final today = DateTime.utc(n.year, n.month, n.day);
  final yday = today.subtract(const Duration(days: 1));
  Recording clip(DateTime base, int h, int m, int dur, int ev) {
    final s = base.add(Duration(hours: h, minutes: m));
    return Recording(s, s.add(Duration(seconds: dur)), ev);
  }

  return [
    clip(yday, 12, 0, 60, 2),
    clip(today, 1, 0, 60, 2),
    clip(today, 2, 0, 120, 1),
    clip(today, 3, 0, 30, 6),
  ];
}

Map<String, int> defaultComponents({bool dualLens = false}) => {
      'ptz': 1,
      'lensMask': 2,
      'led': 1,
      'dayNightMode': 1,
      'nightVisionMode': 1,
      'detection': 3,
      'playback': 2,
      'sdCard': 1,
      'manualAlarm': 1,
      'system': 3,
      'reboot': 1,
      'video': 2,
      'audio': 1,
      'timezone': 1,
      if (dualLens) 'dualCam': 1,
      if (dualLens) 'multiLensCam': 1,
    };

class DeviceShadow {
  DeviceShadow({
    this.model = 'C210',
    this.alias = 'Mock Camera',
    this.firmware = '1.3.11 Build 231019 Rel.59330n',
    this.hardware = '2.0',
    this.mac = 'AA-BB-CC-DD-EE-FF',
    this.deviceId = '80231A1F3B9E2C4D5E6F708192A3B4C5D6E7F801',
    List<Recording>? recordings,
    Map<String, int>? components,
  })  : recordings = recordings ?? defaultRecordings(),
        components = components ?? defaultComponents(),
        presets = {
          '1': Preset('Door', 20, 0),
          '2': Preset('Gate', -60, 10),
        };

  bool privacy = false;
  bool led = true;
  String infType = 'auto'; // auto | on | off
  String nightVisionMode = 'inf_night_vision';
  bool motionEnabled = true;
  int motionSensitivity = 60;
  bool alarmActive = false;
  int ptzX = 0;
  int ptzY = 0;
  Map<String, Preset> presets;
  List<Recording> recordings;
  Map<String, int> components;
  String model;
  String alias;
  String firmware;
  String hardware;
  String mac;
  String deviceId;
  String sdStatus = 'normal';
  bool ptzMoving = false;
  int rebootCount = 0;
  int lastAlarmTime = 0;
  String lastAlarmType = 'motion';

  bool clampMove(int dx, int dy) {
    final nx = max(-panLimit, min(panLimit, ptzX + dx));
    final ny = max(-tiltLimit, min(tiltLimit, ptzY + dy));
    final moved = nx != ptzX || ny != ptzY;
    if ((dx != 0 || dy != 0) && !moved) return false;
    ptzX = nx;
    ptzY = ny;
    return true;
  }

  String nextPresetId() {
    var i = 1;
    while (presets.containsKey('$i')) {
      i++;
    }
    return '$i';
  }
}

// ---------------------------------------------------------------- helpers
Map _module(Object? params, String module) {
  if (params is! Map || params[module] is! Map) throw CommandError(errMissing);
  return params[module] as Map;
}

Map _section(Object? params, String module, String section) {
  final mod = _module(params, module);
  final data = mod[section];
  if (data is! Map) throw CommandError(errMissing);
  return data;
}

void _requireSelector(Object? params, String module, String section,
    [List<String> kinds = const ['name', 'table']]) {
  final mod = _module(params, module);
  for (final k in kinds) {
    final v = mod[k];
    if (v == section || (v is List && v.contains(section))) return;
  }
  throw CommandError(errMissing);
}

bool _onoff(Object? v) {
  if (v == 'on') return true;
  if (v == 'off') return false;
  throw CommandError(errInvalid);
}

String _onoffStr(bool b) => b ? 'on' : 'off';

int _intStr(Object? v) {
  if (v is bool) throw CommandError(errInvalid);
  if (v is int) return v;
  if (v is String) {
    final n = int.tryParse(v.trim());
    if (n != null) return n;
  }
  throw CommandError(errInvalid);
}

int _strictStrInt(Object? v) {
  if (v is! String) throw CommandError(errInvalid);
  return _intStr(v);
}

DateTime _parseYmd(Object? v) {
  if (v is! String || v.length != 8 || int.tryParse(v) == null) {
    throw CommandError(errInvalid);
  }
  final y = int.parse(v.substring(0, 4));
  final m = int.parse(v.substring(4, 6));
  final d = int.parse(v.substring(6, 8));
  final dt = DateTime.utc(y, m, d);
  if (dt.year != y || dt.month != m || dt.day != d) throw CommandError(errInvalid);
  return dt;
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

DateTime _utcDay(DateTime t) {
  final u = t.toUtc();
  return DateTime.utc(u.year, u.month, u.day);
}

Map<String, dynamic> _ptzStatus(DeviceShadow s) => {
      'x_curpos': double.parse((s.ptzX / panLimit).toStringAsFixed(4)),
      'y_curpos': double.parse((s.ptzY / tiltLimit).toStringAsFixed(4)),
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };

// ---------------------------------------------------------------- handlers
typedef _Handler = Map<String, dynamic> Function(DeviceShadow s, Object? p);

Map<String, dynamic> _getDeviceInfo(DeviceShadow s, Object? p) {
  _requireSelector(p, 'device_info', 'basic_info', ['name']);
  return {
    'device_info': {
      'basic_info': {
        'device_type': 'SMART.IPCAMERA',
        'device_model': s.model,
        'device_name': s.model,
        'device_info': '${s.model} ${s.hardware} IPC',
        'hw_version': s.hardware,
        'sw_version': s.firmware,
        'device_alias': s.alias,
        'mac': s.mac,
        'dev_id': s.deviceId,
        'oem_id': '4F62C0C0A1B2C3D4E5F6',
        'hw_id': '8E1B2C3D4E5F60718293A4B5C6D7E8F9',
        'features': '3',
        'region': 'EU',
        'barcode': '',
        'ffs': false,
        'no_rtsp_constrain': 1,
        'has_set_location_info': 0,
        'latitude': 0,
        'longitude': 0,
        'led_status': _onoffStr(s.led),
        'status': 'configured',
      }
    }
  };
}

Map<String, dynamic> _getComponents(DeviceShadow s, Object? p) {
  _requireSelector(p, 'app_component', 'app_component_list', ['name']);
  return {
    'app_component': {
      'app_component_list': [
        for (final e in s.components.entries) {'name': e.key, 'version': e.value}
      ]
    }
  };
}

Map<String, dynamic> _motorMove(DeviceShadow s, Object? p) {
  final d = _section(p, 'motor', 'move');
  if (!d.containsKey('x_coord') || !d.containsKey('y_coord')) {
    throw CommandError(errMissing);
  }
  final x = _strictStrInt(d['x_coord']);
  final y = _strictStrInt(d['y_coord']);
  if (!s.clampMove(x, y)) throw CommandError(-64304);
  return {'move_time': 0.5, 'x_destpos': s.ptzX, 'y_destpos': s.ptzY, ..._ptzStatus(s)};
}

const _stepDirs = {
  '0': (ptzStep, 0),
  '90': (0, ptzStep),
  '180': (-ptzStep, 0),
  '270': (0, -ptzStep),
};

Map<String, dynamic> _motorStep(DeviceShadow s, Object? p) {
  final d = _section(p, 'motor', 'movestep');
  if (!d.containsKey('direction')) throw CommandError(errMissing);
  final dir = _stepDirs[d['direction']];
  if (dir == null) throw CommandError(errInvalid);
  if (!s.clampMove(dir.$1, dir.$2)) throw CommandError(-64304);
  s.ptzMoving = true;
  return {};
}

Map<String, dynamic> _motorStop(DeviceShadow s, Object? p) {
  final mod = _module(p, 'motor');
  if (mod['stop'] != 'null') throw CommandError(errMissing);
  s.ptzMoving = false;
  return {'status_pan': 'idle', 'status_tilt': 'idle', ..._ptzStatus(s)};
}

Map<String, dynamic> _getPresets(DeviceShadow s, Object? p) {
  _requireSelector(p, 'preset', 'preset', ['name']);
  final ids = s.presets.keys.toList()
    ..sort((a, b) => a.length != b.length ? a.length - b.length : a.compareTo(b));
  final pr = [for (final i in ids) s.presets[i]!];
  return {
    'preset': {
      'preset': {
        'id': ids,
        'name': [for (final x in pr) x.name],
        'position_pan': [for (final x in pr) (x.x / panLimit).toStringAsFixed(6)],
        'position_tilt': [for (final x in pr) (x.y / tiltLimit).toStringAsFixed(6)],
        'read_only': [for (final x in pr) x.readOnly ? '1' : '0'],
      }
    }
  };
}

Map<String, dynamic> _gotoPreset(DeviceShadow s, Object? p) {
  final d = _section(p, 'preset', 'goto_preset');
  final id = d['id'];
  if (id == null) throw CommandError(errMissing);
  if (id is! String || !s.presets.containsKey(id)) throw CommandError(errInvalid);
  s.ptzX = s.presets[id]!.x;
  s.ptzY = s.presets[id]!.y;
  return {};
}

Map<String, dynamic> _addPreset(DeviceShadow s, Object? p) {
  final d = _section(p, 'preset', 'set_preset');
  final name = d['name'];
  if (name is! String || d['save_ptz'] == null) throw CommandError(errMissing);
  if (d['save_ptz'] != '1' || name.isEmpty) throw CommandError(errInvalid);
  var id = d['id'];
  if (id != null && id is! String) throw CommandError(errInvalid);
  if ((id == null || !s.presets.containsKey(id)) && s.presets.length >= maxPresets) {
    throw CommandError(-64306);
  }
  id = (id as String?) ?? s.nextPresetId();
  s.presets[id] = Preset(name, s.ptzX, s.ptzY);
  return {'id': id};
}

Map<String, dynamic> _deletePreset(DeviceShadow s, Object? p) {
  final d = _section(p, 'preset', 'remove_preset');
  final ids = d['id'];
  if (ids is! List || ids.isEmpty || !ids.every((e) => e is String)) {
    throw CommandError(ids == null ? errMissing : errInvalid);
  }
  if (!ids.any((i) => s.presets.containsKey(i))) throw CommandError(errInvalid);
  for (final i in ids) {
    s.presets.remove(i);
  }
  return {};
}

Map<String, dynamic> _getPrivacy(DeviceShadow s, Object? p) {
  _requireSelector(p, 'lens_mask', 'lens_mask_info', ['name']);
  return {
    'lens_mask': {
      'lens_mask_info': {'enabled': _onoffStr(s.privacy)}
    }
  };
}

Map<String, dynamic> _setPrivacy(DeviceShadow s, Object? p) {
  final d = _section(p, 'lens_mask', 'lens_mask_info');
  if (!d.containsKey('enabled')) throw CommandError(errMissing);
  s.privacy = _onoff(d['enabled']);
  return {};
}

Map<String, dynamic> _getDayNight(DeviceShadow s, Object? p) {
  _requireSelector(p, 'image', 'common', ['name']);
  return {
    'image': {
      'common': {
        'inf_type': s.infType,
        'light_freq_mode': 'auto',
        'wide_dynamic': 'off',
        'inf_start_time': '64800',
        'inf_end_time': '21600',
        'inf_sensitivity': '4',
      }
    }
  };
}

Map<String, dynamic> _setDayNight(DeviceShadow s, Object? p) {
  final d = _section(p, 'image', 'common');
  if (!d.containsKey('inf_type')) throw CommandError(errMissing);
  if (!['auto', 'on', 'off'].contains(d['inf_type'])) throw CommandError(errInvalid);
  s.infType = d['inf_type'] as String;
  return {};
}

const _nvModes = {
  'inf_night_vision',
  'wtl_night_vision',
  'md_night_vision',
  'shed_night_vision',
  'dbl_night_vision',
  'lamp_closed_vision',
};

Map<String, dynamic> _getNightVision(DeviceShadow s, Object? p) {
  _requireSelector(p, 'image', 'switch', ['name']);
  return {
    'image': {
      'switch': {'night_vision_mode': s.nightVisionMode, 'flip_type': 'off', 'ldc': 'off'}
    }
  };
}

Map<String, dynamic> _setNightVision(DeviceShadow s, Object? p) {
  final d = _section(p, 'image', 'switch');
  if (!d.containsKey('night_vision_mode')) throw CommandError(errMissing);
  if (!_nvModes.contains(d['night_vision_mode'])) throw CommandError(errInvalid);
  s.nightVisionMode = d['night_vision_mode'] as String;
  return {};
}

Map<String, dynamic> _getLed(DeviceShadow s, Object? p) {
  _requireSelector(p, 'led', 'config', ['name']);
  return {
    'led': {
      'config': {'enabled': _onoffStr(s.led)}
    }
  };
}

Map<String, dynamic> _setLed(DeviceShadow s, Object? p) {
  final d = _section(p, 'led', 'config');
  if (!d.containsKey('enabled')) throw CommandError(errMissing);
  s.led = _onoff(d['enabled']);
  return {};
}

Map<String, dynamic> _manualAlarm(DeviceShadow s, Object? p) {
  final d = _section(p, 'msg_alarm', 'manual_alarm');
  if (!d.containsKey('action')) throw CommandError(errMissing);
  if (d['action'] != 'start' && d['action'] != 'stop') throw CommandError(errInvalid);
  s.alarmActive = d['action'] == 'start';
  return {};
}

String _legacySensitivity(int v) => v < 40 ? 'low' : (v < 70 ? 'normal' : 'high');

Map<String, dynamic> _getMotion(DeviceShadow s, Object? p) {
  final mod = _module(p, 'motion_detection');
  final names = mod['name'];
  if (!(names == 'motion_det' || (names is List && names.contains('motion_det')))) {
    throw CommandError(errMissing);
  }
  final out = <String, dynamic>{
    'motion_det': {
      'enabled': _onoffStr(s.motionEnabled),
      'digital_sensitivity': '${s.motionSensitivity}',
      'sensitivity': _legacySensitivity(s.motionSensitivity),
      'enhanced': 'off',
      'non_vehicle_enabled': 'off',
    }
  };
  final tables = mod['table'];
  if (tables == 'region_info' || (tables is List && tables.contains('region_info'))) {
    out['region_info'] = [];
  }
  return {'motion_detection': out};
}

Map<String, dynamic> _setMotion(DeviceShadow s, Object? p) {
  final d = _section(p, 'motion_detection', 'motion_det');
  if (!d.containsKey('enabled') && !d.containsKey('digital_sensitivity')) {
    throw CommandError(errMissing);
  }
  final enabled = d.containsKey('enabled') ? _onoff(d['enabled']) : null;
  int? sens;
  if (d.containsKey('digital_sensitivity')) {
    sens = _strictStrInt(d['digital_sensitivity']);
    if (sens < 0 || sens > 100) throw CommandError(errInvalid);
  }
  if (enabled != null) s.motionEnabled = enabled;
  if (sens != null) s.motionSensitivity = sens;
  return {};
}

Map<String, dynamic> _getSdStatus(DeviceShadow s, Object? p) {
  _requireSelector(p, 'harddisk_manage', 'hd_info', ['table']);
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return {
    'harddisk_manage': {
      'hd_info': [
        {
          'hd_info_1': {
            'disk_name': '1',
            'status': s.sdStatus,
            'detect_status': 'normal',
            'type': 'local',
            'total_space': '29.7GB',
            'free_space': '10.1GB',
            'video_total_space': '28.0GB',
            'video_free_space': '9.0GB',
            'percent': '66',
            'write_protect': '0',
            'record_duration': '1543',
            'record_free_duration': '500',
            'record_start_time': '${now - 86400 * 7}',
            'loop_record_status': '1',
          }
        }
      ]
    }
  };
}

Map<String, dynamic> _searchDays(DeviceShadow s, Object? p) {
  final d = _section(p, 'playback', 'search_year_utility');
  if (!d.containsKey('start_date') || !d.containsKey('end_date')) {
    throw CommandError(errMissing);
  }
  final start = _parseYmd(d['start_date']);
  final end = _parseYmd(d['end_date']);
  final days = <DateTime>{
    for (final c in s.recordings)
      if (!_utcDay(c.start).isBefore(start) && !_utcDay(c.start).isAfter(end))
        _utcDay(c.start)
  }.toList()
    ..sort();
  return {
    'playback': {
      'search_results': [
        for (var i = 0; i < days.length; i++)
          {
            'search_results_${i + 1}': {'date': _ymd(days[i])}
          }
      ]
    }
  };
}

Map<String, dynamic> _clipItem(int i, Recording c) {
  final ev = '${c.eventType}';
  return {
    'search_video_results_${i + 1}': {
      'startTime': c.startEpoch,
      'endTime': c.endEpoch,
      'vedio_type': ev,
      'video_type': ev,
    }
  };
}

Map<String, dynamic> _page(Map d, List<Recording> clips) {
  final si = _intStr(d['start_index'] ?? 0);
  final ei = _intStr(d['end_index'] ?? 99);
  if (si < 0 || ei < si) throw CommandError(errInvalid);
  final page = si >= clips.length
      ? <Recording>[]
      : clips.sublist(si, min(clips.length, ei + 1));
  return {
    'playback': {
      'search_video_results': [
        for (var i = 0; i < page.length; i++) _clipItem(si + i, page[i])
      ],
      'to_be_continued': clips.length > ei + 1 ? 1 : 0,
      'filter_enable': true,
      'filter_chn_enable': false,
      'playback_delete_v2_enable': false,
    }
  };
}

Map<String, dynamic> _searchDayClips(DeviceShadow s, Object? p) {
  final d = _section(p, 'playback', 'search_video_utility');
  if (!d.containsKey('date')) throw CommandError(errMissing);
  final day = _parseYmd(d['date']);
  final clips = s.recordings.where((c) => _utcDay(c.start) == day).toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  return _page(d, clips);
}

Map<String, dynamic> _searchDayClipsUtc(DeviceShadow s, Object? p) {
  final d = _section(p, 'playback', 'search_video_with_utc');
  if (!d.containsKey('start_time') || !d.containsKey('end_time')) {
    throw CommandError(errMissing);
  }
  final st = _intStr(d['start_time']);
  final et = _intStr(d['end_time']);
  if (et < st) throw CommandError(errInvalid);
  final clips = s.recordings
      .where((c) => c.startEpoch >= st && c.startEpoch <= et)
      .toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  return _page(d, clips);
}

Map<String, dynamic> _searchDetectionList(DeviceShadow s, Object? p) {
  final d = _section(p, 'playback', 'search_detection_list');
  final st = _intStr(d['start_time'] ?? 0);
  final et = _intStr(d['end_time'] ?? 2147483648);
  final sorted = [...s.recordings]..sort((a, b) => a.start.compareTo(b.start));
  return {
    'playback': {
      'search_detection_list': [
        for (final c in sorted)
          if (c.startEpoch >= st && c.startEpoch <= et && c.eventType != 1)
            {
              'start_time': c.startEpoch,
              'end_time': c.endEpoch,
              'alarm_type': c.eventType,
              'file_id': '${c.startEpoch}',
            }
      ],
      'snapshot_enable': true,
      'to_be_continued': 0,
    }
  };
}

Map<String, dynamic> _lastAlarmInfo(DeviceShadow s, Object? p) {
  _requireSelector(p, 'system', 'last_alarm_info', ['name']);
  return {
    'system': {
      'last_alarm_info': {
        'last_alarm_time': '${s.lastAlarmTime}',
        'last_alarm_type': s.lastAlarmType,
      }
    }
  };
}

Map<String, dynamic> _reboot(DeviceShadow s, Object? p) {
  final mod = _module(p, 'system');
  final r = mod['reboot'];
  if (!mod.containsKey('reboot') || !(r == 'null' || (r is Map && r.isEmpty))) {
    throw CommandError(errMissing);
  }
  s.rebootCount++;
  return {};
}

Map<String, dynamic> _setDeviceAlias(DeviceShadow s, Object? p) {
  final d = _section(p, 'system', 'sys');
  if (!d.containsKey('dev_alias')) throw CommandError(errMissing);
  final alias = d['dev_alias'];
  if (alias is! String || alias.trim().isEmpty) throw CommandError(errInvalid);
  if (utf8Length(alias) > maxAliasBytes) throw CommandError(errInvalid);
  s.alias = alias;
  return {};
}

int utf8Length(String s) {
  var n = 0;
  for (final r in s.runes) {
    n += r < 0x80 ? 1 : (r < 0x800 ? 2 : (r < 0x10000 ? 3 : 4));
  }
  return n;
}

final Map<String, _Handler> _handlers = {
  'getDeviceInfo': _getDeviceInfo,
  'getAppComponentList': _getComponents,
  'motorMove': _motorMove,
  'singalMove': _motorStep,
  'stopMove': _motorStop,
  'getPresetConfig': _getPresets,
  'motorMoveToPreset': _gotoPreset,
  'addMotorPostion': _addPreset,
  'deletePreset': _deletePreset,
  'getLensMaskConfig': _getPrivacy,
  'setLensMaskConfig': _setPrivacy,
  'getDayNightModeConfig': _getDayNight,
  'setDayNightModeConfig': _setDayNight,
  'getNightVisionModeConfig': _getNightVision,
  'setNightVisionModeConfig': _setNightVision,
  'getLedStatus': _getLed,
  'setLedStatus': _setLed,
  'doManualAlarm': _manualAlarm,
  'getDetectionConfig': _getMotion,
  'setDetectionConfig': _setMotion,
  'getSdCardStatus': _getSdStatus,
  'searchDateWithVideo': _searchDays,
  'searchVideoOfDay': _searchDayClips,
  'searchVideoWithUTC': _searchDayClipsUtc,
  'searchDetectionList': _searchDetectionList,
  'getLastAlarmInfo': _lastAlarmInfo,
  'rebootDevice': _reboot,
  'setDeviceAlias': _setDeviceAlias,
};

/// Runs one command against [s]. Returns (error_code, result).
(int, Map<String, dynamic>) dispatchCommand(DeviceShadow s, Object? method, Object? params) {
  final h = method is String ? _handlers[method] : null;
  if (h == null) return (errUnsupported, <String, dynamic>{});
  try {
    return (0, h(s, params ?? <String, dynamic>{}));
  } on CommandError catch (e) {
    return (e.code, <String, dynamic>{});
  }
}
