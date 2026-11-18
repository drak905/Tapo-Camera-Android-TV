// Specs hc.passthrough.request and hc.passthrough.response_errors (tier 2).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/camera_dtos.dart';
import 'package:tapo_tv/api/cloud_passthrough.dart';
import 'package:tapo_tv/api/iot_things.dart';
import 'package:tapo_tv/api/tapo_cloud.dart';
import 'package:tapo_tv/api/tapo_errors.dart';

import '_support/helpers.dart';

const _uuid = 'A1B2C3D4E5F60718293A4B5C6D7E8F90';

IotThing _thing({String name = 'THING1', String url = 'https://thing-eu.example.com'}) =>
    IotThing(thingName: name, deviceId: 'D1', status: 1, role: 0, appServerUrl: url);

Map<String, dynamic> _item(String method, {int code = 0, Map<String, dynamic>? result}) =>
    {'method': method, 'result': result ?? {}, 'error_code': code};

Map<String, dynamic> _reply(List<Map<String, dynamic>> items, {int code = 0}) => {
      'outputParams': {
        'responseData': {
          'error_code': code,
          'result': {'responses': items},
        },
      },
    };

CloudPassthrough _pt(
  FakeCloudTransport t, {
  Future<String> Function(String)? refresher,
  bool https = true,
}) =>
    CloudPassthrough(
      transport: t,
      token: 'tok-1',
      terminalUuid: _uuid,
      refresher: refresher ?? (_) async => 'tok-2',
      accountApiIsHttps: https,
    );

final _requests = [buildGetDeviceInfo(), buildGetLed()];

void main() {
  group('request', () {
    test('envelope headers and items', () async {
      final t = FakeCloudTransport((r) => jsonReply(_reply([
            _item('getDeviceInfo', result: {'device_info': {'basic_info': {'device_model': 'C200'}}}),
            _item('getLedStatus', result: {'led': {'config': {'enabled': 'on'}}}),
          ])));
      final items = await _pt(t).send(_thing(), _requests);
      final r = t.requests.single;
      expect(r.method, 'POST');
      expect(r.uri.toString(), 'https://thing-eu.example.com/v1/things/THING1/services-sync');
      expect(r.headers['Authorization'], 'ut|tok-1');
      expect(r.headers['app-cid'], 'app:TP-Link_Tapo_Android:$_uuid');
      expect(r.headers['Content-Type'], 'application/json;charset=UTF-8');
      expect(r.headers.keys.map((k) => k.toLowerCase()), isNot(contains('x-authorization')));
      final body = r.json;
      expect(body['serviceId'], 'passthrough');
      final data = (body['inputParams'] as Map)['requestData'] as Map;
      expect(data['method'], 'multipleRequest');
      expect(((data['params'] as Map)['requests'] as List).map((e) => (e as Map)['method']),
          ['getDeviceInfo', 'getLedStatus']);
      expect(items.map((i) => i.method), ['getDeviceInfo', 'getLedStatus']);
    });

    test('thing name is path quoted', () async {
      final t = FakeCloudTransport((r) => jsonReply(_reply([_item('getLedStatus')])));
      await _pt(t).send(_thing(name: 'a/b c?d'), _requests);
      expect(t.requests.single.uri.toString(),
          'https://thing-eu.example.com/v1/things/a%2Fb%20c%3Fd/services-sync');
    });

    test('bad thing url refused', () async {
      final t = FakeCloudTransport((r) => jsonReply(_reply([])));
      for (final url in [
        'ftp://thing.example.com',
        'https://thing.example.com/x?y=1',
        'https://thing.example.com/x#frag',
        'http://thing.example.com', // http while the account API is https
        '',
      ]) {
        await expectLater(
          _pt(t).send(_thing(url: url), _requests),
          throwsA(isA<TapoProtocolError>()),
          reason: url,
        );
      }
      expect(t.requests, isEmpty);
    });

    test('empty batch sends nothing', () async {
      final t = FakeCloudTransport((r) => jsonReply(_reply([])));
      expect(await _pt(t).send(_thing(), const []), isEmpty);
      expect(t.requests, isEmpty);
    });

    test('thing url falls back to app server url', () async {
      // IotThing.appServerUrl already holds appServerUrlV2 else appServerUrl;
      // an empty value must be refused rather than guessed.
      final t = FakeCloudTransport((r) => jsonReply(_reply([_item('getLedStatus')])));
      await expectLater(_pt(t).send(_thing(url: ''), _requests), throwsA(isA<TapoProtocolError>()));
    });
  });

  group('response and errors', () {
    test('direct output params shape', () async {
      final direct = {
        'outputParams': {
          'error_code': 0,
          'result': {'responses': [_item('getLedStatus')]},
        },
      };
      final nested = {
        'result': {'outputParams': {'responseData': {'error_code': 0, 'result': {'responses': [_item('getLedStatus')]}}}},
      };
      for (final body in [direct, nested]) {
        final t = FakeCloudTransport((r) => jsonReply(body));
        final items = await _pt(t).send(_thing(), _requests);
        expect(items.single.method, 'getLedStatus');
      }
    });

    test('per item errors are kept', () async {
      final t = FakeCloudTransport((r) => jsonReply(_reply([
            _item('getDeviceInfo'),
            {'method': 'getLedStatus', 'result': 'nope', 'error_code': '-40106'},
          ])));
      final items = await _pt(t).send(_thing(), _requests);
      expect(items[0].ok, isTrue);
      expect(items[1].errorCode, -40106);
      expect(items[1].result, isEmpty);
    });

    test('cloud errors have user messages', () async {
      final cases = {
        -20571: 'offline',
        -20002: 'did not respond',
        12202: 'did not respond',
        -20580: 'not linked',
      };
      for (final e in cases.entries) {
        final t = FakeCloudTransport((r) => jsonReply({'error_code': e.key}));
        await expectLater(
          _pt(t).send(_thing(), _requests),
          throwsA(isA<TapoException>().having((x) => x.message.toLowerCase(), 'message', contains(e.value))),
          reason: '${e.key}',
        );
      }
      final t408 = FakeCloudTransport((r) => jsonReply({}, status: 408));
      await expectLater(
        _pt(t408).send(_thing(), _requests),
        throwsA(isA<TapoException>().having((x) => x.message.toLowerCase(), 'm', contains('did not respond'))),
      );
      final t429 = FakeCloudTransport((r) => jsonReply({}, status: 429));
      await expectLater(
        _pt(t429).send(_thing(), _requests),
        throwsA(isA<TapoException>().having((x) => x.message.toLowerCase(), 'm', contains('busy'))),
      );
      final tOther = FakeCloudTransport((r) => jsonReply({'errorCode': -9999}));
      await expectLater(
        _pt(tOther).send(_thing(), _requests),
        throwsA(isA<TapoException>().having((x) => x.message, 'm', contains('-9999'))),
      );
    });

    test('device level error outside offline and timeout is a device error', () async {
      final t = FakeCloudTransport((r) => jsonReply(_reply([], code: -40210)));
      await expectLater(_pt(t).send(_thing(), _requests), throwsA(isA<TapoDeviceError>()));
    });

    test('expired token relogs in once', () async {
      var refreshed = 0;
      final t = FakeCloudTransport((r) {
        if (r.headers['Authorization'] == 'ut|tok-1') return jsonReply({'errorCode': -20651});
        return jsonReply(_reply([_item('getLedStatus')]));
      });
      final pt = _pt(t, refresher: (stale) async {
        refreshed++;
        expect(stale, 'tok-1');
        return 'tok-2';
      });
      final items = await pt.send(_thing(), _requests);
      expect(items, hasLength(1));
      expect(refreshed, 1);
      expect(t.requests.last.headers['Authorization'], 'ut|tok-2');
      expect(pt.token, 'tok-2');
    });

    test('http 401 also refreshes', () async {
      final t = FakeCloudTransport((r) {
        if (r.headers['Authorization'] == 'ut|tok-1') return jsonReply({}, status: 401);
        return jsonReply(_reply([_item('getLedStatus')]));
      });
      expect(await _pt(t).send(_thing(), _requests), hasLength(1));
    });

    test('token rejected twice gives up', () async {
      var refreshed = 0;
      final t = FakeCloudTransport((r) => jsonReply({'errorCode': -20652}));
      final pt = _pt(t, refresher: (_) async {
        refreshed++;
        return 'tok-2';
      });
      await expectLater(
        pt.send(_thing(), _requests),
        throwsA(isA<TapoException>().having((e) => e.message.toLowerCase(), 'm', contains('session expired'))),
      );
      expect(refreshed, 1);
      expect(t.requests, hasLength(2));
    });

    test('concurrent callers share one refresh', () async {
      var refreshed = 0;
      final gate = Completer<void>();
      final t = FakeCloudTransport((r) {
        if (r.headers['Authorization'] == 'ut|tok-1') return jsonReply({}, status: 401);
        return jsonReply(_reply([_item('getLedStatus')]));
      });
      final pt = _pt(t, refresher: (_) async {
        refreshed++;
        await gate.future;
        return 'tok-2';
      });
      final a = pt.send(_thing(), _requests);
      final b = pt.send(_thing(name: 'THING2'), _requests);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      gate.complete();
      await Future.wait([a, b]);
      expect(refreshed, 1);
    });

    test('malformed reply is protocol error', () async {
      for (final body in <Object>[
        <String, dynamic>{},
        {'outputParams': 'x'},
        {'outputParams': {'responseData': 5}},
        _reply([]).map((k, v) => MapEntry(k, 'oops')),
      ]) {
        final t = FakeCloudTransport((r) => jsonReply(body));
        await expectLater(
          _pt(t).send(_thing(), _requests),
          throwsA(isA<TapoProtocolError>()),
          reason: '$body',
        );
      }
      final t = FakeCloudTransport((r) => textReply('not json'));
      await expectLater(_pt(t).send(_thing(), _requests), throwsA(isA<TapoProtocolError>()));
    });
  });
}
