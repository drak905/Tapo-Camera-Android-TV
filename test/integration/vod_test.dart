// Tier 2, scenario 10: SD-card recordings (VOD).
//  * day list + day clips through VodClient over the REAL local control client
//    (MockCamera :443) and over the REAL cloud passthrough (MockCloud), incl.
//    the -71103 "player_id required" retry of C510W firmware;
//  * playback through VodSession over MockMedia8800 (local) and MockRelay
//    (cloud relay, streamType 1), up to the end of the last recording;
//  * transport choice (local / relay / failure reason).
// Tag adguard-tls on the :8800 leg (see support/net.dart).
// Specs: vod.search.*, vod.transport.routing, vod.playback.*.
@Timeout(Duration(seconds: 120))
library;


import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/camera_dtos.dart';
import 'package:tapo_tv/api/camera_router.dart';
import 'package:tapo_tv/api/vod_client.dart' as vc;
import 'package:tapo_tv/api/vod_session.dart' as vs;
import 'package:tapo_tv/media/media_deps.dart';
import 'package:tapo_tv/media/media_errors.dart';

import '../fixtures/camera_state.dart' show Recording;
import '../fixtures/mock_camera.dart';
import '../fixtures/mock_cloud.dart';
import '../fixtures/mock_media8800.dart';
import '../fixtures/mock_relay.dart';
import 'support/camera_rig.dart';
import 'support/cloud_rig.dart';
import 'support/net.dart';

class _Control implements vc.VodControl {
  _Control(this._send);
  final Future<List<ControlItem>> Function(List<Map<String, dynamic>>) _send;
  @override
  Future<List<ControlItem>> send(List<Map<String, dynamic>> requests) => _send(requests);
}

class _Auth implements LocalMediaAuth {
  _Auth(this.digestSecret);
  @override
  final String digestSecret;
  @override
  String get username => 'admin';
}

final RegExp _day = RegExp(r'^\d{4}-\d{2}-\d{2}$');

DateTime _parseDay(String s) {
  final p = s.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2]);
}

Map<String, dynamic>? _searchParams(LoggedCall c) {
  final p = c.params;
  final playback = p is Map ? p['playback'] : null;
  final inner = playback is Map ? playback['search_video_with_utc'] : null;
  return inner is Map ? inner.cast<String, dynamic>() : null;
}

/// Day list and clips of every day of the last week: every recording must be listed once.
Future<void> _expectAllRecordings(vc.VodClient vod, List<Recording> expected) async {
  final now = DateTime.now();
  final days = await vod.daysWithRecordings(now.subtract(const Duration(days: 7)), now);
  expect(days, isNotEmpty);
  expect(days.every(_day.hasMatch), isTrue, reason: 'days are YYYY-MM-DD: $days');

  final starts = <int>{};
  for (final d in days) {
    final clips = await vod.recordingsForDay(_parseDay(d));
    for (final c in clips) {
      expect(c.end, greaterThan(c.start));
      expect(c.durationSeconds, c.end - c.start);
      starts.add(c.start);
    }
  }
  expect(starts, expected.map((r) => r.startEpoch).toSet());
}

void main() {
  group('day list and day clips', () {
    test('over local control (secure v3)', () async {
      final cam = await MockCamera(cloudPassword: 'pw').start();
      addTearDown(cam.stop);
      final client = controlClientFor(cam, password: 'pw');
      addTearDown(client.close);
      final vod = vc.VodClient(control: _Control(client.send), terminalUuid: testTerminal);

      await _expectAllRecordings(vod, cam.state.recordings);

      final methods = cam.requestLog.map((c) => c.method).toSet();
      expect(methods, containsAll(['searchDateWithVideo', 'searchVideoWithUTC']));
      expect(vod.playerId, isNotEmpty);
      expect(cam.loginAttempts, lessThanOrEqualTo(3));
    });

    test('C510W: -71103 without player_id is retried once with player_id, then remembered', () async {
      final cam = await MockCamera(cloudPassword: 'pw', clipSearchRequiresPlayerId: true).start();
      addTearDown(cam.stop);
      final client = controlClientFor(cam, password: 'pw');
      addTearDown(client.close);
      final vod = vc.VodClient(control: _Control(client.send), terminalUuid: testTerminal);
      final now = DateTime.now();
      final days = await vod.daysWithRecordings(now.subtract(const Duration(days: 7)), now);
      expect(days, isNotEmpty);

      final clips = await vod.recordingsForDay(_parseDay(days.last));

      expect(clips, isNotEmpty);
      final searches = cam.requestLog.where((c) => c.method == 'searchVideoWithUTC').map(_searchParams).toList();
      expect(searches.length, greaterThanOrEqualTo(2));
      expect(searches.first!.containsKey('player_id'), isFalse, reason: 'first attempt is the plain form');
      expect(searches.last!['player_id'], vod.playerId);

      final before = searches.length;
      await vod.recordingsForDay(_parseDay(days.first));
      final later = cam.requestLog.where((c) => c.method == 'searchVideoWithUTC').map(_searchParams).skip(before);
      expect(later, isNotEmpty);
      expect(later.every((p) => p!['player_id'] == vod.playerId), isTrue,
          reason: 'no second -71103 round trip once the camera needed player_id');
    });

    test('over the cloud passthrough (shared camera, never a local login)', () async {
      final device = makeCloudDevice(1, overrides: {'role': 1});
      final rig = await CloudRig.start(devices: [device]);
      final cam = MockCamera(deviceId: device['deviceId'] as String, cloudPassword: 'x');
      rig.attach(device['deviceId'] as String, cam);
      await rig.signIn();
      final thing = (await (await rig.iotClient()).fetchAll()).values.single;
      final pass = rig.passthrough();
      final vod = vc.VodClient(control: _Control((r) => pass.send(thing, r)), terminalUuid: testTerminal);

      await _expectAllRecordings(vod, cam.state.recordings);

      expect(rig.mock.passthroughLog, isNotEmpty);
      expect(cam.loginAttempts, 0);
    });
  });

  group('playback', () {
    List<vs.VodClipRange> clipsOf(MockCamera cam) => [
          for (final r in cam.state.recordings) vs.VodClipRange(r.startEpoch, r.endEpoch),
        ];

    test('local: clip plays as plain TS over :8800 and ends with "end of recordings"', () async {
      final cam = MockCamera(cloudPassword: 'cloudpass');
      final m = MockMedia8800.forCamera(cam)..previewInterval = const Duration(milliseconds: 1);
      final c = await startMedia8800(m);
      final last = cam.state.recordings.last;
      final session = vs.VodSession.local(
        host: '127.0.0.1',
        port: m.port,
        localAuth: _Auth('cloudpass'),
        connector: c.call,
        startUtc: last.startEpoch,
        endUtc: last.endEpoch,
        clips: clipsOf(cam),
        stopLinger: const Duration(milliseconds: 50),
      );
      final states = <vs.VodState>[];
      final sub = session.states.listen(states.add);
      addTearDown(sub.cancel);

      final bytes = await collect(session.openTs(), minBytes: 1 << 30, timeout: const Duration(seconds: 20));

      expectTsPackets(bytes, minPackets: 1);
      expect(m.playbackRequests, 1);
      expect(await eventually(() => session.state == vs.VodState.stopped), isTrue);
      expect(session.endReason, vs.kEndOfRecordings);
      expect(states, contains(vs.VodState.playing));
      expect(session.failure, isNull);
      expect(await eventually(() => m.activeSessions == 0), isTrue);
    }, tags: [tagAdguardTls]);

    test('local: stop() sends the stop request and frees the camera session', () async {
      final cam = MockCamera(cloudPassword: 'cloudpass');
      final m = MockMedia8800.forCamera(cam)..previewInterval = const Duration(milliseconds: 20);
      final c = await startMedia8800(m);
      final first = cam.state.recordings.first;
      final session = vs.VodSession.local(
        host: '127.0.0.1',
        port: m.port,
        localAuth: _Auth('cloudpass'),
        connector: c.call,
        startUtc: first.startEpoch,
        endUtc: first.endEpoch,
        clips: clipsOf(cam),
        stopLinger: const Duration(milliseconds: 50),
      );
      final sub = session.openTs().listen((_) {}, onError: (Object _) {});
      addTearDown(sub.cancel);
      expect(await eventually(() => m.playbackRequests == 1, timeout: const Duration(seconds: 6)), isTrue);

      await session.stop();

      expect(session.state, vs.VodState.stopped);
      expect(await eventually(() => m.stopRequests >= 1), isTrue);
      expect(await eventually(() => m.activeSessions == 0), isTrue);
    }, tags: [tagAdguardTls]);

    test('relay: playback slot (streamType 1) over the cloud relay, clip ends the session', () async {
      final relay = await MockRelay(partInterval: const Duration(milliseconds: 1)).start();
      addTearDown(relay.stop);
      final device = makeCloudDevice(1, overrides: {'role': 1});
      final rig = await CloudRig.start(devices: [device], relay: relay);
      await rig.signIn();
      final cam = MockCamera();
      final last = cam.state.recordings.last;
      final session = vs.VodSession.relay(
        deviceId: device['deviceId'] as String,
        auth: RigRelayAuth(rig),
        connector: TestConnector(context: relay.clientSecurityContext()).call,
        startUtc: last.startEpoch,
        endUtc: last.endEpoch,
        clips: clipsOf(cam),
        heartbeatInterval: const Duration(milliseconds: 200),
        stopLinger: const Duration(milliseconds: 50),
      );

      final bytes = await collect(session.openTs(), minBytes: 1 << 30, timeout: const Duration(seconds: 20));

      expectTsPackets(bytes, minPackets: 1);
      expect(relay.vodRequests, hasLength(1));
      final slot = rig.mock.requestLog.where((c) => c.path.endsWith('/relay/request')).single.body as Map;
      expect(slot['streamType'], 1);
      expect(slot['cloudType'], 2);
      expect(await eventually(() => session.state == vs.VodState.stopped), isTrue);
      expect(session.endReason, vs.kEndOfRecordings);
    });

    test('relay: the node refusing playback (-52402) is a PlaybackRefusedException', () async {
      final relay = await MockRelay().start();
      addTearDown(relay.stop);
      relay.vodRefuse.add('playback');
      final device = makeCloudDevice(1);
      final rig = await CloudRig.start(devices: [device], relay: relay);
      await rig.signIn();
      final rec = MockCamera().state.recordings.last;
      final session = vs.VodSession.relay(
        deviceId: device['deviceId'] as String,
        auth: RigRelayAuth(rig),
        connector: TestConnector(context: relay.clientSecurityContext()).call,
        startUtc: rec.startEpoch,
        endUtc: rec.endEpoch,
        stopLinger: const Duration(milliseconds: 50),
      );

      final error = await firstError(session.openTs());

      expect(error, isA<PlaybackRefusedException>().having((e) => e.errorCode, 'errorCode', -52402));
      expect(session.state, vs.VodState.failed);
    });
  });

  group('transport choice', () {
    TapoCamera camera({
      required CameraRole role,
      required bool online,
      required CameraRoute route,
      String? lanIp,
    }) =>
        TapoCamera(id: 'dev', name: 'Cam', model: 'C210', role: role, online: online, route: route, lanIp: lanIp);

    test('VodClient side: LAN owner local, shared / remote through the relay, failures carry a reason', () {
      // routeFor() only gives a cloud camera CameraRoute.local when it was found on the LAN with a host.
      final lanOwner = camera(role: CameraRole.owner, online: true, route: CameraRoute.local, lanIp: '192.168.1.20');
      expect(vc.chooseVodTransport(lanOwner, relayAvailable: true).kind, vc.VodTransportKind.local);

      final remoteOwner = camera(role: CameraRole.owner, online: true, route: CameraRoute.cloud);
      expect(vc.chooseVodTransport(remoteOwner, relayAvailable: true).kind, vc.VodTransportKind.relay);
      expect(vc.chooseVodTransport(remoteOwner, relayAvailable: false).failure, vc.VodFailReason.notOnThisNetwork);

      final shared = camera(role: CameraRole.shared, online: true, route: CameraRoute.cloud);
      expect(vc.chooseVodTransport(shared, relayAvailable: true).kind, vc.VodTransportKind.relay);
      expect(vc.chooseVodTransport(shared, relayAvailable: false).failure, vc.VodFailReason.sharedCameraCloudOnly);

      final offline = camera(role: CameraRole.owner, online: false, route: CameraRoute.cloud);
      expect(vc.chooseVodTransport(offline, relayAvailable: true).failure, vc.VodFailReason.cameraOffline);
    });

    test('VodSession side: same decisions with the role number and LAN flag', () {
      expect(vs.selectVodTransport(role: 0, onLan: true, online: true, hasRelayProvider: true).kind,
          vs.VodTransportKind.local);
      expect(vs.selectVodTransport(role: 1, onLan: true, online: true, hasRelayProvider: true).kind,
          vs.VodTransportKind.relay,
          reason: 'shared cameras on the LAN still use the relay');
      expect(vs.selectVodTransport(role: 0, onLan: false, online: true, hasRelayProvider: true).kind,
          vs.VodTransportKind.relay);
      final none = vs.selectVodTransport(role: 0, onLan: false, online: true, hasRelayProvider: false);
      expect(none.kind, vs.VodTransportKind.none);
      expect(none.failReason, vs.kReasonNotOnNetwork);
      expect(vs.selectVodTransport(role: 1, onLan: false, online: true, hasRelayProvider: false).failReason,
          vs.kReasonSharedCloudOnly);
      expect(vs.selectVodTransport(role: 0, onLan: false, online: false, hasRelayProvider: true).failReason,
          vs.kReasonCameraOffline);
    });
  });
}
