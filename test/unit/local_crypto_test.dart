// Specs hc.local.v3_hashes and hc.local.v3_session (tier 1). Vectors from
// tests/unit/test_auth_crypto.py in the Windows repo.

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/local_crypto.dart';
import 'package:tapo_tv/api/tapo_errors.dart';

import '_support/helpers.dart';

const _password = 'test_password';
const _cnonce = 'ABCDEF0123456789';
const _nonce = '0123456789ABCDEF';
const _seq = 1234;
const _firstHash = 'AE0E012599836B112471EC21767309CF4A927A9053B8A9FA7917E8AB28F09D01';
const _inner = '{"method":"multipleRequest","params":{"requests":[{"method":"getDeviceInfo",'
    '"params":{"device_info":{"name":["basic_info"]}}}]}}';
const _cipherB64 =
    'tsPetnY0BwryJNwfMIFkg6TmS7K69/hlPfr/0l4P3q/Ir3YMNXX0fEE1ASXzOjcW0qoTq3WZqTSc9MSNF2kA5hJJqD5UUkNw54G4WGEg/d0+IDljn04yvBwE8MLzstIcebwChQMmXfM4jJ1hTf6Gj920E5ML9J10B5ThkTJqhfG+WKfkRzTHXtMuNpHkFjOd';
const _outer = '{"method":"securePassthrough","params":{"request":"$_cipherB64"}}';
const _tapoTag = '1E3CCDD1AA638ACBF781C0BE09D3510F270E61429E7E86FC56F76B636F2C6A38';

V3SessionKeys _keys() =>
    deriveV3SessionKeys(cnonce: _cnonce, nonce: _nonce, firstHash: _firstHash);

void main() {
  group('hashes', () {
    test('md5 upper golden', () {
      expect(md5Upper(_password), '16EC1EBB01FE02DED9B7D5447D3DFC65');
      expect(
        md5Upper('0123456789ABCDEF0123456789ABCDEF01234567').toLowerCase(),
        'ac80b0ccea9b65429ad9c7a0b903c025',
      );
    });

    test('sha256 upper golden', () {
      expect(
        sha256Upper(_password),
        '10A6E6CC8311A3E2BCC09BF6C199ADECD5DD59408C343E926B129C4914F3CB01',
      );
    });

    test('first hash and device confirm golden', () {
      expect(v3FirstHash(secret: _password, cnonce: _cnonce, nonce: _nonce), _firstHash);
      expect(
        v3ExpectedDeviceConfirm(secret: _password, cnonce: _cnonce, nonce: _nonce),
        'AE0E012599836B112471EC21767309CF4A927A9053B8A9FA7917E8AB28F09D01'
        '0123456789ABCDEFABCDEF0123456789',
      );
    });

    test('verify device confirm constant time', () {
      final ok = v3ExpectedDeviceConfirm(secret: _password, cnonce: _cnonce, nonce: _nonce);
      expect(verifyDeviceConfirm(ok, ok), isTrue);
      expect(verifyDeviceConfirm(ok, '${ok.substring(0, ok.length - 1)}0'), isFalse);
      expect(verifyDeviceConfirm(ok, ok.substring(1)), isFalse);
      expect(verifyDeviceConfirm(ok, ''), isFalse);
    });

    test('digest passwd golden', () {
      expect(
        v3DigestPasswd(secret: _password, cnonce: _cnonce, nonce: _nonce),
        '5A379DADD2ED54B76D3308115F0520E539295A1EF5C5149DBE269EB7C23ACE5E'
        'ABCDEF01234567890123456789ABCDEF',
      );
    });

    test('cnonce format', () {
      final a = generateCnonce();
      expect(RegExp(r'^[0-9A-F]{16}$').hasMatch(a), isTrue);
      expect(generateCnonce(), isNot(a));
      expect(generateCnonce(Random(1)), generateCnonce(Random(1)));
    });
  });

  group('session', () {
    test('derive session keys golden', () {
      final k = _keys();
      expect(hex(k.lsk), '018fb84dcd026fb84e766fa42627c6df');
      expect(hex(k.ivb), '0681a79416d607616bc1572710f41f6d');
    });

    test('encrypt golden', () {
      expect(v3Encrypt(_keys(), _inner), _cipherB64);
    });

    test('decrypt golden', () {
      expect(v3Decrypt(_keys(), _cipherB64), _inner);
    });

    test('wrap secure passthrough golden', () {
      expect(wrapSecurePassthrough(_cipherB64), _outer);
    });

    test('compute tag golden', () {
      expect(
        v3TagPrefix(password: _password, cnonce: _cnonce),
        '965F1905CC2A04E75E383CE6F9D17CEE73D5D3C8F46CB5AF47FAD987EFCB720F',
      );
      expect(
        v3ComputeTag(password: _password, cnonce: _cnonce, outerBody: _outer, seq: _seq),
        _tapoTag,
      );
    });

    test('full golden pipeline', () {
      final r = buildV3SecureRequest(
        password: _password,
        cnonce: _cnonce,
        nonce: _nonce,
        seq: _seq,
        innerJson: _inner,
      );
      expect(r.outerBody, _outer);
      expect(r.headers, {'seq': '1234', 'tapo_tag': _tapoTag});
    });

    test('decrypt garbage is protocol error', () {
      for (final bad in [
        '!!!not base64!!!',
        '',
        base64.encode(List.filled(15, 1)), // not a multiple of 16
        base64.encode(List.filled(32, 7)), // bad padding
      ]) {
        expect(() => v3Decrypt(_keys(), bad), throwsA(isA<TapoProtocolError>()), reason: bad);
      }
    });
  });
}
