// Tier 2: the production adapters the app uses end to end, against the Dart
// mocks (no test-only auth or connector in the media path):
//  * TapoCloudRelayAuth (CloudRelayAuth over TapoCloud: token, CIPC URL,
//    signed POST through the CloudTransport, silent re-login);
//  * LocalSecretsMediaAuth / CameraControlClient.mediaAuth (LAT first, then
//    the cloud password, like Windows vod/session.py `_secret`);
//  * socketConnector(context:) (relay TLS trusts a given SecurityContext,
//    hostname checked against the relay host);
//  * FailoverSource (local stream fails -> cloud relay within 2.5 s).
@Timeout(Duration(seconds: 90))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/camera_control_client.dart';
import 'package:tapo_tv/api/cloud_relay_auth.dart';
import 'package:tapo_tv/media/failover_source.dart';
import 'package:tapo_tv/media/local8800/local_ts_source.dart';
import 'package:tapo_tv/media/media_errors.dart';
import 'package:tapo_tv/media/media_source.dart';
import 'package:tapo_tv/media/media_transport.dart';
import 'package:tapo_tv/media/relay/relay_ts_source.dart';

import '../fixtures/mock_camera.dart';
import '../fixtures/mock_cloud.dart';
import '../fixtures/mock_media8800.dart';
import '../fixtures/mock_relay.dart';
import 'support/camera_rig.dart';
import 'support/cloud_rig.dart';
import 'support/net.dart';

const Duration _budget = Duration(milliseconds: 2500);

class _Rig {
  _Rig(this.rig, this.relay, this.deviceId);
  final CloudRig rig;
  final MockRelay relay;
  final String deviceId;

  TapoCloudRelayAuth auth() => TapoCloudRelayAuth(
        cloud: rig.cloud,
        baseUrl: () => rig.baseUrl,
        transport: rig.transport,
        terminalUuid: testTerminal,
      );

  RelayTsSource source({TransportConnector? connector}) => RelayTsSource(
        deviceId: deviceId,
        auth: auth(),
        connector: connector ?? socketConnector(context: relay.clientSecurityContext()),
        stopLinger: const Duration(milliseconds: 20),
      );
}

Future<_Rig> _cloud() async {
  final relay = await MockRelay(partInterval: const Duration(milliseconds: 1)).start();
  addTearDown(relay.stop);
  final device = makeCloudDevice(1);
  final rig = await CloudRig.start(devices: [device], relay: relay);
  await rig.signIn();
  return _Rig(rig, relay, device['deviceId'] as String);
}

Future<int> _closedPort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

class _NeverCalled implements MediaSource {
  @override
  Stream<Uint8List> openTs() => throw StateError('fallback must not be used');
}

void main() {
  group('TapoCloudRelayAuth + socketConnector', () {
    test('relay live view with the production auth and connector: raw token, CIPC from getAppServiceUrl', () async {
      final w = await _cloud();

      final bytes = await collect(w.source().openTs(), minBytes: 188 * 32 * 8);

      expectTsPackets(bytes);
      final slot = w.rig.mock.requestLog.where((c) => c.path == '$cipcPrefix/v2/relay/request').single;
      expect(slot.headers['authorization'], w.rig.cloud.token);
      expect(slot.headers['x-client-id'], testTerminal);
      expect(w.relay.tunnels.single.status, '200');
    });

    test('relay -1102: one silent TapoCloud re-login, a new slot, the stream starts', () async {
      final w = await _cloud();
      final auth = w.auth();
      await auth.cipcUrl; // discovered at sign-in in the app
      final before = w.rig.cloud.token;
      w.rig.mock.expireTokens();

      final source = RelayTsSource(
        deviceId: w.deviceId,
        auth: auth,
        connector: socketConnector(context: w.relay.clientSecurityContext()),
        stopLinger: const Duration(milliseconds: 20),
      );
      final bytes = await collect(source.openTs(), minBytes: 188 * 32 * 4);

      expectTsPackets(bytes);
      expect(w.rig.cloud.token, isNot(before));
      expect(w.rig.mock.requestLog.where((c) => c.path.endsWith('/relay/request')), hasLength(2));
    });

    test('without the relay trust the TLS handshake fails (verification stays on)', () async {
      final w = await _cloud();
      await expectLater(
        socketConnector()('127.0.0.1', w.relay.port, tls: true, serverName: relayHost),
        throwsA(isA<HandshakeException>()),
      );
    });

    test('a wrong server name fails the hostname check', () async {
      final w = await _cloud();
      await expectLater(
        socketConnector(context: w.relay.clientSecurityContext())(
          '127.0.0.1',
          w.relay.port,
          tls: true,
          serverName: 'relay.example.com',
        ),
        throwsA(isA<HandshakeException>()),
      );
    });

    test('maxConnect bounds the TCP connect wait', () async {
      final port = await _closedPort();
      final clock = Stopwatch()..start();
      await expectLater(
        socketConnector(maxConnect: const Duration(milliseconds: 300))('127.0.0.1', port),
        throwsA(anything),
      );
      expect(clock.elapsed, lessThan(const Duration(milliseconds: 2500)));
    });
  });

  group('local media auth', () {
    test('LAT first, then the cloud password', () {
      expect(LocalSecretsMediaAuth(const LocalSecrets(password: 'pw', lat: 'lat-1')).digestSecret, 'lat-1');
      expect(LocalSecretsMediaAuth(const LocalSecrets(password: 'pw')).digestSecret, 'pw');
      expect(LocalSecretsMediaAuth(const LocalSecrets(password: 'pw', lat: '')).digestSecret, 'pw');
      expect(LocalSecretsMediaAuth(const LocalSecrets()).username, 'admin');
    });

    test('the control client hands its secrets to the :8800 stream (LAT camera)', () async {
      final m = MockMedia8800(secret: 'lat-secret', previewInterval: const Duration(milliseconds: 1));
      final c = await startMedia8800(m);
      // The control client only lends its secrets to the media stream here.
      final cam = await MockCamera().start();
      addTearDown(cam.stop);
      final client = CameraControlClient(
        channel: transportFor(cam),
        secrets: const LocalSecrets(password: 'cloud-pw', lat: 'lat-secret'),
      );
      addTearDown(client.close);

      final source = LocalTsSource(host: '127.0.0.1', port: m.port, auth: client.mediaAuth, connector: c.call);
      final bytes = await collect(source.openTs(), minBytes: m.chunkSize * 4);

      expectTsPackets(bytes);
      expect(m.authFailures, 0);
    }, tags: [tagAdguardTls]);
  });

  group('FailoverSource', () {
    test('unreachable local camera -> cloud relay within 2.5 s', () async {
      final w = await _cloud();
      final port = await _closedPort();
      final local = LocalTsSource(
        host: '127.0.0.1',
        port: port,
        auth: LocalSecretsMediaAuth(const LocalSecrets(password: 'cloudpass')),
        connector: socketConnector(maxConnect: const Duration(milliseconds: 1200)),
        stopLinger: const Duration(milliseconds: 20),
      );
      Duration? switchedAfter;
      final clock = Stopwatch()..start();
      final source = FailoverSource(
        primary: local,
        fallback: () => w.source(),
        budget: _budget,
        onFailover: (_) => switchedAfter = clock.elapsed,
      );

      final bytes = await collect(source.openTs(), minBytes: 188 * 32 * 4);

      expectTsPackets(bytes);
      expect(switchedAfter, isNotNull);
      expect(switchedAfter!, lessThan(_budget));
      expect(w.relay.tunnels.single.status, '200');
    });

    test('a local camera that never answers is abandoned at the budget', () async {
      final w = await _cloud();
      // Accepts TCP but never answers the POST /stream.
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final held = <Socket>[];
      silent.listen(held.add);
      addTearDown(() async {
        for (final s in held) {
          s.destroy();
        }
        await silent.close();
      });
      final local = LocalTsSource(
        host: '127.0.0.1',
        port: silent.port,
        auth: LocalSecretsMediaAuth(const LocalSecrets(password: 'cloudpass')),
        connector: socketConnector(),
        stopLinger: const Duration(milliseconds: 20),
      );
      final clock = Stopwatch()..start();
      Duration? switchedAfter;
      final source = FailoverSource(
        primary: local,
        fallback: () => w.source(),
        budget: const Duration(milliseconds: 800),
        onFailover: (_) => switchedAfter = clock.elapsed,
      );

      final bytes = await collect(source.openTs(), minBytes: 188 * 32 * 4);

      expectTsPackets(bytes);
      expect(switchedAfter, isNotNull);
      expect(switchedAfter!, lessThan(_budget));
    });

    test('a reachable local camera is not failed over; cancel stops the camera stream', () async {
      final m = MockMedia8800(previewInterval: const Duration(milliseconds: 1));
      final c = await startMedia8800(m);
      final source = FailoverSource(
        primary: LocalTsSource(
          host: '127.0.0.1',
          port: m.port,
          auth: LocalSecretsMediaAuth(const LocalSecrets(password: 'cloudpass')),
          connector: c.call,
          stopLinger: const Duration(milliseconds: 20),
        ),
        fallback: () => _NeverCalled(),
        budget: _budget,
      );

      final bytes = await collect(source.openTs(), minBytes: m.chunkSize * 4);

      expectTsPackets(bytes);
      expect(await eventually(() => m.stopRequests >= 1), isTrue);
      expect(await eventually(() => m.activeSessions == 0), isTrue);
    }, tags: [tagAdguardTls]);

    test('a fatal local refusal (wrong password) is not hidden by the relay', () async {
      final m = MockMedia8800(previewInterval: const Duration(milliseconds: 1));
      final c = await startMedia8800(m);
      final source = FailoverSource(
        primary: LocalTsSource(
          host: '127.0.0.1',
          port: m.port,
          auth: LocalSecretsMediaAuth(const LocalSecrets(password: 'WRONG')),
          connector: c.call,
        ),
        fallback: () => _NeverCalled(),
        budget: _budget,
      );

      final error = await firstError(source.openTs());

      expect(error, isA<MediaAuthException>());
      expect(m.authFailures, 1, reason: 'no second login');
    }, tags: [tagAdguardTls]);

    test('without a fallback (shared or not signed in) the local error is reported', () async {
      final port = await _closedPort();
      final source = FailoverSource(
        primary: LocalTsSource(
          host: '127.0.0.1',
          port: port,
          auth: LocalSecretsMediaAuth(const LocalSecrets(password: 'x')),
          connector: socketConnector(maxConnect: const Duration(milliseconds: 500)),
        ),
        fallback: null,
        budget: _budget,
      );
      expect(await firstError(source.openTs()), isNotNull);
    });
  });
}

