// Cloud request signing: Content-MD5 + X-Authorization (HMAC-SHA1).
// Spec: hc.cloud.signing. IoT calls (services-sync, /v2/things) are NOT signed.

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

// App-level credentials of the Tapo Android client (production APK constants).
// They identify the client application, not the user's account.
const cloudAccessKey = '4d11b6b9d5ea4d19a829adbb9714b057';
const cloudSecretKey = '6ed7d97f3e73467f8a5bab90b577ba4c';
const cloudTimestamp = '9999999999';

/// Random lower-case uuid v4.
String randomUuidV4([Random? rng]) {
  final r = rng ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

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
String cloudContentMd5(List<int> body) =>
    base64.encode(md5.convert(body.isEmpty ? const [0x7B, 0x7D] : body).bytes);

/// Signs a cloud account request. Only `url.path` (percent-encoded, with any
/// regional prefix) enters the signature, never the query or the host.
/// [nonce] defaults to a random lower-case uuid v4.
SignedCloudHeaders signCloudRequest({
  required List<int> body,
  required Uri url,
  String? nonce,
  String? accessKey,
  String? secretKey,
}) {
  final md5Value = cloudContentMd5(body);
  final n = nonce ?? randomUuidV4();
  final toSign = '$md5Value\n$cloudTimestamp\n$n\n${url.path}';
  final signature = Hmac(sha1, utf8.encode(secretKey ?? cloudSecretKey))
      .convert(utf8.encode(toSign))
      .toString();
  return SignedCloudHeaders(
    contentMd5: md5Value,
    signature: signature,
    xAuthorization: 'Timestamp=$cloudTimestamp, Nonce=$n, '
        'AccessKey=${accessKey ?? cloudAccessKey}, Signature=$signature',
  );
}
