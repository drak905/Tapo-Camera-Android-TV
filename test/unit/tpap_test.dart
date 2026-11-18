// Specs hc.local.tpap_register / tpap_spake2p / tpap_share_login / tpap_cipher /
// lat_mode (TPAP part) and hc.discovery.tpap_hint. Vectors come from the
// Windows repo (RFC 9383 P-256 vector, CCM channel) or were computed offline
// from the Windows test inputs (PBKDF2, context, LAT passcode).
//
// SAFETY: a wrong password must never cost a camera more than 2 pake_share
// attempts per login.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/lan_matcher.dart' show tpapRequested;
import 'package:tapo_tv/api/tapo_errors.dart';
import 'package:tapo_tv/api/tpap.dart';

import '_support/fake_tpap_camera.dart';
import '_support/helpers.dart';

const _usernameMd5 = '21232f297a57a5a743894a0e4a801fc3';
const _usernameSha256 = '8C6976E5B5410415BDE908BD4DEE15DFB167A9C873FC4BB8A81F6F2AB448A918';
const _lat = '0123456789abcdef0123456789abcdef';
const _latPasscode = '3EB1BD439947EB762998E566CCC2E099C791118B2F40579CC4F7DA2B5061B7F9';
const _password = 'test_password';

final _sha256Pw = sha256UpperRef(_password);
final _md5Pw = md5LowerRef(_password);

Uint8List _fixedRng(int n) => Uint8List.fromList(List.generate(n, (i) => (i * 7 + 1) & 0xff));

({TpapAuthenticator auth, List<Duration> sleeps}) _auth(
  FakeTpapCamera cam, {
  String password = _password,
  String? lat,
  Map<String, dynamic>? hints,
}) {
  final sleeps = <Duration>[];
  final auth = TpapAuthenticator(
    postLogin: cam.postLogin,
    password: password,
    localToken: lat,
    tpapHints: hints,
    rng: _fixedRng,
    sleep: (d) async => sleeps.add(d),
  );
  return (auth: auth, sleeps: sleeps);
}

void main() {
  group('selection hint', () {
    test('tpap requested hints', () {
      expect(tpapRequested({'pake': [1]}), isTrue);
      expect(tpapRequested(null, ['3', '4']), isTrue);
      expect(tpapRequested(null, ['3']), isFalse);
    });
  });

  group('register', () {
    test('register request matches the app', () {
      final user = Uint8List.fromList(List.filled(32, 1));
      final params = buildPakeRegister(username: _usernameMd5, userRandom: user);
      expect(
        jsonEncode(params),
        '{"sub_method":"pake_register","username":"$_usernameMd5",'
        '"user_random":"${base64.encode(user)}","cipher_suites":[1],'
        '"encryption":["aes_128_ccm"],"passcode_type":"userpw"}',
      );
    });

    test('camera username hashing', () {
      expect(tpapCameraUsername(), _usernameMd5);
      expect(tpapCameraUsername(userHashType: 1), _usernameSha256);
    });

    test('register reply defaults and validation', () {
      final ok = TpapRegisterReply.parse({
        'dev_random': base64.encode(List.filled(32, 2)),
        'dev_salt': base64.encode(List.filled(16, 3)),
        'dev_share': base64.encode(List.filled(65, 4)),
      });
      expect(ok.iterations, 10000);
      expect(ok.encryption, 'aes_128_ccm');
      Map<String, dynamic> with_(Map<String, dynamic> extra) => {
            'dev_random': base64.encode(List.filled(32, 2)),
            'dev_salt': base64.encode(List.filled(16, 3)),
            'dev_share': base64.encode(List.filled(65, 4)),
            ...extra,
          };
      for (final bad in [
        with_({'iterations': 0}),
        with_({'iterations': 10000001}),
        with_({'cipher_suites': 2}),
        with_({'dev_salt': '***'}),
        with_({'dev_random': null}),
      ]) {
        expect(() => TpapRegisterReply.parse(bad), throwsA(isA<TapoProtocolError>()), reason: '$bad');
      }
    });

    test('literal admin username fallback', () async {
      final cam = FakeTpapCamera(expectedPasscode: _md5Pw, acceptedUsernames: {'admin'});
      final t = _auth(cam);
      final session = await t.auth.login();
      expect(cam.usernames, [_usernameMd5, 'admin']);
      expect(session.variant, 'md5');
      // The choice is remembered for later logins.
      cam.usernames.clear();
      await t.auth.login();
      expect(cam.usernames.first, 'admin');
    });

    test('user hash type 1 selects the sha256 user name', () async {
      final cam = FakeTpapCamera(expectedPasscode: _md5Pw);
      await _auth(cam, hints: {'user_hash_type': 1}).auth.login();
      expect(cam.usernames.first, _usernameSha256);
    });

    test('needs v3 raises not supported', () async {
      final cam = FakeTpapCamera(expectedPasscode: _md5Pw)..needsV3 = true;
      await expectLater(_auth(cam).auth.login(), throwsA(isA<TpapNotSupported>()));
      expect(cam.shareCount, 0);
    });
  });

  group('spake2+ primitives', () {
    const rfcW0 = 'bb8e1bbcf3c48f62c08db243652ae55d3e5586053fca77102994f23ad95491b3';
    const rfcW1 = '7e945f34d78785b8a3ef44d0df5a1a97d6b3b460409a345ca7830387a74b1dba';
    const rfcX = 'd1232c8e8693d02368976c174e2088851b8365d0d79a9eee709c6a05a2fad539';
    const rfcShareV =
        '04c0f65da0d11927bdf5d560c69e1d7d939a05b0e88291887d679fcadea75810fb5cc1ca7494db39e82ff2f50665255d76173e09986ab46742c798a9a68437b048';
    final rfcContext = utf8.encode('SPAKE2+-P256-SHA256-HKDF-SHA256-HMAC-SHA256 Test Vectors');

    Spake2pKeys prove({Uint8List? idP, Uint8List? idV, Uint8List? shareV}) => spake2pProve(
          w0: BigInt.parse(rfcW0, radix: 16),
          w1: BigInt.parse(rfcW1, radix: 16),
          context: Uint8List.fromList(rfcContext),
          shareV: shareV ?? unhex(rfcShareV),
          x: BigInt.parse(rfcX, radix: 16),
          idProver: idP,
          idVerifier: idV,
        );

    test('rfc9383 vector prover side', () {
      final k = prove(
        idP: Uint8List.fromList(utf8.encode('client')),
        idV: Uint8List.fromList(utf8.encode('server')),
      );
      expect(hex(k.shareP),
          '04ef3bd051bf78a2234ec0df197f7828060fe9856503579bb1733009042c15c0c1de127727f418b5966afadfdd95a6e4591d171056b333dab97a79c7193e341727');
      expect(hex(k.z),
          '04bbfce7dd7f277819c8da21544afb7964705569bdf12fb92aa388059408d50091a0c5f1d3127f56813b5337f9e4e67e2ca633117a4fbd559946ab474356c41839');
      expect(hex(k.v),
          '0458bf27c6bca011c9ce1930e8984a797a3419797b936629a5a937cf2f11c8b9514b82b993da8a46e664f23db7c01edc87faa530db01c2ee405230b18997f16b68');
      expect(hex(k.kMain), '4c59e1ccf2cfb961aa31bd9434478a1089b56cd11542f53d3576fb6c2a438a29');
      expect(hex(k.kConfirmP), '871ae3f7b78445e34438fb284504240239031c39d80ac23eb5ab9be5ad6db58a');
      expect(hex(k.kConfirmV), 'ccd53c7c1fa37b64a462b40db8be101cedcf838950162902054e644b400f1680');
      expect(hex(k.confirmP), '926cc713504b9b4d76c9162ded04b5493e89109f6d89462cd33adc46fda27527');
      expect(hex(k.confirmV), '9747bcc4f8fe9f63defee53ac9b07876d907d55047e6ff2def2e7529089d3e68');
      expect(hex(k.kShared), '0c5f8ccd1413423a54f6c1fb26ff01534a87f893779c6e68666d772bfd91f3e7');
    });

    test('real camera flow uses empty ids', () {
      final named = prove(
        idP: Uint8List.fromList(utf8.encode('client')),
        idV: Uint8List.fromList(utf8.encode('server')),
      );
      final empty = prove();
      // The shares and points do not depend on the ids, the transcript does.
      expect(hex(empty.shareP), hex(named.shareP));
      expect(hex(empty.z), hex(named.z));
      expect(hex(empty.v), hex(named.v));
      expect(hex(empty.kMain), isNot(hex(named.kMain)));
      expect(empty.kMain.length, 32);
      expect(empty.kShared.length, 32);
    });

    test('derive w0 w1 pbkdf2 80 bytes mod n', () {
      final salt = unhex('000102030405060708090a0b0c0d0e0f');
      final dk = tpapPbkdf2('0123abcd', salt, 1000);
      expect(
        hex(dk),
        '6a2609b1bd0e81bb87a610193883a82cfcfbf9895fda4773531c635cd94d37707c5f53c7cf54ef1d8385682989155bfd78a368e90c4defa9b76edf27983ae65b3199554a0f499343c0dc9dea8e4d076e',
      );
      final n = BigInt.parse(
          'ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551',
          radix: 16);
      BigInt big(List<int> b) => b.fold(BigInt.zero, (a, v) => (a << 8) | BigInt.from(v));
      final (w0, w1) = tpapDeriveW0W1('0123abcd', salt, 1000);
      expect(w0, big(dk.sublist(0, 40)) % n);
      expect(w1, big(dk.sublist(40, 80)) % n);
    });

    test('tpap context is sha256 of tag and randoms', () {
      final c = tpapContext(
        Uint8List.fromList(List.filled(32, 1)),
        Uint8List.fromList(List.filled(32, 2)),
      );
      expect(hex(c), 'c597cc9152238905dce4745e18c986b649f703a29e16e7894ff911464cff835f');
    });

    test('points m n round trip', () {
      for (final compressed in [tpapPointM, tpapPointN]) {
        expect(compressed.length, 33);
        final full = tpapDecodePoint(compressed);
        expect(full.length, 65);
        expect(full[0], 4);
        expect(tpapCompressPoint(full), compressed);
      }
      expect(hex(tpapPointM), '02886e2f97ace46e55ba9dd7242579f2993b64e16ef3dcab95afd497333d8fa12f');
      expect(hex(tpapPointN), '03d8bbd6c639c62937b04d997f38c3770719c629d7014d49a24b4f98baa1292b49');
    });

    test('invalid points rejected', () {
      for (final bad in <Uint8List>[
        Uint8List(0),
        Uint8List(33), // prefix 0 is not a point
        Uint8List.fromList([5, ...List.filled(32, 1)]),
        Uint8List.fromList([4, ...List.filled(10, 1)]),
        Uint8List.fromList([2, ...List.filled(32, 0xff)]), // x >= p
      ]) {
        expect(() => tpapDecodePoint(bad), throwsA(isA<TapoProtocolError>()), reason: hex(bad));
      }
    });

    test('off curve peer share rejected', () {
      final offCurve = Uint8List.fromList([4, ...List.filled(32, 1), ...List.filled(32, 2)]);
      expect(() => prove(shareV: offCurve), throwsA(isA<TapoProtocolError>()));
    });
  });

  group('cipher', () {
    final shared = unhex('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');
    final plain = Uint8List.fromList(
        utf8.encode('{"method":"multipleRequest","params":{"requests":[]}}'));

    test('cipher golden vector and framing', () {
      final c = TpapCipher(shared);
      expect(hex(c.aesKey), '1f477a8c3d031511dcfd57aa01895887');
      expect(hex(c.nonceBase), '4240c38bb08a77faaae56105');
      final sealed = c.seal(plain, 0x01020304);
      expect(
        hex(sealed),
        '01020304c0331c1c36a5df4ce0c68e5037aa4d73aa9e21f8948de12facf360f76840e308fd5655a5743a88ed00d870b74e27c752b26488afcc7d374dcd269cd7adbba8488279634617',
      );
      expect(sealed.length, 4 + plain.length + 16);
      final (seq, opened) = c.open(sealed);
      expect(seq, 0x01020304);
      expect(opened, plain);
    });

    test('nonce depends on seq and tamper detected', () {
      final c = TpapCipher(shared);
      final n1 = c.nonceFor(1), n2 = c.nonceFor(2);
      expect(n1.length, 12);
      expect(n1.sublist(0, 8), c.nonceBase.sublist(0, 8));
      expect(n1.sublist(8), [0, 0, 0, 1]);
      expect(n1, isNot(n2));
      final sealed = Uint8List.fromList(c.seal(plain, 7));
      sealed[10] ^= 1;
      expect(() => c.open(sealed), throwsA(isA<TapoSessionInvalid>()));
      expect(() => c.open(Uint8List(10)), throwsA(isA<TapoSessionInvalid>()));
      final otherSeq = Uint8List.fromList(c.seal(plain, 7))..[3] ^= 1; // seq changed
      expect(() => c.open(otherSeq), throwsA(isA<TapoSessionInvalid>()));
    });

    test('unknown encryption rejected', () {
      expect(() => TpapCipher(shared, encryption: 'chacha20'), throwsA(isA<TapoProtocolError>()));
    });

    test('plaintext refusal detected', () {
      Uint8List j(String s) => Uint8List.fromList(utf8.encode(s));
      expect(TpapCipher.plaintextRefusalCode(j('{"error_code":-40401}')), -40401);
      expect(TpapCipher.plaintextRefusalCode(j('{"error_code":-2402}')), -2402);
      expect(TpapCipher.plaintextRefusalCode(j('{"error_code":-1,"result":{}}')), -1);
      expect(TpapCipher.plaintextRefusalCode(TpapCipher(shared).seal(plain, 1)), isNull);
      expect(TpapCipher.plaintextRefusalCode(j('{not json')), isNull);
      expect(TpapCipher.plaintextRefusalCode(Uint8List(0)), isNull);
    });
  });

  group('login with candidates (bounded attempts)', () {
    test('lat passcode is sha256 upper of token', () {
      expect(tpapCredential('lat', _lat), _latPasscode);
      expect(tpapCredential('sha256', _password), _sha256Pw);
      expect(tpapCredential('md5', _password), _md5Pw);
    });

    test('wrong password raises auth error after exactly two attempts', () async {
      final cam = FakeTpapCamera(expectedPasscode: md5LowerRef('some other password'));
      final t = _auth(cam, password: 'wrong-password-1');
      await expectLater(
        t.auth.login(),
        throwsA(isA<TapoAuthError>().having((e) => e.message, 'message', isNot(contains('wrong-password-1')))),
      );
      expect(cam.shareCount, 2);
      expect(cam.registerCount, 2);
      expect(t.auth.goodVariant, isNull);
    });

    test('a second login call is again bounded to two attempts', () async {
      final cam = FakeTpapCamera(expectedPasscode: md5LowerRef('some other password'));
      final t = _auth(cam, password: 'wrong-password-1');
      for (var i = 0; i < 2; i++) {
        await expectLater(t.auth.login(), throwsA(isA<TapoAuthError>()));
      }
      expect(cam.shareCount, 4); // 2 per login, never a loop
    });

    test('locked camera stops immediately', () async {
      final cam = FakeTpapCamera(expectedPasscode: _md5Pw)..locked = true;
      await expectLater(
        _auth(cam).auth.login(),
        throwsA(isA<TapoLockedError>().having((e) => e.secLeft, 'secLeft', 300)),
      );
      expect(cam.shareCount, 0);
      expect(cam.registerCount, 0);
    });

    test('dev confirm mismatch is auth error without retry', () async {
      final cam = FakeTpapCamera(expectedPasscode: _md5Pw)..badDevConfirm = true;
      await expectLater(_auth(cam).auth.login(), throwsA(isA<TapoAuthError>()));
      expect(cam.shareCount, 1);
    });

    test('empty password never reaches the camera', () async {
      final cam = FakeTpapCamera(expectedPasscode: _md5Pw);
      await expectLater(_auth(cam, password: '').auth.login(), throwsA(isA<TapoAuthError>()));
      expect(cam.registerCount, 0);
      expect(cam.shareCount, 0);
    });

    test('c200 sha256 extra crypt uses one attempt', () async {
      // extra_crypt present (shadow id 2 = sha1 hex) -> sha256 candidate first.
      final shaped = sha1.convert(utf8.encode(_sha256Pw)).toString();
      final cam = FakeTpapCamera(
        expectedPasscode: shaped,
        extraCrypt: {'type': 'password_shadow', 'params': {'passwd_id': 2}},
      );
      final t = _auth(cam);
      final s = await t.auth.login();
      expect(cam.shareCount, 1);
      expect(s.variant, 'sha256');
      expect(t.auth.goodVariant, 'sha256');
      expect(s.stok, 'stok-fake-1');
      expect(s.startSeq, 100);
      expect(s.expiresIn, 600);
    });

    test('order follows register evidence', () async {
      // No extra_crypt: md5 first.
      final plainCam = FakeTpapCamera(expectedPasscode: _md5Pw);
      expect((await _auth(plainCam).auth.login()).variant, 'md5');
      expect(plainCam.shareCount, 1);
      // With extra_crypt but a camera that wants the md5-derived passcode: sha256 is tried
      // first and refused, md5 second.
      final shaped = sha1.convert(utf8.encode(_md5Pw)).toString();
      final cam = FakeTpapCamera(
        expectedPasscode: shaped,
        extraCrypt: {'type': 'password_shadow', 'params': {'passwd_id': 2}},
      );
      expect((await _auth(cam).auth.login()).variant, 'md5');
      expect(cam.shareCount, 2);
    });

    test('lat tried first', () async {
      final cam = FakeTpapCamera(expectedPasscode: _latPasscode);
      final s = await _auth(cam, lat: _lat).auth.login();
      expect(s.variant, 'lat');
      expect(cam.shareCount, 1);
    });

    test('wrong lat falls back to best password variant', () async {
      final cam = FakeTpapCamera(expectedPasscode: _md5Pw);
      final s = await _auth(cam, lat: 'stale-lat-token').auth.login();
      expect(s.variant, 'md5');
      expect(cam.shareCount, 2); // still within the cap
    });

    test('lat only without password logs in', () async {
      final cam = FakeTpapCamera(expectedPasscode: _latPasscode);
      final s = await _auth(cam, password: '', lat: _lat).auth.login();
      expect(s.variant, 'lat');
      expect(cam.shareCount, 1);
    });

    test('wrong lat without password stops after one attempt and never names the token', () async {
      final cam = FakeTpapCamera(expectedPasscode: _latPasscode);
      await expectLater(
        _auth(cam, password: '', lat: 'stale-lat-token').auth.login(),
        throwsA(isA<TapoAuthError>().having((e) => e.message, 'message', isNot(contains('stale-lat-token')))),
      );
      expect(cam.shareCount, 1);
    });

    test('relogin reuses known good variant', () async {
      // Camera wants SHA256U(password) without extra_crypt: md5 fails, sha256 works.
      final cam = FakeTpapCamera(expectedPasscode: _sha256Pw);
      final t = _auth(cam);
      expect((await t.auth.login()).variant, 'sha256');
      expect(cam.shareCount, 2);
      // Second login: only the known variant. The C200 refuses the first share after a
      // session ended, so it is retried once after 2 s.
      cam.refuseNextShares = 1;
      final before = cam.shareCount;
      expect((await t.auth.login()).variant, 'sha256');
      expect(cam.shareCount - before, 2);
      expect(t.sleeps, [const Duration(seconds: 2)]);
    });

    test('two refusals of the known good variant raise', () async {
      final cam = FakeTpapCamera(expectedPasscode: _sha256Pw);
      final t = _auth(cam);
      await t.auth.login();
      cam.refuseNextShares = 5;
      final before = cam.shareCount;
      await expectLater(t.auth.login(), throwsA(isA<TapoAuthError>()));
      expect(cam.shareCount - before, 2);
      expect(t.auth.goodVariant, isNull);
    });

    test('session toString never shows the stok or keys', () async {
      final cam = FakeTpapCamera(expectedPasscode: _md5Pw);
      final s = await _auth(cam).auth.login();
      expect('$s', isNot(contains('stok-fake')));
      expect('${_auth(cam).auth}', isNot(contains(_password)));
    });
  });
}
