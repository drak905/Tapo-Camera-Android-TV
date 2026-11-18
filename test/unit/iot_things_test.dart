// Spec hc.cloud.iot_things (tier 2) and hc.cloud.online_state input side.

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/iot_things.dart';

import '_support/helpers.dart';

const _uuid = 'A1B2C3D4E5F60718293A4B5C6D7E8F90';

Map<String, dynamic> _thing(String id, {Object? status = 1, Object? role = 0, Object? lat, String? v2}) => {
      'thingName': id,
      'deviceId': '${id}X',
      'status': status,
      'role': role,
      'shareType': 'owner',
      'appServerUrlV2': v2 ?? 'https://thing-eu.example.com/',
      'deviceType': 'SMART.IPCAMERA',
      'model': 'C200',
      'localAccessToken': ?lat,
    };

IotThingsClient _client(FakeCloudTransport t) => IotThingsClient(
      transport: t,
      iotBaseUrl: 'https://iot.example.com',
      token: 'tok-1',
      terminalUuid: _uuid,
    );

void main() {
  test('query and headers', () async {
    final t = FakeCloudTransport((r) => jsonReply({'code': 0, 'data': [], 'total': 0}));
    await _client(t).fetchAll();
    final r = t.requests.single;
    expect(r.method, 'GET');
    expect(r.uri.origin, 'https://iot.example.com');
    expect(r.uri.path, '/v2/things');
    expect(r.uri.queryParameters, {
      'page': '0',
      'pageSize': '100',
      'deviceTypes': 'SMART.IPCAMERA,SMART.TAPODOORBELL,SMART.TAPOHUB',
      'includePcDevice': 'false',
      'includeKasaShareDevices': 'true',
      'includeMatterDevice': 'false',
      'includeExternalVendorDeviceInfo': 'true',
    });
    expect(r.headers['Authorization'], 'ut|tok-1');
    expect(r.headers['app-cid'], 'app:TP-Link_Tapo_Android:$_uuid');
    expect(r.headers['x-term-id'], _uuid);
    expect(r.headers.keys.map((k) => k.toLowerCase()), isNot(contains('x-authorization')));
  });

  test('things carry role status url and are indexed twice', () async {
    final t = FakeCloudTransport((r) => jsonReply({
          'code': 0,
          'total': 2,
          'data': [
            _thing('T1', lat: 'lat-value-1'),
            _thing('T2', status: 0, role: 1, v2: 'https://thing-us.example.com'),
          ],
        }));
    final m = await _client(t).fetchAll();
    expect(m['T1'], same(m['T1X']));
    expect(m['T1']!.online, isTrue);
    expect(m['T1']!.isShared, isFalse);
    expect(m['T1']!.appServerUrl, 'https://thing-eu.example.com');
    expect(m['T2']!.online, isFalse);
    expect(m['T2']!.isShared, isTrue);
    expect(m['T2']!.appServerUrl, 'https://thing-us.example.com');
    expect(m['T1']!.localAccessToken, 'lat-value-1');
  });

  test('pages until total', () async {
    final pages = <int, List<Map<String, dynamic>>>{
      0: [for (var i = 0; i < 100; i++) _thing('P$i')],
      1: [for (var i = 100; i < 120; i++) _thing('P$i')],
    };
    final t = FakeCloudTransport((r) {
      final page = int.parse(r.uri.queryParameters['page']!);
      return jsonReply({'code': 0, 'total': 120, 'data': pages[page] ?? []});
    });
    final m = await _client(t).fetchAll();
    expect(t.requests.map((r) => r.uri.queryParameters['page']), ['0', '1']);
    expect(m.keys.where((k) => k.startsWith('P') && !k.endsWith('X')), hasLength(120));
  });

  test('stops on a short page when the reply has no total', () async {
    final t = FakeCloudTransport((r) => jsonReply({'code': 0, 'data': [_thing('S1')]}));
    await _client(t).fetchAll();
    expect(t.requests, hasLength(1));
  });

  test('missing null empty token left out', () async {
    final t = FakeCloudTransport((r) => jsonReply({
          'code': 0,
          'total': 4,
          'data': [
            _thing('N1'),
            _thing('N2', lat: null),
            _thing('N3', lat: ''),
            _thing('N4', lat: 'lat-value-4'),
          ],
        }));
    final m = await _client(t).fetchAll();
    expect(m['N1']!.localAccessToken, isNull);
    expect(m['N2']!.localAccessToken, isNull);
    expect(m['N3']!.localAccessToken, isNull);
    expect(m['N4']!.localAccessToken, 'lat-value-4');
  });

  test('malformed entries skipped and bool status rejected', () async {
    final t = FakeCloudTransport((r) => jsonReply({
          'code': 0,
          'total': 4,
          'data': [
            'garbage',
            {'noName': true},
            _thing('B1', status: true),
            _thing('B2'),
          ],
        }));
    final m = await _client(t).fetchAll();
    expect(m.containsKey('B2'), isTrue);
    expect(m['B1']?.online ?? false, isFalse);
  });

  test('401 maps to token expired', () async {
    final t = FakeCloudTransport((r) => jsonReply({'code': -1}, status: 401));
    await expectLater(_client(t).fetchAll(), throwsA(isA<IotTokenExpired>()));
    for (final code in [-20651, -20652, -20675]) {
      final t2 = FakeCloudTransport((r) => jsonReply({'code': code}));
      await expectLater(_client(t2).fetchAll(), throwsA(isA<IotTokenExpired>()), reason: '$code');
    }
  });

  test('toString never shows the local access token', () {
    const thing = IotThing(
      thingName: 'T1',
      deviceId: 'D1',
      status: 1,
      role: 0,
      localAccessToken: 'lat-secret-value',
    );
    expect('$thing', isNot(contains('lat-secret-value')));
  });
}
