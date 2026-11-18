// Wire DTOs of the camera control protocol: builders return the exact maps
// (key order matters, compact JSON via jsonEncode) and parsers throw
// TapoProtocolError, never a cast error. Shared by the local client and the
// cloud passthrough. Spec: hc.dto.*.

/// One normalised item of a `multipleRequest` reply.
class ControlItem {
  const ControlItem({this.method, this.result = const {}, this.errorCode = 0});

  /// Items from a reply: `{method, result, error_code}`. `error_code` may be an
  /// int or an integer string (bools are rejected); a non-map `result` becomes
  /// `{}`. Throws `TapoProtocolError` on unusable data.
  factory ControlItem.normalize(Object? raw) => throw UnimplementedError();

  final String? method;
  final Map<String, dynamic> result;
  final int errorCode;
  bool get ok => errorCode == 0;

  /// Throws `TapoDeviceError(code, method)` when [errorCode] != 0.
  void ensureOk() => throw UnimplementedError();
}

/// `{"method":"multipleRequest","params":{"requests":[...]}}`; order kept, an
/// empty list is allowed.
Map<String, dynamic> buildMultipleRequest(List<Map<String, dynamic>> requests) =>
    throw UnimplementedError();

/// Items of a decoded reply `{error_code, result:{responses:[...]}}`.
/// Top-level `error_code != 0` throws `TapoDeviceError('multipleRequest')`.
List<ControlItem> parseMultipleResponse(Object? reply) => throw UnimplementedError();

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

Map<String, dynamic> buildGetDeviceInfo() => throw UnimplementedError();

/// Parses `result.device_info.basic_info`; `device_model` must be non-empty.
DeviceInfo parseDeviceInfo(Map<String, dynamic> result) => throw UnimplementedError();

Map<String, dynamic> buildGetAppComponentList() => throw UnimplementedError();

/// `result.app_component.app_component_list[]` -> name -> int version
/// (version may be an int or a string).
Map<String, int> parseAppComponents(Map<String, dynamic> result) =>
    throw UnimplementedError();

// ---- privacy (lens mask) --------------------------------------------------

Map<String, dynamic> buildGetPrivacy() => throw UnimplementedError();
Map<String, dynamic> buildSetPrivacy(bool on) => throw UnimplementedError();

/// `'on'` -> true, `'off'` -> false, anything else `TapoProtocolError`.
bool parsePrivacy(Map<String, dynamic> result) => throw UnimplementedError();

// ---- PTZ --------------------------------------------------------------------

/// `motorMove` with signed integer strings; dx > 0 pans right.
Map<String, dynamic> buildMotorMove(int x, int y) => throw UnimplementedError();

/// `singalMove` (sic). [direction] must be 0, 90, 180 or 270 else ArgumentError.
Map<String, dynamic> buildMotorStep(int direction) => throw UnimplementedError();

/// `stopMove` with the STRING `'null'`.
Map<String, dynamic> buildStopMove() => throw UnimplementedError();

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

Map<String, dynamic> buildGetPresets() => throw UnimplementedError();

/// Parallel arrays `result.preset.preset {id, name, position_pan, ...}`.
List<PtzPreset> parsePresets(Map<String, dynamic> result) => throw UnimplementedError();

Map<String, dynamic> buildGotoPreset(String id) => throw UnimplementedError();

/// `addMotorPostion` (sic) with `save_ptz: '1'`.
Map<String, dynamic> buildAddPreset(String name) => throw UnimplementedError();
Map<String, dynamic> buildDeletePreset(String id) => throw UnimplementedError();

// ---- night vision / day-night -------------------------------------------------

enum DayNightMode { auto, on, off }

/// `getDayNightModeConfig` with `image: {name: 'common'}` (a STRING).
Map<String, dynamic> buildGetDayNight() => throw UnimplementedError();
Map<String, dynamic> buildSetDayNight(DayNightMode mode) => throw UnimplementedError();

/// `result.image.common.inf_type`; unknown values are a `TapoProtocolError`.
DayNightMode parseDayNight(Map<String, dynamic> result) => throw UnimplementedError();

// ---- LED, siren, motion detection ----------------------------------------------

Map<String, dynamic> buildGetLed() => throw UnimplementedError();
Map<String, dynamic> buildSetLed(bool on) => throw UnimplementedError();
bool parseLed(Map<String, dynamic> result) => throw UnimplementedError();

/// `doManualAlarm` with action `start` / `stop`.
Map<String, dynamic> buildManualAlarm(bool start) => throw UnimplementedError();

class MotionConfig {
  const MotionConfig({required this.enabled, this.sensitivity});
  final bool enabled;
  final int? sensitivity;
}

Map<String, dynamic> buildGetMotion() => throw UnimplementedError();

/// [sensitivity] must be 20, 60 or 80 (else ArgumentError); sent as a string.
Map<String, dynamic> buildSetMotion(bool enabled, {int? sensitivity}) =>
    throw UnimplementedError();
MotionConfig parseMotion(Map<String, dynamic> result) => throw UnimplementedError();

// ---- rename ---------------------------------------------------------------------

/// `setDeviceAlias`; [alias] must already be valid (see camera_names.dart).
Map<String, dynamic> buildSetDeviceAlias(String alias) => throw UnimplementedError();

// ---- alarms ---------------------------------------------------------------------

Map<String, dynamic> buildGetLastAlarmInfo() => throw UnimplementedError();

class LastAlarmInfo {
  const LastAlarmInfo({this.time, this.type});

  /// `last_alarm_time` as sent (epoch seconds string) or null.
  final String? time;

  /// `last_alarm_type` (motion, person, ...) or null.
  final String? type;
}

/// `result.system.last_alarm_info`.
LastAlarmInfo parseLastAlarmInfo(Map<String, dynamic> result) => throw UnimplementedError();

// ---- clip search (SD playback lane) -----------------------------------------------

/// `searchVideoWithUTC`; `id: 1` unless [playerId] is given (then `player_id`).
Map<String, dynamic> buildSearchVideoWithUtc({
  required int startTime,
  required int endTime,
  required int startIndex,
  required int endIndex,
  String? playerId,
}) =>
    throw UnimplementedError();
