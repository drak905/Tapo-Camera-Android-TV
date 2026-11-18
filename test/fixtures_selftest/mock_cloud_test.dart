// Self-test of test/fixtures/mock_cloud.dart with raw signed HTTP requests.
import 'package:flutter_test/flutter_test.dart';

import '../fixtures/fx_crypto.dart';
import '../fixtures/mock_camera.dart';
import '../fixtures/mock_cloud.dart';
import '../fixtures/mock_relay.dart';
import 'raw_clients.dart';

Future<MockCloud> startCloud([MockCloud? c]) async {
  final cloud = c ?? MockCloud(accounts: {'user@example.com': 'pw-12345'});
  await cloud.start();
  addTearDown(cloud.stop);
  return cloud;
}

Map<String, dynamic> loginBody({String pw = 'pw-12345', String term = 'term-0001'}) => {
      'appType': 'TP-Link_Tapo_Android',
      'appVersion': '3.22.806',
      'cloudUserName': 'user@example.com',
      'cloudPassword': pw,
      'platform': 'Android 14',
      'refreshTokenNeeded': false,
      'terminalUUID': term,
    };

void main() {
  group('signing (hc.cloud.signing)', () {
    test('golden vector and empty-body hash', () {
      const body = '{"appType":"TP-Link_Tapo_Android","cloudUserName":"user@example.com"}';
      final h = cloudSignedHeaders('/api/v2/account/getAccountStatusAndUrl', body);
      expect(h['Content-MD5'], 'Tm1i6bgNP+L0b9fkTC+BUA==');
      expect(h['X-Authorization'],
          'Timestamp=9999999999, Nonce=2f1a6c3e-8b7d-4e21-9a55-0c4d3b2a1f00, AccessKey=4d11b6b9d5ea4d19a829adbb9714b057, Signature=d3e911ddfed0a8f151fa2d9ceef11062fc3a1a6f');
      expect(cloudSignedHeaders('/x', '')['Content-MD5'], 'mZFLkyvTelC5g8XnyQrpOw==');
      expect(MockCloud.verifySignature('/api/v2/account/getAccountStatusAndUrl',
          body.codeUnits, {for (final e in h.entries) e.key.toLowerCase(): e.value}), isTrue);
    });

    test('unsigned, tampered body and wrong path -> 401 -1', () async {
      final cloud = await startCloud();
      const path = '/api/v2/account/getAccountStatusAndUrl';
      final q = '?appName=TP-Link_Tapo_Android&termID=t';
      var (s, j) = await rawHttp('POST', '${cloud.baseUrl}$path$q', body: '{}');
      expect((s, j!['errorCode']), (401, -1));
      final good = cloudSignedHeaders(path, '{"a":1}');
      (s, j) = await rawHttp('POST', '${cloud.baseUrl}$path$q', headers: good, body: '{"a":2}');
      expect(s, 401);
      (s, j) = await rawHttp('POST', '${cloud.baseUrl}$path$q',
          headers: cloudSignedHeaders('/other', '{"a":1}'), body: '{"a":1}');
      expect(s, 401);
      expect(cloud.requestLog.every((r) => r.signatureOk == false), isTrue);
    });
  });

  group('account', () {
    test('status + url, login, wrong password, locked, refresh (captchaLogin)', () async {
      final cloud = await startCloud();
      var (s, j) = await cloudPost(cloud.baseUrl, '/api/v2/account/getAccountStatusAndUrl',
          {'appType': 'TP-Link_Tapo_Android', 'cloudUserName': 'user@example.com'});
      expect(s, 200);
      expect(j!['result']['appServerUrlV2'], cloud.regionalUrl);
      (s, j) = await cloudPost(cloud.baseUrl, '/api/v2/account/getAccountStatusAndUrl',
          {'appType': 'TP-Link_Tapo_Android', 'cloudUserName': 'nobody@example.com'});
      expect(j!['errorCode'], -20600);

      (s, j) = await cloudPost(cloud.baseUrl, '/eu/api/v2/account/login', loginBody(pw: 'bad'));
      expect(j!['result']['errorCode'], '-20601');
      (s, j) = await cloudPost(cloud.baseUrl, '/eu/api/v2/account/login', loginBody());
      expect(j!['result']['errorCode'], '0');
      final token = j['result']['token'] as String;
      expect(cloud.validTokens, [token]);

      (s, j) = await cloudPost(cloud.baseUrl, '/eu/api/v2/account/captchaLogin', loginBody());
      expect(j!['result']['errorCode'], '0');
      expect(cloud.validTokens.length, 2);

      cloud.locked.add('user@example.com');
      (s, j) = await cloudPost(cloud.baseUrl, '/eu/api/v2/account/login', loginBody());
      expect(j!['result']['errorCode'], '-20661');
    });

    test('regionRedirect: bootstrap login answers -20212 with the regional url', () async {
      final cloud = await startCloud(
          MockCloud(accounts: {'user@example.com': 'pw-12345'}, regionRedirect: true));
      final (_, j) = await cloudPost(cloud.baseUrl, '/api/v2/account/login', loginBody());
      expect(j!['result']['errorCode'], '-20212');
      expect(j['result']['appServerUrlV2'], cloud.regionalUrl);
      final (_, r) = await cloudPost(cloud.baseUrl, '/eu/api/v2/account/login', loginBody());
      expect(r!['result']['errorCode'], '0');
    });

    test('MFA: -20677, send code, wrong/right code, terminal binding skips MFA', () async {
      final cloud = await startCloud(
          MockCloud(accounts: {'user@example.com': 'pw-12345'}, mfa: true));
      var (_, j) = await cloudPost(cloud.baseUrl, '/eu/api/v2/account/login', loginBody());
      expect(j!['result']['errorCode'], '-20677');
      final pid = j['result']['MFAProcessId'] as String;
      expect(j['result']['supportedMFATypes'], [1, 2, 3]);
      (_, j) = await cloudPost(cloud.baseUrl, '/eu/api/v2/account/getEmailVC4TerminalMFA', loginBody());
      expect(j!['errorCode'], 0);
      expect(cloud.sentCodes, [(2, 'user@example.com')]);
      Map<String, dynamic> check(String code) => {
            ...loginBody(),
            'MFAProcessId': pid,
            'MFAType': 2,
            'code': code,
            'terminalBindEnabled': true,
          };
      (_, j) = await cloudPost(cloud.baseUrl, '/eu/api/v2/account/checkMFACodeAndLogin', check('000000'));
      expect(j!['result']['errorCode'], '-20676');
      (_, j) = await cloudPost(cloud.baseUrl, '/eu/api/v2/account/checkMFACodeAndLogin', check('123456'));
      expect(j!['result']['errorCode'], '0');
      expect(cloud.boundTerminals, {'term-0001'});
      (_, j) = await cloudPost(cloud.baseUrl, '/eu/api/v2/account/login', loginBody());
      expect(j!['result']['errorCode'], '0');
    });
  });

  group('device list + IoT things', () {
    late MockCloud cloud;
    late String token;

    setUp(() async {
      cloud = await startCloud(MockCloud(
        accounts: {'user@example.com': 'pw-12345'},
        devices: [
          for (var i = 1; i <= 5; i++) makeCloudDevice(i),
          makeCloudDevice(6, overrides: {'role': 1, 'status': 0, 'alias': 'Shared'}),
        ],
        localTokens: {makeCloudDevice(1)['deviceId'] as String: 'lat-token-1'},
      ));
      final (_, j) = await cloudPost(cloud.baseUrl, '/eu/api/v2/account/login', loginBody());
      token = j!['result']['token'] as String;
    });

    test('getDeviceListByPage pages; unknown token -> -20651', () async {
      var (_, j) = await cloudPost(cloud.baseUrl, '/eu/api/v2/common/getDeviceListByPage',
          {'index': 4, 'limit': 50}, token: token);
      expect(j!['result']['totalNum'], 6);
      expect((j['result']['deviceList'] as List).length, 2);
      expect(makeCloudDevice(1)['deviceId'], '8022${'0' * 35}1');
      (_, j) = await cloudPost(cloud.baseUrl, '/eu/api/v2/common/getDeviceListByPage',
          {'index': 0, 'limit': 50}, token: 'nope');
      expect(j!['errorCode'], -20651);
      cloud.expireTokens();
      (_, j) = await cloudPost(cloud.baseUrl, '/eu/api/v2/common/getDeviceListByPage',
          {'index': 0, 'limit': 50}, token: token);
      expect(j!['errorCode'], -20651);
    });

    test('getAppServiceUrl returns iot and cipc urls', () async {
      final (_, j) = await cloudPost(cloud.baseUrl, '/eu/api/v2/common/getAppServiceUrl',
          {'serviceIds': ['nbu.iot-app-server.app-v2', 'cipc.api.cloud']}, token: token);
      expect(j!['result']['serviceUrls'],
          {'nbu.iot-app-server.app-v2': cloud.iotUrl, 'cipc.api.cloud': cloud.cipcUrl});
      cloud.cipcServiceUrl = '';
      final (_, k) = await cloudPost(cloud.baseUrl, '/eu/api/v2/common/getAppServiceUrl',
          {'serviceIds': ['cipc.api.cloud']}, token: token);
      expect(k!['result']['serviceUrls'], isEmpty);
    });

    test('GET /iot/v2/things: role, status, localAccessToken, paging, auth', () async {
      var (s, j) = await rawHttp('GET', '${cloud.iotUrl}/v2/things?page=0&pageSize=4',
          headers: iotHeaders(token));
      expect(s, 200);
      expect(j!['total'], 6);
      final things = (j['data'] as List).cast<Map<String, dynamic>>();
      expect(things.length, 4);
      expect(things[0]['localAccessToken'], 'lat-token-1');
      expect(things[1]['localAccessToken'], isNull);
      (s, j) = await rawHttp('GET', '${cloud.iotUrl}/v2/things?page=1&pageSize=4', headers: iotHeaders(token));
      final shared = (j!['data'] as List).last as Map<String, dynamic>;
      expect((shared['role'], shared['status'], shared['shareType']), (1, 0, 'deviceShare'));
      (s, j) = await rawHttp('GET', '${cloud.iotUrl}/v2/things', headers: iotHeaders('bad'));
      expect((s, j!['code']), (401, -20651));
      final h = iotHeaders(token)..remove('x-strict');
      (s, _) = await rawHttp('GET', '${cloud.iotUrl}/v2/things', headers: h);
      expect(s, 400);
      cloud.thingsMaxPageSize = 2;
      (s, j) = await rawHttp('GET', '${cloud.iotUrl}/v2/things?page=0&pageSize=50', headers: iotHeaders(token));
      expect((j!['data'] as List).length, 2);
    });

    test('services-sync passthrough runs on the registered camera', () async {
      final cam = MockCamera();
      cloud.registerCamera(makeCloudDevice(1)['deviceId'] as String, cam);
      final id = makeCloudDevice(1)['deviceId'] as String;
      final body = compactJson({
        'serviceId': 'passthrough',
        'inputParams': {
          'requestData': {
            'method': 'multipleRequest',
            'params': {
              'requests': [
                {'method': 'setLedStatus', 'params': {'led': {'config': {'enabled': 'off'}}}},
                {'method': 'getLedStatus', 'params': {'led': {'name': ['config']}}},
              ]
            }
          }
        }
      });
      final url = '${cloud.regionalUrl}/v1/things/$id/services-sync';
      final hdr = {...iotHeaders(token), 'Content-Type': 'application/json'};
      var (s, j) = await rawHttp('POST', url, headers: hdr, body: body);
      expect(s, 200);
      final rs = j!['outputParams']['responseData']['result']['responses'] as List;
      expect(rs[1]['result']['led']['config']['enabled'], 'off');
      expect(cam.state.led, isFalse);
      expect(cloud.passthroughLog.single.thing, id);

      cloud.passthroughShape = 'direct';
      (s, j) = await rawHttp('POST', url, headers: hdr, body: body);
      expect(j!['outputParams']['result']['responses'], isNotEmpty);

      // offline (status 0) -> 400 -20571, unknown -> 404 -20580, no camera -> 500 -20002
      final offId = makeCloudDevice(6)['deviceId'] as String;
      (s, j) = await rawHttp('POST', '${cloud.regionalUrl}/v1/things/$offId/services-sync', headers: hdr, body: body);
      expect((s, j!['code']), (400, -20571));
      (s, j) = await rawHttp('POST', '${cloud.regionalUrl}/v1/things/unknown/services-sync', headers: hdr, body: body);
      expect((s, j!['code']), (404, -20580));
      final noCam = makeCloudDevice(2)['deviceId'] as String;
      (s, j) = await rawHttp('POST', '${cloud.regionalUrl}/v1/things/$noCam/services-sync', headers: hdr, body: body);
      expect((s, j!['code']), (500, -20002));
      cloud.passthroughErrors[id] = (200, -20002);
      (s, j) = await rawHttp('POST', url, headers: hdr, body: body);
      expect((s, j!['errorCode']), (200, -20002));
      (s, j) = await rawHttp('POST', url, headers: {...hdr}..remove('Authorization'), body: body);
      expect(s, 401);
      (s, j) = await rawHttp('POST', url, headers: hdr, body: '{"serviceId":"x"}');
      expect(s, 400);
    });

    test('passthrough uses the camera injectError and -71103 knobs', () async {
      final cam = MockCamera()..clipSearchRequiresPlayerId = true;
      final id = makeCloudDevice(1)['deviceId'] as String;
      cloud.registerCamera(id, cam);
      cam.injectError('getLedStatus', -40401);
      final body = compactJson({
        'serviceId': 'passthrough',
        'inputParams': {
          'requestData': {
            'method': 'multipleRequest',
            'params': {
              'requests': [
                {'method': 'getLedStatus', 'params': {'led': {'name': ['config']}}},
                {
                  'method': 'searchVideoWithUTC',
                  'params': {'playback': {'search_video_with_utc': {'id': 1, 'start_time': 1, 'end_time': 2}}}
                },
              ]
            }
          }
        }
      });
      final (_, j) = await rawHttp('POST', '${cloud.regionalUrl}/v1/things/$id/services-sync',
          headers: {...iotHeaders(token), 'Content-Type': 'application/json'}, body: body);
      final rs = j!['outputParams']['responseData']['result']['responses'] as List;
      expect([rs[0]['error_code'], rs[1]['error_code']], [-40401, -71103]);
    });

    group('CIPC /v2/relay/request', () {
      Map<String, String> headers() => {
            'Content-Type': 'application/json; charset=UTF-8',
            'Accept': '*/*',
            'User-Agent': 'Tapo_APP/Pixel/3.22.806_Android/Android 14',
            'X-Request-Signature': 'aB3dE5gH7k',
            'X-Client-Id': 'client-id-0001',
            'X-Source': 'tapo-app',
            'X-Brand': 'TPLINK',
            'X-Ca-Type': 'cloud-self',
            'Authorization': token,
          };
      Map<String, dynamic> relayBody({int streamType = 0}) => {
            'deviceId': makeCloudDevice(1)['deviceId'],
            'dataTimeoutCount': 0,
            'cloudType': 2,
            'deviceType': 'SMART.IPCAMERA',
            'playerId': 'client-id-0001',
            'rootCaVer': '1',
            if (streamType == 0) ...{'preConnection': 0, 'resolution': 'VGA'},
            if (streamType != 0) 'channelId': '0',
            'streamType': streamType,
            'customParams': '{}',
            'trackId': '11111111-2222-3333-4444-555555555555',
          };

      test('no relay node -> -1014; error injection; bad headers 400; bad token 401', () async {
        final url = '${cloud.cipcUrl}/v2/relay/request';
        var (s, j) = await rawHttp('POST', url, headers: headers(), body: compactJson(relayBody()));
        expect((s, j!['errorCode']), (200, -1014));
        cloud.relayErrors[makeCloudDevice(1)['deviceId'] as String] = -1007;
        (s, j) = await rawHttp('POST', url, headers: headers(), body: compactJson(relayBody()));
        expect(j!['errorCode'], -1007);
        (s, j) = await rawHttp('POST', url, headers: {...headers()}..remove('X-Brand'), body: compactJson(relayBody()));
        expect(s, 400);
        (s, j) = await rawHttp('POST', url, headers: {...headers(), 'Authorization': 'x'}, body: compactJson(relayBody()));
        expect((s, j!['errorCode']), (401, -1102));
        (s, j) = await rawHttp('POST', url, headers: headers(), body: compactJson({...relayBody(), 'cloudType': 7}));
        expect(j!['errorCode'], -1);
      });

      test('slot is issued by the attached relay (live, playback, refused stream type)', () async {
        final relay = await MockRelay().start();
        addTearDown(relay.stop);
        cloud.relay = relay;
        final url = '${cloud.cipcUrl}/v2/relay/request';
        var (s, j) = await rawHttp('POST', url, headers: headers(), body: compactJson(relayBody()));
        final r = j!['result'] as Map<String, dynamic>;
        expect(r['relayUrl'], contains('https://localhost:${relay.port}/relayservice?deviceid='));
        expect(r['relayUrl'], contains('type=video&resolution=VGA'));
        expect(r['relayIp'], '127.0.0.1');
        expect(relay.slots[r['relayToken']]!.trackId, '11111111-2222-3333-4444-555555555555');
        (s, j) = await rawHttp('POST', url,
            headers: headers(),
            body: compactJson({...relayBody(streamType: 1), 'customParams': '{"a":1}'}));
        expect(j!['result']['relayUrl'], contains('type=sdvod'));
        cloud.relayRefuseStreamTypes.add(1);
        (s, j) = await rawHttp('POST', url,
            headers: headers(), body: compactJson({...relayBody(streamType: 1), 'customParams': '{}'}));
        expect(j!['errorCode'], -1);
      });
    });
  });

  test('makeCloudDevice is deterministic and personal-data free', () {
    final d = makeCloudDevice(255);
    expect(d['deviceId'], '8022${'0' * 34}FF');
    expect(d['deviceMac'], 'A0B1C20000FF');
    expect(md5Hex(d['deviceId'] as String), hasLength(32));
  });
}
