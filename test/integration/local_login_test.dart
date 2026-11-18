// Tier 2, scenario 4: local login. Real CameraControlClient -> CameraTransport
// (TOFU pin) -> TlsCameraLink -> MockCamera :443 over loopback TLS.
// Covers secure v3, legacy MD5, TPAP (password and LAT), -40211 forcing TPAP,
// wrong password -> breaker, and "no login loops" via MockCamera.loginAttempts.
// Specs: hc.local.v3, hc.local.legacy, hc.local.tpap, hc.local.breaker.
@Timeout(Duration(seconds: 120))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/camera_control_client.dart';
import 'package:tapo_tv/api/camera_dtos.dart';
import 'package:tapo_tv/api/tapo_errors.dart';

import '../fixtures/mock_camera.dart';
import 'support/camera_rig.dart';

Future<MockCamera> _start(MockCamera cam) async {
  await cam.start();
  addTearDown(cam.stop);
  return cam;
}

Future<void> _expectModel(CameraControlClient client, String model) async {
  final items = await client.send([buildGetDeviceInfo()]);
  expect(items, hasLength(1));
  expect(items.single.ok, isTrue);
  expect(parseDeviceInfo(items.single.result).deviceModel, model);
}

void main() {
  group('secure v3', () {
    test('two-step login, encrypted /ds call, one session, no loop', () async {
      final cam = await _start(MockCamera(cloudPassword: 'pw-secure'));
      final client = controlClientFor(cam, password: 'pw-secure');
      addTearDown(client.close);

      await client.login();

      expect(client.loggedIn, isTrue);
      await _expectModel(client, 'C210');
      expect(cam.loginCount, 1);
      expect(cam.loginAttempts, lessThanOrEqualTo(3));
      expect(cam.requestLog.map((c) => c.method), contains('getDeviceInfo'));
    });

    test('the certificate is pinned on first use and a rotated one is refused before any login', () async {
      final cam = await _start(MockCamera(cloudPassword: 'pw-secure'));
      final pins = MemoryPins();
      final first = controlClientFor(cam, password: 'pw-secure', pins: pins);
      await first.login();
      first.close();
      expect(pins.pins, hasLength(1));
      expect(pins.pins.values.single, cam.certFingerprint);
      final attempts = cam.loginAttempts;

      await cam.rotateCertificate();
      final second = controlClientFor(cam, password: 'pw-secure', pins: pins);
      addTearDown(second.close);
      await expectLater(second.login(), throwsA(anything));
      expect(cam.loginAttempts, attempts, reason: 'secrets must not be sent to a changed certificate');
    });

    test('an expired session is renewed once and the call succeeds', () async {
      final cam = await _start(MockCamera(cloudPassword: 'pw-secure'));
      final client = controlClientFor(cam, password: 'pw-secure');
      addTearDown(client.close);
      await client.login();

      cam.expireSessions();
      await _expectModel(client, 'C210');

      expect(cam.loginCount, 2);
      expect(cam.loginAttempts, lessThanOrEqualTo(6));
    });

    test('wrong password: login fails, breaker opens, nothing more is sent until reset', () async {
      final cam = await _start(MockCamera(cloudPassword: 'pw-secure'));
      final client = controlClientFor(cam, password: 'WRONG');
      addTearDown(client.close);

      await expectLater(client.login(), throwsA(anything));
      expect(client.loggedIn, isFalse);
      final retry = client.authRetryAfter;
      expect(retry, isNotNull);
      expect(retry!.inSeconds, inInclusiveRange(1, CameraControlClient.authBackoff.inSeconds));
      final attempts = cam.loginAttempts;
      expect(attempts, lessThanOrEqualTo(3));
      expect(cam.loginCount, 0);

      await expectLater(client.login(), throwsA(anything));
      await expectLater(client.send([buildGetDeviceInfo()]), throwsA(anything));
      expect(cam.loginAttempts, attempts, reason: 'breaker open: the camera sees no more logins');

      client.resetAuthBackoff();
      expect(client.authRetryAfter, isNull);
      await expectLater(client.login(), throwsA(anything));
      expect(cam.loginAttempts, greaterThan(attempts));
      expect(cam.loginAttempts, lessThanOrEqualTo(attempts + 3));
    });

    test('LAT mode: the local access token is the camera password', () async {
      final cam = await _start(MockCamera(
        protocol: CameraProtocol.secure,
        tpapCredential: TpapCredential.lat,
        localToken: 'LAT-0123456789abcdef',
      ));
      final client = controlClientFor(cam, lat: 'LAT-0123456789abcdef');
      addTearDown(client.close);
      await client.login();
      await _expectModel(client, 'C210');
      expect(cam.loginCount, 1);
    });
  });

  group('legacy MD5', () {
    test('hashed login, plain JSON /ds, no loop', () async {
      final cam = await _start(MockCamera(protocol: CameraProtocol.legacy, cloudPassword: 'pw-legacy'));
      final client = controlClientFor(cam, password: 'pw-legacy');
      addTearDown(client.close);

      await client.login();

      expect(client.loggedIn, isTrue);
      await _expectModel(client, 'C210');
      expect(cam.loginCount, 1);
      expect(cam.loginAttempts, lessThanOrEqualTo(3));
    });

    test('wrong password opens the breaker', () async {
      final cam = await _start(MockCamera(protocol: CameraProtocol.legacy, cloudPassword: 'pw-legacy'));
      final client = controlClientFor(cam, password: 'WRONG');
      addTearDown(client.close);
      await expectLater(client.login(), throwsA(anything));
      final attempts = cam.loginAttempts;
      expect(client.authRetryAfter, isNotNull);
      await expectLater(client.login(), throwsA(anything));
      expect(cam.loginAttempts, attempts);
    });
  });

  group('TPAP', () {
    test('password login with the TDP hint: register + share, at most 2 attempts', () async {
      final cam = await _start(MockCamera(protocol: CameraProtocol.tpap, cloudPassword: 'pw-tpap'));
      final client = controlClientFor(cam, password: 'pw-tpap', hint: LocalProtocolHint.tpap);
      addTearDown(client.close);

      await client.login();

      expect(client.loggedIn, isTrue);
      await _expectModel(client, 'C210');
      expect(cam.tpapRegisterCount, 1);
      expect(cam.tpapShareAttempts, 1);
      expect(cam.loginAttempts, lessThanOrEqualTo(2));
      expect(cam.v3ProbeCount, 0);
      expect(cam.tpapDsSeqs, isNotEmpty);
      for (var i = 1; i < cam.tpapDsSeqs.length; i++) {
        expect(cam.tpapDsSeqs[i], greaterThan(cam.tpapDsSeqs[i - 1]), reason: 'seq must increase');
      }
    });

    test('LAT login (no password stored)', () async {
      final cam = await _start(MockCamera(
        protocol: CameraProtocol.tpap,
        tpapCredential: TpapCredential.lat,
        localToken: 'LAT-0123456789abcdef',
      ));
      final client = controlClientFor(cam, lat: 'LAT-0123456789abcdef', hint: LocalProtocolHint.tpap);
      addTearDown(client.close);

      await client.login();

      await _expectModel(client, 'C210');
      expect(cam.tpapShareAttempts, 1);
      expect(cam.loginAttempts, lessThanOrEqualTo(2));
    });

    test('-40211 on the v3 probe forces TPAP without a hint, one probe only', () async {
      final cam = await _start(MockCamera(protocol: CameraProtocol.tpap, cloudPassword: 'pw-tpap'));
      final client = controlClientFor(cam, password: 'pw-tpap');
      addTearDown(client.close);

      await client.login();

      await _expectModel(client, 'C210');
      expect(cam.v3ProbeCount, 1);
      expect(cam.tpapRegisterCount, 1);
      expect(cam.tpapShareAttempts, 1);
      expect(cam.loginAttempts, lessThanOrEqualTo(3));
    });

    test('wrong password: two failed shares (MAX_ATTEMPTS), breaker opens, no loop', () async {
      final cam = await _start(MockCamera(protocol: CameraProtocol.tpap, cloudPassword: 'pw-tpap'));
      final client = controlClientFor(cam, password: 'WRONG', hint: LocalProtocolHint.tpap);
      addTearDown(client.close);

      await expectLater(client.login(), throwsA(anything));

      expect(client.loggedIn, isFalse);
      expect(client.authRetryAfter, isNotNull);
      // Windows tpap.py MAX_ATTEMPTS = 2 (md5 then sha256); test_tpap_login.py:166
      // asserts exactly two shares for a wrong password.
      expect(cam.tpapShareAttempts, 2);
      expect(cam.loginAttempts, lessThanOrEqualTo(4), reason: '2 x (register + share)');
      final attempts = cam.loginAttempts;
      await expectLater(client.login(), throwsA(anything));
      await expectLater(client.send([buildGetDeviceInfo()]), throwsA(anything));
      expect(cam.loginAttempts, attempts);
    });

    test('a locked camera (-40404) stops at the register step, no password guess is spent', () async {
      final cam = await _start(MockCamera(protocol: CameraProtocol.tpap, cloudPassword: 'pw-tpap'));
      cam.lockLogin(const Duration(minutes: 5));
      final client = controlClientFor(cam, password: 'pw-tpap', hint: LocalProtocolHint.tpap);
      addTearDown(client.close);

      // Lockout is NOT breakered (spec hc.local.breaker, Windows client.py:385,
      // unit test 'lockout is not breakered'): every login is one register that
      // answers -40404; no pake_share (password guess) is ever sent.
      await expectLater(client.login(), throwsA(isA<TapoLockedError>()));
      final attempts = cam.loginAttempts;
      expect(attempts, 1);
      expect(client.authRetryAfter, isNull);
      await expectLater(client.login(), throwsA(isA<TapoLockedError>()));
      expect(cam.loginAttempts, attempts + 1);
      expect(cam.tpapShareAttempts, 0);
    });

    test('TPAP session expiry mid-run: one re-login, the call succeeds', () async {
      final cam = await _start(MockCamera(protocol: CameraProtocol.tpap, cloudPassword: 'pw-tpap'));
      final client = controlClientFor(cam, password: 'pw-tpap', hint: LocalProtocolHint.tpap);
      addTearDown(client.close);
      await client.login();

      cam.expireSessions();
      await _expectModel(client, 'C210');

      expect(cam.tpapShareAttempts, 2);
      expect(cam.loginAttempts, lessThanOrEqualTo(4));
    });
  });
}
