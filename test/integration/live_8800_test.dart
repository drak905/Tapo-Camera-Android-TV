// Tier 2, scenario 6: live view over the local :8800 media port. Real
// LocalTsSource (digest handshake, key exchange, part decryption, acks, stop)
// against MockMedia8800 over real loopback sockets.
//
// Tag adguard-tls: when HTTP-inspecting software on the PC breaks plain :8800
// multipart traffic, the mock runs inside TLS and the test connector wraps the
// socket in TLS (support/net.dart). Protocol bytes above that are identical.
// Specs: mb.local.*, mb.limits.per_camera, mb.crypto.*.
@Tags(['adguard-tls'])
@Timeout(Duration(seconds: 90))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/media/local8800/local_ts_source.dart';
import 'package:tapo_tv/media/media_deps.dart';
import 'package:tapo_tv/media/media_errors.dart';
import 'package:tapo_tv/media/stream_limiter.dart';

import '../fixtures/mock_camera.dart';
import '../fixtures/mock_media8800.dart';
import 'support/net.dart';

class _Auth implements LocalMediaAuth {
  _Auth(this.digestSecret);
  @override
  final String digestSecret;
  @override
  String get username => 'admin';
}

LocalTsSource _source(
  MockMedia8800 m,
  TestConnector c, {
  String secret = 'cloudpass',
  String resolution = 'VGA',
  StreamLimiter? limiter,
}) =>
    LocalTsSource(
      host: '127.0.0.1',
      port: m.port,
      auth: _Auth(secret),
      connector: c.call,
      resolution: resolution,
      limiter: limiter,
      stopLinger: const Duration(milliseconds: 50),
    );

/// Bytes worth `parts` mock chunks.
int _parts(MockMedia8800 m, int parts) => m.chunkSize * parts;

void main() {
  group('live :8800', () {
    test('MD5 key exchange: digest handshake, preview request, plain TS from the first byte', () async {
      final m = MockMedia8800(kex: MediaKex.md5, previewInterval: const Duration(milliseconds: 1));
      final c = await startMedia8800(m);

      final bytes = await collect(_source(m, c).openTs(), minBytes: _parts(m, 20));

      expectTsPackets(bytes, minPackets: 600);
      expectSamplePrefix(bytes, m.ts);
      expect(m.challenges, 1);
      expect(m.authFailures, 0);
      expect(m.authorizationLog, hasLength(1));
      expect(m.previewRequests, 1);
      expect(
        m.requestLog.any((r) => jsonEncode(r.body ?? const {}).contains('"resolutions":["VGA"]')),
        isTrue,
        reason: 'VGA was asked for the tile',
      );
    });

    test('HD is requested for fullscreen', () async {
      final m = MockMedia8800(previewInterval: const Duration(milliseconds: 1));
      final c = await startMedia8800(m);
      await collect(_source(m, c, resolution: 'HD').openTs(), minBytes: _parts(m, 4));
      expect(m.requestLog.any((r) => jsonEncode(r.body ?? const {}).contains('"resolutions":["HD"]')), isTrue);
    });

    test('HKDF key exchange: parts are decrypted and verified', () async {
      final m = MockMedia8800(kex: MediaKex.hkdf, previewInterval: const Duration(milliseconds: 1));
      final c = await startMedia8800(m);

      final bytes = await collect(_source(m, c).openTs(), minBytes: _parts(m, 20));

      expectTsPackets(bytes, minPackets: 600);
      expectSamplePrefix(bytes, m.ts);
    });

    test('HKDF: a part with a bad HMAC is dropped, never forwarded, and the stream goes on', () async {
      final m = MockMedia8800(
        kex: MediaKex.hkdf,
        corruptHmacEvery: 4,
        previewInterval: const Duration(milliseconds: 1),
      );
      final c = await startMedia8800(m);

      final bytes = await collect(_source(m, c).openTs(), minBytes: _parts(m, 30));

      expectTsPackets(bytes, minPackets: 600);
      expect(bytes.length % 188, 0, reason: 'only whole 188-byte packets reach the player');
      expect(bytes.length, lessThanOrEqualTo((m.partsSent * 3 / 4 + 2).ceil() * m.chunkSize),
          reason: 'every 4th part was corrupt and must be missing');
    });

    test('acks keep the camera sending beyond its un-acked window; stop request arrives before close', () async {
      final m = MockMedia8800(ackWindow: 50, previewInterval: const Duration(milliseconds: 1));
      final c = await startMedia8800(m);
      final source = _source(m, c);

      await collect(source.openTs(), minBytes: _parts(m, 130));

      expect(m.partsSent, greaterThan(60), reason: 'camera stalls at 50 parts without acks');
      expect(m.acks, isNotEmpty);
      expect(m.acks.every((a) => a > 0), isTrue);
      expect(source.sessionId, isNotNull);
      expect(await eventually(() => m.stopRequests == 1), isTrue, reason: 'client must send do/stop');
      expect(await eventually(() => m.activeSessions == 0), isTrue, reason: 'socket closed after stop');
    });

    test('legacy digest (no encrypt_type, MD5U password) and SHA-256 digest both work', () async {
      final legacy = MockMedia8800(encryptType3: false, previewInterval: const Duration(milliseconds: 1));
      final c1 = await startMedia8800(legacy);
      expectTsPackets(await collect(_source(legacy, c1).openTs(), minBytes: _parts(legacy, 4)));

      final sha = MockMedia8800(digestAlgorithm: 'SHA-256', previewInterval: const Duration(milliseconds: 1));
      final c2 = await startMedia8800(sha);
      expectTsPackets(await collect(_source(sha, c2).openTs(), minBytes: _parts(sha, 4)));
    });

    test('LAT mode: the local access token is the digest secret', () async {
      final cam = MockCamera(
        protocol: CameraProtocol.tpap,
        tpapCredential: TpapCredential.lat,
        localToken: 'LAT-0123456789abcdef',
      );
      final m = MockMedia8800.forCamera(cam, kex: MediaKex.hkdf)..previewInterval = const Duration(milliseconds: 1);
      final c = await startMedia8800(m);
      final bytes = await collect(_source(m, c, secret: 'LAT-0123456789abcdef').openTs(), minBytes: _parts(m, 4));
      expectTsPackets(bytes);
    });

    test('wrong password: MediaAuthException, no retry loop', () async {
      final m = MockMedia8800();
      final c = await startMedia8800(m);

      final error = await firstError(_source(m, c, secret: 'WRONG').openTs());

      expect(error, isA<MediaAuthException>());
      final failures = m.authFailures;
      expect(failures, inInclusiveRange(1, 2));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(m.authFailures, failures);
      expect(m.activeSessions, 0);
    });

    test('2 sessions per camera: the third is refused with a fatal limit error and is not retried', () async {
      final m = MockMedia8800(previewInterval: const Duration(milliseconds: 5));
      final c = await startMedia8800(m);
      final subs = <StreamSubscription<Uint8List>>[];
      addTearDown(() async {
        for (final s in subs) {
          await s.cancel();
        }
      });
      for (var i = 0; i < 2; i++) {
        subs.add(_source(m, c).openTs().listen((_) {}, onError: (Object _) {}));
      }
      expect(await eventually(() => m.activeSessions == 2, timeout: const Duration(seconds: 6)), isTrue);

      final error = await firstError(_source(m, c).openTs());

      expect(error, isA<StreamLimitException>().having((e) => e.errorCode, 'errorCode', -52407));
      expect(m.limitRejections, 1);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(m.limitRejections, 1, reason: 'limit errors are fatal: no retry loop');
      expect(m.activeSessions, 2);
    });

    test('a StreamLimiter shared by live sources refuses the third before any socket is opened', () async {
      final m = MockMedia8800(previewInterval: const Duration(milliseconds: 5));
      final c = await startMedia8800(m);
      final limiter = StreamLimiter();
      final subs = <StreamSubscription<Uint8List>>[];
      addTearDown(() async {
        for (final s in subs) {
          await s.cancel();
        }
      });
      for (var i = 0; i < 2; i++) {
        subs.add(_source(m, c, limiter: limiter).openTs().listen((_) {}, onError: (Object _) {}));
      }
      expect(await eventually(() => m.activeSessions == 2, timeout: const Duration(seconds: 6)), isTrue);
      final opened = c.opened;

      final error = await firstError(_source(m, c, limiter: limiter).openTs());

      expect(error, isA<StreamLimitException>());
      expect(c.opened, opened, reason: 'no new connection for the refused stream');
      expect(limiter.active('127.0.0.1'), 2);

      await subs.removeAt(0).cancel();
      expect(await eventually(() => limiter.active('127.0.0.1') == 1), isTrue, reason: 'lease released on cancel');
    });

    test('the camera dropping the connection ends the stream (no hang)', () async {
      final m = MockMedia8800(previewInterval: const Duration(milliseconds: 5));
      final c = await startMedia8800(m);
      Timer(const Duration(milliseconds: 500), m.dropConnections);
      try {
        await collect(_source(m, c).openTs(), minBytes: 1 << 30, timeout: const Duration(seconds: 8));
      } on MediaException {
        // an error is as valid as a clean end
      }
    });
  });
}
