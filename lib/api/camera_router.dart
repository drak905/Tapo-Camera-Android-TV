// Shared camera model and per-camera routing (local vs cloud) used by the UI.
// Spec: hc.routing.*, hc.cloud.online_state, hc.dto.* (CameraControl).

import 'camera_dtos.dart';
import 'cloud_passthrough.dart';
import 'camera_control_client.dart';
import 'iot_things.dart';

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
CameraRole roleFromRecords({int? thingRole, int? deviceListRole}) =>
    throw UnimplementedError();

/// `status == 1` on the IoT thing OR answered TDP on the LAN; without a thing
/// record fall back to device-list `status != 0`.
bool cameraOnline({int? thingStatus, int? deviceListStatus, required bool lanFound}) =>
    throw UnimplementedError();

/// cloud_routed = cloud camera AND (shared OR not (lanFound AND host non-empty)).
/// Manual cameras are never cloud-routed.
CameraRoute routeFor({
  required bool isManual,
  required CameraRole role,
  required bool lanFound,
  String? host,
}) =>
    throw UnimplementedError();

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

/// LAN control through [CameraControlClient].
class LocalControl implements CameraControl {
  LocalControl(CameraControlClient client);

  @override
  Future<bool> privacy() => throw UnimplementedError();
  @override
  Future<void> setPrivacy(bool on) => throw UnimplementedError();
  @override
  Future<void> ptzMove(int x, int y) => throw UnimplementedError();
  @override
  Future<void> ptzStop() => throw UnimplementedError();
  @override
  Future<DayNightMode> nightVision() => throw UnimplementedError();
  @override
  Future<void> setNightVision(DayNightMode mode) => throw UnimplementedError();
  @override
  Future<void> setSiren(bool on) => throw UnimplementedError();
  @override
  Future<void> rename(String name) => throw UnimplementedError();
  @override
  Future<DeviceInfo> deviceInfo() => throw UnimplementedError();
  @override
  Future<LastAlarmInfo> lastAlarm() => throw UnimplementedError();
  @override
  Future<CameraStatus> readStatus() => throw UnimplementedError();
  @override
  void close() => throw UnimplementedError();
}

/// Remote/shared control through the cloud passthrough.
class CloudControl implements CameraControl {
  CloudControl({required CloudPassthrough passthrough, required IotThing thing});

  @override
  Future<bool> privacy() => throw UnimplementedError();
  @override
  Future<void> setPrivacy(bool on) => throw UnimplementedError();
  @override
  Future<void> ptzMove(int x, int y) => throw UnimplementedError();
  @override
  Future<void> ptzStop() => throw UnimplementedError();
  @override
  Future<DayNightMode> nightVision() => throw UnimplementedError();
  @override
  Future<void> setNightVision(DayNightMode mode) => throw UnimplementedError();
  @override
  Future<void> setSiren(bool on) => throw UnimplementedError();
  @override
  Future<void> rename(String name) => throw UnimplementedError();
  @override
  Future<DeviceInfo> deviceInfo() => throw UnimplementedError();
  @override
  Future<LastAlarmInfo> lastAlarm() => throw UnimplementedError();
  @override
  Future<CameraStatus> readStatus() => throw UnimplementedError();
  @override
  void close() => throw UnimplementedError();
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
  });

  /// Throws [CameraRouteError]: remote camera without cloud -> networkOnly;
  /// shared without cloud -> sharedCloudOnly; offline cloud camera -> cameraOffline.
  CameraControl controlFor(TapoCamera camera, {String? lat}) => throw UnimplementedError();

  /// Drops cached clients (all, or one camera).
  void invalidate([String? cameraId]) => throw UnimplementedError();
}