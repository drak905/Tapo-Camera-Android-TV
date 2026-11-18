// Shared camera model and per-camera routing (local vs cloud) used by the UI.
// Spec: hc.routing.*, hc.cloud.online_state, hc.dto.* (CameraControl).

import '../state/camera_names.dart';
import 'camera_control_client.dart';
import 'camera_dtos.dart';
import 'cloud_passthrough.dart';
import 'iot_things.dart';
import 'tapo_errors.dart';

/// Owner (thing role 0) or shared with this account (role != 0).
enum CameraRole { owner, shared }

/// Where control/live/playback go.
enum CameraRoute { local, cloud }

/// Features the camera exposes (from the component list).
class CameraCapabilities {
  const CameraCapabilities({
    this.ptz = false,
    this.privacy = true,
    this.nightVision = false,
    this.siren = false,
    this.led = false,
    this.motion = false,
  });
  final bool ptz, privacy, nightVision, siren, led, motion;
}

/// Camera as the UI sees it. Defined by the api lane; the UI lane wires it
/// into `AppState`.
class TapoCamera {
  const TapoCamera({
    required this.id,
    required this.name,
    required this.model,
    required this.role,
    required this.online,
    required this.route,
    this.lanIp,
    this.isManual = false,
    this.capabilities = const CameraCapabilities(),
  });

  /// Cloud deviceId (stable id).
  final String id;
  final String name;
  final String model;
  final CameraRole role;
  final bool online;
  final CameraRoute route;

  /// Set when found on the LAN.
  final String? lanIp;

  /// Added by IP, no cloud record: never cloud-routed.
  final bool isManual;
  final CameraCapabilities capabilities;

  bool get isShared => role == CameraRole.shared;
}

/// Role of a camera: the thing record wins over the device list; null means owner.
CameraRole roleFromRecords({int? thingRole, int? deviceListRole}) {
  final role = thingRole ?? deviceListRole ?? 0;
  return role == 0 ? CameraRole.owner : CameraRole.shared;
}

/// `status == 1` on the IoT thing OR answered TDP on the LAN; without a thing
/// record fall back to device-list `status != 0`.
bool cameraOnline({int? thingStatus, int? deviceListStatus, required bool lanFound}) {
  if (lanFound) return true;
  if (thingStatus != null) return thingStatus == 1;
  return deviceListStatus != null && deviceListStatus != 0;
}

/// cloud_routed = cloud camera AND (shared OR not (lanFound AND host non-empty)).
/// Manual cameras are never cloud-routed.
CameraRoute routeFor({
  required bool isManual,
  required CameraRole role,
  required bool lanFound,
  String? host,
}) {
  if (isManual) return CameraRoute.local;
  final localPossible = lanFound && host != null && host.isNotEmpty;
  if (role == CameraRole.shared || !localPossible) return CameraRoute.cloud;
  return CameraRoute.local;
}
/// Why no control path exists.
enum RouteFailure { networkOnly, sharedCloudOnly, cameraOffline }

class CameraRouteError implements Exception {
  const CameraRouteError(this.reason);
  final RouteFailure reason;
}

/// Status read in one go. Unsupported getters give defaults (privacy false,
/// night vision auto, led false, motion disabled).
class CameraStatus {
  const CameraStatus({
    this.privacy = false,
    this.nightVision = DayNightMode.auto,
    this.led = false,
    this.motion = const MotionConfig(enabled: false),
  });
  final bool privacy;
  final DayNightMode nightVision;
  final bool led;
  final MotionConfig motion;
}

/// Commands the UI sends, independent of the route.
abstract class CameraControl {
  Future<bool> privacy();
  Future<void> setPrivacy(bool on);

  /// Relative pan/tilt step; x > 0 pans right, y > 0 tilts up.
  Future<void> ptzMove(int x, int y);
  Future<void> ptzStop();
  Future<DayNightMode> nightVision();
  Future<void> setNightVision(DayNightMode mode);
  Future<void> setSiren(bool on);

  /// Sends `setDeviceAlias` (validated by `normalizeCameraName`).
  Future<void> rename(String name);
  Future<DeviceInfo> deviceInfo();
  Future<LastAlarmInfo> lastAlarm();

  /// LAN: separate reads. Cloud: ONE passthrough batch of
  /// [getLensMaskConfig, getDayNightModeConfig, getLedStatus, getDetectionConfig].
  Future<CameraStatus> readStatus();
  void close();
}

/// Shared read/write logic of the two controls; subclasses only provide the
/// transport of one request batch.
abstract class _BatchControl implements CameraControl {
  Future<List<ControlItem>> _send(List<Map<String, dynamic>> requests);

  Future<Map<String, dynamic>> _one(Map<String, dynamic> request) async {
    final items = await _send([request]);
    if (items.isEmpty) throw TapoProtocolError('The camera sent no answer for ${request['method']}');
    items.first.ensureOk();
    return items.first.result;
  }

  @override
  Future<bool> privacy() async => parsePrivacy(await _one(buildGetPrivacy()));

  @override
  Future<void> setPrivacy(bool on) async => _one(buildSetPrivacy(on));

  @override
  Future<void> ptzMove(int x, int y) async => _one(buildMotorMove(x, y));

  @override
  Future<void> ptzStop() async => _one(buildStopMove());

  @override
  Future<DayNightMode> nightVision() async => parseDayNight(await _one(buildGetDayNight()));

  @override
  Future<void> setNightVision(DayNightMode mode) async => _one(buildSetDayNight(mode));

  @override
  Future<void> setSiren(bool on) async => _one(buildManualAlarm(on));

  @override
  Future<void> rename(String name) async => _one(buildSetDeviceAlias(normalizeCameraName(name)));

  @override
  Future<DeviceInfo> deviceInfo() async => parseDeviceInfo(await _one(buildGetDeviceInfo()));

  @override
  Future<LastAlarmInfo> lastAlarm() async => parseLastAlarmInfo(await _one(buildGetLastAlarmInfo()));

  /// Value of an item, or [fallback] when the camera does not support it.
  static T _orDefault<T>(ControlItem? item, T Function(Map<String, dynamic>) parse, T fallback) {
    if (item == null || !item.ok) return fallback;
    try {
      return parse(item.result);
    } on TapoProtocolError {
      return fallback;
    }
  }

  static CameraStatus _status(List<ControlItem?> items) => CameraStatus(
        privacy: _orDefault<bool>(items[0], parsePrivacy, false),
        nightVision: _orDefault<DayNightMode>(items[1], parseDayNight, DayNightMode.auto),
        led: _orDefault<bool>(items[2], parseLed, false),
        motion: _orDefault<MotionConfig>(items[3], parseMotion, const MotionConfig(enabled: false)),
      );
}

/// LAN control through [CameraControlClient].
class LocalControl extends _BatchControl {
  LocalControl(CameraControlClient client) : _client = client;

  final CameraControlClient _client;

  @override
  Future<List<ControlItem>> _send(List<Map<String, dynamic>> requests) => _client.send(requests);

  /// Separate reads: an unsupported getter must not hide the others.
  @override
  Future<CameraStatus> readStatus() async {
    final requests = [buildGetPrivacy(), buildGetDayNight(), buildGetLed(), buildGetMotion()];
    final items = <ControlItem?>[];
    for (final request in requests) {
      final reply = await _client.send([request]);
      items.add(reply.isEmpty ? null : reply.first);
    }
    return _BatchControl._status(items);
  }

  @override
  void close() => _client.close();
}

/// Remote/shared control through the cloud passthrough.
class CloudControl extends _BatchControl {
  CloudControl({required CloudPassthrough passthrough, required IotThing thing})
      : _passthrough = passthrough,
        _thing = thing;

  final CloudPassthrough _passthrough;
  final IotThing _thing;

  @override
  Future<List<ControlItem>> _send(List<Map<String, dynamic>> requests) =>
      _passthrough.send(_thing, requests);

  /// ONE passthrough batch.
  @override
  Future<CameraStatus> readStatus() async {
    final items = await _send([buildGetPrivacy(), buildGetDayNight(), buildGetLed(), buildGetMotion()]);
    return _BatchControl._status([for (var i = 0; i < 4; i++) i < items.length ? items[i] : null]);
  }

  @override
  void close() {}
}

typedef LocalControlFactory = CameraControl Function(TapoCamera camera, String? lat);
typedef CloudControlFactory = CameraControl Function(TapoCamera camera);

/// Picks and caches a [CameraControl] per camera. A new client is built when
/// the route, the LAN address or the LAT changes (fresh breaker). A shared
/// camera NEVER gets a local client.
class CameraRouter {
  CameraRouter({
    required LocalControlFactory localFactory,
    required CloudControlFactory cloudFactory,
    required bool Function() cloudSignedIn,
  })  : _localFactory = localFactory,
        _cloudFactory = cloudFactory,
        _cloudSignedIn = cloudSignedIn;

  final LocalControlFactory _localFactory;
  final CloudControlFactory _cloudFactory;
  final bool Function() _cloudSignedIn;
  final Map<String, (String, CameraControl)> _cache = {};

  /// Throws [CameraRouteError]: remote camera without cloud -> networkOnly;
  /// shared without cloud -> sharedCloudOnly; offline cloud camera -> cameraOffline.
  CameraControl controlFor(TapoCamera camera, {String? lat}) {
    final useLocal = !camera.isShared &&
        camera.route == CameraRoute.local &&
        (camera.lanIp != null && camera.lanIp!.isNotEmpty);
    final String key;
    if (useLocal) {
      key = 'local|${camera.lanIp}|${lat ?? ''}';
    } else {
      if (camera.isManual) throw const CameraRouteError(RouteFailure.networkOnly);
      if (!_cloudSignedIn()) {
        throw CameraRouteError(camera.isShared ? RouteFailure.sharedCloudOnly : RouteFailure.networkOnly);
      }
      if (!camera.online) throw const CameraRouteError(RouteFailure.cameraOffline);
      key = 'cloud';
    }
    final cached = _cache[camera.id];
    if (cached != null && cached.$1 == key) return cached.$2;
    if (cached != null) _closeQuietly(cached.$2);
    final control = useLocal ? _localFactory(camera, lat) : _cloudFactory(camera);
    _cache[camera.id] = (key, control);
    return control;
  }

  /// Drops cached clients (all, or one camera).
  void invalidate([String? cameraId]) {
    if (cameraId == null) {
      for (final entry in _cache.values) {
        _closeQuietly(entry.$2);
      }
      _cache.clear();
    } else {
      final removed = _cache.remove(cameraId);
      if (removed != null) _closeQuietly(removed.$2);
    }
  }

  static void _closeQuietly(CameraControl control) {
    try {
      control.close();
    } catch (_) {}
  }
}
