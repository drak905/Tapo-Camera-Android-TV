library;

import 'dart:typed_data';

/// One camera byte source (local :8800, relay, VOD, RTSP bridge) that yields
/// plain MPEG-TS for ExoPlayer. The RelayBridge forwards exactly what
/// [openTs] emits as `video/mp2t`.
abstract class MediaSource {
  /// Starts the source and emits plain TS bytes. Single subscription.
  ///
  /// Errors are typed (`media_errors.dart`); the first byte only arrives after
  /// handshake and camera acceptance. Cancelling the subscription ends the
  /// session politely (stop request, linger, then close).
  Stream<Uint8List> openTs();
}
