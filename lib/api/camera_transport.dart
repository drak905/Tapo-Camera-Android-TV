// Local HTTPS transport to a camera: headers, TOFU certificate pin,
// reconnect-once, one request at a time. Spec: hc.local.headers_tls.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'tapo_errors.dart';

/// Reply to one local request.
class ChannelResponse {
  const ChannelResponse(this.status, this.body, [this.headers = const {}]);
  final int status;
  final Uint8List body;
  final Map<String, String> headers;
}

/// What the control client needs from a transport (so tests can script one).
abstract class CameraChannel {
  /// POSTs [body] to [path] (`/` or `/stok=<stok>/ds`). Extra [headers] are
  /// merged over the standard camera headers.
  Future<ChannelResponse> post(
    String path,
    List<int> body, {
    Map<String, String> headers = const {},
  });
  void close();
}

/// Stores `sha256(DER)` of a camera leaf certificate per `host:port`.
abstract class PinStore {
  String? read(String hostPort);
  Future<void> write(String hostPort, String sha256Hex);
}

/// One physical connection (kept alive). The real one wraps `HttpClient` with
/// `badCertificateCallback` that only records the certificate.
abstract class CameraLink {
  /// DER bytes of the leaf certificate presented on connect.
  Uint8List get peerCertificateDer;

  /// Sends one request. Reset/EOF throws `SocketException`; a timeout throws
  /// `TimeoutException`.
  Future<ChannelResponse> send(
    String path,
    List<int> body,
    Map<String, String> headers, {
    required Duration timeout,
  });
  void close();
}

typedef CameraLinkFactory = Future<CameraLink> Function(String host, int port);

/// Real [CameraChannel]: pins on first contact (TOFU), raises
/// `CertificateMismatch` when the certificate changes, resends once after a
/// stale socket, never retries timeouts (10 s), serialises requests.
class CameraTransport implements CameraChannel {
  CameraTransport({
    required this.host,
    this.port = 443,
    required this.pins,
    required this.linkFactory,
    this.timeout = const Duration(seconds: 10),
  });

  final String host;
  final int port;
  final PinStore pins;
  final CameraLinkFactory linkFactory;
  final Duration timeout;

  CameraLink? _link;
  Future<void> _tail = Future<void>.value();
  bool _closed = false;

  String get _hostPort => '$host:$port';

  Map<String, String> get _standardHeaders => {
        'Accept': 'application/json',
        'User-Agent': 'Tapo CameraClient Android',
        'requestByApp': 'true',
        'Referer': 'https://$host:$port',
        'Content-Type': 'application/json; charset=UTF-8',
      };

  @override
  Future<ChannelResponse> post(
    String path,
    List<int> body, {
    Map<String, String> headers = const {},
  }) {
    final done = Completer<ChannelResponse>();
    final previous = _tail;
    _tail = done.future.then<void>((_) {}, onError: (Object _) {});
    previous.then((_) async {
      try {
        done.complete(await _post(path, body, headers));
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  Future<ChannelResponse> _post(String path, List<int> body, Map<String, String> extra) async {
    if (_closed) throw const SocketException('Connection closed');
    final headers = {..._standardHeaders, ...extra};
    for (var attempt = 1;; attempt++) {
      final link = await _connection();
      try {
        return await link.send(path, body, headers, timeout: timeout);
      } on TimeoutException {
        _drop();
        throw TapoTimeoutError('Request to the camera timed out');
      } on SocketException {
        _drop();
        if (attempt >= 2) rethrow;
      } on HandshakeException {
        _drop();
        if (attempt >= 2) rethrow;
      } on HttpException {
        _drop();
        if (attempt >= 2) rethrow;
      } catch (_) {
        _drop();
        rethrow;
      }
    }
  }

  Future<CameraLink> _connection() async {
    final existing = _link;
    if (existing != null) return existing;
    final CameraLink link;
    try {
      link = await linkFactory(host, port).timeout(timeout);
    } on TimeoutException {
      throw TapoTimeoutError('Connecting to the camera timed out');
    }
    final der = link.peerCertificateDer;
    if (der.isEmpty) {
      link.close();
      throw TapoProtocolError('The camera presented no TLS certificate');
    }
    final actual = sha256.convert(der).toString();
    final pinned = pins.read(_hostPort);
    if (pinned == null) {
      await pins.write(_hostPort, actual);
    } else if (pinned != actual) {
      link.close();
      throw CertificateMismatch('The camera certificate changed since first contact');
    }
    _link = link;
    return link;
  }

  void _drop() {
    final link = _link;
    _link = null;
    link?.close();
  }

  @override
  void close() {
    _closed = true;
    _drop();
  }
}

/// [CameraLink] over a `SecureSocket` that accepts the camera's self-signed
/// certificate and exposes it for pinning. Speaks plain HTTP/1.1 keep-alive.
class SocketCameraLink implements CameraLink {
  SocketCameraLink._(this._socket, this.peerCertificateDer, this._host, this._port) {
    _sub = _socket.listen(
      (chunk) {
        _incoming.add(chunk);
        _wake();
      },
      onError: (Object e) {
        _error = e;
        _wake();
      },
      onDone: () {
        _eof = true;
        _wake();
      },
      cancelOnError: false,
    );
  }

  /// Connects and records the leaf certificate. The caller decides trust by
  /// comparing the fingerprint with its pin (see [CameraTransport]).
  static Future<SocketCameraLink> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final socket = await SecureSocket.connect(
      host,
      port,
      timeout: timeout,
      onBadCertificate: (_) => true,
    );
    final cert = socket.peerCertificate;
    return SocketCameraLink._(socket, cert?.der ?? Uint8List(0), host, port);
  }

  final SecureSocket _socket;
  final String _host;
  final int _port;
  late final StreamSubscription<Uint8List> _sub;
  final BytesBuilder _incoming = BytesBuilder(copy: false);
  Uint8List _view = Uint8List(0);
  bool _eof = false;
  Object? _error;
  Completer<void>? _waiter;

  @override
  final Uint8List peerCertificateDer;

  void _wake() {
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> _more() async {
    if (_error != null) throw _error!;
    if (_eof) throw const SocketException('Connection closed by the camera');
    final w = _waiter = Completer<void>();
    await w.future;
    if (_error != null) throw _error!;
  }

  void _absorb() {
    if (_incoming.isEmpty) return;
    final merged = BytesBuilder(copy: false)
      ..add(_view)
      ..add(_incoming.takeBytes());
    _view = merged.takeBytes();
  }

  Future<Uint8List> _readUntilHeaderEnd() async {
    while (true) {
      _absorb();
      for (var i = 3; i < _view.length; i++) {
        if (_view[i] == 10 && _view[i - 1] == 13 && _view[i - 2] == 10 && _view[i - 3] == 13) {
          final head = Uint8List.fromList(Uint8List.sublistView(_view, 0, i + 1));
          _view = Uint8List.sublistView(_view, i + 1);
          return head;
        }
      }
      if (_view.length > 65536) throw const SocketException('Malformed HTTP reply');
      await _more();
    }
  }

  Future<Uint8List> _readExact(int n) async {
    while (true) {
      _absorb();
      if (_view.length >= n) {
        final out = Uint8List.fromList(Uint8List.sublistView(_view, 0, n));
        _view = Uint8List.sublistView(_view, n);
        return out;
      }
      await _more();
    }
  }

  Future<Uint8List> _readLine() async {
    while (true) {
      _absorb();
      for (var i = 1; i < _view.length; i++) {
        if (_view[i] == 10 && _view[i - 1] == 13) {
          final line = Uint8List.fromList(Uint8List.sublistView(_view, 0, i - 1));
          _view = Uint8List.sublistView(_view, i + 1);
          return line;
        }
      }
      await _more();
    }
  }

  @override
  Future<ChannelResponse> send(
    String path,
    List<int> body,
    Map<String, String> headers, {
    required Duration timeout,
  }) {
    final request = StringBuffer('POST $path HTTP/1.1\r\nHost: $_host:$_port\r\n');
    headers.forEach((k, v) => request.write('$k: $v\r\n'));
    request.write('Content-Length: ${body.length}\r\nConnection: keep-alive\r\n\r\n');
    return _exchange(request.toString(), body).timeout(timeout);
  }

  Future<ChannelResponse> _exchange(String head, List<int> body) async {
    _socket.add(ascii.encode(head));
    if (body.isNotEmpty) _socket.add(body);
    await _socket.flush();
    final headBytes = await _readUntilHeaderEnd();
    final lines = latin1.decode(headBytes).split('\r\n');
    final parts = lines.first.split(' ');
    final status = parts.length > 1 ? int.tryParse(parts[1]) : null;
    if (status == null) throw const SocketException('Malformed HTTP status line');
    final replyHeaders = <String, String>{};
    for (final line in lines.skip(1)) {
      final sep = line.indexOf(':');
      if (sep > 0) replyHeaders[line.substring(0, sep).trim()] = line.substring(sep + 1).trim();
    }
    String? header(String name) {
      for (final e in replyHeaders.entries) {
        if (e.key.toLowerCase() == name) return e.value;
      }
      return null;
    }

    final out = BytesBuilder(copy: false);
    final length = int.tryParse(header('content-length') ?? '');
    if ((header('transfer-encoding') ?? '').toLowerCase().contains('chunked')) {
      while (true) {
        final size = int.tryParse(latin1.decode(await _readLine()).split(';').first.trim(), radix: 16);
        if (size == null || size > 16 * 1024 * 1024) throw const SocketException('Malformed chunk');
        if (size == 0) {
          while ((await _readLine()).isNotEmpty) {}
          break;
        }
        out.add(await _readExact(size));
        await _readExact(2);
      }
    } else if (length != null) {
      if (length > 16 * 1024 * 1024) throw const SocketException('Reply too large');
      out.add(await _readExact(length));
    } else {
      // No framing: the reply ends with the connection.
      try {
        while (true) {
          await _more();
        }
      } on SocketException {
        _absorb();
        out.add(_view);
        _view = Uint8List(0);
      }
    }
    if ((header('connection') ?? '').toLowerCase() == 'close') {
      scheduleMicrotask(close);
    }
    return ChannelResponse(status, out.takeBytes(), replyHeaders);
  }

  @override
  void close() {
    _sub.cancel();
    _socket.destroy();
  }
}
