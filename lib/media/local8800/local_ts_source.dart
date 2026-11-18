/// Live preview over the local :8800 media port as plain MPEG-TS.
library;

import 'dart:typed_data';

import '../client_parts.dart';
import '../media_deps.dart';
import '../media_source.dart';
import '../media_transport.dart';
import '../preview_stream.dart';
import '../stream_limiter.dart';
import 'media_session.dart';

class LocalTsSource implements MediaSource {
  LocalTsSource({
    required this.host,
    this.port = 8800,
    required this.auth,
    required this.connector,
    this.resolution = 'VGA',
    this.limiter,
    this.limiterKey,
    this.startGate,
    this.stopLinger = const Duration(milliseconds: 150),
    this.ackEvery = 25,
  });

  final String host;
  final int port;
  final LocalMediaAuth auth;
  final TransportConnector connector;

  /// `HD` (main stream) or `VGA` (minor stream).
  final String resolution;

  /// When set, one lease is acquired (key [limiterKey], default [host])
  /// before any socket is opened and released when the stream ends.
  final StreamLimiter? limiter;
  final String? limiterKey;

  /// StreamQueue slot: the handshake (Digest) starts only after this completes.
  final Future<void>? startGate;

  /// Wait between the stop request and closing the socket.
  final Duration stopLinger;

  /// Ack every Nth `X-Data-Sequence` (25), only with a session id.
  final int ackEvery;

  PreviewStream? _run;

  /// Session id once the camera has sent one (params.session_id,
  /// result.session_id or X-Session-Id).
  String? get sessionId => _run?.session?.sessionId;

  /// Flow: gate, limiter, handshake, preview request (seq 1), wait for the
  /// matching response (error codes -52407/-52405/-52419/-52435 throw
  /// `StreamLimitException`, other non-zero `StreamRefusedException`; neither
  /// is retried), replay up to 8 early video parts, then forward video parts
  /// only (JSON and audio are never forwarded). Cancelling sends the stop
  /// request (only with a session id), waits [stopLinger], then closes.
  @override
  Stream<Uint8List> openTs() => PreviewStream.open(
        openSession: () => MediaSession.connect(host: host, port: port, auth: auth, connector: connector),
        requestBody: (seq) => previewRequestJson(resolution, seq: seq),
        limiter: limiter,
        limiterKey: limiterKey ?? host,
        startGate: startGate,
        stopLinger: stopLinger,
        ackEvery: ackEvery,
        onCreate: (run) => _run = run,
      );
}
