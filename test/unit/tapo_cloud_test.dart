// Specs hc.cloud.* and hc.baseline.gap_list, against an in-memory fake cloud.
// The fake answers like the Windows mock_cloud.py: envelope
// {errorCode, msg, result:{...}}.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/tapo_cloud.dart';

import '_support/helpers.dart';

const _uuid = 'A1B2C3D4E5F60718293A4B5C6D7E8F90';
const _region = 'https://eu-wap.example.com';

Map<String, dynamic> _ok(Map<String, dynamic> result) =>
    {'errorCode': 0, 'msg': 'Success', 'result': result};

Map<String, dynamic> _err(int code, [Map<String, dynamic>? result]) =>
    {'errorCode': code, 'msg': 'x', 'result': ?result};

TapoCloud _cloud(FakeCloudTransport t, {String locale = 'en_US'}) =>
    TapoCloud.withTransport(terminalUuid: _uuid, transport: t, locale: locale);

Map<String, dynamic> _device(String id, {String type = 'SMART.IPCAMERA', String? mac, int role = 0}) => {
      'deviceId': id,
      'deviceMac': mac ?? 'a0:b1:c2:00:00:01',
      'deviceModel': 'C200',
      'alias': 'Cam $id',
      'deviceType': type,
      'status': 1,
      'role': role,
    };

void main() {
  group('baseline gaps (hc.baseline.gap_list)', () {
    test('app version and bootstrap follow Windows', () {
      expect(appVersion, '3.22.806');
      expect(loginUrl, 'https://n-wap.i.tplinkcloud.com');
    });
  });

  group('common query (hc.cloud.common_query)', () {
    test('query carries common params in order', () async {
      final t = FakeCloudTransport((r) => jsonReply(_ok({'deviceList': [], 'totalNum': 0})));
      final cloud = _cloud(t)..token = 'tok-1';
      await cloud.listCameras(_region);
      final q = t.requests.single.uri.queryParameters.keys.toList();
      expect(q, ['appName', 'appVer', 'netType', 'termID', 'ospf', 'brand', 'locale', 'token']);
      final p = t.requests.single.uri.queryParameters;
      expect(p['appName'], 'TP-Link_Tapo_Android');
      expect(p['netType'], 'wifi');
      expect(p['termID'], _uuid);
      expect(p['ospf'], startsWith('Android '));
      expect(p['brand'], 'TPLINK');
      expect(p['locale'], 'en_US');
      expect(p['token'], 'tok-1');
    });

    test('signed headers present and query not signed', () async {
      final t = FakeCloudTransport((r) => jsonReply(_ok({'deviceList': []})));
      final cloud = _cloud(t, locale: 'vi_VN')..token = 'tok-1';
      await cloud.listCameras(_region);
      final h = t.requests.single.headers;
      expect(h['X-Authorization'], startsWith('Timestamp=9999999999, Nonce='));
      expect(h['Content-MD5'], isNotEmpty);
      expect(h['Content-Type'], 'application/json;charset=UTF-8');
      expect(t.requests.single.uri.queryParameters['locale'], 'vi_VN');
    });
  });

  group('envelope and errors (hc.cloud.envelope_errors)', () {
    test('error code from envelope or result', () async {
      final t = FakeCloudTransport((r) => jsonReply(_err(-20600)));
      var cloud = _cloud(t);
      await expectLater(
        cloud.login('user@example.com', 'test_password'),
        throwsA(isA<TapoException>().having((e) => e.code, 'code', -20600)),
      );
      final t2 = FakeCloudTransport((r) => jsonReply(_ok({'errorCode': '-20615'})));
      cloud = _cloud(t2);
      await expectLater(
        cloud.login('user@example.com', 'test_password'),
        throwsA(isA<TapoException>().having((e) => e.code, 'code', -20615)),
      );
    });

    test('locked and remain attempts messages', () async {
      var t = FakeCloudTransport((r) => jsonReply(_err(-20661, {'lockedMinutes': 15})));
      await expectLater(
        _cloud(t).login('user@example.com', 'x'),
        throwsA(isA<TapoException>().having((e) => e.message, 'message', contains('15'))),
      );
      t = FakeCloudTransport((r) => jsonReply(_err(-20601, {'remainAttempts': 3})));
      await expectLater(
        _cloud(t).login('user@example.com', 'x'),
        throwsA(isA<TapoException>().having((e) => e.message, 'message', contains('3'))),
      );
    });

    test('non json and http errors are errors, not crashes', () async {
      final t = FakeCloudTransport((r) => textReply('<html>', status: 502));
      await expectLater(_cloud(t).login('u@example.com', 'x'), throwsA(isA<TapoException>()));
    });
  });

  group('login (hc.cloud.login_region)', () {
    test('login follows region redirect once', () async {
      const other = 'https://other-wap.example.com';
      final t = FakeCloudTransport((r) {
        if (r.path == '/api/v2/account/getAccountStatusAndUrl') {
          return jsonReply(_ok({'appServerUrlV2': '$_region/'}));
        }
        if (r.uri.origin == _region) return jsonReply(_err(-20212, {'appServerUrlV2': other}));
        return jsonReply(_ok({'token': 'tok-new', 'email': 'user@example.com', 'accountId': '1'}));
      });
      final res = await _cloud(t).login('user@example.com', 'test_password');
      expect(res.token, 'tok-new');
      expect(res.baseUrl, other);
      expect(t.requests.map((r) => '${r.uri.origin}${r.path}'), [
        'https://n-wap.i.tplinkcloud.com/api/v2/account/getAccountStatusAndUrl',
        '$_region/api/v2/account/login',
        '$other/api/v2/account/login',
      ]);
      final body = t.requests[1].json;
      expect(body['appType'], 'TP-Link_Tapo_Android');
      expect(body['terminalUUID'], _uuid);
      expect(body['refreshTokenNeeded'], false);
      expect(body['terminalMeta'], '1');
    });

    test('redirect to the same url is not followed again', () async {
      final t = FakeCloudTransport((r) {
        if (r.path == '/api/v2/account/getAccountStatusAndUrl') {
          return jsonReply(_ok({'appServerUrlV2': _region}));
        }
        return jsonReply(_err(-20212, {'appServerUrlV2': _region}));
      });
      await expectLater(_cloud(t).login('u@example.com', 'x'), throwsA(isA<TapoException>()));
      expect(t.requests.where((r) => r.path.endsWith('/login')).length, 1);
    });

    test('login without token is malformed', () async {
      final t = FakeCloudTransport((r) {
        if (r.path == '/api/v2/account/getAccountStatusAndUrl') {
          return jsonReply(_ok({'appServerUrlV2': _region}));
        }
        return jsonReply(_ok({}));
      });
      await expectLater(_cloud(t).login('u@example.com', 'x'), throwsA(isA<TapoException>()));
    });
  });

  group('mfa (hc.cloud.mfa)', () {
    FakeCloudTransport mfaCloud() => FakeCloudTransport((r) {
          switch (r.path) {
            case '/api/v2/account/getAccountStatusAndUrl':
              return jsonReply(_ok({'appServerUrlV2': _region}));
            case '/api/v2/account/login':
              return jsonReply(_err(-20677, {
                'MFAProcessId': 'proc-1',
                'supportedMFATypes': [2, 3],
              }));
            case '/api/v2/account/checkMFACodeAndLogin':
              return jsonReply(_ok({'token': 'tok-mfa'}));
            default:
              return jsonReply(_ok({}));
          }
        });

    test('mfa required then complete', () async {
      final t = mfaCloud();
      final cloud = _cloud(t);
      final first = await cloud.login('user@example.com', 'test_password');
      expect(first.token, isNull);
      expect(first.mfaProcessId, 'proc-1');
      expect(first.mfaTypes, [2, 3]);

      await cloud.requestMfa(_region, 'user@example.com', 'test_password', 2);
      final send = t.requests.last;
      expect(send.path, '/api/v2/account/getEmailVC4TerminalMFA');
      expect(send.json['terminalUUID'], _uuid);
      expect(send.json.containsKey('locale'), isTrue);

      final done = await cloud.verifyMfa(_region, 'user@example.com', '123456', 'proc-1', 3);
      expect(done['token'], 'tok-mfa');
      final check = t.requests.last.json;
      expect(check['MFAType'], 3);
      expect(check['MFAProcessId'], 'proc-1');
      expect(check['terminalBindEnabled'], true);
    });

    test('totp type sends no request', () async {
      final t = mfaCloud();
      final cloud = _cloud(t);
      await cloud.requestMfa(_region, 'user@example.com', 'test_password', 3);
      expect(t.requests, isEmpty);
    });

    test('push and sms use their own endpoints', () async {
      final t = mfaCloud();
      final cloud = _cloud(t);
      await cloud.requestMfa(_region, 'user@example.com', 'p', 1);
      await cloud.requestMfa(_region, 'user@example.com', 'p', 4);
      expect(t.requests.map((r) => r.path), [
        '/api/v2/account/getPushVC4TerminalMFA',
        '/api/v2/account/getSmsVC4TerminalMFA',
      ]);
    });
  });

  group('token refresh (hc.cloud.token_refresh)', () {
    test('expired token relogs in once', () async {
      var listCalls = 0;
      final t = FakeCloudTransport((r) {
        if (r.path == '/api/v2/account/captchaLogin') return jsonReply(_ok({'token': 'tok-2'}));
        if (r.path == '/api/v2/common/getDeviceListByPage') {
          listCalls++;
          if (r.uri.queryParameters['token'] == 'tok-1') return jsonReply(_err(-20651));
          return jsonReply(_ok({
            'deviceList': [_device('802200000000000000000000000000000000AAAA')],
            'totalNum': 1,
          }));
        }
        return jsonReply(_ok({}));
      });
      final cloud = _cloud(t)..token = 'tok-1';
      cloud.rememberCredentials(username: 'user@example.com', password: 'test_password', baseUrl: _region);
      final devices = await cloud.listCameras(_region);
      expect(devices, hasLength(1));
      expect(cloud.token, 'tok-2');
      expect(listCalls, 2);
      expect(t.requests.where((r) => r.path == '/api/v2/account/captchaLogin'), hasLength(1));
    });

    test('second rejection is not retried', () async {
      final t = FakeCloudTransport((r) {
        if (r.path == '/api/v2/account/captchaLogin') return jsonReply(_ok({'token': 'tok-2'}));
        return jsonReply(_err(-20651));
      });
      final cloud = _cloud(t)..token = 'tok-1';
      cloud.rememberCredentials(username: 'user@example.com', password: 'test_password', baseUrl: _region);
      await expectLater(
        cloud.listCameras(_region),
        throwsA(isA<TapoException>().having((e) => e.isAuthError, 'isAuthError', isTrue)),
      );
      expect(t.requests.where((r) => r.path == '/api/v2/account/captchaLogin'), hasLength(1));
      expect(t.requests.where((r) => r.path.endsWith('getDeviceListByPage')), hasLength(2));
    });

    test('mismatch and logged in elsewhere do one full login', () async {
      for (final code in [-20652, -20675]) {
        var first = true;
        final t = FakeCloudTransport((r) {
          if (r.path == '/api/v2/account/getAccountStatusAndUrl') {
            return jsonReply(_ok({'appServerUrlV2': _region}));
          }
          if (r.path == '/api/v2/account/login') return jsonReply(_ok({'token': 'tok-3'}));
          if (first) {
            first = false;
            return jsonReply(_err(code));
          }
          return jsonReply(_ok({'deviceList': []}));
        });
        final cloud = _cloud(t)..token = 'tok-1';
        cloud.rememberCredentials(username: 'user@example.com', password: 'test_password', baseUrl: _region);
        await cloud.listCameras(_region);
        expect(t.requests.where((r) => r.path == '/api/v2/account/login'), hasLength(1), reason: '$code');
        expect(t.requests.where((r) => r.path.contains('captcha')), isEmpty);
      }
    });

    test('without remembered credentials the auth error surfaces', () async {
      final t = FakeCloudTransport((r) => jsonReply(_err(-20651)));
      final cloud = _cloud(t)..token = 'tok-1';
      await expectLater(cloud.listCameras(_region), throwsA(isA<TapoException>()));
      expect(t.requests, hasLength(1));
    });
  });

  group('device list (hc.cloud.device_list_v2)', () {
    test('device list pages and filters doorbell', () async {
      final page1 = [
        for (var i = 0; i < 18; i++) _device('802200000000000000000000000000000000A${i.toString().padLeft(3, '0')}'),
        _device('802200000000000000000000000000000000BELL', type: 'SMART.TAPODOORBELL', mac: 'A0B1C2000002'),
        _device('802200000000000000000000000000000000A000'), // duplicate of the first
      ];
      final page2 = [_device('802200000000000000000000000000000000LAST')];
      final t = FakeCloudTransport((r) {
        final index = r.json['index'] as int;
        return jsonReply(_ok({'deviceList': index == 0 ? page1 : page2, 'totalNum': 21}));
      });
      final cloud = _cloud(t)..token = 'tok-1';
      final out = await cloud.listCameras(_region);
      expect(t.requests.map((r) => r.json['index']), [0, 20]);
      expect(t.requests.first.json['limit'], 20);
      expect(t.requests.first.json['deviceTypeList'],
          ['SMART.IPCAMERA', 'SMART.TAPODOORBELL', 'SMART.TAPOHUB']);
      expect(out, hasLength(20)); // 18 + doorbell + last, duplicate dropped
      final bell = out.firstWhere((d) => d['deviceType'] == 'SMART.TAPODOORBELL');
      expect(bell['deviceMac'], 'A0-B1-C2-00-00-02');
    });

    test('hub is dropped', () async {
      final t = FakeCloudTransport((r) => jsonReply(_ok({
            'deviceList': [
              _device('802200000000000000000000000000000000HUB1', type: 'SMART.TAPOHUB'),
              _device('', type: 'SMART.IPCAMERA'),
              _device('802200000000000000000000000000000000CAM1'),
            ],
            'totalNum': 3,
          })));
      final out = await (_cloud(t)..token = 'tok-1').listCameras(_region);
      expect(out.map((d) => d['deviceId']), ['802200000000000000000000000000000000CAM1']);
    });
  });

  group('service urls (hc.cloud.service_urls)', () {
    test('service urls signed with token', () async {
      final t = FakeCloudTransport((r) => jsonReply(_ok({
            'serviceUrls': {'a.b': 'https://svc.example.com/', 'bad': 5, 'empty': ''},
          })));
      final cloud = _cloud(t)..token = 'tok-1';
      final urls = await cloud.serviceUrls(_region, ['a.b', 'bad', 'empty']);
      expect(urls, {'a.b': 'https://svc.example.com'});
      final r = t.requests.single;
      expect(r.path, '/api/v2/common/getAppServiceUrl');
      expect(r.uri.queryParameters['token'], 'tok-1');
      expect(r.headers['X-Authorization'], isNotNull);
      expect(r.json['serviceIds'], ['a.b', 'bad', 'empty']);
    });

    test('iot server uses the v2 service id and is cached', () async {
      final t = FakeCloudTransport((r) => jsonReply(_ok({
            'serviceUrls': {'nbu.iot-app-server.app-v2': 'https://iot.example.com'},
          })));
      final cloud = _cloud(t)..token = 'tok-1';
      expect(await cloud.discoverIotServer(_region), 'https://iot.example.com');
      expect(await cloud.discoverIotServer(_region), 'https://iot.example.com');
      expect(t.requests, hasLength(1));
      expect(t.requests.single.json['serviceIds'], ['nbu.iot-app-server.app-v2']);
    });

    test('insecure iot url refused', () async {
      final t = FakeCloudTransport((r) => jsonReply(_ok({
            'serviceUrls': {'nbu.iot-app-server.app-v2': 'http://iot.example.com'},
          })));
      final cloud = _cloud(t)..token = 'tok-1';
      await expectLater(cloud.discoverIotServer(_region), throwsA(isA<TapoException>()));
      final t2 = FakeCloudTransport((r) => jsonReply(_ok({
            'serviceUrls': {'nbu.iot-app-server.app-v2': 'ftp://iot.example.com'},
          })));
      await expectLater((_cloud(t2)..token = 'tok-1').discoverIotServer(_region), throwsA(isA<TapoException>()));
    });

    test('cipc url discovery for the player lane', () async {
      final t = FakeCloudTransport((r) => jsonReply(_ok({
            'serviceUrls': {'cipc.api.cloud': 'https://cipc.example.com/'},
          })));
      final cloud = _cloud(t)..token = 'tok-1';
      expect(await cloud.discoverCipcUrl(_region), 'https://cipc.example.com');
      expect(t.requests.single.json['serviceIds'], ['cipc.api.cloud']);
    });
  });

  group('iot headers (hc.cloud.iot_headers)', () {
    test('iot headers and no x-authorization', () {
      final cloud = _cloud(FakeCloudTransport((r) => jsonReply(_ok({}))))..token = 'tok-1';
      final h = cloud.iotHeaders();
      expect(h['Authorization'], 'ut|tok-1');
      expect(h['app-cid'], 'app:TP-Link_Tapo_Android:$_uuid');
      expect(h['x-app-name'], 'TP-Link_Tapo_Android');
      expect(h['x-app-version'], isNotEmpty);
      expect(h['x-term-id'], _uuid);
      expect(h['x-ospf'], 'Android 14');
      expect(h['x-net-type'], 'wifi');
      expect(h['x-strict'], '0');
      expect(h['x-locale'], 'en_US');
      expect(h['User-Agent'], isNotEmpty);
      expect(h.keys.map((k) => k.toLowerCase()), isNot(contains('x-authorization')));
      expect(h.keys.map((k) => k.toLowerCase()), isNot(contains('content-md5')));
      expect(h.keys.map((k) => k.toLowerCase()), isNot(contains('content-type')));
      expect(cloud.iotHeaders(post: true)['Content-Type'], 'application/json;charset=UTF-8');
    });
  });

  group('alias (hc.cloud.alias_decode)', () {
    test('decode alias plain vs base64', () {
      expect(TapoCloud.decodeAlias('Front door'), 'Front door');
      expect(TapoCloud.decodeAlias('TGl2aW5nIFJvb20='), 'Living Room');
      expect(TapoCloud.decodeAlias('Test'), 'Test'); // valid base64, not printable UTF-8
      expect(TapoCloud.decodeAlias('Door'), 'Door');
      expect(TapoCloud.decodeAlias('abc'), 'abc'); // length not a multiple of 4
      expect(TapoCloud.decodeAlias(''), '');
    });

    test('alias falls back to device name then model', () {
      expect(TapoCloud.aliasOf({'alias': '', 'deviceName': 'Name1', 'deviceModel': 'C200'}), 'Name1');
      expect(TapoCloud.aliasOf({'deviceModel': 'C200'}), 'C200');
      expect(TapoCloud.aliasOf({'alias': 'TGl2aW5nIFJvb20=', 'deviceModel': 'C200'}), 'Living Room');
    });
  });

  group('safety', () {
    test('no secrets in printed output or error text', () async {
      final printed = <String>[];
      Object? error;
      await runZoned(() async {
        final t = FakeCloudTransport((r) => jsonReply(_err(-20651)));
        final cloud = _cloud(t)..token = 'tok-secret-1';
        cloud.rememberCredentials(username: 'user@example.com', password: 'pw-secret-1', baseUrl: _region);
        try {
          await cloud.listCameras(_region);
        } catch (e) {
          error = e;
        }
        printed.add(cloud.toString());
      }, zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) => printed.add(line)));
      final all = [...printed, '$error'].join('\n');
      expect(all, isNot(contains('tok-secret-1')));
      expect(all, isNot(contains('pw-secret-1')));
    });
  });
}
