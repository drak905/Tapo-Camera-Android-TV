// vod.playback.request, vod.playback.local8800: SD playback over :8800.
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/vod_session.dart';
import 'package:tapo_tv/media/client_parts.dart';
import 'package:tapo_tv/media/media_errors.dart';
import 'package:tapo_tv/media/stream_limiter.dart';

import '../media/helpers/crypto_fixtures.dart';
import '../media/helpers/fakes.dart';
import '../media/helpers/pump.dart';

const start = 1700000000;
const end = 1700086399;

class _Rig {
  _Rig({int errorCode = 0, String sessionId = '9'}) {
    connector = FakeConnector(
      onConnect: (t, i) => cameras
          .add(FakeCamera(t, keyExchange: kMd5KeyExchangeAdmin, errorCode: errorCode, sessionId: sessionId)),
    );
    session = VodSession.local(
      host: kCameraHost,
      localAuth: FakeLocalAuth(),
      connector: connector.connect,
      startUtc: start,
      endUtc: end,
    );
  }
  late FakeConnector connector;
  late VodSession session;
  final List<FakeCamera> cameras = [];

  Iterable<Map<String, dynamic>> get playbackRequests => cameras.expand((c) => c.requestsOf('get', 'playback'));
}

void main() {
  test('range playback request exact json after the digest handshake', () async {
    final r = _Rig();
    final c = Collector(r.session.openTs());
    await settle();
    final cam = r.cameras.single;
    expect(cam.heads.first, startsWith('POST /stream HTTP/1.1'));
    expect(utf8.decode(cam.parts.first.body), playbackRequestJson(start, end, seq: 1));
    final req = jsonDecode(utf8.decode(cam.parts.first.body)) as Map<String, dynamic>;
    expect(req['params'], {
      'method': 'get',
      'playback': {
        'client_id': 1,
        'channels': [0],
        'scale': '1/1',
        'start_time': '1700000000',
        'end_time': '1700086399',
        'event_type': [1, 2],
      },
    });
    await c.sub.cancel();
  });

  test('only video parts are forwarded to the player', () async {
    final r = _Rig();
    final c = Collector(r.session.openTs());
    await settle();
    r.cameras.single.notify({'event_type': 'playback_switch_next'});
    r.cameras.single.video(tsPacket(1), sequence: 1);
    r.cameras.single.audio([1, 2]);
    await settle();
    expect(c.items, [tsPacket(1)]);
    expect(r.session.state, VodState.playing);
    await c.sub.cancel();
  });

  test('ack part bytes', () async {
    final r = _Rig(sessionId: '9');
    final c = Collector(r.session.openTs());
    await settle();
    for (var n = 1; n <= 25; n++) {
      r.cameras.single.video(tsPacket(n), sequence: n);
    }
    await settle();
    final written = latin1.decode(r.cameras.single.t.written);
    expect(
      written,
      contains('----client-stream-boundary--\r\nX-Data-Received: 25\r\nX-Session-Id: 9\r\nContent-Type: application/json\r\n'
          'Content-Length: 65\r\n\r\n{"type":"notification","params":{"event_type":"stream_sequence"}}\r\n'),
    );
    await c.sub.cancel();
  });

  test('acks every 25 parts', () async {
    final r = _Rig();
    final c = Collector(r.session.openTs());
    await settle();
    for (var n = 1; n <= 75; n++) {
      r.cameras.single.video(tsPacket(n), sequence: n);
    }
    await settle();
    final acks = r.cameras.single.parts.where((p) => p.header('X-Data-Received') != null);
    expect(acks.map((p) => p.header('X-Data-Received')), ['25', '50', '75']);
    await c.sub.cancel();
  });

  test('refused playback is fatal with error code', () async {
    final r = _Rig(errorCode: -40101);
    final c = Collector(r.session.openTs());
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(c.errors.single, isA<PlaybackRefusedException>().having((e) => e.errorCode, 'errorCode', -40101));
    expect(r.session.state, VodState.failed);
    expect(r.session.failure, isA<PlaybackRefusedException>());
    expect(r.connector.calls, hasLength(1), reason: 'no retry loop against the camera');
  });

  test('reconnect resumes at last position', () {
    fakeAsync((async) {
      final r = _Rig();
      final c = Collector(r.session.openTs());
      pump(async);
      r.cameras.single.video(tsPacket(1), sequence: 1);
      pump(async);
      r.session.reportPosition(1700001234);
      expect(r.session.lastPositionUtc, 1700001234);
      r.cameras.single.t.end(); // connection lost
      async.elapse(const Duration(seconds: 12));
      pump(async);
      expect(r.connector.calls, hasLength(2));
      final starts = r.playbackRequests
          .map((q) => ((q['params'] as Map)['playback'] as Map)['start_time'])
          .toList();
      expect(starts, ['1700000000', '1700001234']);
      expect(r.session.state, isNot(VodState.failed));
      c.sub.cancel();
      pump(async, 400);
    });
  });

  test('playback shares the per camera limiter with live view', () async {
    final limiter = StreamLimiter();
    await limiter.acquire(kCameraHost); // two live tiles of the same camera
    await limiter.acquire(kCameraHost);
    final connector = FakeConnector();
    final session = VodSession.local(
      host: kCameraHost,
      localAuth: FakeLocalAuth(),
      connector: connector.connect,
      startUtc: start,
      endUtc: end,
      limiter: limiter,
    );
    final c = Collector(session.openTs());
    await settle();
    expect(c.errors.single, isA<StreamLimitException>());
    expect(connector.calls, isEmpty);
  });
}
