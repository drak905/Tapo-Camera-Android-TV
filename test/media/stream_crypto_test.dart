// mb.local.key_md5, mb.local.key_hkdf: stream keys and part decryption.
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/media/local8800/stream_crypto.dart';
import 'package:tapo_tv/media/media_errors.dart';

import '../fixtures/fx_crypto.dart' as fx;
import 'helpers/crypto_fixtures.dart';
import 'helpers/fakes.dart';

void main() {
  group('key exchange header', () {
    test('parses space separated k=v and strips quotes', () {
      final ke = KeyExchange.parse(kHkdfKeyExchange);
      expect(ke.nonce, kHkdfNonce);
      expect(ke.salt, kHkdfSalt);
      expect(ke.username, 'admin');
      expect(ke.isHkdf, isTrue);
      expect(ke.encryptType, '3');
    });

    test('nonce is required', () {
      expect(() => KeyExchange.parse('username="admin"'), throwsFormatException);
    });
  });

  group('md5 keys', () {
    test('md5 key iv admin', () {
      final k = deriveMd5Keys(username: 'admin', nonce: kMd5NonceAdmin, plainPassword: 'cloudpass')!;
      expect(hexOf(k.aesKey), kMd5AdminKeyHex);
      expect(hexOf(k.iv!), kMd5AdminIvHex);
    });

    test('md5 key iv none uses default password', () {
      final k = deriveMd5Keys(username: 'none', nonce: 'ff00', plainPassword: 'ignored')!;
      expect(hexOf(k.aesKey), '88b73b827a9f4ec95642cde1bd6c67c9');
      expect(hexOf(k.iv!), '911eefc8e9ca20cca3a5437f35fee305');
    });

    test('challenge encrypt_type 3: the secret is UPPER_HEX(SHA256(password)) (Windows transform_password)', () {
      final k = deriveMd5Keys(
          username: 'admin', nonce: kMd5NonceAdmin, plainPassword: 'cloudpass', encryptType: '3')!;
      final secret = sha256.convert('cloudpass'.codeUnits).toString().toUpperCase();
      expect(hexOf(k.aesKey), md5.convert('$kMd5NonceAdmin:$secret'.codeUnits).toString());
      expect(hexOf(k.iv!), kMd5AdminIvHex);
    });

    test('unknown username yields null', () {
      expect(deriveMd5Keys(username: 'guest', nonce: 'ff00', plainPassword: 'x'), isNull);
    });

    test('decrypts a golden part with the md5 keys', () {
      final k = deriveMd5Keys(username: 'admin', nonce: kMd5NonceAdmin, plainPassword: 'cloudpass')!;
      expect(decryptPart(k, md5AdminCiphertext()), goldenPlaintext());
    });

    test('bad part length rejected', () {
      final k = deriveMd5Keys(username: 'admin', nonce: kMd5NonceAdmin, plainPassword: 'cloudpass')!;
      expect(() => decryptPart(k, Uint8List(17)), throwsA(isA<PartDecryptException>()));
    });
  });

  group('hkdf keys', () {
    StreamKeys keys() => deriveHkdfKeys(KeyExchange.parse(kHkdfKeyExchange), plainSecret: kHkdfLat);

    test('hkdf keys golden', () {
      final k = keys();
      expect(hexOf(k.aesKey), kHkdfAesKeyHex);
      expect(hexOf(k.hmacKey!), kHkdfHmacKeyHex);
    });

    test('challenge without encrypt_type: the secret is UPPER_HEX(MD5(secret)) (Windows transform_password)', () {
      final k = deriveHkdfKeys(KeyExchange.parse(kHkdfKeyExchange), plainSecret: kHkdfLat, encryptType: null);
      final want = fx.mediaHkdfKeys(kHkdfNonce, fx.md5Upper(kHkdfLat), kHkdfSalt);
      expect(hexOf(k.aesKey), hexOf(want.aesKey));
      expect(hexOf(k.hmacKey!), hexOf(want.hmacKey));
    });

    test('ciphertext fixture matches the golden hash', () {
      expect(sha256.convert(hkdfCiphertext()).toString(),
          'ec3f29f76e512b47a0de3a571d2d117f8159bc6fa5d94d8babd1f7b7a2a78bb7');
    });

    test('decrypt hkdf part verifies hmac', () {
      expect(decryptPart(keys(), hkdfCiphertext(), ivHex: kHkdfIvHex, hmacB64: kHkdfHmacB64), goldenPlaintext());
    });

    test('tampered hmac dropped', () {
      const bad = 'dUifIYhlkuXvqtMjeF8lsU0TIqIEjLkDhRKaLIQzYBN=';
      expect(() => decryptPart(keys(), hkdfCiphertext(), ivHex: kHkdfIvHex, hmacB64: bad),
          throwsA(isA<PartDecryptException>()));
    });

    test('tampered ciphertext fails the hmac', () {
      final c = hkdfCiphertext()..[5] ^= 1;
      expect(() => decryptPart(keys(), c, ivHex: kHkdfIvHex, hmacB64: kHkdfHmacB64),
          throwsA(isA<PartDecryptException>()));
    });

    test('invalid x-nonce rejected', () {
      expect(() => decryptPart(keys(), hkdfCiphertext(), ivHex: '0011', hmacB64: kHkdfHmacB64),
          throwsA(isA<PartDecryptException>()));
      expect(() => decryptPart(keys(), hkdfCiphertext(), ivHex: 'zz', hmacB64: kHkdfHmacB64),
          throwsA(isA<PartDecryptException>()));
    });

    test('hmac header optional', () {
      expect(decryptPart(keys(), hkdfCiphertext(), ivHex: kHkdfIvHex), goldenPlaintext());
    });
  });
}
