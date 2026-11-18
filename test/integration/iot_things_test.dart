// Tier 2, scenario 2: IoT things -> roles, online state, local access token.
// Real TapoCloud + IotThingsClient + camera_router helpers against MockCloud.
// Specs: hc.cloud.iot_things, hc.cloud.online_state, hc.cloud.role.
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/camera_router.dart';
import 'package:tapo_tv/api/iot_things.dart';

import '../fixtures/mock_cloud.dart';
import 'support/cloud_rig.dart';

const String _lat = 'LAT-SECRET-0123456789abcdef';

List<Map<String, dynamic>> _devices() => [
      makeCloudDevice(1, overrides: {'alias': 'Owner online'}),
      makeCloudDevice(2, overrides: {'alias': 'Owner offline', 'status': 0}),
      makeCloudDevice(3, overrides: {'alias': 'Shared online', 'role': 1}),
      makeCloudDevice(4, overrides: {'alias': 'Shared offline', 'role': 1, 'status': 0}),
    ];

String _id(int i) => makeCloudDevice(i)['deviceId'] as String;

void main() {
  late CloudRig rig;

  setUp(() async {
    rig = await CloudRig.start(devices: _devices(), localTokens: {_id(1): _lat});
    rig.mock.thingsMaxPageSize = 2; // the client asks for 100: the server caps, the client must page
    await rig.signIn();
  });

  test('fetchAll pages through every thing: role, status, region URL, LAT', () async {
    final client = await rig.iotClient();
    final things = await client.fetchAll();

    expect(things.keys.toSet(), {_id(1), _id(2), _id(3), _id(4)});
    expect(rig.mock.calls('/v2/things').length, greaterThanOrEqualTo(2));
    for (final call in rig.mock.calls('/v2/things')) {
      expect(call.headers['authorization'], 'ut|${rig.cloud.token}');
      expect(call.headers['x-term-id'], testTerminal);
    }

    final owner = things[_id(1)]!;
    expect(owner.thingName, _id(1));
    expect(owner.deviceId, _id(1));
    expect(owner.role, 0);
    expect(owner.isShared, isFalse);
    expect(owner.online, isTrue);
    expect(owner.localAccessToken, _lat);
    expect(owner.appServerUrl, rig.mock.regionalUrl);
    expect(owner.deviceType, 'SMART.IPCAMERA');

    expect(things[_id(2)]!.online, isFalse);
    expect(things[_id(2)]!.localAccessToken, isNull);
    expect(things[_id(3)]!.isShared, isTrue);
    expect(things[_id(3)]!.online, isTrue);
    expect(things[_id(4)]!.isShared, isTrue);
    expect(things[_id(4)]!.online, isFalse);
  });

  test('a thing never prints its local access token', () async {
    final things = await (await rig.iotClient()).fetchAll();
    expect('${things[_id(1)]}', isNot(contains(_lat)));
  });

  test('an expired token is reported as IotTokenExpired (caller re-logins once)', () async {
    final client = await rig.iotClient();
    rig.mock.expireTokens();
    await expectLater(client.fetchAll(), throwsA(isA<IotTokenExpired>()));
  });

  test('things + device list give role, online and route like the app derives them', () async {
    final things = await (await rig.iotClient()).fetchAll();
    final list = await rig.cloud.listCameras(rig.baseUrl);
    expect(list, hasLength(4));

    for (final dev in list) {
      final thing = things[dev['deviceId']]!;
      final role = roleFromRecords(thingRole: thing.role, deviceListRole: dev['role'] as int?);
      final online = cameraOnline(
          thingStatus: thing.status, deviceListStatus: dev['status'] as int?, lanFound: false);
      final route = routeFor(isManual: false, role: role, lanFound: false);

      expect(role, thing.isShared ? CameraRole.shared : CameraRole.owner, reason: '${dev['alias']}');
      expect(online, thing.online, reason: '${dev['alias']}');
      expect(route, CameraRoute.cloud, reason: 'no LAN answer: everything is cloud routed');
    }

    // On the LAN an owner camera is local, a shared one stays on the cloud.
    expect(routeFor(isManual: false, role: CameraRole.owner, lanFound: true, host: '192.168.1.51'),
        CameraRoute.local);
    expect(routeFor(isManual: false, role: CameraRole.shared, lanFound: true, host: '192.168.1.51'),
        CameraRoute.cloud);
    // A TDP answer makes an offline thing online (spec hc.cloud.online_state).
    expect(cameraOnline(thingStatus: 0, deviceListStatus: 0, lanFound: true), isTrue);
  });
}
