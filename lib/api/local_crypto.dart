// Secure login (encrypt_type 3) primitives and the secure-passthrough
// envelope. Spec: hc.local.v3_hashes, hc.local.v3_session. All hex is UPPER
// case unless stated. Nothing here may log a secret.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import 'tapo_errors.dart';

/// Upper-case hex SHA-256 over UTF-8.
String sha256Upper(String text) => sha256.convert(utf8.encode(text)).toString().toUpperCase();

/// Upper-case hex MD5 over UTF-8.
String md5Upper(String text) => md5.convert(utf8.encode(text)).toString().toUpperCase();

/// 8 random bytes as 16 upper-case hex chars.
String generateCnonce([Random? rng]) {
  final r = rng ?? Random.secure();
  return List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join().toUpperCase();
}

/// `SHA256U(cnonce + SHA256U(secret) + nonce)`.
String v3FirstHash({required String secret, required String cnonce, required String nonce}) =>
    sha256Upper(cnonce + sha256Upper(secret) + nonce);

/// What the camera must answer in `device_confirm`: `first_hash + nonce + cnonce`.
String v3ExpectedDeviceConfirm({
  required String secret,
  required String cnonce,
  required String nonce,
}) =>
    v3FirstHash(secret: secret, cnonce: cnonce, nonce: nonce) + nonce + cnonce;

/// Constant-time comparison of the camera's device_confirm.
bool verifyDeviceConfirm(String expected, String actual) {
  final a = utf8.encode(expected), b = utf8.encode(actual);
  var diff = a.length ^ b.length;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ (i < b.length ? b[i] : 0);
  }
  return diff == 0;
}

/// `SHA256U(SHA256U(secret) + cnonce + nonce) + cnonce + nonce`.
String v3DigestPasswd({required String secret, required String cnonce, required String nonce}) =>
    sha256Upper(sha256Upper(secret) + cnonce + nonce) + cnonce + nonce;

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
}) {
  Uint8List derive(String label) => Uint8List.fromList(
      sha256.convert(utf8.encode(label + cnonce + nonce + firstHash)).bytes.sublist(0, 16));
  return V3SessionKeys(derive('lsk'), derive('ivb'));
}

Uint8List _cbc(bool encrypt, V3SessionKeys keys, Uint8List data) {
  final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
    ..init(
      encrypt,
      PaddedBlockCipherParameters(ParametersWithIV(KeyParameter(keys.lsk), keys.ivb), null),
    );
  return cipher.process(data);
}

/// AES-128-CBC/PKCS7 then standard base64 (padded, no newlines).
String v3Encrypt(V3SessionKeys keys, String plainJson) =>
    base64.encode(_cbc(true, keys, Uint8List.fromList(utf8.encode(plainJson))));

/// Inverse of [v3Encrypt]. Throws `TapoProtocolError` on bad base64, length
/// not a positive multiple of 16, bad padding or invalid UTF-8.
String v3Decrypt(V3SessionKeys keys, String base64Text) {
  try {
    final raw = base64.decode(base64Text);
    if (raw.isEmpty || raw.length % 16 != 0) {
      throw TapoProtocolError('Encrypted reply has an invalid length');
    }
    return utf8.decode(_cbc(false, keys, Uint8List.fromList(raw)));
  } on TapoProtocolError {
    rethrow;
  } on FormatException {
    throw TapoProtocolError('Encrypted reply is not valid');
  } catch (_) {
    throw TapoProtocolError('Encrypted reply could not be decrypted');
  }
}

/// Exact outer body: `{"method":"securePassthrough","params":{"request":"<b64>"}}`.
String wrapSecurePassthrough(String base64Request) =>
    '{"method":"securePassthrough","params":{"request":"$base64Request"}}';

/// `SHA256U(SHA256U(password) + cnonce)`; the tag prefix.
String v3TagPrefix({required String password, required String cnonce}) =>
    sha256Upper(sha256Upper(password) + cnonce);

/// `tapo_tag = SHA256U(tagPrefix + outerBody + str(seq))`.
String v3ComputeTag({
  required String password,
  required String cnonce,
  required String outerBody,
  required int seq,
}) =>
    sha256Upper('${v3TagPrefix(password: password, cnonce: cnonce)}$outerBody$seq');

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
}) {
  final first = v3FirstHash(secret: password, cnonce: cnonce, nonce: nonce);
  final keys = deriveV3SessionKeys(cnonce: cnonce, nonce: nonce, firstHash: first);
  final outer = wrapSecurePassthrough(v3Encrypt(keys, innerJson));
  return V3SecureRequest(
    outerBody: outer,
    headers: {
      'seq': '$seq',
      'tapo_tag': v3ComputeTag(password: password, cnonce: cnonce, outerBody: outer, seq: seq),
    },
  );
}