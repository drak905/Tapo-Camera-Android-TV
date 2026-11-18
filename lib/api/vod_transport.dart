// The one definition of the SD-playback transport choice, re-exported by
// vod_client.dart (search side, TapoCamera) and vod_session.dart (playback
// side, role number + LAN flag). Spec: vod.transport.routing.

/// Which path an SD playback takes; [none] when no path works.
enum VodTransportKind { local, relay, none }

/// Why playback is impossible.
enum VodFailReason { notOnThisNetwork, cameraOffline, sharedCameraCloudOnly }

const String kReasonNotOnNetwork = 'not on this network';
const String kReasonCameraOffline = 'camera offline';
const String kReasonSharedCloudOnly = 'shared camera cloud only';

class VodTransportChoice {
  const VodTransportChoice.use(this.kind) : failure = null;
  const VodTransportChoice.failed(VodFailReason this.failure) : kind = VodTransportKind.none;

  final VodTransportKind kind;

  /// Set when [kind] is [VodTransportKind.none].
  final VodFailReason? failure;

  /// [failure] as text: `not on this network`, `camera offline` or `shared
  /// camera cloud only`; null on success.
  String? get failReason => switch (failure) {
        null => null,
        VodFailReason.notOnThisNetwork => kReasonNotOnNetwork,
        VodFailReason.cameraOffline => kReasonCameraOffline,
        VodFailReason.sharedCameraCloudOnly => kReasonSharedCloudOnly,
      };
}
