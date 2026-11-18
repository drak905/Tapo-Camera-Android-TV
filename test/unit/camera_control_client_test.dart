// Specs hc.local.login_flow, hc.local.breaker and the control-client part of
// hc.local.lat_mode (tier 2), against an in-test v3/legacy camera.
//
// SAFETY: after an auth failure no new login request may reach the camera for
// 120 s; a wrong password never sends a digest.

import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/camera_control_client.dart';
import 'package:tapo_tv/api/camera_dtos.dart';
import 'package:tapo_tv/api/tapo_errors.dart';

import '_support/fake_v3_camera.dart';
import '_support/helpers.dart';

const _password = 'test_password';
const _cnonce = 'ABCDEF0123456789';
const _nonce = '0123456789ABCDEF';

CameraControlClient _client(
  FakeV3Camera cam, {
  String password = _password,
  String? lat,
  LocalProtocolHint hint = LocalProtocolHint.probe,
  DateTime Function()? clock,
}) =>
    CameraControlClient(
      channel: cam,
      secrets: LocalSecrets(password: password, lat: lat),
      hint: hint,
      cnonce: () => _cnonce,
      clock: clock,
      sleep: (_) async {},
    );

final _info = [buildGetDeviceInfo()];

void main() {
  group('login flow', () {
    test('secure login step1 body exact', () async {
      final cam = FakeV3Camera(secret: _password);
      await _client(cam).login();
      expect(
        cam.loginBodies.first,
        '{"method":"login","params":{"cnonce":"$_cnonce","encrypt_type":"3","username":"admin"}}',
      );
    });

    test('secure login step2 body exact', () async {
      final cam = FakeV3Camera(secret: _password);
      await _client(cam).login();
      expect(cam.loginBodies, hasLength(2));
      final step2 = jsonDecode(cam.loginBodies[1]) as Map<String, dynamic>;
      expect(step2['method'], 'login');
      expect(step2['params'], {
        'cnonce': _cnonce,
        'encrypt_type': '3',
        'username': 'admin',
        'digest_passwd':
            '${sha256UpperRef(sha256UpperRef(_password) + _cnonce + _nonce)}$_cnonce$_nonce',
      });
      expect(cam.loginSuccesses, 1);
    });

    test('legacy login body exact', () async {
      final cam = FakeV3Camera(secret: _password, mode: FakeCameraMode.legacy);
      final c = _client(cam);
      await c.login();
      expect(
        cam.loginBodies.last,
        '{"method":"login","params":{"hashed":true,"password":"16EC1EBB01FE02DED9B7D5447D3DFC65",'
        '"username":"admin"}}',
      );
      final items = await c.send(_info);
      expect(items.single.ok, isTrue);
      expect(cam.received.single['method'], 'multipleRequest'); // plain JSON, no tag
    });

    test('wrong password sends no digest', () async {
      final cam = FakeV3Camera(secret: 'the real password');
      await expectLater(_client(cam).login(), throwsA(isA<TapoAuthError>()));
      expect(cam.digestAttempts, 0);
      expect(cam.loginBodies, hasLength(1));
    });

    test('locked login', () async {
      final cam = FakeV3Camera(secret: _password)..locked = true;
      await expectLater(
        _client(cam).login(),
        throwsA(isA<TapoLockedError>().having((e) => e.secLeft, 'secLeft', 300)),
      );
    });

    test('http 401 is an auth error and other statuses protocol errors', () async {
      final cam = FakeV3Camera(secret: _password)..loginHttpStatus = 401;
      await expectLater(_client(cam).login(), throwsA(isA<TapoAuthError>()));
      final cam2 = FakeV3Camera(secret: _password)..loginHttpStatus = 500;
      await expectLater(_client(cam2).login(), throwsA(isA<TapoProtocolError>()));
    });

    test('tpap hint skips the v3 probe', () async {
      final cam = FakeV3Camera(secret: _password, mode: FakeCameraMode.tpap);
      try {
        await _client(cam, hint: LocalProtocolHint.tpap).login();
      } on TapoError {
        // the fake does not speak TPAP; only the first request matters
      }
      expect(cam.loginBodies.first, contains('"sub_method":"pake_register"'));
      expect(cam.stepOneCount, 0);
    });

    test('minus 40211 on step one switches to tpap', () async {
      final cam = FakeV3Camera(secret: _password, mode: FakeCameraMode.tpap);
      try {
        await _client(cam).login();
      } on TapoError {
        // the fake does not speak TPAP
      }
      expect(cam.stepOneCount, 1);
      expect(cam.loginBodies[1], contains('"sub_method":"pake_register"'));
    });
  });

  group('session handling', () {
    test('per item -40401 relogins once', () async {
      final cam = FakeV3Camera(secret: _password);
      final c = _client(cam);
      await c.login();
      cam.invalidateNext = 1;
      final items = await c.send(_info);
      expect(items.single.ok, isTrue);
      expect(cam.stepOneCount, 2); // initial login + one re-login
      expect(cam.received, hasLength(2)); // failed try + one retry
    });

    test('persistent expiry gives up after one retry', () async {
      final cam = FakeV3Camera(secret: _password);
      final c = _client(cam);
      await c.login();
      cam.invalidateNext = 99;
      await expectLater(c.send(_info), throwsA(isA<TapoError>()));
      expect(cam.stepOneCount, 2);
      expect(cam.received, hasLength(2));
    });

    test('seq increments per request', () async {
      final cam = FakeV3Camera(secret: _password);
      final c = _client(cam);
      await c.login();
      await c.send(_info);
      await c.send(_info);
      await c.send(_info);
      expect(cam.seqs, [1234, 1235, 1236]);
    });

    test('seq is consumed even when the request fails', () async {
      final cam = FakeV3Camera(secret: _password);
      final c = _client(cam);
      await c.login();
      cam.throwOnNext = 1;
      await expectLater(c.send(_info), throwsA(anything));
      await c.send(_info);
      expect(cam.seqs.single, 1235);
    });
  });

  group('lat mode', () {
    test('v3 camera in lat mode', () async {
      final cam = FakeV3Camera(secret: 'lat-token-value');
      final c = _client(cam, password: _password, lat: 'lat-token-value');
      await c.login();
      expect(cam.digestAttempts, 1);
      expect((await c.send(_info)).single.ok, isTrue); // tag is built from the LAT too
    });

    test('v3 on password with lat given', () async {
      final cam = FakeV3Camera(secret: _password);
      final c = _client(cam, lat: 'stale-lat-token');
      await c.login();
      expect(cam.digestAttempts, 1); // the stale LAT never produced a digest
      expect((await c.send(_info)).single.ok, isTrue);
    });

    test('device confirm matching neither lat nor password sends no digest', () async {
      final cam = FakeV3Camera(secret: 'something else');
      await expectLater(_client(cam, lat: 'stale-lat-token').login(), throwsA(isA<TapoAuthError>()));
      expect(cam.digestAttempts, 0);
    });

    test('legacy login always uses the password', () async {
      final cam = FakeV3Camera(secret: _password, mode: FakeCameraMode.legacy);
      await _client(cam, lat: 'lat-token-value').login();
      expect(cam.loginSuccesses, 1);
    });

    test('secrets never appear in toString', () {
      const s = LocalSecrets(password: 'pw-secret-1', lat: 'lat-secret-1');
      expect('$s', isNot(contains('pw-secret-1')));
      expect('$s', isNot(contains('lat-secret-1')));
    });
  });

  group('breaker', () {
    test('wrong password fails fast without new login attempts', () {
      fakeAsync((async) {
        final cam = FakeV3Camera(secret: 'the real password');
        final c = _client(cam, clock: async.getClock(DateTime(2025)).now);
        final errors = <Object>[];
        void attempt() => c.login().then((_) {}, onError: errors.add);

        attempt();
        async.flushMicrotasks();
        expect(errors.single, isA<TapoAuthError>());
        expect(cam.loginBodies, hasLength(1));

        for (var i = 0; i < 5; i++) {
          attempt();
          async.flushMicrotasks();
        }
        expect(errors, everyElement(isA<TapoAuthError>()));
        expect(errors, hasLength(6));
        expect(cam.loginBodies, hasLength(1), reason: 'no new request while the breaker is armed');
        expect(c.authRetryAfter, isNotNull);
        expect(c.authRetryAfter!.inSeconds, inInclusiveRange(119, 120));
      });
    });

    test('breaker expires after 120 s and reset allows retry', () {
      fakeAsync((async) {
        final cam = FakeV3Camera(secret: 'the real password');
        final c = _client(cam, clock: async.getClock(DateTime(2025)).now);
        final errors = <Object>[];
        void attempt() => c.login().then((_) {}, onError: errors.add);

        attempt();
        async.flushMicrotasks();
        expect(cam.loginBodies, hasLength(1));

        async.elapse(const Duration(seconds: 119));
        attempt();
        async.flushMicrotasks();
        expect(cam.loginBodies, hasLength(1), reason: 'still blocked at 119 s');

        async.elapse(const Duration(seconds: 2));
        attempt();
        async.flushMicrotasks();
        expect(cam.loginBodies, hasLength(2), reason: 'allowed after 120 s');

        // An explicit reset (new password / new LAT) allows an immediate retry.
        c.resetAuthBackoff();
        expect(c.authRetryAfter, isNull);
        cam.secret = _password;
        var ok = false;
        c.login().then((_) => ok = true);
        async.flushMicrotasks();
        expect(ok, isTrue);
        expect(c.authRetryAfter, isNull);
        expect(c.loggedIn, isTrue);
      });
    });

    test('lockout is not breakered', () {
      fakeAsync((async) {
        final cam = FakeV3Camera(secret: _password)..locked = true;
        final c = _client(cam, clock: async.getClock(DateTime(2025)).now);
        final errors = <Object>[];
        for (var i = 0; i < 2; i++) {
          c.login().then((_) {}, onError: errors.add);
          async.flushMicrotasks();
        }
        expect(errors, everyElement(isA<TapoLockedError>()));
        expect(cam.loginBodies, hasLength(2));
        expect(c.authRetryAfter, isNull);
      });
    });
  });
}
