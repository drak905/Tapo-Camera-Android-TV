/// HTTP Digest (RFC 7616) for the local :8800 media port.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Default media password when no secret is known.
const String kDefaultMediaPassword = 'TPL075526460603';

/// Parsed `WWW-Authenticate: Digest ...` challenge.
class DigestChallenge {
  const DigestChallenge({
    required this.realm,
    required this.nonce,
    this.qop = 'auth',
    this.opaque = '',
    this.algorithm = 'MD5',
    this.encryptType,
    this.userhash = false,
  });

  final String realm;
  final String nonce;
  final String qop;
  final String opaque;
  final String algorithm;
  final String? encryptType;
  final bool userhash;

  /// Parses a `WWW-Authenticate` header value (realm, qop, nonce, opaque,
  /// algorithm, encrypt_type, userhash). Throws [FormatException] without nonce.
  factory DigestChallenge.parse(String header) {
    var text = header.trim();
    if (text.toLowerCase().startsWith('digest')) text = text.substring(6);
    final fields = <String, String>{};
    final re = RegExp(r'([A-Za-z_][\w-]*)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^\s,]*))');
    for (final m in re.allMatches(text)) {
      fields[m[1]!.toLowerCase()] = m[2] ?? m[3] ?? '';
    }
    final nonce = fields['nonce'];
    if (nonce == null || nonce.isEmpty) {
      throw const FormatException('Digest challenge without nonce');
    }
    return DigestChallenge(
      realm: fields['realm'] ?? '',
      nonce: nonce,
      qop: fields['qop'] ?? 'auth',
      opaque: fields['opaque'] ?? '',
      algorithm: fields['algorithm'] ?? 'MD5',
      encryptType: fields['encrypt_type'],
      userhash: (fields['userhash'] ?? '').toLowerCase() == 'true',
    );
  }
}

String _upperHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

/// `UPPER_HEX(SHA256(secret))` when [encryptType] is `3`, else
/// `UPPER_HEX(MD5(secret))`. An empty [secret] means [kDefaultMediaPassword].
String digestSecret(String secret, {String? encryptType}) {
  final bytes = utf8.encode(secret.isEmpty ? kDefaultMediaPassword : secret);
  return _upperHex(encryptType == '3' ? sha256.convert(bytes).bytes : md5.convert(bytes).bytes);
}

/// RFC 7616 response in lower-case hex. [password] is used as-is.
/// [algorithm]: MD5, SHA-256 and their `-sess` variants.
String digestResponse({
  required String username,
  required String realm,
  required String password,
  required String method,
  required String uri,
  required String nonce,
  required String nc,
  required String cnonce,
  required String qop,
  String algorithm = 'MD5',
}) {
  final upper = algorithm.toUpperCase();
  final isSha = upper.startsWith('SHA-256');
  String h(String s) => (isSha ? sha256 : md5).convert(utf8.encode(s)).toString();
  var ha1 = h('$username:$realm:$password');
  if (upper.endsWith('-SESS')) ha1 = h('$ha1:$nonce:$cnonce');
  final ha2 = h('$method:$uri');
  final firstQop = qop.split(',').first.trim();
  if (firstQop.isEmpty) return h('$ha1:$nonce:$ha2');
  return h('$ha1:$nonce:$nc:$cnonce:$firstQop:$ha2');
}

/// `Authorization` value for `POST /stream`: `Digest username="admin",
/// realm="..",uri="/stream",algorithm=MD5,nonce="..",nc=00000001,cnonce="..",
/// qop=auth,response="..",opaque=".."` (no spaces between fields).
/// [secret] is the plain secret; it is transformed with [digestSecret].
String buildDigestAuthorization(
  DigestChallenge challenge, {
  required String secret,
  required String cnonce,
  String username = 'admin',
  String uri = '/stream',
  String method = 'POST',
}) {
  const counter = '00000001';
  final qop = challenge.qop.split(',').first.trim();
  final response = digestResponse(
    username: username,
    realm: challenge.realm,
    password: digestSecret(secret, encryptType: challenge.encryptType),
    method: method,
    uri: uri,
    nonce: challenge.nonce,
    nc: counter,
    cnonce: cnonce,
    qop: qop,
    algorithm: challenge.algorithm,
  );
  return 'Digest username="$username",realm="${challenge.realm}",uri="$uri",'
      'algorithm=${challenge.algorithm},nonce="${challenge.nonce}",nc=$counter,'
      'cnonce="$cnonce",qop=$qop,response="$response",opaque="${challenge.opaque}"';
}

/// 16 chars, alternating random lower-case letter and digit (`a1b2c3...`).
String generateCnonce() {
  final rng = Random.secure();
  final sb = StringBuffer();
  for (var i = 0; i < 8; i++) {
    sb
      ..writeCharCode(0x61 + rng.nextInt(26))
      ..writeCharCode(0x30 + rng.nextInt(10));
  }
  return sb.toString();
}
