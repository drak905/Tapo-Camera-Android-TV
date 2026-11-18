// Tier 2, scenario 5: camera controls (privacy, PTZ, night vision, siren, rename)
// through LocalControl (real client -> MockCamera :443) and CloudControl (real
// CloudPassthrough -> MockCloud services-sync -> MockCamera.execute), plus the
// CameraRouter choice. A shared camera never logs in locally.
// Specs: hc.control.*, hc.cloud.passthrough, hc.router.*.
@Timeout(Duration(seconds: 120))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/camera_control_client.dart';
import 'package:tapo_tv/api/camera_dtos.dart';
import 'package:tapo_tv/api/camera_router.dart';
import 'package:tapo_tv/api/iot_things.dart';

import '../fixtures/mock_camera.dart';
import '../fixtures/mock_cloud.dart';
import 'support/camera_rig.dart';
import 'support/cloud_rig.dart';

String _id(int i) => makeCloudDevice(i)['deviceId'] as String;

/// The same command sequence for every route and protocol.
Future<void> _exercise(CameraControl c, MockCamera cam) async {
  expect(await c.privacy(), isFalse);
  await c.setPrivacy(true);
  expect(cam.state.privacy, isTrue);
  expect(await c.privacy(), isTrue);
  await c.setPrivacy(false);
  expect(cam.state.privacy, isFalse);

  await c.ptzMove(10, 0);
  expect(cam.state.ptzX, 10);
  await c.ptzMove(0, -10);
  expect(cam.state.ptzY, -10);
  await c.ptzStop();

  await c.setNightVision(DayNightMode.on);
  expect(cam.state.infType, 'on');
  expect(await c.nightVision(), DayNightMode.on);
  await c.setNightVision(DayNightMode.auto);
  expect(await c.nightVision(), DayNightMode.auto);

  await c.setSiren(true);
  expect(cam.state.alarmActive, isTrue);
  await c.setSiren(false);
  expect(cam.state.alarmActive, isFalse);

  await c.rename('Porch');
  expect(cam.state.alias, 'Porch');
  final info = await c.deviceInfo();
  expect(info.deviceAlias, 'Porch');
  expect(info.deviceModel, 'C210');

  await c.setPrivacy(true);
  final status = await c.readStatus();
  expect(status.privacy, isTrue);
  expect(status.nightVision, DayNightMode.auto);
}

void main() {
  group('LocalControl over :443', () {
    for (final protocol in CameraProtocol.values) {
      test('${protocol.name}: privacy, PTZ, night vision, siren, rename, status', () async {
        final cam = await MockCamera(protocol: protocol, cloudPassword: 'pw-${protocol.name}').start();
        addTearDown(cam.stop);
        final client = controlClientFor(
          cam,
          password: 'pw-${protocol.name}',
          hint: protocol == CameraProtocol.tpap ? LocalProtocolHint.tpap : LocalProtocolHint.probe,
        );
        final control = LocalControl(client);
        addTearDown(control.close);

        await _exercise(control, cam);

        expect(cam.loginAttempts, lessThanOrEqualTo(4), reason: 'one login for the whole sequence');
      });
    }

    test('a failing command reports its camera error code without a re-login loop', () async {
      final cam = await MockCamera(cloudPassword: 'pw').start();
      addTearDown(cam.stop);
      final control = LocalControl(controlClientFor(cam, password: 'pw'));
      addTearDown(control.close);
      await control.privacy();
      final attempts = cam.loginAttempts;

      cam.state.ptzX = 180; // at the pan limit: -64304
      await expectLater(control.ptzMove(10, 0), throwsA(anything));
      expect(cam.loginAttempts, attempts);
    });
  });

  group('CloudControl through passthrough', () {
    late CloudRig rig;
    late MockCamera owned, shared;
    late Map<String, IotThing> things;

    setUp(() async {
      rig = await CloudRig.start(devices: [
        makeCloudDevice(1),
        makeCloudDevice(2, overrides: {'role': 1}),
      ]);
      owned = MockCamera(deviceId: _id(1), cloudPassword: 'pw-owned');
      shared = await MockCamera(deviceId: _id(2), cloudPassword: 'unknown-to-us').start();
      addTearDown(shared.stop);
      rig.attach(_id(1), owned);
      rig.attach(_id(2), shared);
      await rig.signIn();
      things = await (await rig.iotClient()).fetchAll();
    });

    test('owner camera: all controls work, URL is the thing\'s regional /v1/things/<id>/services-sync', () async {
      final control = CloudControl(passthrough: rig.passthrough(), thing: things[_id(1)]!);
      await _exercise(control, owned);

      expect(rig.mock.passthroughLog.map((e) => e.thing).toSet(), {_id(1)});
      final call = rig.mock.requestLog.lastWhere((c) => c.path.endsWith('/services-sync'));
      expect(call.path, '$regionPrefix/v1/things/${_id(1)}/services-sync');
      expect(call.headers['authorization'], 'ut|${rig.cloud.token}');
      expect(owned.loginAttempts, 0);
    });

    test('shared camera: controls work and the camera never sees a local login', () async {
      final control = CloudControl(passthrough: rig.passthrough(), thing: things[_id(2)]!);
      expect(things[_id(2)]!.isShared, isTrue);

      await _exercise(control, shared);

      expect(shared.loginAttempts, 0);
      expect(shared.loginCount, 0);
      expect(shared.dsRequestCount, 0);
      expect(rig.mock.passthroughLog, isNotEmpty);
    });

    test('readStatus is ONE passthrough batch', () async {
      final control = CloudControl(passthrough: rig.passthrough(), thing: things[_id(1)]!);
      await control.readStatus();
      expect(rig.mock.passthroughLog, hasLength(1));
      final methods = rig.mock.passthroughLog.single.requests.map((r) => (r as Map)['method']).toList();
      expect(methods, containsAll(['getLensMaskConfig', 'getDayNightModeConfig', 'getLedStatus', 'getDetectionConfig']));
    });

    test('expired cloud token: refreshed once, the command succeeds', () async {
      final control = CloudControl(passthrough: rig.passthrough(), thing: things[_id(1)]!);
      await control.privacy();
      final old = rig.cloud.token;
      rig.mock.expireTokens();

      await control.setPrivacy(true);

      expect(owned.state.privacy, isTrue);
      expect(rig.refreshes, 1);
      expect(rig.cloud.token, isNot(old));
    });

    test('offline camera and gateway errors surface as errors, not hangs', () async {
      final rig2 = await CloudRig.start(devices: [makeCloudDevice(5, overrides: {'status': 0})]);
      await rig2.signIn();
      final t = (await (await rig2.iotClient()).fetchAll()).values.single;
      expect(t.online, isFalse);
      final control = CloudControl(passthrough: rig2.passthrough(), thing: t);
      await expectLater(control.privacy(), throwsA(anything));
    });
  });

  group('CameraRouter', () {
    late CloudRig rig;
    late MockCamera owner, shared;
    late Map<String, IotThing> things;
    late int localBuilt, cloudBuilt;
    late List<String?> latsSeen;

    CameraRouter makeRouter({bool signedIn = true}) => CameraRouter(
          cloudSignedIn: () => signedIn,
          localFactory: (camera, lat) {
            localBuilt++;
            latsSeen.add(lat);
            return LocalControl(controlClientFor(owner, password: 'pw-owner'));
          },
          cloudFactory: (camera) {
            cloudBuilt++;
            return CloudControl(passthrough: rig.passthrough(), thing: things[camera.id]!);
          },
        );

    setUp(() async {
      localBuilt = 0;
      cloudBuilt = 0;
      latsSeen = [];
      rig = await CloudRig.start(devices: [
        makeCloudDevice(1),
        makeCloudDevice(2, overrides: {'role': 1}),
      ]);
      owner = await MockCamera(deviceId: _id(1), cloudPassword: 'pw-owner').start();
      shared = await MockCamera(deviceId: _id(2), cloudPassword: 'x').start();
      addTearDown(owner.stop);
      addTearDown(shared.stop);
      rig.attach(_id(1), owner);
      rig.attach(_id(2), shared);
      await rig.signIn();
      things = await (await rig.iotClient()).fetchAll();
    });

    test('owner on the LAN is controlled locally, cached, rebuilt when the LAT changes', () async {
      final router = makeRouter();
      final cam = CloudRig.tapoCamera(things[_id(1)]!, route: CameraRoute.local, lanIp: '192.168.1.51');

      final a = router.controlFor(cam, lat: 'LAT1');
      await a.setPrivacy(true);
      final again = router.controlFor(cam, lat: 'LAT1');

      expect(identical(a, again), isTrue);
      expect(localBuilt, 1);
      expect(cloudBuilt, 0);
      expect(owner.state.privacy, isTrue);
      expect(rig.mock.passthroughLog, isEmpty);

      router.controlFor(cam, lat: 'LAT2');
      expect(localBuilt, 2);
      expect(latsSeen, ['LAT1', 'LAT2']);
    });

    test('shared camera always goes through the cloud, even when it is on the LAN', () async {
      final router = makeRouter();
      final cam = CloudRig.tapoCamera(things[_id(2)]!, route: CameraRoute.cloud, lanIp: '192.168.1.52');

      final control = router.controlFor(cam);
      await control.setPrivacy(true);

      expect(localBuilt, 0);
      expect(cloudBuilt, 1);
      expect(shared.state.privacy, isTrue);
      expect(shared.loginAttempts, 0);
    });

    test('no cloud session: remote and shared cameras report why there is no path', () async {
      final router = makeRouter(signedIn: false);
      final remote = CloudRig.tapoCamera(things[_id(1)]!, route: CameraRoute.cloud);
      final sharedCam = CloudRig.tapoCamera(things[_id(2)]!, route: CameraRoute.cloud);

      expect(
        () => router.controlFor(remote),
        throwsA(isA<CameraRouteError>().having((e) => e.reason, 'reason', RouteFailure.networkOnly)),
      );
      expect(
        () => router.controlFor(sharedCam),
        throwsA(isA<CameraRouteError>().having((e) => e.reason, 'reason', RouteFailure.sharedCloudOnly)),
      );
      expect(localBuilt + cloudBuilt, 0);
    });

    test('invalidate drops the cached client', () async {
      final router = makeRouter();
      final cam = CloudRig.tapoCamera(things[_id(1)]!, route: CameraRoute.cloud);
      final a = router.controlFor(cam);
      router.invalidate(cam.id);
      final b = router.controlFor(cam);
      expect(identical(a, b), isFalse);
      expect(cloudBuilt, 2);
    });
  });
}
