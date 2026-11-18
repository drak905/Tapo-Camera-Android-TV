// mb.local.preview_flow, mb.policy.staggered_start (handshake gate), mb.limits.per_camera
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/media/client_parts.dart';
import 'package:tapo_tv/media/local8800/local_ts_source.dart';
import 'package:tapo_tv/media/media_errors.dart';
import 'package:tapo_tv/media/stream_limiter.dart';

import 'helpers/crypto_fixtures.dart';
import 'helpers/fakes.dart';

void main() {
  late List<FakeCamera> cameras;
  late FakeConnector connector;
  late Stopwatch clock;

  void setUpCamera({int errorCode = 0, String? sessionId = '7', bool respond = true}) {
    cameras = [];
    clock = Stopwatch()..start();
    connector = FakeConnector(
      clock: () => clock.elapsed,
      onConnect: (t, i) => cameras.add(FakeCamera(t,
          keyExchange: kMd5KeyExchangeAdmin, errorCode: errorCode, sessionId: sessionId, respond: respond)),
    );
  }

  LocalTsSource source({
    String resolution = 'VGA',
    StreamLimiter? limiter,
    Future<void>? gate,
    String secret = 'cloudpass',
  }) =>
      LocalTsSource(
        host: kCameraHost,
        auth: FakeLocalAuth(digestSecret: secret),
        connector: connector.connect,
        resolution: resolution,
        limiter: limiter,
        startGate: gate,
      );

  test('preview request exact json', () async {
    setUpCamera();
    final c = Collector(source().openTs());
    await settle();
    cameras.single.video(tsPacket(), sequence: 1);
    await settle();
    final first = cameras.single.parts.first;
    expect(utf8.decode(first.body), previewRequestJson('VGA', seq: 1));
    expect(first.header('Content-Type'), 'application/json');
    expect(c.items, [tsPacket()]);
    await c.sub.cancel();
  });

  test('HD resolution is requested for fullscreen', () async {
    setUpCamera();
    final c = Collector(source(resolution: 'HD').openTs());
    await settle();
    expect(utf8.decode(cameras.single.parts.first.body), previewRequestJson('HD', seq: 1));
    await c.sub.cancel();
  });

  test('ack every 25th sequence only with session id', () async {
    setUpCamera();
    final c = Collector(source().openTs());
    await settle();
    for (var n = 1; n <= 30; n++) {
      cameras.single.video(tsPacket(n), sequence: n);
    }
    await settle();
    final acks = cameras.single.parts.where((p) => p.header('X-Data-Received') != null).toList();
    expect(acks, hasLength(1));
    expect(acks.single.header('X-Data-Received'), '25');
    expect(acks.single.header('X-Session-Id'), '7');
    expect(utf8.decode(acks.single.body), '{"type":"notification","params":{"event_type":"stream_sequence"}}');
    expect(c.items, hasLength(30));
    await c.sub.cancel();
  });

  test('no ack and no stop without a session id', () async {
    setUpCamera(sessionId: null);
    final c = Collector(source().openTs());
    await settle();
    for (var n = 1; n <= 26; n++) {
      cameras.single.video(tsPacket(n), sequence: n);
    }
    await settle();
    expect(cameras.single.parts.where((p) => p.header('X-Data-Received') != null), isEmpty);
    await c.sub.cancel();
    await settle();
    expect(cameras.single.requestsOf('do', 'stop'), isEmpty);
    expect(cameras.single.t.closed, isTrue);
  });

  test('stop sent then 150 ms linger before close', () async {
    setUpCamera();
    final c = Collector(source().openTs());
    await settle();
    cameras.single.video(tsPacket(), sequence: 1);
    await settle();
    await c.sub.cancel();
    final t = cameras.single.t;
    final stop = cameras.single.requestsOf('do', 'stop').single;
    expect(stop['params'], {'method': 'do', 'stop': 'null'});
    expect(stop['seq'], 2, reason: 'preview was seq 1');
    final lastWrite = t.events.lastWhere((e) => e.$1 == 'write').$2;
    final closeAt = t.events.firstWhere((e) => e.$1 == 'close').$2;
    expect(closeAt - lastWrite, greaterThanOrEqualTo(const Duration(milliseconds: 140)));
    expect(t.closeCount, greaterThanOrEqualTo(1));
  });

  test('limit error code is fatal no retry', () async {
    for (final code in [-52407, -52405, -52419, -52435]) {
      setUpCamera(errorCode: code);
      final c = Collector(source().openTs());
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(c.errors.single, isA<StreamLimitException>(), reason: '$code');
      expect(connector.calls, hasLength(1), reason: 'no retry for $code');
      expect(c.items, isEmpty);
    }
  });

  test('other non-zero error code is a refusal', () async {
    setUpCamera(errorCode: -40101);
    final c = Collector(source().openTs());
    await settle();
    expect(c.errors.single, isA<StreamRefusedException>().having((e) => e.errorCode, 'errorCode', -40101));
  });

  test('audio and json parts are not forwarded to the video stream', () async {
    setUpCamera();
    final c = Collector(source().openTs());
    await settle();
    final cam = cameras.single;
    cam.audio([1, 2, 3, 4]);
    cam.notify({'event_type': 'heartbeat'});
    cam.video(tsPacket(1), sequence: 1);
    cam.audio([5, 6]);
    cam.video(tsPacket(2), sequence: 2);
    await settle();
    expect(c.items, [tsPacket(1), tsPacket(2)]);
    await c.sub.cancel();
  });

  test('early media parts before response replayed in order', () async {
    setUpCamera(respond: false);
    final c = Collector(source().openTs());
    await settle();
    final cam = cameras.single;
    cam.video(tsPacket(1), sequence: 1);
    cam.video(tsPacket(2), sequence: 2);
    await settle();
    expect(c.items, isEmpty, reason: 'nothing is forwarded before the camera accepted the request');
    cam.t.push(jsonPart({
      'type': 'response',
      'seq': 1,
      'params': {'session_id': '7'},
      'result': {'error_code': 0},
    }));
    cam.video(tsPacket(3), sequence: 3);
    await settle();
    expect(c.items, [tsPacket(1), tsPacket(2), tsPacket(3)]);
    await c.sub.cancel();
  });

  test('digest handshake waits for the stream queue slot', () async {
    setUpCamera();
    final gate = Completer<void>();
    final c = Collector(source(gate: gate.future).openTs());
    await settle();
    expect(connector.calls, isEmpty, reason: 'no socket before the slot is granted');
    gate.complete();
    await settle();
    expect(connector.calls, hasLength(1));
    await c.sub.cancel();
  });

  test('limiter lease is taken before connecting and released at the end', () async {
    setUpCamera();
    final limiter = StreamLimiter();
    final a = Collector(source(limiter: limiter).openTs());
    final b = Collector(source(limiter: limiter).openTs());
    await settle();
    expect(limiter.active(kCameraHost), 2);
    final third = Collector(source(limiter: limiter).openTs());
    await settle();
    expect(third.errors.single, isA<StreamLimitException>());
    expect(connector.calls, hasLength(2), reason: 'the third source never opens a socket');
    await a.sub.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(limiter.active(kCameraHost), 1);
    await b.sub.cancel();
  });
}
