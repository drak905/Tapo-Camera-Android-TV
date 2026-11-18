/// Stream keys and part decryption for the local :8800 media port.
library;

import 'dart:typed_data';

/// Parsed `Key-Exchange` response header (space separated k=v, quotes
/// stripped). `nonce` is required.
class KeyExchange {
  const KeyExchange(this.params);
  final Map<String, String> params;

  factory KeyExchange.parse(String header) => throw UnimplementedError();

  String get nonce => params['nonce'] ?? '';
  String? get salt => params['salt'];
  String get username => params['username'] ?? 'admin';
  String? get algorithm => params['algorithm'];
  String? get encryptType => params['encrypt_type'];
  bool get isHkdf => (algorithm ?? '').toUpperCase() == 'HKDF';
}

/// AES-128-CBC key, IV (legacy MD5 only) and HMAC key (HKDF only).
class StreamKeys {
  const StreamKeys({required this.aesKey, this.iv, this.hmacKey});
  final Uint8List aesKey;
  final Uint8List? iv;
  final Uint8List? hmacKey;
}

/// Legacy MD5 keys: key = MD5(nonce + ':' + secret), iv = MD5(username + ':'
/// + nonce), raw 16 bytes. `admin`: secret = UPPER_HEX(MD5(plainPassword));
/// `none`: the default media password (untransformed); any other username
/// returns null (parts cannot be read).
StreamKeys? deriveMd5Keys({
  required String username,
  required String nonce,
  required String plainPassword,
}) =>
    throw UnimplementedError();

/// HKDF-SHA256 keys, L=16: ikm = nonce + ':' + secret with secret =
/// UPPER_HEX(SHA256(plainSecret)); salt = the Key-Exchange salt as UTF-8
/// (none when empty); info `stream_hkdf_aes_key` and `stream_hkdf_hmac_key`.
StreamKeys deriveHkdfKeys(KeyExchange keyExchange, {required String plainSecret}) => throw UnimplementedError();

/// Decrypts one part body with AES-128-CBC PKCS7. [ivHex] is `X-Nonce`
/// (HKDF: must decode to 16 bytes); [hmacB64] is the optional `X-Data-Hmac`
/// = base64(HMAC-SHA256(hmacKey, ciphertext)), compared in constant time
/// BEFORE decrypting. Legacy keys use the fixed IV and ignore [ivHex].
/// Throws [PartDecryptException] for a length that is not a multiple of 16, an
/// invalid nonce, or a bad HMAC.
Uint8List decryptPart(StreamKeys keys, Uint8List ciphertext, {String? ivHex, String? hmacB64}) =>
    throw UnimplementedError();
