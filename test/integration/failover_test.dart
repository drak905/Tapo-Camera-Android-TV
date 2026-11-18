// Tier 2, scenario 9: failover. The camera was found on the LAN but is not
// reachable (port closed): the app must end up on the cloud relay (live) or
// cloud passthrough (control) within 2.5 s of the first attempt.
//
// API gap (see report): there is no production failover/orchestrator class yet,
// so the test composes the real pieces the way the app will:
//   live:    LocalTsSource fails -> app asks routeFor(lanFound: false) -> RelayTsSource
//   control: LocalControl fails -> router.invalidate() -> route is cloud -> CloudControl
// A connect to a closed loopback port can take ~2 s to be refused on Windows,
// so the connectors cap the connect wait at 1.2 s (what the app's local probe
// does too); the whole decision stays under 2.5 s.
@Timeout(Duration(seconds: 90))
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/camera_router.dart';
import 'package:tapo_tv/media/local8800/local_ts_source.dart';
import 'package:tapo_tv/media/media_deps.dart';
import 'package:tapo_tv/media/media_source.dart';
import 'package:tapo_tv/media/relay/relay_ts_source.dart';

import '../fixtures/mock_camera.dart';
import '../fixtures/mock_cloud.dart';
import '../fixtures/mock_media8800.dart';
import '../fixtures/mock_relay.dart';
import 'support/camera_rig.dart';
import 'support/cloud_rig.dart';
import 'support/net.dart';

const Duration _budget = Duration(milliseconds: 2500);

class _Auth implements LocalMediaAuth {
  @override
  String get digestSecret => 'cloudpass';
  @override
  String get username => 'admin';
}

/// A loopback port nothing listens on.
Future<int> _closedMediaPort() async {
  final m = await MockMedia8800().start();
  final port = m.port;
  await m.stop();
  return port;
}

/// What the app does: try [primary], on any failure use [fallback].
/// Returns (bytes from the winning source, time until the fallback was chosen).
Future<(Uint8List, Duration, bool)> _liveWithFailover(
  MediaSource primary,
  MediaSource Function() fallback,
) async {
  final clock = Stopwatch()..start();
  try {
    final first = await collect(primary.openTs(), minBytes: 188, timeout: _budget);
    return (first, clock.elapsed, false);
  } on Object {
    final decided = clock.elapsed;
    final bytes = await collect(fallback().openTs(), minBytes: 188 * 32 * 4);
    return (bytes, decided, true);
  }
}

void main() {
  test('live: unreachable local camera -> cloud relay within 2.5 s', () async {
    final port = await _closedMediaPort();
    final relay = await MockRelay(partInterval: const Duration(milliseconds: 1)).start();
    addTearDown(relay.stop);
    final device = makeCloudDevice(1);
    final rig = await CloudRig.start(devices: [device], relay: relay);
    await rig.signIn();

    final local = LocalTsSource(
      host: '127.0.0.1',
      port: port,
      auth: _Auth(),
      connector: TestConnector(maxConnect: const Duration(milliseconds: 1200)).call,
      stopLinger: const Duration(milliseconds: 20),
    );
    RelayTsSource relayFor() => RelayTsSource(
          deviceId: device['deviceId'] as String,
          auth: RigRelayAuth(rig),
          connector: TestConnector(context: relay.clientSecurityContext()).call,
          stopLinger: const Duration(milliseconds: 20),
        );

    final (bytes, decidedAfter, usedFallback) = await _liveWithFailover(local, relayFor);

    expect(usedFallback, isTrue);
    expect(decidedAfter, lessThan(_budget));
    expectTsPackets(bytes);
    expect(routeFor(isManual: false, role: CameraRole.owner, lanFound: false), CameraRoute.cloud);
    expect(relay.tunnels.single.status, '200');
  });

  test('live: a reachable local camera is not failed over', () async {
    final m = MockMedia8800(previewInterval: const Duration(milliseconds: 1));
    final c = await startMedia8800(m);
    final local = LocalTsSource(
      host: '127.0.0.1',
      port: m.port,
      auth: _Auth(),
      connector: c.call,
      stopLinger: const Duration(milliseconds: 20),
    );

    final (bytes, _, usedFallback) = await _liveWithFailover(local, () => fail('no fallback expected'));

    expect(usedFallback, isFalse);
    expectTsPackets(bytes, minPackets: 1);
  }, tags: [tagAdguardTls]);

  test('control: local camera unreachable -> router re-routes to the cloud within 2.5 s', () async {
    final device = makeCloudDevice(1);
    final rig = await CloudRig.start(devices: [device]);
    final cam = MockCamera(deviceId: device['deviceId'] as String);
    rig.attach(device['deviceId'] as String, cam);
    await rig.signIn();
    final thing = (await (await rig.iotClient()).fetchAll()).values.single;

    // A camera that answered TDP once, then went away: start + stop = closed port.
    final gone = await MockCamera(cloudPassword: 'pw').start();
    final gonePort = gone.port;
    await gone.stop();

    final router = CameraRouter(
      cloudSignedIn: () => true,
      localFactory: (camera, lat) => LocalControl(
        controlClientFor(gone, password: 'pw', port: gonePort),
      ),
      cloudFactory: (camera) => CloudControl(passthrough: rig.passthrough(), thing: thing),
    );

    final clock = Stopwatch()..start();
    var camera = CloudRig.tapoCamera(thing, route: CameraRoute.local, lanIp: '192.168.1.51');
    try {
      await router.controlFor(camera).setPrivacy(true);
      fail('the unreachable camera must not answer');
    } on TestFailure {
      rethrow;
    } on Object {
      // local path failed: mark it not found on the LAN and ask again
      router.invalidate(camera.id);
      camera = CloudRig.tapoCamera(thing,
          route: routeFor(isManual: false, role: CameraRole.owner, lanFound: false));
    }
    expect(camera.route, CameraRoute.cloud);
    await router.controlFor(camera).setPrivacy(true);

    expect(clock.elapsed, lessThan(_budget));
    expect(cam.state.privacy, isTrue);
    expect(cam.loginAttempts, 0);
  });
}
