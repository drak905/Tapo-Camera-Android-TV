/// Relay tunnel: one never-ending TLS POST carrying multipart both ways.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../head_reader.dart';
import '../media_errors.dart';
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
}) {
  final sep = slot.relayPath.contains('?') ? '&' : '?';
  final lines = <String>[
    'POST ${slot.relayPath}${sep}retryTime=0 HTTP/1.1',
    'User-Agent: Client=TP-Link_Tapo_Android Android $appVersion/1.3',
    'Keep-Relay: 3600',
    'Accept: */*',
    'Content-Type: multipart/mixed;boundary=--client-stream-boundary--',
    'Host: ${slot.relayHost}',
    'Content-Length: 9223372036854775807',
    'X-token: ${slot.token}',
    'X-Client-Model: $clientModel',
    'X-Client-UUID: $terminalUuid',
    'X-Track-Id: ${slot.trackId}',
    'X-Redirect-Times: $redirectTimes',
    'X-Pull-Mode: 2',
    if (slot.elbCookie.isNotEmpty) 'Cookie: ${slot.elbCookie}',
    'X-Version: 2.0',
    'X-Arrive-Latency: ${arriveLatencyMs < 0 ? 0 : arriveLatencyMs}',
  ];
  for (final line in lines) {
    if (line.contains('\r') || line.contains('\n') || line.contains('\x00')) {
      throw const RelayException('The TP-Link cloud returned an invalid relay slot.');
    }
  }
  return Uint8List.fromList(latin1.encode('${lines.join('\r\n')}\r\n\r\n'));
}

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
    Duration timeout = const Duration(seconds: 15),
  }) async {
    var current = slot;
    for (var redirects = 0; redirects <= maxRedirects; redirects++) {
      final started = DateTime.now();
      final transport = await connector(
        current.relayIp.isEmpty ? current.relayHost : current.relayIp,
        current.relayPort,
        tls: true,
        serverName: current.relayHost,
        timeout: timeout,
      );
      final latency = DateTime.now().difference(started).inMilliseconds;
      final reader = HeadReader(transport.input);
      try {
        transport.add(buildTunnelRequest(
          current,
          clientModel: clientModel,
          terminalUuid: terminalUuid,
          appVersion: appVersion,
          redirectTimes: redirects,
          arriveLatencyMs: latency,
        ));
        final head = await reader.readHead(timeout: timeout);
        if (head.status == 200) {
          return RelayTunnelConnection(transport, reader.takeRest(), current, redirects);
        }
        final want = head.contentLength > 65536 ? 65536 : head.contentLength;
        final bodyBytes = want > 0 ? await reader.readBytes(want, timeout: timeout) : Uint8List(0);
        await reader.dispose();
        await transport.close();
        Map<String, dynamic> reply = {};
        try {
          final v = jsonDecode(utf8.decode(bodyBytes));
          if (v is Map<String, dynamic>) reply = v;
        } catch (_) {}
        if (head.status == 304) {
          final result = reply['result'];
          current = RelaySlot.fromResult(
            result is Map<String, dynamic> ? result : reply,
            deviceId: slot.deviceId,
            trackId: slot.trackId,
            resolution: slot.resolution,
          );
          continue;
        }
        final rawCode = reply['errorCode'];
        final code = rawCode == null ? null : int.tryParse('$rawCode');
        final reason = '${reply['closeReason'] ?? reply['msg'] ?? ''}';
        throw relayErrorFor(code ?? head.status,
            detail: reason.length > 120 ? reason.substring(0, 120) : reason);
      } catch (_) {
        await reader.dispose();
        await transport.close();
        rethrow;
      }
    }
    throw RelayException('The TP-Link relay redirected more than $maxRedirects times.');
  }
}
