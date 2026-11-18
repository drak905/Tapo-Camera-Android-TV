// Tier 2, scenario 7: live view through the cloud relay. Real TapoCloud login,
// real RelayTsSource + RelaySlotClient + RelayTunnel against MockCloud (CIPC
// slot request) and MockRelay (TLS tunnel). The relay mock enforces the exact
// header order, cloudType, redirect and offline behaviour of the real node.
// Specs: mb.relay.slot, mb.relay.tunnel, mb.relay.heartbeat, mb.relay.redirect.
@Timeout(Duration(seconds: 90))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/media/media_errors.dart';
import 'package:tapo_tv/media/relay/relay_ts_source.dart';

import '../fixtures/mock_cloud.dart';
import '../fixtures/mock_relay.dart';
import 'support/cloud_rig.dart';
import 'support/net.dart';

class _World {
  _World(this.rig, this.relay, this.auth, this.connector, this.deviceId);
  final CloudRig rig;
  final MockRelay relay;
  final RigRelayAuth auth;
  final TestConnector connector;
  final String deviceId;

  RelayTsSource source({
    int cloudType = 2,
    String resolution = 'VGA',
    Duration heartbeat = const Duration(milliseconds: 200),
  }) =>
      RelayTsSource(
        deviceId: deviceId,
        auth: auth,
        connector: connector.call,
        resolution: resolution,
        cloudType: cloudType,
        heartbeatInterval: heartbeat,
        stopLinger: const Duration(milliseconds: 50),
      );
}

Future<_World> _world({String elbCookie = ''}) async {
  final relay = await MockRelay(partInterval: const Duration(milliseconds: 1)).start();
  addTearDown(relay.stop);
  relay.elbCookie = elbCookie;
  final device = makeCloudDevice(1);
  final rig = await CloudRig.start(devices: [device], relay: relay);
  await rig.signIn();
  return _World(rig, relay, RigRelayAuth(rig), TestConnector(context: relay.clientSecurityContext()),
      device['deviceId'] as String);
}

void main() {
  test('live relay: slot request (cloudType 2) then tunnel with the exact header order, plain TS out', () async {
    final w = await _world();

    final bytes = await collect(w.source().openTs(), minBytes: 188 * 32 * 20);

    expectTsPackets(bytes, minPackets: 600);
    expectSamplePrefix(bytes, w.relay.ts);

    final slotCalls = w.rig.mock.requestLog.where((c) => c.path == '$cipcPrefix/v2/relay/request').toList();
    expect(slotCalls, hasLength(1));
    final body = slotCalls.single.body as Map;
    expect(body['cloudType'], 2);
    expect(body['streamType'], 0);
    expect(body['deviceId'], w.deviceId);
    expect(slotCalls.single.headers['authorization'], w.rig.cloud.token, reason: 'raw token, no ut| prefix');

    expect(w.relay.tunnels, hasLength(1));
    expect(w.relay.tunnels.single.status, '200');
    expect(w.relay.tunnels.single.headers.map((h) => h.$1).toList(), expectedHeaderOrder.where((h) => h != 'Cookie').toList());
    expect(w.relay.slots.values.single.cloudType, 2);
    expect(w.relay.previews, hasLength(1));
    expect(w.relay.previews.single, isNotEmpty);
  });

  test('ELB cookie from the slot is sent back as Cookie in the right position', () async {
    final w = await _world(elbCookie: 'AWSELB=abc123');
    await collect(w.source().openTs(), minBytes: 188 * 32 * 4);
    expect(w.relay.tunnels.single.status, '200');
    expect(w.relay.tunnels.single.headers.map((h) => h.$1).toList(), expectedHeaderOrder);
  });

  test('heartbeats while idle-ish, acks while data flows, stop request before the socket closes', () async {
    final w = await _world();
    final seen = <int>[0];
    final sub = w.source(heartbeat: const Duration(milliseconds: 150)).openTs().listen((c) => seen[0] += c.length);
    addTearDown(sub.cancel);

    expect(await eventually(() => w.relay.heartbeats.length >= 3, timeout: const Duration(seconds: 6)), isTrue);
    expect(await eventually(() => w.relay.acks.isNotEmpty, timeout: const Duration(seconds: 6)), isTrue);
    for (final (_, raw) in w.relay.heartbeats) {
      expect(utf8.decode(raw), '{"type": "notification", "params": {"event_type": "heartbeat"}}');
    }
    expect(seen[0], greaterThan(188 * 100));

    await sub.cancel();
    expect(await eventually(() => w.relay.stops >= 1), isTrue, reason: 'client sends do/stop before closing');
    expect(await eventually(() => w.relay.openTunnels == 0), isTrue);
  });

  test('304 redirect: the client reconnects with X-Redirect-Times + 1 and streams', () async {
    final w = await _world();
    w.relay.redirects = 1;

    final bytes = await collect(w.source().openTs(), minBytes: 188 * 32 * 4);

    expectTsPackets(bytes);
    expect(w.relay.tunnels, hasLength(2));
    expect(w.relay.tunnels[0].status, startsWith('304'));
    expect(w.relay.tunnels[1].status, '200');
    final times = {for (final h in w.relay.tunnels[1].headers) h.$1: h.$2}['X-Redirect-Times'];
    expect(times, '1');
  });

  test('device offline (relay -1007): a media error, one tunnel, no retry loop', () async {
    final w = await _world();
    w.relay.mode = RelayMode.offline;

    final error = await firstError(w.source().openTs());

    expect(error, isA<MediaException>());
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(w.relay.tunnels, hasLength(1));
    expect(w.relay.tunnels.single.status, startsWith('500'));
    expect(w.rig.mock.requestLog.where((c) => c.path.endsWith('/relay/request')), hasLength(1));
  });

  test('wrong cloudType makes the relay answer offline', () async {
    final w = await _world();
    final error = await firstError(w.source(cloudType: 1).openTs());
    expect(error, isA<MediaException>());
    expect(w.relay.tunnels, hasLength(1));
  });

  test('cloud says the camera is offline (-40401): no tunnel is opened', () async {
    final w = await _world();
    w.rig.mock.relayErrors[w.deviceId] = -40401;

    final error = await firstError(w.source().openTs());

    expect(error, isA<RelayException>());
    expect(w.relay.tunnels, isEmpty);
  });

  test('expired cloud token: one silent re-login, then the stream starts', () async {
    final w = await _world();
    w.rig.mock.expireTokens();

    final bytes = await collect(w.source().openTs(), minBytes: 188 * 32 * 4);

    expectTsPackets(bytes);
    expect(w.auth.relogins, 1);
    expect(w.rig.mock.requestLog.where((c) => c.path.endsWith('/relay/request')), hasLength(2));
  });

  test('relay dropping the connection ends the stream without a hang', () async {
    final w = await _world();
    w.relay.mode = RelayMode.drop;
    try {
      await collect(w.source().openTs(), minBytes: 1 << 30, timeout: const Duration(seconds: 8));
    } on MediaException {
      // an error is as valid as a clean end
    }
    expect(w.relay.tunnels.length, lessThanOrEqualTo(2));
  });

  test('encrypted relay media is refused with a clear error, nothing is forwarded', () async {
    final w = await _world();
    w.relay.mode = RelayMode.encrypted;
    final received = <Uint8List>[];
    Object? error;
    try {
      await collect(
        w.source().openTs().map((c) {
          received.add(c);
          return c;
        }),
        minBytes: 188 * 32 * 4,
      );
    } on Object catch (e) {
      error = e;
    }
    expect(error, isA<EncryptedRelayMediaException>());
    expect(received.fold<int>(0, (a, c) => a + c.length), 0);
  });
}
