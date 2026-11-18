// mb.relay.encrypted_parts, mb.local.key_hkdf (drop vs broken session).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/media/local8800/stream_crypto.dart';
import 'package:tapo_tv/media/media_errors.dart';
import 'package:tapo_tv/media/multipart_reader.dart';
import 'package:tapo_tv/media/part_decryptor.dart';

import 'helpers/crypto_fixtures.dart';
import 'helpers/fakes.dart';

MultipartPart _part(List<int> body, [Map<String, String> headers = const {}]) =>
    MultipartPart({'Content-Type': 'video/mp2t', ...headers}, Uint8List.fromList(body));

HkdfPartDecryptor _hkdf() => HkdfPartDecryptor(
    deriveHkdfKeys(KeyExchange.parse(kHkdfKeyExchange), plainSecret: kHkdfLat));

void main() {
  test('passthrough on unencrypted part', () {
    final body = tsPacket();
    expect(const PassthroughDecryptor().decrypt(_part(body)), body);
  });

  test('encrypted relay part without key throws typed error with header names only', () {
    final part = _part([1, 2, 3], {'X-If-Encrypt': '1', 'X-Nonce': 'secretvalue'});
    expect(
      () => const PassthroughDecryptor().decrypt(part),
      throwsA(isA<EncryptedRelayMediaException>()
          .having((e) => e.headerNames, 'headerNames', containsAll(['X-If-Encrypt', 'X-Nonce']))
          .having((e) => e.toString(), 'message', isNot(contains('secretvalue')))),
    );
  });

  test('hkdf decryptor decrypts only parts flagged X-If-Encrypt 1', () {
    final d = _hkdf();
    final enc = _part(hkdfCiphertext(), {'X-If-Encrypt': '1', 'X-Nonce': kHkdfIvHex, 'X-Data-Hmac': kHkdfHmacB64});
    expect(d.decrypt(enc), goldenPlaintext());
    final plain = _part(tsPacket());
    expect(d.decrypt(plain), tsPacket());
  });

  test('bad hmac part is dropped (null), not fatal', () {
    final d = _hkdf();
    final bad = _part(hkdfCiphertext(), {'X-If-Encrypt': '1', 'X-Nonce': kHkdfIvHex, 'X-Data-Hmac': 'AAAA'});
    expect(d.decrypt(bad), isNull);
    // a good part afterwards still works and resets the failure counter
    final good = _part(hkdfCiphertext(), {'X-If-Encrypt': '1', 'X-Nonce': kHkdfIvHex, 'X-Data-Hmac': kHkdfHmacB64});
    expect(d.decrypt(good), goldenPlaintext());
  });

  test('more than 50 consecutive failures raise a broken session', () {
    final d = _hkdf();
    final bad = _part(hkdfCiphertext(), {'X-If-Encrypt': '1', 'X-Nonce': kHkdfIvHex, 'X-Data-Hmac': 'AAAA'});
    for (var i = 0; i < 50; i++) {
      expect(d.decrypt(bad), isNull, reason: 'failure ${i + 1}');
    }
    expect(() => d.decrypt(bad), throwsA(isA<BrokenSessionException>()));
  });

  test('md5 decryptor uses the fixed iv for every part', () {
    final keys = deriveMd5Keys(username: 'admin', nonce: kMd5NonceAdmin, plainPassword: 'cloudpass')!;
    final d = Md5PartDecryptor(keys);
    final p = _part(md5AdminCiphertext(), {'X-If-Encrypt': '1'});
    expect(d.decrypt(p), goldenPlaintext());
    expect(d.decrypt(p), goldenPlaintext());
  });
}
