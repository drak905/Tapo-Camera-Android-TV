/// Local :8800 media session: Digest handshake, Key-Exchange, part stream.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../client_parts.dart';
import '../digest.dart';
import '../head_reader.dart';
import '../media_deps.dart';
import '../media_errors.dart';
import '../media_transport.dart';
import '../multipart_reader.dart';
import '../part_decryptor.dart';
import 'stream_crypto.dart';

class MediaSession {
  MediaSession._(this._transport, this._input, this._decryptor, this.keyExchange);

  /// A session over an already open tunnel (relay): no `POST /stream`, no
  /// Digest. [input] carries only bytes after the tunnel head.
  factory MediaSession.overTunnel(
    MediaTransport transport,
    Stream<Uint8List> input, {
    PartDecryptor decryptor = const PassthroughDecryptor(),
  }) =>
      MediaSession._(transport, input, decryptor, null);

  final MediaTransport _transport;
  final Stream<Uint8List> _input;
  final PartDecryptor _decryptor;
  final ClientPartWriter _writer = ClientPartWriter();
  bool _closed = false;
  bool _partsTaken = false;

  static const _boundaryLine = 'Content-Type: multipart/mixed; boundary=--client-stream-boundary--';

  /// Opens TCP to host:port (NODELAY) and sends `POST /stream HTTP/1.1` with
  /// headers in the order Host, Content-Type (multipart/mixed;
  /// boundary=--client-stream-boundary--), Connection: keep-alive,
  /// Content-Length: 0, X-Key-Exchange: 1 (then Authorization on the retry).
  ///
  /// 401: parse WWW-Authenticate, reopen the socket when the response says
  /// `Connection: close`, retry once with Digest. A second 401 throws
  /// `MediaAuthException` without a third attempt (lockout rule). HTTP 503 or
  /// error -52407 throws `StreamLimitException`. After 200 the `Key-Exchange`
  /// header selects the part decryptor (MD5 or HKDF).
  static Future<MediaSession> connect({
    required String host,
    int port = 8800,
    required LocalMediaAuth auth,
    required TransportConnector connector,
    Duration timeout = const Duration(seconds: 10),
    String Function()? cnonce,
  }) async {
    final baseHead = 'POST /stream HTTP/1.1\r\n'
        'Host: $host:$port\r\n'
        '$_boundaryLine\r\n'
        'Connection: keep-alive\r\n'
        'Content-Length: 0\r\n'
        'X-Key-Exchange: 1';

    var transport = await connector(host, port, tls: false, timeout: timeout);
    var reader = HeadReader(transport.input);
    try {
      transport.add(latin1.encode('$baseHead\r\n\r\n'));
      var head = await reader.readHead(timeout: timeout);
      var body = await _readBody(reader, head, timeout);
      String? encryptType;

      if (head.status == 401) {
        final DigestChallenge challenge;
        try {
          challenge = DigestChallenge.parse(head.headers['www-authenticate'] ?? '');
        } on FormatException {
          throw const MediaAuthException('camera sent no usable Digest challenge');
        }
        encryptType = challenge.encryptType;
        if ((head.headers['connection'] ?? '').toLowerCase() == 'close') {
          await reader.dispose();
          await transport.close();
          transport = await connector(host, port, tls: false, timeout: timeout);
          reader = HeadReader(transport.input);
        }
        final authorization = buildDigestAuthorization(
          challenge,
          secret: auth.digestSecret,
          cnonce: (cnonce ?? generateCnonce)(),
          username: auth.username,
        );
        transport.add(latin1.encode('$baseHead\r\nAuthorization: $authorization\r\n\r\n'));
        head = await reader.readHead(timeout: timeout);
        body = await _readBody(reader, head, timeout);
        if (head.status == 401) {
          throw const MediaAuthException('camera rejected the credentials');
        }
      }
      final code = _errorCode(body);
      if (head.status == 503 || code == -52407) {
        throw StreamLimitException('camera refused another media session (HTTP ${head.status})',
            errorCode: code ?? -52407);
      }
      if (head.status != 200) {
        throw MediaException('camera answered the media request with HTTP ${head.status}');
      }

      KeyExchange? ke;
      PartDecryptor decryptor = const PassthroughDecryptor();
      final header = head.headers['key-exchange'];
      if (header != null && header.trim().isNotEmpty) {
        try {
          ke = KeyExchange.parse(header);
        } on FormatException {
          throw const MediaException('camera sent an invalid Key-Exchange header');
        }
        // Windows `_setup_encryption`: both key schedules use the password
        // transformed with the challenge's encrypt_type.
        if (ke.isHkdf) {
          decryptor = HkdfPartDecryptor(
              deriveHkdfKeys(ke, plainSecret: auth.digestSecret, encryptType: encryptType));
        } else {
          final keys = deriveMd5Keys(
              username: ke.username, nonce: ke.nonce, plainPassword: auth.digestSecret, encryptType: encryptType);
          if (keys == null) throw const MediaException('camera uses a key exchange user that is not supported');
          decryptor = Md5PartDecryptor(keys);
        }
      }
      return MediaSession._(transport, reader.takeRest(), decryptor, ke);
    } catch (_) {
      await reader.dispose();
      await transport.close();
      rethrow;
    }
  }

  /// Body of a non-200 answer (a 200 starts the multipart stream).
  static Future<Uint8List> _readBody(HeadReader reader, HttpHead head, Duration timeout) async {
    final n = head.contentLength;
    if (head.status == 200 || n <= 0) return Uint8List(0);
    return reader.readBytes(n > 65536 ? 65536 : n, timeout: timeout);
  }

  static int? _errorCode(Uint8List body) {
    if (body.isEmpty) return null;
    try {
      final v = jsonDecode(utf8.decode(body, allowMalformed: true));
      if (v is Map) return int.tryParse('${v['error_code'] ?? ''}');
    } catch (_) {}
    return null;
  }

  final KeyExchange? keyExchange;
  PartDecryptor get decryptor => _decryptor;

  String? _sessionId;

  /// Device parts, already decrypted (dropped parts are skipped).
  Stream<MultipartPart> get parts {
    if (_partsTaken) throw StateError('parts is a single-subscription stream');
    _partsTaken = true;
    return _decode();
  }

  Stream<MultipartPart> _decode() {
    final reader = MultipartReader();
    StreamSubscription<Uint8List>? sub;
    late final StreamController<MultipartPart> out;
    out = StreamController<MultipartPart>(
      onListen: () {
        sub = _input.listen(
          (chunk) {
            try {
              for (final part in reader.add(chunk)) {
                MultipartPart p = part;
                if (!part.isJson) {
                  final body = _decryptor.decrypt(part);
                  if (body == null) continue;
                  p = MultipartPart(part.headers, body);
                }
                _remember(p);
                out.add(p);
              }
            } catch (e, s) {
              out.addError(e, s);
              sub?.cancel();
              out.close();
            }
          },
          onError: out.addError,
          onDone: out.close,
        );
      },
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () {
        unawaited(sub?.cancel());
      },
    );
    return out.stream;
  }
  void _remember(MultipartPart part) {
    if (_sessionId != null) return;
    if (part.isJson) {
      try {
        final msg = jsonDecode(utf8.decode(part.body));
        if (msg is Map) {
          for (final key in const ['result', 'params']) {
            final inner = msg[key];
            if (inner is Map) {
              final sid = inner['session_id'];
              final code = inner['error_code'] ?? 0;
              if (sid != null && sid is! bool && '$sid'.isNotEmpty && (code == 0 || code == '0')) {
                _setSession('$sid');
                return;
              }
            }
          }
        }
      } catch (_) {}
    }
    final header = part.header('X-Session-Id');
    if (header != null && header.trim().isNotEmpty) _setSession(header.trim());
  }

  void _setSession(String id) {
    _sessionId = id;
    _writer.sessionId = id;
  }

  /// Next request sequence number (1, 2, ...).
  int nextSeq() => _writer.nextSeq();

  /// Sends a JSON control part. Returns the seq used: the body's own `seq`,
  /// or a new one appended after the existing keys (as the Windows app does).
  Future<int> sendJson(String compactBody) async {
    var body = compactBody;
    int seq;
    try {
      final decoded = jsonDecode(compactBody);
      if (decoded is Map<String, dynamic> && decoded['seq'] is int) {
        seq = decoded['seq'] as int;
      } else if (decoded is Map<String, dynamic>) {
        seq = _writer.nextSeq();
        body = compactJson({...decoded, 'seq': seq});
      } else {
        seq = _writer.nextSeq();
      }
    } on FormatException {
      seq = _writer.nextSeq();
    }
    sendRaw(_writer.json(body));
    return seq;
  }

  /// Sends raw client-part bytes (acks, heartbeats).
  void sendRaw(Uint8List bytes) {
    if (_closed) return;
    _transport.add(bytes);
  }

  /// Ack part for the current session.
  Uint8List ackPart(int received) => _writer.ack(received);

  /// Heartbeat part (the app sends it without a session id header).
  Uint8List heartbeatPart() => encodeClientPart(utf8.encode(kHeartbeatBody));

  /// Session id learned from `params.session_id`, `result.session_id` or the
  /// `X-Session-Id` header; null until known.
  String? get sessionId => _sessionId;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _transport.close();
  }
}
