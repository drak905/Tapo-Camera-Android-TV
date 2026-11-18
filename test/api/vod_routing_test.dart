// Spec vod.transport.routing (tier 2). The spec names test/api/vod_transport_test.dart,
// which LANES.md gives to the player lane; this file is the api lane's routing test.

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/camera_router.dart';
import 'package:tapo_tv/api/vod_client.dart';

TapoCamera _cam({
  CameraRole role = CameraRole.owner,
  String? lanIp,
  bool online = true,
  CameraRoute route = CameraRoute.local,
}) =>
    TapoCamera(
      id: 'cam-1',
      name: 'Porch',
      model: 'C200',
      role: role,
      online: online,
      route: route,
      lanIp: lanIp,
    );

void main() {
  test('lan owned camera uses local', () {
    final c = chooseVodTransport(_cam(lanIp: '192.168.1.20'), relayAvailable: false);
    expect(c.kind, VodTransportKind.local);
    expect(c.failure, isNull);
  });

  test('remote camera uses relay', () {
    final c = chooseVodTransport(_cam(route: CameraRoute.cloud), relayAvailable: true);
    expect(c.kind, VodTransportKind.relay);
  });

  test('shared camera on LAN uses relay', () {
    final c = chooseVodTransport(
      _cam(role: CameraRole.shared, lanIp: '192.168.1.20', route: CameraRoute.cloud),
      relayAvailable: true,
    );
    expect(c.kind, VodTransportKind.relay);
  });

  test('unreachable camera fails fast with reason', () {
    final remote = chooseVodTransport(_cam(route: CameraRoute.cloud), relayAvailable: false);
    expect(remote.kind, isNull);
    expect(remote.failure, VodFailReason.notOnThisNetwork);

    final offline = chooseVodTransport(
      _cam(route: CameraRoute.cloud, online: false),
      relayAvailable: true,
    );
    expect(offline.failure, VodFailReason.cameraOffline);

    final shared = chooseVodTransport(
      _cam(role: CameraRole.shared, lanIp: '192.168.1.20', route: CameraRoute.cloud),
      relayAvailable: false,
    );
    expect(shared.failure, VodFailReason.sharedCameraCloudOnly);
  });
}
