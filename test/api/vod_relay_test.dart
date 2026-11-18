// vod.playback.relay: SD playback through the cloud relay.
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/vod_session.dart';
import 'package:tapo_tv/media/client_parts.dart';

import '../media/helpers/fakes.dart';
import '../media/helpers/pump.dart';

const start = 1700000000;
const end = 1700086399;

class _Rig {
  _Rig(FakeAsync async) {
    connector = FakeConnector(
      clock: () => async.elapsed,
      onConnect: (t, i) => cameras.add(FakeCamera(t, mode: CameraMode.relay, sessionId: '9')),
    );
    session = VodSession.relay(
      deviceId: 'DEV',
      auth: cloud,
      connector: connector.connect,
      startUtc: start,
      endUtc: end,
    );
  }
  final cloud = FakeCloudAuth();
  late FakeConnector connector;
  late VodSession session;
  final List<FakeCamera> cameras = [];
}

void main() {
  test('slot request uses streamType 1 and cloudType 2', () {
    fakeAsync((async) {
      final r = _Rig(async);
      final c = Collector(r.session.openTs());
      pump(async);
      final body = r.cloud.posts.single.body;
      expect(body['streamType'], 1);
      expect(body['cloudType'], 2);
      expect(body['channelId'], '0');
      expect(body['customParams'], '{}');
      c.sub.cancel();
      pump(async, 400);
    });
  });

  test('playback request json is the first part, with no inner POST /stream', () {
    fakeAsync((async) {
      final r = _Rig(async);
      final c = Collector(r.session.openTs());
      pump(async);
      final cam = r.cameras.single;
      expect(cam.heads, hasLength(1));
      expect(cam.heads.single, startsWith('POST /relayservice'));
      expect(utf8.decode(cam.parts.first.body), playbackRequestJson(start, end, seq: 1));
      c.sub.cancel();
      pump(async, 400);
    });
  });

  test('video parts reach the player, acks every 25 parts', () {
    fakeAsync((async) {
      final r = _Rig(async);
      final c = Collector(r.session.openTs());
      pump(async);
      for (var n = 1; n <= 50; n++) {
        r.cameras.single.video(tsPacket(n), sequence: n);
      }
      pump(async);
      expect(c.items, hasLength(50));
      final acks = r.cameras.single.parts.where((p) => p.header('X-Data-Received') != null);
      expect(acks.map((p) => p.header('X-Data-Received')), ['25', '50']);
      c.sub.cancel();
      pump(async, 400);
    });
  });

  test('seek takes a new slot', () {
    fakeAsync((async) {
      final r = _Rig(async);
      final c = Collector(r.session.openTs());
      pump(async);
      r.session.seek(1700003600);
      pump(async, 400);
      expect(r.cloud.posts, hasLength(2), reason: 'relayToken is single use: every seek needs a new slot');
      expect(r.cameras, hasLength(2));
      final second = r.cameras[1].requestsOf('get', 'playback').single;
      expect(((second['params'] as Map)['playback'] as Map)['start_time'], '1700003600');
      expect(r.cameras[0].t.closed, isTrue, reason: 'the old tunnel is closed');
      c.sub.cancel();
      pump(async, 400);
    });
  });

  test('heartbeat every 15 s', () {
    fakeAsync((async) {
      final r = _Rig(async);
      final c = Collector(r.session.openTs());
      pump(async);
      int beats() => latin1.decode(r.cameras.single.t.written).split('"event_type": "heartbeat"').length - 1;
      async.elapse(const Duration(seconds: 14));
      expect(beats(), 0);
      async.elapse(const Duration(seconds: 1, milliseconds: 100));
      expect(beats(), 1);
      async.elapse(const Duration(seconds: 15));
      expect(beats(), 2);
      c.sub.cancel();
      pump(async, 400);
    });
  });

  test('stop request json on stop', () {
    fakeAsync((async) {
      final r = _Rig(async);
      final c = Collector(r.session.openTs());
      pump(async);
      r.session.stop();
      pump(async, 400);
      final stop = r.cameras.single.requestsOf('do', 'stop').single;
      expect(stop['params'], {'method': 'do', 'stop': 'null'});
      expect(r.cameras.single.t.closed, isTrue);
      expect(c.done, isTrue);
    });
  });
}
