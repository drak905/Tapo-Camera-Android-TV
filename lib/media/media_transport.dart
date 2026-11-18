/// Byte transport under every media protocol, so the protocols can be tested
/// against in-memory fakes and run over TCP / TLS on a TV.
library;

import 'dart:typed_data';

abstract class MediaTransport {
  /// Bytes from the peer (single subscription). Ends when the peer closes.
  Stream<Uint8List> get input;

  /// Queues [data] for sending. Writes from one isolate stay in order.
  void add(List<int> data);

  Future<void> flush();

  /// Closes both directions. Idempotent.
  Future<void> close();
}

/// Opens a transport. [tls] true: TLS with SNI and hostname check =
/// [serverName] (default [host]). TCP_NODELAY is always set.
typedef TransportConnector = Future<MediaTransport> Function(
  String host,
  int port, {
  bool tls,
  String? serverName,
  Duration? timeout,
});

/// Real TCP/TLS connector (`dart:io` Socket / SecureSocket).
Future<MediaTransport> connectSocketTransport(
  String host,
  int port, {
  bool tls = false,
  String? serverName,
  Duration? timeout,
}) =>
    throw UnimplementedError();
