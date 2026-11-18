// Specs hc.routing.local_vs_cloud, hc.routing.shared_rule, hc.routing.status_batch,
// hc.cloud.online_state (pure rule) and the CameraControl implementations.
//
// SAFETY: a shared camera (thing role != 0) must never get a local client,
// even when it is found on the LAN.

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/camera_control_client.dart';
import 'package:tapo_tv/api/camera_dtos.dart';
import 'package:tapo_tv/api/camera_router.dart';
import 'package:tapo_tv/api/cloud_passthrough.dart';
import 'package:tapo_tv/api/iot_things.dart';

import '_support/fake_v3_camera.dart';
import '_support/helpers.dart';

const _lan = '192.168.1.20';

TapoCamera _cam({
  CameraRole role = CameraRole.owner,
  String? lanIp,
  bool online = true,
  bool manual = false,
  CameraRoute route = CameraRoute.cloud,
}) =>
    TapoCamera(
      id: 'cam-1',
      name: 'Porch',
      model: 'C200',
      role: role,
      online: online,
      route: route,
      lanIp: lanIp,
      isManual: manual,
    );

class _FakeControl implements CameraControl {
  _FakeControl(this.kind, [this.lat]);
  final String kind;
  final String? lat;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Rig {
  _Rig({this.signedIn = true}) {
    router = CameraRouter(
      localFactory: (cam, lat) {
        localBuilt++;
        return _FakeControl('local', lat);
      },
      cloudFactory: (cam) {
        cloudBuilt++;
        return _FakeControl('cloud');
      },
      cloudSignedIn: () => signedIn,
    );
  }
  bool signedIn;
  int localBuilt = 0;
  int cloudBuilt = 0;
  late final CameraRouter router;
}

void main() {
  group('pure rules', () {
    test('owner on lan is local', () {
      expect(routeFor(isManual: false, role: CameraRole.owner, lanFound: true, host: _lan),
          CameraRoute.local);
    });

    test('owner not found on lan is cloud', () {
      expect(routeFor(isManual: false, role: CameraRole.owner, lanFound: false, host: null),
          CameraRoute.cloud);
      expect(routeFor(isManual: false, role: CameraRole.owner, lanFound: true, host: ''),
          CameraRoute.cloud);
    });

    test('shared on lan is cloud', () {
      expect(routeFor(isManual: false, role: CameraRole.shared, lanFound: true, host: _lan),
          CameraRoute.cloud);
    });

    test('manual camera never cloud', () {
      expect(routeFor(isManual: true, role: CameraRole.owner, lanFound: false, host: _lan),
          CameraRoute.local);
      expect(routeFor(isManual: true, role: CameraRole.owner, lanFound: false, host: null),
          CameraRoute.local);
    });

    test('role from thing record wins over device list', () {
      expect(roleFromRecords(thingRole: 1, deviceListRole: 0), CameraRole.shared);
      expect(roleFromRecords(thingRole: 0, deviceListRole: 1), CameraRole.owner);
      expect(roleFromRecords(thingRole: null, deviceListRole: 2), CameraRole.shared);
      expect(roleFromRecords(), CameraRole.owner);
    });

    test('online from thing status or lan', () {
      expect(cameraOnline(thingStatus: 1, lanFound: false), isTrue);
      expect(cameraOnline(thingStatus: 0, lanFound: true), isTrue);
      expect(cameraOnline(thingStatus: 0, lanFound: false), isFalse);
      // The device list status is only a fallback without a thing record.
      expect(cameraOnline(thingStatus: null, deviceListStatus: 1, lanFound: false), isTrue);
      expect(cameraOnline(thingStatus: null, deviceListStatus: 0, lanFound: false), isFalse);
      expect(cameraOnline(thingStatus: 0, deviceListStatus: 1, lanFound: false), isFalse);
    });
  });

  group('router', () {
    test('role 1 never builds local client', () {
      final rig = _Rig();
      final shared = _cam(role: CameraRole.shared, lanIp: _lan);
      for (var i = 0; i < 3; i++) {
        rig.router.controlFor(shared, lat: 'lat-token-value');
      }
      expect(rig.localBuilt, 0);
      expect(rig.cloudBuilt, 1);
    });

    test('owner on lan gets a local client with the lat', () {
      final rig = _Rig();
      final c = rig.router.controlFor(_cam(lanIp: _lan, route: CameraRoute.local), lat: 'lat-1');
      expect((c as _FakeControl).kind, 'local');
      expect(c.lat, 'lat-1');
      expect(rig.cloudBuilt, 0);
    });

    test('rebuild client when lan_found flips', () {
      final rig = _Rig();
      final onLan = _cam(lanIp: _lan, route: CameraRoute.local);
      final a = rig.router.controlFor(onLan);
      expect(rig.router.controlFor(onLan), same(a), reason: 'cached while nothing changes');
      expect(rig.localBuilt, 1);

      final away = _cam();
      final b = rig.router.controlFor(away);
      expect((b as _FakeControl).kind, 'cloud');
      expect(rig.cloudBuilt, 1);

      final back = rig.router.controlFor(onLan);
      expect(back, isNot(same(a)));
      expect(rig.localBuilt, 2);
    });

    test('lat change rebuilds client', () {
      final rig = _Rig();
      final onLan = _cam(lanIp: _lan, route: CameraRoute.local);
      final a = rig.router.controlFor(onLan, lat: 'lat-1');
      final b = rig.router.controlFor(onLan, lat: 'lat-2');
      expect(b, isNot(same(a)));
      expect(rig.localBuilt, 2);
      rig.router.invalidate('cam-1');
      rig.router.controlFor(onLan, lat: 'lat-2');
      expect(rig.localBuilt, 3);
    });

    test('route errors', () {
      final rig = _Rig(signedIn: false);
      RouteFailure? reason(void Function() f) {
        try {
          f();
        } on CameraRouteError catch (e) {
          return e.reason;
        }
        return null;
      }

      expect(reason(() => rig.router.controlFor(_cam())), RouteFailure.networkOnly);
      expect(reason(() => rig.router.controlFor(_cam(role: CameraRole.shared, lanIp: _lan))),
          RouteFailure.sharedCloudOnly);
      rig.signedIn = true;
      expect(reason(() => rig.router.controlFor(_cam(online: false))), RouteFailure.cameraOffline);
      expect(rig.localBuilt, 0);
    });
  });

  group('status batch', () {
    test('remote status single call with defaults', () async {
      final t = FakeCloudTransport((r) => jsonReply({
            'outputParams': {
              'responseData': {
                'error_code': 0,
                'result': {
                  'responses': [
                    {
                      'method': 'getLensMaskConfig',
                      'error_code': 0,
                      'result': {'lens_mask': {'lens_mask_info': {'enabled': 'on'}}},
                    },
                    {'method': 'getDayNightModeConfig', 'error_code': -40106, 'result': {}},
                    {
                      'method': 'getLedStatus',
                      'error_code': 0,
                      'result': {'led': {'config': {'enabled': 'on'}}},
                    },
                    {'method': 'getDetectionConfig', 'error_code': -40106, 'result': {}},
                  ],
                },
              },
            },
          }));
      final pt = CloudPassthrough(
        transport: t,
        token: 'tok-1',
        terminalUuid: 'A1B2C3D4E5F60718293A4B5C6D7E8F90',
        refresher: (_) async => 'tok-2',
      );
      const thing = IotThing(
        thingName: 'T1',
        deviceId: 'D1',
        status: 1,
        role: 1,
        appServerUrl: 'https://thing-eu.example.com',
      );
      final status = await CloudControl(passthrough: pt, thing: thing).readStatus();
      expect(t.requests, hasLength(1));
      final methods = (((t.requests.single.json['inputParams'] as Map)['requestData'] as Map)['params']
              as Map)['requests']
          .map((e) => (e as Map)['method'])
          .toList();
      expect(methods, ['getLensMaskConfig', 'getDayNightModeConfig', 'getLedStatus', 'getDetectionConfig']);
      expect(status.privacy, isTrue);
      expect(status.nightVision, DayNightMode.auto); // unsupported -> default
      expect(status.led, isTrue);
      expect(status.motion.enabled, isFalse); // unsupported -> default
    });
  });

  group('control implementations', () {
    test('local control sends the shared dto builders', () async {
      final cam = FakeV3Camera(secret: 'test_password');
      final client = CameraControlClient(
        channel: cam,
        secrets: const LocalSecrets(password: 'test_password'),
        cnonce: () => 'ABCDEF0123456789',
      );
      final control = LocalControl(client);
      await control.ptzMove(-5, 7);
      await control.setSiren(true);
      final sent = cam.received
          .expand((m) => ((m['params'] as Map)['requests'] as List).cast<Map>())
          .map((r) => r['method'])
          .toList();
      expect(sent, ['motorMove', 'doManualAlarm']);
    });

    test('cloud control rename goes through the passthrough', () async {
      final t = FakeCloudTransport((r) => jsonReply({
            'outputParams': {
              'responseData': {
                'error_code': 0,
                'result': {
                  'responses': [
                    {'method': 'setDeviceAlias', 'error_code': 0, 'result': {}},
                  ],
                },
              },
            },
          }));
      final pt = CloudPassthrough(
        transport: t,
        token: 'tok-1',
        terminalUuid: 'A1B2C3D4E5F60718293A4B5C6D7E8F90',
        refresher: (_) async => 'tok-2',
      );
      const thing = IotThing(
        thingName: 'T1',
        deviceId: 'D1',
        status: 1,
        role: 0,
        appServerUrl: 'https://thing-eu.example.com',
      );
      await CloudControl(passthrough: pt, thing: thing).rename('Garage');
      final sentJson = t.requests.single.body;
      expect(sentJson, contains('"setDeviceAlias"'));
      expect(sentJson, contains('"dev_alias":"Garage"'));
    });
  });
}
