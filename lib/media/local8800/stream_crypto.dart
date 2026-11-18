/// Stream keys and part decryption for the local :8800 media port.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart' as pc;

import '../digest.dart' show kDefaultMediaPassword;
import '../media_errors.dart';

/// Parsed `Key-Exchange` response header (space separated k=v, quotes
/// stripped). `nonce` is required.
class KeyExchange {
  const KeyExchange(this.params);
  final Map<String, String> params;

  factory KeyExchange.parse(String header) {
    final params = <String, String>{};
    final re = RegExp(r'([A-Za-z_][\w-]*)=(?:"([^"]*)"|([^\s",]*))');
    for (final m in re.allMatches(header)) {
      params[m[1]!.toLowerCase()] = m[2] ?? m[3] ?? '';
    }
    if ((params['nonce'] ?? '').isEmpty) {
      throw const FormatException('Key-Exchange without nonce');
    }
    return KeyExchange(params);
  }

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

String _upperHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

Uint8List _md5(String s) => Uint8List.fromList(md5.convert(utf8.encode(s)).bytes);

/// Legacy MD5 keys: key = MD5(nonce + ':' + secret), iv = MD5(username + ':'
/// + nonce), raw 16 bytes. `admin`: secret = the Digest transform of
/// plainPassword (UPPER_HEX(SHA256) when the challenge's [encryptType] is `3`,
/// else UPPER_HEX(MD5)); `none`: the default media password (untransformed);
/// any other username returns null (parts cannot be read).
/// Windows: `vod/session.py` `_setup_encryption` + `transform_password`.
StreamKeys? deriveMd5Keys({
  required String username,
  required String nonce,
  required String plainPassword,
  String? encryptType,
}) {
  final String secret;
  if (username == 'admin') {
    secret = _transform(plainPassword, encryptType);
  } else if (username == 'none') {
    secret = kDefaultMediaPassword;
  } else {
    return null;
  }
  return StreamKeys(aesKey: _md5('$nonce:$secret'), iv: _md5('$username:$nonce'));
}

String _transform(String plain, String? encryptType) {
  final bytes = utf8.encode(plain.isEmpty ? kDefaultMediaPassword : plain);
  return _upperHex(encryptType?.trim() == '3' ? sha256.convert(bytes).bytes : md5.convert(bytes).bytes);
}

Uint8List _hkdf16(List<int> ikm, List<int>? salt, String info) {
  final prk = Hmac(sha256, (salt == null || salt.isEmpty) ? List<int>.filled(32, 0) : salt).convert(ikm).bytes;
  final t1 = Hmac(sha256, prk).convert([...utf8.encode(info), 1]).bytes;
  return Uint8List.fromList(t1.sublist(0, 16));
}

/// HKDF-SHA256 keys, L=16: ikm = nonce + ':' + secret with secret = the
/// Digest transform of plainSecret ([encryptType] `3`: UPPER_HEX(SHA256), else
/// UPPER_HEX(MD5); pass the challenge's encrypt_type); salt = the Key-Exchange
/// salt as UTF-8 (none when empty); info `stream_hkdf_aes_key` and
/// `stream_hkdf_hmac_key`.
StreamKeys deriveHkdfKeys(KeyExchange keyExchange, {required String plainSecret, String? encryptType = '3'}) {
  final secret = keyExchange.username == 'none' ? kDefaultMediaPassword : _transform(plainSecret, encryptType);
  final ikm = utf8.encode('${keyExchange.nonce}:$secret');
  final saltText = keyExchange.salt ?? '';
  final salt = saltText.isEmpty ? null : utf8.encode(saltText);
  return StreamKeys(
    aesKey: _hkdf16(ikm, salt, 'stream_hkdf_aes_key'),
    hmacKey: _hkdf16(ikm, salt, 'stream_hkdf_hmac_key'),
  );
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Decrypts one part body with AES-128-CBC PKCS7. [ivHex] is `X-Nonce`
/// (HKDF: must decode to 16 bytes); [hmacB64] is the optional `X-Data-Hmac`
/// = base64(HMAC-SHA256(hmacKey, ciphertext)), compared in constant time
/// BEFORE decrypting. Legacy keys use the fixed IV and ignore [ivHex].
/// Throws [PartDecryptException] for a length that is not a multiple of 16, an
/// invalid nonce, or a bad HMAC.
Uint8List decryptPart(StreamKeys keys, Uint8List ciphertext, {String? ivHex, String? hmacB64}) {
  if (ciphertext.isEmpty || ciphertext.length % 16 != 0) {
    throw const PartDecryptException('part length is not a multiple of 16');
  }
  Uint8List iv;
  final fixedIv = keys.iv;
  if (fixedIv != null) {
    iv = fixedIv;
  } else {
    final hex = ivHex ?? '';
    if (hex.length != 32 || !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(hex)) {
      throw const PartDecryptException('invalid X-Nonce');
    }
    iv = Uint8List.fromList([for (var i = 0; i < 32; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
  }
  final hmacKey = keys.hmacKey;
  if (hmacB64 != null && hmacKey != null) {
    List<int> expected;
    try {
      expected = base64.decode(hmacB64);
    } on FormatException {
      throw const PartDecryptException('bad X-Data-Hmac');
    }
    final actual = Hmac(sha256, hmacKey).convert(ciphertext).bytes;
    if (!_constantTimeEquals(actual, expected)) {
      throw const PartDecryptException('part integrity check failed');
    }
  }
  try {
    final cipher = pc.PaddedBlockCipherImpl(pc.PKCS7Padding(), pc.CBCBlockCipher(pc.AESEngine()))
      ..init(
        false,
        pc.PaddedBlockCipherParameters<pc.ParametersWithIV<pc.KeyParameter>, pc.CipherParameters?>(
          pc.ParametersWithIV(pc.KeyParameter(keys.aesKey), iv),
          null,
        ),
      );
    return cipher.process(ciphertext);
  } on ArgumentError {
    throw const PartDecryptException('bad padding');
  } on pc.InvalidCipherTextException {
    throw const PartDecryptException('bad padding');
  }
}
