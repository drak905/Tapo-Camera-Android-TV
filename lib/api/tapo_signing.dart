// Cloud request signing: Content-MD5 + X-Authorization (HMAC-SHA1).
// Spec: hc.cloud.signing. IoT calls (services-sync, /v2/things) are NOT signed.

/// Headers produced by [signCloudRequest].
class SignedCloudHeaders {
  const SignedCloudHeaders({
    required this.contentMd5,
    required this.signature,
    required this.xAuthorization,
  });

  /// base64(MD5(body)); an empty body is hashed (and must be sent) as `{}`.
  final String contentMd5;

  /// Lower-case hex HMAC-SHA1 of `md5 LF 9999999999 LF nonce LF path`.
  final String signature;

  /// `Timestamp=9999999999, Nonce=<uuid>, AccessKey=<AK>, Signature=<hex>`.
  final String xAuthorization;
}

/// base64(MD5(body)); an empty [body] hashes the two bytes `{}`.
String cloudContentMd5(List<int> body) => throw UnimplementedError();

/// Signs a cloud account request. Only `url.path` (percent-encoded, with any
/// regional prefix) enters the signature, never the query or the host.
/// [nonce] defaults to a random lower-case uuid v4.
SignedCloudHeaders signCloudRequest({
  required List<int> body,
  required Uri url,
  String? nonce,
  String? accessKey,
  String? secretKey,
}) =>
    throw UnimplementedError();