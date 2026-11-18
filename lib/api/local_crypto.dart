// Secure login (encrypt_type 3) primitives and the secure-passthrough
// envelope. Spec: hc.local.v3_hashes, hc.local.v3_session. All hex is UPPER
// case unless stated. Nothing here may log a secret.

import 'dart:math';
import 'dart:typed_data';

/// Upper-case hex SHA-256 over UTF-8.
String sha256Upper(String text) => throw UnimplementedError();

/// Upper-case hex MD5 over UTF-8.
String md5Upper(String text) => throw UnimplementedError();

/// 8 random bytes as 16 upper-case hex chars.
String generateCnonce([Random? rng]) => throw UnimplementedError();

/// `SHA256U(cnonce + SHA256U(secret) + nonce)`.
String v3FirstHash({required String secret, required String cnonce, required String nonce}) =>
    throw UnimplementedError();

/// What the camera must answer in `device_confirm`: `first_hash + nonce + cnonce`.
String v3ExpectedDeviceConfirm({
  required String secret,
  required String cnonce,
  required String nonce,
}) =>
    throw UnimplementedError();

/// Constant-time comparison of the camera's device_confirm.
bool verifyDeviceConfirm(String expected, String actual) => throw UnimplementedError();

/// `SHA256U(SHA256U(secret) + cnonce + nonce) + cnonce + nonce`.
String v3DigestPasswd({required String secret, required String cnonce, required String nonce}) =>
    throw UnimplementedError();

/// Keys of one secure session.
class V3SessionKeys {
  const V3SessionKeys(this.lsk, this.ivb);

  /// AES-128 key: first 16 bytes of SHA256('lsk'+cnonce+nonce+first_hash).
  final Uint8List lsk;

  /// CBC IV: first 16 bytes of SHA256('ivb'+cnonce+nonce+first_hash).
  final Uint8List ivb;
}

V3SessionKeys deriveV3SessionKeys({
  required String cnonce,
  required String nonce,
  required String firstHash,
}) =>
    throw UnimplementedError();

/// AES-128-CBC/PKCS7 then standard base64 (padded, no newlines).
String v3Encrypt(V3SessionKeys keys, String plainJson) => throw UnimplementedError();

/// Inverse of [v3Encrypt]. Throws `TapoProtocolError` on bad base64, length
/// not a positive multiple of 16, bad padding or invalid UTF-8.
String v3Decrypt(V3SessionKeys keys, String base64Text) => throw UnimplementedError();

/// Exact outer body: `{"method":"securePassthrough","params":{"request":"<b64>"}}`.
String wrapSecurePassthrough(String base64Request) => throw UnimplementedError();

/// `SHA256U(SHA256U(password) + cnonce)`; the tag prefix.
String v3TagPrefix({required String password, required String cnonce}) =>
    throw UnimplementedError();

/// `tapo_tag = SHA256U(tagPrefix + outerBody + str(seq))`.
String v3ComputeTag({
  required String password,
  required String cnonce,
  required String outerBody,
  required int seq,
}) =>
    throw UnimplementedError();

/// A ready-to-send secure request.
class V3SecureRequest {
  const V3SecureRequest({required this.outerBody, required this.headers});
  final String outerBody;

  /// `seq` and `tapo_tag`.
  final Map<String, String> headers;
}

V3SecureRequest buildV3SecureRequest({
  required String password,
  required String cnonce,
  required String nonce,
  required int seq,
  required String innerJson,
}) =>
    throw UnimplementedError();