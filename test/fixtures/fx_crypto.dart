// Server-side (camera / relay / cloud) crypto primitives for the wire-level
// fixtures. Stand-alone on purpose: nothing here imports lib/, so the mocks stay
// an independent reference implementation of the protocol.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

final Random _rng = Random.secure();

Uint8List randomBytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (_) => _rng.nextInt(256)));

String randomHex(int nBytes, {bool upper = false}) {
  final h = toHex(randomBytes(nBytes));
  return upper ? h.toUpperCase() : h;
}

String toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List fromHex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String b64e(List<int> b) => base64.encode(b);

/// Strict standard base64 (padded). Throws [FormatException] otherwise.
Uint8List b64d(String s) {
  if (!RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(s) || s.length % 4 != 0) {
    throw const FormatException('bad base64');
  }
  return Uint8List.fromList(base64.decode(s));
}

Uint8List utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));

Uint8List concatBytes(Iterable<List<int>> parts) {
  final b = BytesBuilder(copy: false);
  for (final p in parts) {
    b.add(p);
  }
  return b.toBytes();
}

bool constTimeEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

bool constTimeEqStr(String a, String b) =>
    constTimeEq(utf8.encode(a), utf8.encode(b));

String compactJson(Object? o) => jsonEncode(o);

// ---------------------------------------------------------------- hashes
String md5Hex(String s) => c.md5.convert(utf8.encode(s)).toString();
String md5Upper(String s) => md5Hex(s).toUpperCase();
String sha256Hex(String s) => c.sha256.convert(utf8.encode(s)).toString();
String sha256Upper(String s) => sha256Hex(s).toUpperCase();
Uint8List sha256Raw(List<int> b) =>
    Uint8List.fromList(c.sha256.convert(b).bytes);
Uint8List md5Raw(String s) => Uint8List.fromList(c.md5.convert(utf8.encode(s)).bytes);
Uint8List hmacSha256(List<int> key, List<int> data) =>
    Uint8List.fromList(c.Hmac(c.sha256, key).convert(data).bytes);

/// RFC 5869 HKDF-SHA256. A null/empty [salt] means 32 zero bytes.
Uint8List hkdfSha256(List<int> ikm, List<int>? salt, List<int> info, int length) {
  final s = (salt == null || salt.isEmpty) ? Uint8List(32) : salt;
  final prk = hmacSha256(s, ikm);
  final out = BytesBuilder();
  var block = Uint8List(0);
  var i = 1;
  while (out.length < length) {
    block = hmacSha256(prk, [...block, ...info, i]);
    out.add(block);
    i++;
  }
  return Uint8List.sublistView(out.toBytes(), 0, length);
}

// ---------------------------------------------------------------- secure v3
String firstHash(String password, String cnonce, String nonce) =>
    sha256Upper(cnonce + sha256Upper(password) + nonce);

/// SHA256U(cnonce + SHA256U(pwd) + nonce) + nonce + cnonce
String deviceConfirm(String password, String cnonce, String nonce) =>
    firstHash(password, cnonce, nonce) + nonce + cnonce;

/// SHA256U(SHA256U(pwd) + cnonce + nonce) + cnonce + nonce
String digestPasswd(String password, String cnonce, String nonce) =>
    sha256Upper(sha256Upper(password) + cnonce + nonce) + cnonce + nonce;

({Uint8List lsk, Uint8List ivb}) sessionKeys(
    String password, String cnonce, String nonce) {
  final fh = firstHash(password, cnonce, nonce);
  Uint8List k(String tag) =>
      Uint8List.fromList(sha256Raw(utf8.encode(tag + cnonce + nonce + fh)).sublist(0, 16));
  return (lsk: k('lsk'), ivb: k('ivb'));
}

String tagPrefix(String password, String cnonce) =>
    sha256Upper(sha256Upper(password) + cnonce);

String tapoTag(String password, String cnonce, String body, int seq) =>
    sha256Upper(tagPrefix(password, cnonce) + body + seq.toString());

// ---------------------------------------------------------------- AES
Uint8List aesCbcEncrypt(List<int> key, List<int> iv, List<int> data) {
  final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
    ..init(
        true,
        PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
            ParametersWithIV(KeyParameter(Uint8List.fromList(key)),
                Uint8List.fromList(iv)),
            null));
  return cipher.process(Uint8List.fromList(data));
}

/// Throws [ArgumentError] on bad length / padding.
Uint8List aesCbcDecrypt(List<int> key, List<int> iv, List<int> data) {
  if (data.isEmpty || data.length % 16 != 0) {
    throw ArgumentError('ciphertext length is not a multiple of 16');
  }
  try {
    final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
      ..init(
          false,
          PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
              ParametersWithIV(KeyParameter(Uint8List.fromList(key)),
                  Uint8List.fromList(iv)),
              null));
    return cipher.process(Uint8List.fromList(data));
  } on ArgumentError {
    rethrow;
  } catch (e) {
    throw ArgumentError('bad padding: $e');
  }
}

String b64Encrypt(List<int> key, List<int> iv, String text) =>
    b64e(aesCbcEncrypt(key, iv, utf8.encode(text)));

String b64Decrypt(List<int> key, List<int> iv, String b64) =>
    utf8.decode(aesCbcDecrypt(key, iv, b64d(b64)));

// ---------------------------------------------------------------- AES-128-CCM (TPAP /ds)
Uint8List ccmSeal(List<int> key, List<int> nonce, List<int> plain) {
  final cipher = CCMBlockCipher(AESEngine())
    ..init(
        true,
        AEADParameters(KeyParameter(Uint8List.fromList(key)), 128,
            Uint8List.fromList(nonce), Uint8List(0)));
  return cipher.process(Uint8List.fromList(plain));
}

/// Returns null when the tag does not verify.
Uint8List? ccmOpen(List<int> key, List<int> nonce, List<int> sealed) {
  try {
    final cipher = CCMBlockCipher(AESEngine())
      ..init(
          false,
          AEADParameters(KeyParameter(Uint8List.fromList(key)), 128,
              Uint8List.fromList(nonce), Uint8List(0)));
    return cipher.process(Uint8List.fromList(sealed));
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------- :8800 media
String mediaPassword(String secret, bool encryptV3) =>
    encryptV3 ? sha256Upper(secret) : md5Upper(secret);

/// key = MD5(nonce:pwd'), iv = MD5(username:nonce) (raw 16 bytes each).
({Uint8List key, Uint8List iv}) mediaKeys(String nonce, String passwordT,
        [String username = 'admin']) =>
    (key: md5Raw('$nonce:$passwordT'), iv: md5Raw('$username:$nonce'));

/// HKDF-SHA256(nonce:pwd', salt, info) L=16 for AES and HMAC keys.
({Uint8List aesKey, Uint8List hmacKey}) mediaHkdfKeys(
    String nonce, String passwordT, String salt) {
  final ikm = utf8.encode('$nonce:$passwordT');
  final s = salt.isEmpty ? null : utf8.encode(salt);
  return (
    aesKey: hkdfSha256(ikm, s, utf8.encode('stream_hkdf_aes_key'), 16),
    hmacKey: hkdfSha256(ikm, s, utf8.encode('stream_hkdf_hmac_key'), 16),
  );
}

/// One HKDF-mode part: fresh IV, returns the ciphertext and the X-Nonce / X-Data-Hmac headers.
({Uint8List data, Map<String, String> headers}) mediaHkdfEncrypt(
    List<int> aesKey, List<int> hmacKey, List<int> data,
    {bool corruptHmac = false, List<int>? iv}) {
  final ivb = iv ?? randomBytes(16);
  final ct = aesCbcEncrypt(aesKey, ivb, data);
  var mac = hmacSha256(hmacKey, ct);
  if (corruptHmac) mac = Uint8List.fromList(mac.map((b) => b ^ 0xFF).toList());
  return (
    data: ct,
    headers: {'X-Nonce': toHex(ivb), 'X-Data-Hmac': b64e(mac)},
  );
}

// ---------------------------------------------------------------- RSA-OAEP (TDP)
/// Parses a PEM SubjectPublicKeyInfo RSA public key.
RSAPublicKey rsaPublicKeyFromPem(String pem) {
  final der = base64.decode(pem
      .replaceAll(RegExp(r'-----(BEGIN|END) [A-Z ]+-----'), '')
      .replaceAll(RegExp(r'\s+'), ''));
  final spki = ASN1Parser(Uint8List.fromList(der)).nextObject() as ASN1Sequence;
  final bits = spki.elements![1] as ASN1BitString;
  final inner = ASN1Parser(Uint8List.fromList(bits.stringValues!)).nextObject()
      as ASN1Sequence;
  return RSAPublicKey(
      (inner.elements![0] as ASN1Integer).integer!,
      (inner.elements![1] as ASN1Integer).integer!);
}

/// RSA-OAEP, MGF1-SHA1, hash SHA1, no label (what the TDP encrypt_info uses).
Uint8List rsaOaepSha1Encrypt(RSAPublicKey key, List<int> data) {
  final e = OAEPEncoding.withSHA1(RSAEngine())
    ..init(true, PublicKeyParameter<RSAPublicKey>(key));
  return e.process(Uint8List.fromList(data));
}
