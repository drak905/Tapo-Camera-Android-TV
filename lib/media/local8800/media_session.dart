/// Local :8800 media session: Digest handshake, Key-Exchange, part stream.
library;

import 'dart:typed_data';

import '../media_deps.dart';
import '../media_transport.dart';
import '../multipart_reader.dart';
import '../part_decryptor.dart';
import 'stream_crypto.dart';

class MediaSession {
  MediaSession._();

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
  }) =>
      throw UnimplementedError();

  KeyExchange? get keyExchange => throw UnimplementedError();
  PartDecryptor get decryptor => throw UnimplementedError();

  /// Device parts, already decrypted (dropped parts are skipped).
  Stream<MultipartPart> get parts => throw UnimplementedError();

  /// Sends a JSON control part. Returns the seq used.
  Future<int> sendJson(String compactBody) => throw UnimplementedError();

  /// Sends raw client-part bytes (acks, heartbeats).
  void sendRaw(Uint8List bytes) => throw UnimplementedError();

  /// Session id learned from `params.session_id`, `result.session_id` or the
  /// `X-Session-Id` header; null until known.
  String? get sessionId => throw UnimplementedError();

  Future<void> close() => throw UnimplementedError();
}
