// Self-test: the fixture crypto helpers reproduce the golden vectors of
// specs/android_tv_port_spec.json (hc.local.*, mb.local.*).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../fixtures/fx_crypto.dart';

void main() {
  group('secure v3 (hc.local.v3_hashes / v3_session)', () {
    const pw = 'test_password';
    const cnonce = 'ABCDEF0123456789';
    const nonce = '0123456789ABCDEF';

    test('hashes match the golden vector', () {
      expect(md5Upper(pw), '16EC1EBB01FE02DED9B7D5447D3DFC65');
      expect(sha256Upper(pw),
          '10A6E6CC8311A3E2BCC09BF6C199ADECD5DD59408C343E926B129C4914F3CB01');
      expect(firstHash(pw, cnonce, nonce),
          'AE0E012599836B112471EC21767309CF4A927A9053B8A9FA7917E8AB28F09D01');
      expect(deviceConfirm(pw, cnonce, nonce),
          'AE0E012599836B112471EC21767309CF4A927A9053B8A9FA7917E8AB28F09D010123456789ABCDEFABCDEF0123456789');
      expect(digestPasswd(pw, cnonce, nonce),
          '5A379DADD2ED54B76D3308115F0520E539295A1EF5C5149DBE269EB7C23ACE5EABCDEF01234567890123456789ABCDEF');
      expect(md5Hex('0123456789ABCDEF0123456789ABCDEF01234567'),
          'ac80b0ccea9b65429ad9c7a0b903c025');
    });

    test('session keys, ciphertext and tapo_tag match the golden vector', () {
      final k = sessionKeys(pw, cnonce, nonce);
      expect(toHex(k.lsk), '018fb84dcd026fb84e766fa42627c6df');
      expect(toHex(k.ivb), '0681a79416d607616bc1572710f41f6d');
      const inner =
          '{"method":"multipleRequest","params":{"requests":[{"method":"getDeviceInfo","params":{"device_info":{"name":["basic_info"]}}}]}}';
      final ct = b64Encrypt(k.lsk, k.ivb, inner);
      expect(ct,
          'tsPetnY0BwryJNwfMIFkg6TmS7K69/hlPfr/0l4P3q/Ir3YMNXX0fEE1ASXzOjcW0qoTq3WZqTSc9MSNF2kA5hJJqD5UUkNw54G4WGEg/d0+IDljn04yvBwE8MLzstIcebwChQMmXfM4jJ1hTf6Gj920E5ML9J10B5ThkTJqhfG+WKfkRzTHXtMuNpHkFjOd');
      expect(b64Decrypt(k.lsk, k.ivb, ct), inner);
      final outer = compactJson({
        'method': 'securePassthrough',
        'params': {'request': ct}
      });
      expect(tagPrefix(pw, cnonce),
          '965F1905CC2A04E75E383CE6F9D17CEE73D5D3C8F46CB5AF47FAD987EFCB720F');
      expect(tapoTag(pw, cnonce, outer, 1234),
          '1E3CCDD1AA638ACBF781C0BE09D3510F270E61429E7E86FC56F76B636F2C6A38');
    });

    test('bad ciphertext is rejected', () {
      final k = sessionKeys(pw, cnonce, nonce);
      expect(() => aesCbcDecrypt(k.lsk, k.ivb, Uint8List(15)), throwsArgumentError);
      expect(() => b64Decrypt(k.lsk, k.ivb, '!!'), throwsFormatException);
    });
  });

  group('TPAP channel (hc.local.tpap_cipher)', () {
    test('CCM sealed body matches the golden vector', () {
      final shared = fromHex(
          '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');
      final key = hkdfSha256(shared, utf8.encode('tp-kdf-salt-aes128-key'),
          utf8.encode('tp-kdf-info-aes128-key'), 32)
          .sublist(0, 16);
      final nb = hkdfSha256(shared, utf8.encode('tp-kdf-salt-aes128-iv'),
          utf8.encode('tp-kdf-info-aes128-iv'), 32)
          .sublist(0, 12);
      expect(toHex(key), '1f477a8c3d031511dcfd57aa01895887');
      expect(toHex(nb), '4240c38bb08a77faaae56105');
      const seq = 0x01020304;
      final nonce = Uint8List.fromList(
          [...nb.sublist(0, 8), 1, 2, 3, 4]);
      final plain = utf8
          .encode('{"method":"multipleRequest","params":{"requests":[]}}');
      final sealed = ccmSeal(key, nonce, plain);
      expect(seq.toRadixString(16).padLeft(8, '0') + toHex(sealed),
          '01020304c0331c1c36a5df4ce0c68e5037aa4d73aa9e21f8948de12facf360f76840e308fd5655a5743a88ed00d870b74e27c752b26488afcc7d374dcd269cd7adbba8488279634617');
      expect(ccmOpen(key, nonce, sealed), plain);
      final bad = Uint8List.fromList(sealed)..[0] ^= 1;
      expect(ccmOpen(key, nonce, bad), isNull);
    });

    test('LAT passcode', () {
      expect(sha256Upper('0123456789abcdef0123456789abcdef'),
          '3EB1BD439947EB762998E566CCC2E099C791118B2F40579CC4F7DA2B5061B7F9');
    });
  });

  group(':8800 keys (mb.local.key_md5 / key_hkdf)', () {
    test('md5 keys, admin and none', () {
      expect(md5Upper('cloudpass'), '0318564DA313CFBFF096FE8CE56FA912');
      final k = mediaKeys('0d4a5e9f3b2c1a77', md5Upper('cloudpass'));
      expect(toHex(k.key), '62c1b78af0e55ddf735e142052110aee');
      expect(toHex(k.iv), '65c2e710f689f298effbb35b974d7ce6');
    });

    test('hkdf keys and part match the golden vector', () {
      final secret = sha256Upper('local-access-token');
      expect(secret,
          '4E5B2C20C1645A4EEDA8BD59251974653FFF883CA5480C9A54FBF87A263BD2C2');
      final k = mediaHkdfKeys('0123456789abcdef0123456789abcdef', secret,
          'fedcba9876543210fedcba9876543210');
      expect(toHex(k.aesKey), '0a6e6cb5d694ce1b2f081fb2c3b88d96');
      expect(toHex(k.hmacKey), '941348d22b7ba9eaa114b393798ecade');
      final plain = Uint8List.fromList(
          [0x47, 0x40, 0x00, 0x10, ...List<int>.generate(184, (i) => i)]);
      final part = mediaHkdfEncrypt(k.aesKey, k.hmacKey, plain,
          iv: fromHex('000102030405060708090a0b0c0d0e0f'));
      expect(part.data.length, 192);
      expect(toHex(part.data.sublist(0, 32)),
          '98d0d2d6927239bacfa3da8f429884cf1d7b0d861262b856fe4db48440c7a6bd');
      expect(part.headers['X-Data-Hmac'],
          'dUifIYhlkuXvqtMjeF8lsU0TIqIEjLkDhRKaLIQzYBM=');
      expect(part.headers['X-Nonce'], '000102030405060708090a0b0c0d0e0f');
    });
  });
}
