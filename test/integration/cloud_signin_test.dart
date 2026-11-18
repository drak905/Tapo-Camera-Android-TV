// Tier 2, scenario 1: cloud sign-in incl. MFA, region redirect and silent token
// refresh. Real TapoCloud -> LoopbackCloudTransport -> MockCloud (signature
// verified by the mock). Specs: hc.cloud.signing, hc.cloud.mfa,
// hc.cloud.region_redirect, hc.cloud.token_refresh, hc.cloud.service_urls.
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/tapo_cloud.dart';

import '../fixtures/mock_cloud.dart' hide iotServiceId, cipcServiceId;
import 'support/cloud_rig.dart';

void main() {
  test('plain login at the bootstrap host: token, signed request, common query', () async {
    final rig = await CloudRig.start(regionRedirect: false);
    final login = await rig.cloud.login(testEmail, testPassword);

    expect(login.token, isNotNull);
    expect(rig.mock.validTokens, contains(login.token));
    final call = rig.mock.calls('/api/v2/account/login').single;
    expect(call.signatureOk, isTrue, reason: 'Content-MD5 / HMAC-SHA1 signature must verify');
    expect(call.query['appName'], appType);
    expect(call.query['termID'], testTerminal);
    expect(call.body, isA<Map>());
    expect((call.body as Map)['terminalUUID'], testTerminal);
    expect((call.body as Map)['cloudUserName'], testEmail);
  });

  test('wrong password and unknown account map to TapoException codes', () async {
    final rig = await CloudRig.start(regionRedirect: false);
    await expectLater(
      rig.cloud.login(testEmail, 'nope'),
      throwsA(isA<TapoException>().having((e) => e.code, 'code', -20601)),
    );
    await expectLater(
      rig.cloud.login('nobody@example.com', 'x'),
      throwsA(isA<TapoException>().having((e) => e.code, 'code', -20600)),
    );
    expect(rig.mock.validTokens, isEmpty);
  });

  test('locked account answers -20661 without a token', () async {
    final rig = await CloudRig.start(regionRedirect: false);
    rig.mock.locked.add(testEmail);
    await expectLater(
      rig.cloud.login(testEmail, testPassword),
      throwsA(isA<TapoException>().having((e) => e.code, 'code', -20661)),
    );
  });

  test('region redirect (-20212): second login at the regional URL, baseUrl is appServerUrlV2', () async {
    final rig = await CloudRig.start();
    final login = await rig.cloud.login(testEmail, testPassword);

    expect(login.token, isNotNull);
    expect(login.baseUrl, rig.mock.regionalUrl);
    final paths = rig.mock.calls('/login').map((c) => c.path).toList();
    expect(paths, ['/api/v2/account/login', '$regionPrefix/api/v2/account/login']);
    expect(rig.mock.calls('/login').every((c) => c.signatureOk == true), isTrue);
  });

  test('MFA: login asks for a code, email code is sent, wrong code fails, right code signs in and binds the terminal', () async {
    final rig = await CloudRig.start(mfa: true);
    final login = await rig.cloud.login(testEmail, testPassword);

    expect(login.token, isNull);
    expect(login.mfaProcessId, isNotEmpty);
    expect(login.mfaTypes, contains(2));
    expect(login.baseUrl, rig.mock.regionalUrl);

    await rig.cloud.requestMfa(login.baseUrl, testEmail, testPassword, 2);
    expect(rig.mock.sentCodes, [(2, testEmail)]);

    await expectLater(
      rig.cloud.verifyMfa(login.baseUrl, testEmail, '000000', login.mfaProcessId!, 2),
      throwsA(isA<TapoException>().having((e) => e.code, 'code', -20676)),
    );

    final done = await rig.cloud.verifyMfa(
        login.baseUrl, testEmail, rig.mock.mfaCode, login.mfaProcessId!, 2);
    expect(done['token'], isA<String>());
    expect(rig.mock.validTokens, contains(done['token']));
    expect(rig.mock.boundTerminals, contains(testTerminal));

    // The terminal is bound now: the next login needs no code.
    final again = await rig.cloud.login(testEmail, testPassword);
    expect(again.token, isNotNull);
    expect(again.mfaProcessId, isNull);
  });

  test('MFA by push uses the push endpoint', () async {
    final rig = await CloudRig.start(mfa: true);
    final login = await rig.cloud.login(testEmail, testPassword);
    await rig.cloud.requestMfa(login.baseUrl, testEmail, testPassword, 1);
    expect(rig.mock.sentCodes, [(1, testEmail)]);
  });

  test('device list pages through 45 cameras with a valid token', () async {
    final rig = await CloudRig.start(devices: [for (var i = 1; i <= 45; i++) makeCloudDevice(i)]);
    await rig.signIn();
    final cameras = await rig.cloud.listCameras(rig.baseUrl);

    expect(cameras, hasLength(45));
    expect(TapoCloud.aliasOf(cameras[2]), 'Camera 3');
    expect(rig.mock.calls('getDeviceListByPage').length, greaterThanOrEqualTo(2));
    expect(rig.mock.calls('getDeviceListByPage').every((c) => c.query['token'] == rig.cloud.token), isTrue);
  });

  test('expired token is renewed silently with captchaLogin, exactly once', () async {
    final rig = await CloudRig.start();
    await rig.signIn();
    final stale = rig.cloud.token;
    rig.mock.expireTokens();

    final cameras = await rig.cloud.listCameras(rig.baseUrl);

    expect(cameras, hasLength(1));
    expect(rig.mock.calls('/captchaLogin'), hasLength(1));
    expect(rig.cloud.token, isNot(stale));
    expect(rig.mock.validTokens, contains(rig.cloud.token));
    expect(rig.mock.calls('/captchaLogin').single.signatureOk, isTrue);
  });

  test('without remembered credentials an expired token is an auth error (-20651)', () async {
    final rig = await CloudRig.start();
    final login = await rig.cloud.login(testEmail, testPassword);
    final bare = TapoCloud.withTransport(terminalUuid: testTerminal, transport: rig.transport)
      ..token = login.token!;
    rig.mock.expireTokens();

    await expectLater(
      bare.listCameras(login.baseUrl),
      throwsA(isA<TapoException>().having((e) => e.isAuthError, 'isAuthError', isTrue)),
    );
    expect(rig.mock.calls('/captchaLogin'), isEmpty);
  });

  test('service discovery: signed getAppServiceUrl, cached per session', () async {
    final rig = await CloudRig.start();
    await rig.signIn();

    final urls = await rig.cloud.serviceUrls(rig.baseUrl, [iotServiceId, cipcServiceId]);
    expect(urls[iotServiceId], rig.mock.iotUrl);
    expect(urls[cipcServiceId], rig.mock.cipcUrl);
    final first = rig.mock.calls('getAppServiceUrl');
    expect(first, hasLength(1));
    expect(first.single.signatureOk, isTrue);

    await rig.cloud.serviceUrls(rig.baseUrl, [iotServiceId, cipcServiceId]);
    expect(rig.mock.calls('getAppServiceUrl'), hasLength(1), reason: 'second call must hit the cache');

    expect(await rig.cloud.discoverIotServer(rig.baseUrl), rig.mock.iotUrl);
    expect(await rig.cloud.discoverCipcUrl(rig.baseUrl), rig.mock.cipcUrl);
  });

  test('IoT headers carry the token as ut|<token> and no HMAC headers', () async {
    final rig = await CloudRig.start();
    await rig.signIn();
    final h = rig.cloud.iotHeaders();
    expect(h['Authorization'], 'ut|${rig.cloud.token}');
    expect(h['x-term-id'], testTerminal);
    expect(h.keys.map((k) => k.toLowerCase()), isNot(contains('x-authorization')));
    expect(h.keys.map((k) => k.toLowerCase()), isNot(contains('content-md5')));
  });
}
