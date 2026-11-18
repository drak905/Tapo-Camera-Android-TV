/// Live preview through the cloud relay as plain MPEG-TS.
library;

import 'dart:typed_data';

import '../media_deps.dart';
import '../media_source.dart';
import '../media_transport.dart';
import '../stream_limiter.dart';

class RelayTsSource implements MediaSource {
  RelayTsSource({
    required this.deviceId,
    required this.auth,
    required this.connector,
    this.resolution = 'VGA',
    this.cloudType = 2,
    this.limiter,
    this.startGate,
    this.heartbeatInterval = const Duration(seconds: 15),
    this.stopLinger = const Duration(milliseconds: 150),
    this.ackEvery = 25,
  });

  final String deviceId;
  final CloudRelayAuth auth;
  final TransportConnector connector;
  final String resolution;
  final int cloudType;

  /// Keyed by [deviceId]; the lease is released when the stream ends.
  final StreamLimiter? limiter;

  /// StreamQueue slot: the slot request starts only after this completes.
  final Future<void>? startGate;

  /// Heartbeat part every [heartbeatInterval] (15 s) on the tunnel.
  final Duration heartbeatInterval;
  final Duration stopLinger;
  final int ackEvery;

  /// Flow: gate, limiter, fresh slot (relayToken is single use), tunnel (no
  /// inner `POST /stream`, no Digest), preview request written first, then
  /// heartbeats. Only video parts are forwarded; acks follow the LAN rule.
  /// A part with `X-If-Encrypt: 1` throws `EncryptedRelayMediaException`.
  /// Fatal relay errors (-1007 etc.) end the stream without reconnect.
  /// Cancelling sends the stop request, waits [stopLinger], then closes.
  @override
  Stream<Uint8List> openTs() => throw UnimplementedError();
}
