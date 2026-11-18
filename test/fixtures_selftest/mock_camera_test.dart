// Self-test of test/fixtures/mock_camera.dart, driven with raw HTTPS requests.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../fixtures/camera_state.dart';
import '../fixtures/fx_crypto.dart';
import '../fixtures/mock_camera.dart';
import '../fixtures/tpap_server.dart';
import 'raw_clients.dart';

Future<MockCamera> startCam([MockCamera? c]) async {
  final cam = c ?? MockCamera();
  await cam.start();
  addTearDown(cam.stop);
  return cam;
}

Map<String, dynamic> req(String method, Map<String, dynamic> params) =>
    {'method': method, 'params': params};

void main() {
  group('secure v3', () {
    test('golden device_confirm and deterministic start_seq', () async {
      final cam = await startCam(MockCamera(cloudPassword: 'test_password')
        ..fixedNonce = '0123456789ABCDEF'
        ..fixedStartSeq = 1234);
      final c = SecureClient(cam.host, cam.port, 'test_password', cnonce: 'ABCDEF0123456789');
      addTearDown(c.close);
      final r1 = await c.step1();
      expect(r1['error_code'], -40413);
      expect(r1['result']['data']['nonce'], '0123456789ABCDEF');
      expect(r1['result']['data']['device_confirm'],
          'AE0E012599836B112471EC21767309CF4A927A9053B8A9FA7917E8AB28F09D010123456789ABCDEFABCDEF0123456789');
      final r2 = await c.step2('0123456789ABCDEF');
      expect(r2['error_code'], 0);
      expect(r2['result']['start_seq'], 1234);
      expect(cam.loginAttempts, 2);
      expect(cam.loginCount, 1);
    });

    test('presents a self-signed cert with a stable fingerprint', () async {
      final cam = await startCam();
      final c = RawHttps(cam.host, cam.port);
      await c.post('/', '{}');
      expect(toHex(sha256Raw(c.peerDer!)), cam.certFingerprint);
      c.close();
    });

    test('multipleRequest: info, privacy toggle, PTZ, alarm, search', () async {
      final cam = await startCam();
      final c = SecureClient(cam.host, cam.port, 'cloudpass');
      addTearDown(c.close);
      await c.login();
      final rs = await c.multi([
        getDeviceInfoReq(),
        req('getLensMaskConfig', {'lens_mask': {'name': ['lens_mask_info']}}),
        req('getLastAlarmInfo', {'system': {'name': ['last_alarm_info']}}),
      ]);
      expect(rs[0]['result']['device_info']['basic_info']['device_alias'], 'Mock Camera');
      expect(rs[1]['result']['lens_mask']['lens_mask_info']['enabled'], 'off');
      expect(rs[2]['result']['system']['last_alarm_info']['last_alarm_type'], 'motion');

      final set = await c.multi([
        req('setLensMaskConfig', {'lens_mask': {'lens_mask_info': {'enabled': 'on'}}}),
        req('motorMove', {'motor': {'move': {'x_coord': '10', 'y_coord': '-5'}}}),
        req('motorMove', {'motor': {'move': {'x_coord': 10, 'y_coord': 0}}}),
        req('nonsense', {}),
      ]);
      expect(set.map((e) => e['error_code']), [0, 0, -40210, -40106]);
      expect(cam.state.privacy, isTrue);
      expect((cam.state.ptzX, cam.state.ptzY), (10, -5));
      expect(cam.requestLog.map((e) => e.method).toList().sublist(3, 5),
          ['setLensMaskConfig', 'motorMove']);
    });

    test('recordings: days, clips by UTC window, -71103 with id, ok with player_id', () async {
      final cam = await startCam(MockCamera()..clipSearchRequiresPlayerId = true);
      final c = SecureClient(cam.host, cam.port, 'cloudpass');
      addTearDown(c.close);
      await c.login();
      final today = cam.state.recordings[1].start;
      final from = today.subtract(const Duration(days: 3));
      String ymd(DateTime d) =>
          '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
      final days = await c.multi([
        req('searchDateWithVideo', {
          'playback': {
            'search_year_utility': {'channel': [0], 'start_date': ymd(from), 'end_date': ymd(today)}
          }
        })
      ]);
      expect((days[0]['result']['playback']['search_results'] as List).length, 2);

      final lo = cam.state.recordings[1].startEpoch - 10;
      final hi = cam.state.recordings[3].startEpoch + 10;
      Map<String, dynamic> clipReq(Map<String, dynamic> idPart) => req('searchVideoWithUTC', {
            'playback': {
              'search_video_with_utc': {
                ...idPart,
                'channel': 0,
                'start_time': lo,
                'end_time': hi,
                'start_index': 0,
                'end_index': 1
              }
            }
          });
      final legacy = await c.multi([clipReq({'id': 1})]);
      expect(legacy[0]['error_code'], -71103);
      final ok = await c.multi([clipReq({'player_id': 'ab' * 16})]);
      expect(ok[0]['error_code'], 0);
      final pb = ok[0]['result']['playback'];
      expect((pb['search_video_results'] as List).length, 2);
      expect(pb['to_be_continued'], 1);
      expect(pb['search_video_results'][0]['search_video_results_1']['startTime'], lo + 10);
    });

    test('wrong password: -40401, counters, lockout after N, -40404 sec_left', () async {
      final cam = await startCam(MockCamera()
        ..maxFailedLogins = 2
        ..lockoutSeconds = 60);
      for (var i = 0; i < 2; i++) {
        final c = SecureClient(cam.host, cam.port, 'WRONG');
        final r1 = await c.step1();
        final r2 = await c.step2(r1['result']['data']['nonce'] as String);
        expect(r2['error_code'], -40401);
        c.close();
      }
      expect(cam.loginAttempts, 4);
      final c = SecureClient(cam.host, cam.port, 'cloudpass');
      final r = await c.step1();
      expect(r['error_code'], -40404);
      expect(r['result']['data']['sec_left'], inInclusiveRange(1, 61));
      expect(cam.loginCount, 0);
      c.close();
    });

    test('device_confirm lets a client verify the password before spending an attempt', () async {
      final cam = await startCam();
      final c = SecureClient(cam.host, cam.port, 'WRONG');
      final r1 = await c.step1();
      final d = r1['result']['data'];
      expect(d['device_confirm'], isNot(deviceConfirm('WRONG', c.cnonce, d['nonce'] as String)));
      expect(d['device_confirm'], deviceConfirm('cloudpass', c.cnonce, d['nonce'] as String));
      c.close();
    });

    test('replayed seq, bad tag, expired session, undecodable body', () async {
      final cam = await startCam();
      final c = SecureClient(cam.host, cam.port, 'cloudpass');
      addTearDown(c.close);
      await c.login();
      final info = {'method': 'multipleRequest', 'params': {'requests': [getDeviceInfoReq()]}};
      expect((await c.send(info))['error_code'], 0);
      final used = c.seq - 1;
      expect((await c.send(info, seqOverride: used))['error_code'], -40401);
      expect((await c.send(info, tagOverride: 'DEAD'))['error_code'], -40401);
      final junk = 'not json';
      expect((await c.send(info, body: junk))['error_code'], -40210);
      cam.expireSessions();
      expect((await c.send(info))['error_code'], -40401);
    });

    test('injectError, token expiry every 2nd request, HTTP status injection', () async {
      final cam = await startCam();
      final c = SecureClient(cam.host, cam.port, 'cloudpass');
      addTearDown(c.close);
      await c.login();
      cam.injectError('getDeviceInfo', -40401);
      var rs = await c.multi([getDeviceInfoReq()]);
      expect(rs[0]['error_code'], -40401);
      rs = await c.multi([getDeviceInfoReq()]);
      expect(rs[0]['error_code'], 0);
      cam.injectTokenExpiry(2);
      final info = {'method': 'multipleRequest', 'params': {'requests': [getDeviceInfoReq()]}};
      expect((await c.send(info))['error_code'], 0);
      expect((await c.send(info))['error_code'], -40401);
      cam.injectHttpStatus(503);
      final (status, _) = await c.post('/', '{}');
      expect(status, 503);
    });

    test('v3 step 1 with a legacy-style body does not hand out a nonce', () async {
      final cam = await startCam();
      final c = LegacyClient(cam.host, cam.port, 'cloudpass');
      final r = await c.login();
      expect(r['error_code'], -40413);
      expect(r['result']['data'].containsKey('nonce'), isFalse);
      c.close();
    });
  });

  group('legacy MD5', () {
    test('login + plain JSON /ds; wrong password -40401', () async {
      final cam = await startCam(MockCamera(protocol: CameraProtocol.legacy));
      final c = LegacyClient(cam.host, cam.port, 'cloudpass');
      addTearDown(c.close);
      expect((await c.login('nope'))['error_code'], -40401);
      expect((await c.login())['error_code'], 0);
      final r = await c.send({'method': 'multipleRequest', 'params': {'requests': [getDeviceInfoReq()]}});
      expect(r['result']['responses'][0]['result']['device_info']['basic_info']['device_model'], 'C210');
      expect(cam.loginAttempts, 2);
      cam.expireSessions();
      expect((await c.send({'method': 'multipleRequest', 'params': {'requests': []}}))['error_code'], -40401);
    });

    test('secure step 1 on a legacy camera -> -40210', () async {
      final cam = await startCam(MockCamera(protocol: CameraProtocol.legacy));
      final c = SecureClient(cam.host, cam.port, 'cloudpass');
      expect((await c.step1())['error_code'], -40210);
      c.close();
    });
  });

  group('TPAP', () {
    test('RFC 9383 prover vector (client side used by these tests)', () {
      final r = spakeProve(
        w0: bigFromHex('bb8e1bbcf3c48f62c08db243652ae55d3e5586053fca77102994f23ad95491b3'),
        w1: bigFromHex('7e945f34d78785b8a3ef44d0df5a1a97d6b3b460409a345ca7830387a74b1dba'),
        x: bigFromHex('d1232c8e8693d02368976c174e2088851b8365d0d79a9eee709c6a05a2fad539'),
        shareV: fromHex(
            '04c0f65da0d11927bdf5d560c69e1d7d939a05b0e88291887d679fcadea75810fb5cc1ca7494db39e82ff2f50665255d76173e09986ab46742c798a9a68437b048'),
        context: utf8.encode('SPAKE2+-P256-SHA256-HKDF-SHA256-HMAC-SHA256 Test Vectors'),
        idProver: utf8.encode('client'),
        idVerifier: utf8.encode('server'),
      );
      expect(toHex(r.shareP),
          '04ef3bd051bf78a2234ec0df197f7828060fe9856503579bb1733009042c15c0c1de127727f418b5966afadfdd95a6e4591d171056b333dab97a79c7193e341727');
      expect(toHex(r.z),
          '04bbfce7dd7f277819c8da21544afb7964705569bdf12fb92aa388059408d50091a0c5f1d3127f56813b5337f9e4e67e2ca633117a4fbd559946ab474356c41839');
      expect(toHex(r.v),
          '0458bf27c6bca011c9ce1930e8984a797a3419797b936629a5a937cf2f11c8b9514b82b993da8a46e664f23db7c01edc87faa530db01c2ee405230b18997f16b68');
      expect(toHex(r.kMain), '4c59e1ccf2cfb961aa31bd9434478a1089b56cd11542f53d3576fb6c2a438a29');
      expect(toHex(r.kConfirmP), '871ae3f7b78445e34438fb284504240239031c39d80ac23eb5ab9be5ad6db58a');
      expect(toHex(r.kConfirmV), 'ccd53c7c1fa37b64a462b40db8be101cedcf838950162902054e644b400f1680');
      expect(toHex(r.confirmP), '926cc713504b9b4d76c9162ded04b5493e89109f6d89462cd33adc46fda27527');
      expect(toHex(r.confirmV), '9747bcc4f8fe9f63defee53ac9b07876d907d55047e6ff2def2e7529089d3e68');
      expect(toHex(r.kShared), '0c5f8ccd1413423a54f6c1fb26ff01534a87f893779c6e68666d772bfd91f3e7');
    });

    test('PBKDF2 raw dk and sha256-crypt goldens', () {
      // dk = 6a2609b1... for passcode 0123abcd; w0/w1 are dk[0:40], dk[40:80] mod n.
      final dk = fromHex(
          '6a2609b1bd0e81bb87a610193883a82cfcfbf9895fda4773531c635cd94d37707c5f53c7cf54ef1d8385682989155bfd78a368e90c4defa9b76edf27983ae65b3199554a0f499343c0dc9dea8e4d076e');
      final w = tpapW0W1('0123abcd', fromHex('000102030405060708090a0b0c0d0e0f'), 1000);
      BigInt big(List<int> b) => b.fold(BigInt.zero, (a, x) => (a << 8) | BigInt.from(x));
      expect(w.w0, big(dk.sublist(0, 40)) % p256Order);
      expect(w.w1, big(dk.sublist(40)) % p256Order);
      expect(sha256Crypt('Hello world!', r'$5$saltstring'),
          r'$5$saltstring$5B8vYYiY.CVt1RlTTf8KbXBH3hsxY/GNooZaBBGWEc5');
      expect(sha256Crypt('Hello world!', r'$5$rounds=10000$saltstringsaltstring'),
          r'$5$rounds=10000$saltstringsaltst$3xv.VbSHBb41AL9AvLeujZkZRBAwqFMz2.opqey6IcA');
    });

    test('v3 probe -> -40211; md5 passcode login; CCM /ds; replay refused', () async {
      final cam = await startCam(MockCamera(protocol: CameraProtocol.tpap)..fixedStartSeq = 4242);
      final c = TpapClient(cam.host, cam.port);
      addTearDown(c.close);
      expect((await c.v3Probe())['error_code'], -40211);
      expect(cam.v3ProbeCount, 1);
      final r = await c.login(md5Hex('cloudpass'));
      expect(r['error_code'], 0, reason: '$r');
      expect(r['result']['start_seq'], 4242);
      final reply = await c.send({'method': 'multipleRequest', 'params': {'requests': [getDeviceInfoReq()]}});
      expect(reply['result']['responses'][0]['result']['device_info']['basic_info']['device_model'], 'C210');
      expect(cam.tpapDsSeqs, [4242]);
      // replay -> plaintext -40401 and the session is gone
      final replay = await c.send(
          {'method': 'multipleRequest', 'params': {'requests': []}}, seqOverride: 4242);
      expect(replay['_plain'], isTrue);
      expect(replay['error_code'], -40401);
      final after = await c.send({'method': 'multipleRequest', 'params': {'requests': []}});
      expect(after['error_code'], -40401);
    });

    test('wrong passcode -40401, counters, lockout', () async {
      final cam = await startCam(MockCamera(protocol: CameraProtocol.tpap)
        ..maxFailedLogins = 2
        ..lockoutSeconds = 60);
      final c = TpapClient(cam.host, cam.port);
      addTearDown(c.close);
      expect((await c.login(md5Hex('wrong')))['error_code'], -40401);
      expect((await c.login(md5Hex('wrong')))['error_code'], -40401);
      expect(cam.tpapShareAttempts, 2);
      expect(cam.tpapRegisterCount, 2);
      final locked = await c.register();
      expect(locked['error_code'], -40404);
      expect(cam.loginCount, 0);
    });

    test('LAT mode accepts only SHA256U(LAT); user_hash admin variant', () async {
      final cam = await startCam(MockCamera(
          protocol: CameraProtocol.tpap,
          tpapCredential: TpapCredential.lat,
          localToken: '0123456789abcdef0123456789abcdef'));
      final c = TpapClient(cam.host, cam.port);
      addTearDown(c.close);
      expect((await c.login(md5Hex('cloudpass')))['error_code'], -40401);
      final ok = await c.login(
          '3EB1BD439947EB762998E566CCC2E099C791118B2F40579CC4F7DA2B5061B7F9');
      expect(ok['error_code'], 0);
      // literal "admin" is refused by default (-40209)
      expect((await c.register(username: 'admin'))['error_code'], -40209);
    });

    test('sha256_extra advertises extra_crypt and expects the shadow passcode', () async {
      final cam = await startCam(MockCamera(
          protocol: CameraProtocol.tpap, tpapCredential: TpapCredential.sha256Extra));
      final c = TpapClient(cam.host, cam.port);
      addTearDown(c.close);
      final reg = await c.register();
      final ec = reg['result']['extra_crypt'];
      expect(ec['type'], 'password_shadow');
      expect(ec['params']['passwd_id'], 5);
      final pass = sha256Crypt(sha256Upper('cloudpass'), ec['params']['passwd_prefix'] as String);
      expect((await c.login(pass))['error_code'], 0);
    });

    test('tpapRefuseShares refuses the first correct share once', () async {
      final cam = await startCam(
          MockCamera(protocol: CameraProtocol.tpap)..tpapRefuseShares = 1);
      final c = TpapClient(cam.host, cam.port);
      addTearDown(c.close);
      expect((await c.login(md5Hex('cloudpass')))['error_code'], -40401);
      expect((await c.login(md5Hex('cloudpass')))['error_code'], 0);
      expect(cam.tpapShareAttempts, 2);
    });
  });

  test('shadow: defaults have 3 clips today and 1 yesterday', () {
    final r = defaultRecordings();
    expect(r.length, 4);
    expect(r.first.eventType, 2);
  });
}
