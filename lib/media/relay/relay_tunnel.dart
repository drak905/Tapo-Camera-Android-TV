/// Relay tunnel: one never-ending TLS POST carrying multipart both ways.
library;

import 'dart:typed_data';

import '../media_transport.dart';
import 'relay_slot.dart';

/// The tunnel head in the exact app order: request line `POST path&retryTime=0
/// HTTP/1.1` (`?` when the path has no query), User-Agent
/// `Client=TP-Link_Tapo_Android Android <ver>/1.3`, Keep-Relay 3600, Accept,
/// Content-Type multipart/mixed;boundary=--client-stream-boundary--, Host,
/// Content-Length 9223372036854775807, X-token, X-Client-Model, X-Client-UUID,
/// X-Track-Id, X-Redirect-Times, X-Pull-Mode 2, [Cookie], X-Version 2.0,
/// X-Arrive-Latency. CRLF line ends and a blank line.
Uint8List buildTunnelRequest(
  RelaySlot slot, {
  required String clientModel,
  required String terminalUuid,
  required String appVersion,
  int redirectTimes = 0,
  int arriveLatencyMs = 0,
}) =>
    throw UnimplementedError();

/// An open tunnel: [input] carries only bytes after the 200 head.
class RelayTunnelConnection {
  const RelayTunnelConnection(this.transport, this.input, this.slot, this.redirectTimes);
  final MediaTransport transport;
  final Stream<Uint8List> input;
  final RelaySlot slot;
  final int redirectTimes;
}

class RelayTunnel {
  /// TLS to relayIp:443 (fallback relay host; SNI = relay host), sends
  /// [buildTunnelRequest], reads the response head byte by byte so nothing
  /// after a 200 is consumed. 200 returns the raw tunnel. 304: the body is a
  /// RequestUrlResult; reconnect with X-Redirect-Times + 1 (at most 3
  /// redirects, then `RelayException`). Other statuses throw `RelayException`
  /// from errorCode/closeReason (400 errorCode 3 is fatal illegal_request).
  static Future<RelayTunnelConnection> open(
    RelaySlot slot, {
    required TransportConnector connector,
    required String clientModel,
    required String terminalUuid,
    required String appVersion,
    int maxRedirects = 3,
  }) =>
      throw UnimplementedError();
}
