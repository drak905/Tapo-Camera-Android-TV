// mb.relay.session_flow, mb.tvbaseline.gaps (stop on close), mb.limits.per_camera (relay key = deviceId)
import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/media/client_parts.dart';
import 'package:tapo_tv/media/media_errors.dart';
import 'package:tapo_tv/media/relay/relay_ts_source.dart';
import 'package:tapo_tv/media/stream_limiter.dart';

import 'helpers/fakes.dart';
import 'helpers/pump.dart';

const _heartbeatPart = '----client-stream-boundary--\r\nContent-Type: application/json\r\nContent-Length: 63\r\n\r\n'
    '{"type": "notification", "params": {"event_type": "heartbeat"}}\r\n';

class _Rig {
  _Rig(FakeAsync async, {FakeCloudAuth? auth, int errorCode = 0, String? sessionId = '7', Future<void>? gate, StreamLimiter? limiter}) {
    cloud = auth ?? FakeCloudAuth();
    connector = FakeConnector(
      clock: () => async.elapsed,
      onConnect: (t, i) => cameras.add(FakeCamera(t, mode: CameraMode.relay, errorCode: errorCode, sessionId: sessionId)),
    );
    source = RelayTsSource(
      deviceId: 'DEV',
      auth: cloud,
      connector: connector.connect,
      startGate: gate,
      limiter: limiter,
    );
  }
  late FakeCloudAuth cloud;
  late FakeConnector connector;
  late RelayTsSource source;
  final List<FakeCamera> cameras = [];
}

void main() {
  test('preview request written first, after the tunnel head, with slot resolution', () {
    fakeAsync((async) {
      final r = _Rig(async);
      final c = Collector(r.source.openTs());
      pump(async);
      final cam = r.cameras.single;
      expect(r.connector.calls.single.tls, isTrue);
      expect(r.connector.calls.single.serverName, 'relay.example.com');
      expect(cam.heads.single, startsWith('POST /relayservice?deviceid=DEV&type=video&retryTime=0 HTTP/1.1'));
      expect(cam.heads.single, contains('X-token: RELAYTOKEN1'));
      expect(utf8.decode(cam.parts.first.body), previewRequestJson('VGA', seq: 1));
      expect(r.cloud.posts.single.body['resolution'], 'VGA');
      expect(r.cloud.posts.single.body['cloudType'], 2);
      c.sub.cancel();
      pump(async, 200);
    });
  });

  test('heartbeat bytes exact and interval 15 s (fake async)', () {
    fakeAsync((async) {
      final r = _Rig(async);
      final c = Collector(r.source.openTs());
      pump(async);
      final cam = r.cameras.single;
      List<ClientPart> beats() => cam.parts.where((p) => latin1.decode(p.body).contains('heartbeat')).toList();
      async.elapse(const Duration(seconds: 14));
      expect(beats(), isEmpty);
      async.elapse(const Duration(seconds: 1, milliseconds: 100));
      expect(beats(), hasLength(1));
      async.elapse(const Duration(seconds: 15));
      expect(beats(), hasLength(2));
      final written = latin1.decode(cam.t.written);
      expect(written, contains(_heartbeatPart));
      c.sub.cancel();
      pump(async, 200);
    });
  });

  test('video parts forwarded, json and audio are not', () {
    fakeAsync((async) {
      final r = _Rig(async);
      final c = Collector(r.source.openTs());
      pump(async);
      final cam = r.cameras.single;
      cam.audio([1, 2]);
      cam.notify({'event_type': 'heartbeat'});
      cam.video(tsPacket(1), sequence: 1);
      pump(async);
      expect(c.items, [tsPacket(1)]);
      c.sub.cancel();
      pump(async, 200);
    });
  });

  test('-1007 is fatal no reconnect', () {
    fakeAsync((async) {
      final r = _Rig(async, auth: FakeCloudAuth(replies: [FakeCloudAuth.error(-1007)]));
      final c = Collector(r.source.openTs());
      pump(async);
      async.elapse(const Duration(seconds: 60));
      expect(c.errors.single, isA<RelayException>().having((e) => e.fatal, 'fatal', isTrue).having((e) => e.code, 'code', -1007));
      expect(r.cloud.posts, hasLength(1));
      expect(r.connector.calls, isEmpty);
    });
  });

  test('camera refusal -52407 on the preview request is a fatal limit error', () {
    fakeAsync((async) {
      final r = _Rig(async, errorCode: -52407);
      final c = Collector(r.source.openTs());
      pump(async);
      async.elapse(const Duration(seconds: 30));
      expect(c.errors.single, isA<StreamLimitException>());
      expect(r.cloud.posts, hasLength(1), reason: 'no new slot after a limit error');
    });
  });

  test('encrypted part reports capture hint with header names only', () {
    fakeAsync((async) {
      final r = _Rig(async);
      final c = Collector(r.source.openTs());
      pump(async);
      r.cameras.single.video(tsPacket(), headers: [('X-If-Encrypt', '1'), ('X-Nonce', 'deadbeefvalue')]);
      pump(async);
      expect(
        c.errors.single,
        isA<EncryptedRelayMediaException>()
            .having((e) => e.headerNames, 'names', containsAll(['X-If-Encrypt', 'X-Nonce']))
            .having((e) => e.toString(), 'text', isNot(contains('deadbeefvalue'))),
      );
      expect(c.items, isEmpty, reason: 'ciphertext never reaches ExoPlayer');
    });
  });

  test('stop request sent on close with 150 ms linger', () {
    fakeAsync((async) {
      final r = _Rig(async);
      final c = Collector(r.source.openTs());
      pump(async);
      r.cameras.single.video(tsPacket(), sequence: 1);
      pump(async);
      c.sub.cancel();
      pump(async, 400);
      final t = r.cameras.single.t;
      final stop = r.cameras.single.requestsOf('do', 'stop').single;
      expect(stop['params'], {'method': 'do', 'stop': 'null'});
      final lastWrite = t.events.lastWhere((e) => e.$1 == 'write').$2;
      final closeAt = t.events.firstWhere((e) => e.$1 == 'close').$2;
      expect(closeAt - lastWrite, greaterThanOrEqualTo(const Duration(milliseconds: 150)));
    });
  });

  test('acks follow the LAN rule: every 25th sequence with session id', () {
    fakeAsync((async) {
      final r = _Rig(async);
      final c = Collector(r.source.openTs());
      pump(async);
      for (var n = 1; n <= 50; n++) {
        r.cameras.single.video(tsPacket(n), sequence: n);
      }
      pump(async);
      final acks = r.cameras.single.parts.where((p) => p.header('X-Data-Received') != null).toList();
      expect(acks.map((p) => p.header('X-Data-Received')), ['25', '50']);
      expect(acks.first.header('X-Session-Id'), '7');
      c.sub.cancel();
      pump(async, 200);
    });
  });

  test('slot request waits for the stream queue slot', () {
    fakeAsync((async) {
      final gate = Completer<void>();
      final r = _Rig(async, gate: gate.future);
      final c = Collector(r.source.openTs());
      pump(async);
      expect(r.cloud.posts, isEmpty);
      gate.complete();
      pump(async);
      expect(r.cloud.posts, hasLength(1));
      c.sub.cancel();
      pump(async, 200);
    });
  });

  test('relay streams use the cloud deviceId as limiter key and release it', () {
    fakeAsync((async) {
      final limiter = StreamLimiter();
      final r = _Rig(async, limiter: limiter);
      final c = Collector(r.source.openTs());
      pump(async);
      expect(limiter.active('DEV'), 1);
      c.sub.cancel();
      pump(async, 400);
      expect(limiter.active('DEV'), 0);
    });
  });
}
