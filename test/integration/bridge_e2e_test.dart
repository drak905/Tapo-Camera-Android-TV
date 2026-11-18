// Tier 2, scenario 8: RelayBridge end to end. The bridge serves the plain
// MPEG-TS of a REAL LocalTsSource (vs MockMedia8800) and a REAL RelayTsSource
// (vs MockCloud + MockRelay) on 127.0.0.1, guarded by the per-launch key.
// Decision: "Every byte source reaches ExoPlayer as plain MPEG-TS on the
// 127.0.0.1 RelayBridge with a per-launch key; JSON/audio/bad-HMAC parts are
// never forwarded."  Specs: mb.bridge.*.
//
// Tag adguard-tls: the :8800 legs use the TLS fallback when plain loopback
// multipart traffic is intercepted (see support/net.dart).
@Timeout(Duration(seconds: 90))
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/relay_bridge.dart';
import 'package:tapo_tv/media/local8800/local_ts_source.dart';
import 'package:tapo_tv/media/media_deps.dart';
import 'package:tapo_tv/media/media_source.dart';
import 'package:tapo_tv/media/relay/relay_ts_source.dart';

import '../fixtures/mock_cloud.dart';
import '../fixtures/mock_media8800.dart';
import '../fixtures/mock_relay.dart';
import 'support/cloud_rig.dart';
import 'support/net.dart';

class _Auth implements LocalMediaAuth {
  _Auth(this.digestSecret);
  @override
  final String digestSecret;
  @override
  String get username => 'admin';
}

/// GET [url]; returns (status, headers, body-stream).
Future<(HttpClientResponse, HttpClient)> _get(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  final req = await client.getUrl(Uri.parse(url));
  final res = await req.close().timeout(const Duration(seconds: 8));
  return (res, client);
}

Stream<Uint8List> _body(HttpClientResponse r) => r.map(Uint8List.fromList);

Future<int> _status(String url) async {
  final (res, client) = await _get(url);
  await res.drain<void>();
  client.close(force: true);
  return res.statusCode;
}

void localTest(String name, Future<void> Function() body) => test(name, body, tags: [tagAdguardTls]);

void main() {
  late RelayBridge bridge;
  final resolved = <(String, String?)>[];
  final sources = <String, MediaSource>{};

  setUp(() async {
    resolved.clear();
    sources.clear();
    bridge = RelayBridge.sources((id, resolution) {
      resolved.add((id, resolution));
      return sources[id];
    });
    await bridge.start();
    addTearDown(bridge.stop);
  });

  group('local :8800 source', () {
    LocalTsSource local(MockMedia8800 m, TestConnector c, {String secret = 'cloudpass'}) => LocalTsSource(
          host: '127.0.0.1',
          port: m.port,
          auth: _Auth(secret),
          connector: c.call,
          resolution: 'VGA',
          stopLinger: const Duration(milliseconds: 50),
        );

    localTest('serves video/mp2t on 127.0.0.1 with the key; resolution comes from the URL', () async {
      final m = MockMedia8800(previewInterval: const Duration(milliseconds: 1));
      final c = await startMedia8800(m);
      sources['cam-local'] = local(m, c);
      expect(bridge.boundAddress, isNotNull);
      expect(bridge.boundAddress!.isLoopback, isTrue);

      final url = bridge.urlFor('cam-local', resolution: 'HD');
      expect(url, startsWith('http://127.0.0.1:'));
      final (res, client) = await _get(url);
      addTearDown(() => client.close(force: true));

      expect(res.statusCode, 200);
      expect(res.headers.contentType?.mimeType, 'video/mp2t');
      final bytes = await collect(_body(res), minBytes: m.chunkSize * 20);
      expectTsPackets(bytes, minPackets: 600);
      expectSamplePrefix(bytes, m.ts);
      expect(resolved.single, ('cam-local', 'HD'));
    });

    localTest('HKDF with corrupt HMACs: only verified video bytes leave the bridge', () async {
      final m = MockMedia8800(
        kex: MediaKex.hkdf,
        corruptHmacEvery: 3,
        previewInterval: const Duration(milliseconds: 1),
      );
      final c = await startMedia8800(m);
      sources['cam-local'] = local(m, c);

      final (res, client) = await _get(bridge.urlFor('cam-local'));
      addTearDown(() => client.close(force: true));
      final bytes = await collect(_body(res), minBytes: m.chunkSize * 20);

      expectTsPackets(bytes, minPackets: 600);
      expect(bytes.length % 188, 0);
    });

    localTest('closing the HTTP request stops the camera stream (stop request, session freed)', () async {
      final m = MockMedia8800(previewInterval: const Duration(milliseconds: 1));
      final c = await startMedia8800(m);
      sources['cam-local'] = local(m, c);

      final (res, client) = await _get(bridge.urlFor('cam-local'));
      await collect(_body(res), minBytes: m.chunkSize * 4);
      client.close(force: true);

      expect(await eventually(() => m.stopRequests >= 1, timeout: const Duration(seconds: 5)), isTrue);
      expect(await eventually(() => m.activeSessions == 0, timeout: const Duration(seconds: 5)), isTrue);
    });

    localTest('camera refuses the password: the player gets an HTTP error, not an empty 200', () async {
      final m = MockMedia8800();
      final c = await startMedia8800(m);
      sources['cam-local'] = local(m, c, secret: 'WRONG');
      expect(await _status(bridge.urlFor('cam-local')), anyOf(502, 500, 503));
    });
  });

  group('cloud relay source', () {
    test('serves the relay video as plain TS', () async {
      final relay = await MockRelay(partInterval: const Duration(milliseconds: 1)).start();
      addTearDown(relay.stop);
      final device = makeCloudDevice(1);
      final rig = await CloudRig.start(devices: [device], relay: relay);
      await rig.signIn();
      sources['cam-cloud'] = RelayTsSource(
        deviceId: device['deviceId'] as String,
        auth: RigRelayAuth(rig),
        connector: TestConnector(context: relay.clientSecurityContext()).call,
        stopLinger: const Duration(milliseconds: 50),
      );

      final (res, client) = await _get(bridge.urlFor('cam-cloud'));
      addTearDown(() => client.close(force: true));
      expect(res.statusCode, 200);
      expect(res.headers.contentType?.mimeType, 'video/mp2t');
      final bytes = await collect(_body(res), minBytes: 188 * 32 * 20);

      expectTsPackets(bytes, minPackets: 600);
      expectSamplePrefix(bytes, relay.ts);
    });

    test('offline camera: HTTP error from the bridge', () async {
      final relay = await MockRelay().start();
      addTearDown(relay.stop);
      relay.mode = RelayMode.offline;
      final device = makeCloudDevice(1);
      final rig = await CloudRig.start(devices: [device], relay: relay);
      await rig.signIn();
      sources['cam-cloud'] = RelayTsSource(
        deviceId: device['deviceId'] as String,
        auth: RigRelayAuth(rig),
        connector: TestConnector(context: relay.clientSecurityContext()).call,
      );
      expect(await _status(bridge.urlFor('cam-cloud')), anyOf(502, 500, 503));
    });
  });

  group('access control', () {
    test('without the per-launch key, with a wrong key, with a wrong path or for an unknown camera: 404', () async {
      sources['cam'] = _NeverOpened();
      final good = Uri.parse(bridge.urlFor('cam'));

      expect(await _status(good.replace(queryParameters: {}).toString()), 404, reason: 'no key');
      expect(await _status(good.replace(queryParameters: {'k': 'wrong'}).toString()), 404, reason: 'wrong key');
      expect(await _status(good.replace(path: '/other/cam.ts').toString()), 404, reason: 'wrong path');
      expect(await _status(good.replace(path: '/camera/cam.mp4').toString()), 404, reason: 'wrong extension');
      expect(await _status(bridge.urlFor('unknown')), 404, reason: 'unknown camera');
      expect(sources['cam'], isA<_NeverOpened>().having((s) => s.opened, 'opened', 0));
    });

    test('every urlFor carries the same long per-launch key', () {
      final a = Uri.parse(bridge.urlFor('cam'));
      final b = Uri.parse(bridge.urlFor('cam'));
      expect(a.queryParameters['k']!.length, greaterThanOrEqualTo(16));
      expect(a.queryParameters['k'], b.queryParameters['k']);
    });
  });
}

class _NeverOpened implements MediaSource {
  int opened = 0;
  @override
  Stream<Uint8List> openTs() {
    opened++;
    return const Stream.empty();
  }
}
