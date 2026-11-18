/// HTTP Digest (RFC 7616) for the local :8800 media port.
library;

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
  factory DigestChallenge.parse(String header) => throw UnimplementedError();
}

/// `UPPER_HEX(SHA256(secret))` when [encryptType] is `3`, else
/// `UPPER_HEX(MD5(secret))`. An empty [secret] means [kDefaultMediaPassword].
String digestSecret(String secret, {String? encryptType}) => throw UnimplementedError();

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
}) =>
    throw UnimplementedError();

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
}) =>
    throw UnimplementedError();

/// 16 chars, alternating random lower-case letter and digit (`a1b2c3...`).
String generateCnonce() => throw UnimplementedError();
