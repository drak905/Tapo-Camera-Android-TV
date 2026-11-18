/// UI-side view of a camera. The api lane produces these from its own
/// camera model (lib/api/camera_router.dart); the UI only reads this.
library;

/// Which control path the network lane chose for a camera.
/// `local` = found on the LAN and owned; `cloud` = relay/passthrough
/// (also every shared camera).
enum CameraRoute { local, cloud }

/// Optional features a camera may offer. Entries for a missing capability
/// are hidden in the quick actions and the live controls.
enum CameraCapability { nightVision, siren, sdCard }

/// Day/night (IR) setting: Auto, Night vision (IR on), Day mode (IR off).
enum DayNightMode { auto, on, off }

class CameraViewModel {
  const CameraViewModel({
    required this.id,
    required this.displayName,
    required this.model,
    this.isShared = false,
    this.online = true,
    this.route = CameraRoute.cloud,
    this.capabilities = const {},
    this.thumbnail,
    this.localName,
  });

  final String id;

  /// Resolved name: local display name, else pending name, else cloud alias.
  final String displayName;
  final String model;

  /// Thing role != 0 (shared with this account); never logged in locally.
  final bool isShared;

  /// Cloud thing status == 1, or found on the LAN.
  final bool online;
  final CameraRoute route;
  final Set<CameraCapability> capabilities;

  /// Path of the last picture, if any.
  final String? thumbnail;

  /// Local display name set on this TV (shared cameras), if any.
  final String? localName;

  CameraViewModel copyWith({String? displayName, String? localName, bool clearLocalName = false}) => CameraViewModel(
        id: id,
        displayName: displayName ?? this.displayName,
        model: model,
        isShared: isShared,
        online: online,
        route: route,
        capabilities: capabilities,
        thumbnail: thumbnail,
        localName: clearLocalName ? null : (localName ?? this.localName),
      );
}