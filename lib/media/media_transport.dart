/// Byte transport under every media protocol, so the protocols can be tested
/// against in-memory fakes and run over TCP / TLS on a TV.
library;

import 'dart:async';
import 'dart:io';
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

/// Trust store for relay TLS. The app sets this once at start-up to a context
/// that adds the TP-Link roots (`TapoCloud.buildContext`); null uses the
/// platform defaults.
SecurityContext? mediaTlsContext;

class _SocketTransport implements MediaTransport {
  _SocketTransport(this._socket) {
    // Write errors after a peer reset are reported on `done`; without a
    // handler they become uncaught zone errors (Windows 10053/10054). The
    // read side ([input]) already carries the failure to the protocol code.
    _socket.done.ignore();
  }
  final Socket _socket;
  bool _closed = false;

  @override
  Stream<Uint8List> get input => _socket;

  @override
  void add(List<int> data) {
    if (_closed) return;
    try {
      _socket.add(data);
    } on StateError {
      // sink already closed by a peer reset; the input side reports it
    }
  }

  @override
  Future<void> flush() async {
    if (_closed) return;
    try {
      await _socket.flush();
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _socket.close().timeout(const Duration(seconds: 1));
    } catch (_) {}
    _socket.destroy();
  }
}

/// Real TCP/TLS connector (`dart:io` Socket / SecureSocket). TLS verification
/// (chain and hostname = [serverName] or [host]) is always on; [context] is
/// the trust store (null: [mediaTlsContext], then the platform roots).
Future<MediaTransport> connectSocketTransport(
  String host,
  int port, {
  bool tls = false,
  String? serverName,
  Duration? timeout,
  SecurityContext? context,
  Duration? connectTimeout,
}) async {
  final Socket raw =
      await Socket.connect(host, port, timeout: connectTimeout ?? timeout ?? const Duration(seconds: 10));
  raw.setOption(SocketOption.tcpNoDelay, true);
  if (!tls) return _SocketTransport(raw);
  try {
    final secure = await SecureSocket.secure(
      raw,
      host: serverName ?? host,
      context: context ?? mediaTlsContext,
    ).timeout(timeout ?? const Duration(seconds: 10));
    return _SocketTransport(secure);
  } catch (_) {
    raw.destroy();
    rethrow;
  }
}

/// A [TransportConnector] over [connectSocketTransport] bound to a trust
/// store. Relay TLS uses [context] = `TapoCloud.buildContext` (system roots
/// plus the TP-Link roots). [maxConnect] caps the TCP connect wait (the local
/// :8800 probe uses about 1.2 s so a failover stays under 2.5 s).
TransportConnector socketConnector({SecurityContext? context, Duration? maxConnect}) =>
    (String host, int port, {bool tls = false, String? serverName, Duration? timeout}) {
      var wait = timeout;
      if (maxConnect != null && (wait == null || maxConnect < wait)) wait = maxConnect;
      return connectSocketTransport(host, port,
          tls: tls, serverName: serverName, timeout: timeout, connectTimeout: wait, context: context);
    };
