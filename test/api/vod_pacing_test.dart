// vod.playback.timeline_position: VodSession paces forwarded parts by the PTS,
// tracks the recording position and holds the stream while paused.
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/vod_session.dart';
import 'package:tapo_tv/api/vod_timeline.dart';

import '../media/helpers/crypto_fixtures.dart';
import '../media/helpers/fakes.dart';
import '../media/helpers/pump.dart';
import 'vod_timeline_test.dart' show videoPacket;

const start = 1700000000;
const end = 1700086399;

class _Rig {
  _Rig(this.async, {List<VodClipRange> clips = const []}) {
    connector = FakeConnector(
      clock: () => async.elapsed,
      onConnect: (t, i) => cameras.add(FakeCamera(t, keyExchange: kMd5KeyExchangeAdmin, sessionId: '9')),
    );
    session = VodSession.local(
      host: kCameraHost,
      localAuth: FakeLocalAuth(),
      connector: connector.connect,
      startUtc: start,
      endUtc: end,
      clips: clips,
      monotonic: () => async.elapsed,
    );
    c = Collector(session.openTs());
    pump(async);
  }
  final FakeAsync async;
  late FakeConnector connector;
  late VodSession session;
  late Collector<Uint8List> c;
  final List<FakeCamera> cameras = [];
  FakeCamera get cam => cameras.last;

  /// One part carrying a video frame whose PTS is [seconds] of media time.
  void frame(double seconds, {int? sequence}) =>
      cam.video(videoPacket((seconds * kPtsClock).round()), sequence: sequence);

  void elapse(int ms) => async.elapse(Duration(milliseconds: ms));
}

void main() {
  test('1x: frames come out one media second apart, not as fast as they arrive', () {
    fakeAsync((async) {
      final r = _Rig(async);
      for (var s = 0; s < 4; s++) {
        r.frame(s.toDouble());
      }
      pump(async);
      expect(r.c.items, hasLength(1));
      r.elapse(1000);
      expect(r.c.items, hasLength(2));
      r.elapse(2000);
      expect(r.c.items, hasLength(4));
      r.c.sub.cancel();
      pump(async, 400);
    });
  });

  for (final (speed, gap) in [('2/1', 500), ('4/1', 250), ('8/1', 125)]) {
    test('$speed: a frame every $gap ms', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.session.setSpeed(speed);
        for (var s = 0; s < 4; s++) {
          r.frame(s.toDouble());
        }
        pump(async);
        expect(r.c.items, hasLength(1));
        r.elapse(gap - 40); // pump() already advanced 20 ms
        expect(r.c.items, hasLength(1));
        r.elapse(60);
        expect(r.c.items, hasLength(2));
        r.elapse(gap * 2);
        expect(r.c.items, hasLength(4));
        r.c.sub.cancel();
        pump(async, 400);
      });
    });
  }

  test('setSpeed takes effect on the frame being waited for', () {
    fakeAsync((async) {
      final r = _Rig(async);
      for (var s = 0; s < 6; s++) {
        r.frame(s.toDouble());
      }
      pump(async);
      r.elapse(300); // waiting for media second 1 (due at 1000 ms)
      r.session.setSpeed('8/1');
      pump(async);
      // rebased at the position of the waiting frame: it shows now, the next ones every 125 ms
      expect(r.c.items.length, 2);
      r.elapse(125 * 4 + 5);
      expect(r.c.items, hasLength(6));
      r.c.sub.cancel();
      pump(async, 400);
    });
  });

  test('pause holds forwarding and the position, resume continues without a burst', () {
    fakeAsync((async) {
      final r = _Rig(async);
      for (var s = 0; s < 6; s++) {
        r.frame(s.toDouble());
      }
      pump(async);
      r.elapse(1000);
      expect(r.c.items, hasLength(2));
      final pos = r.session.lastPositionUtc;
      r.session.pause();
      pump(async);
      r.elapse(30000);
      expect(r.c.items, hasLength(2));
      expect(r.session.lastPositionUtc, pos);
      expect(r.session.state, VodState.paused);
      r.session.resume();
      pump(async);
      expect(r.c.items, hasLength(3)); // the held frame is released at once
      r.elapse(900);
      expect(r.c.items, hasLength(3)); // then paced again
      r.elapse(200);
      expect(r.c.items, hasLength(4));
      r.c.sub.cancel();
      pump(async, 400);
    });
  });

  test('lastPositionUtc follows the PTS and positions emits it', () {
    fakeAsync((async) {
      final r = _Rig(async);
      final seen = <int>[];
      final sub = r.session.positions.listen(seen.add);
      for (var s = 0; s < 5; s++) {
        r.frame(s.toDouble());
      }
      pump(async);
      expect(r.session.lastPositionUtc, start);
      r.elapse(3000);
      expect(r.session.lastPositionUtc, start + 3);
      r.elapse(1000);
      expect(r.session.lastPositionUtc, start + 4);
      expect(seen, containsAllInOrder([start + 1, start + 2, start + 3, start + 4]));
      expect(seen, orderedEquals([...seen]..sort()));
      sub.cancel();
      r.c.sub.cancel();
      pump(async, 400);
    });
  });

  test('positions are rate limited to about 5 per second', () {
    fakeAsync((async) {
      final r = _Rig(async);
      final seen = <int>[];
      final sub = r.session.positions.listen(seen.add);
      r.session.setSpeed('8/1');
      for (var s = 0; s < 40; s++) {
        r.frame(s.toDouble());
      }
      pump(async);
      r.elapse(5100); // 40 media seconds at 8x
      expect(r.session.lastPositionUtc, start + 39);
      expect(seen.length, lessThanOrEqualTo(5 * 5 + 2));
      expect(seen.length, greaterThanOrEqualTo(15));
      sub.cancel();
      r.c.sub.cancel();
      pump(async, 400);
    });
  });

  test('a PTS jump moves the position to the next clip', () {
    fakeAsync((async) {
      final clips = [const VodClipRange(start, start + 60), const VodClipRange(start + 3600, start + 3660)];
      final r = _Rig(async, clips: clips);
      r.frame(100);
      r.frame(101);
      r.frame(5000); // new recording file
      pump(async);
      r.elapse(1000);
      r.elapse(100);
      expect(r.session.lastPositionUtc, start + 3600);
      r.c.sub.cancel();
      pump(async, 400);
    });
  });

  test('parts that are not aligned TS are paced by X-Data-PTS', () {
    fakeAsync((async) {
      final r = _Rig(async);
      for (var s = 0; s < 3; s++) {
        r.cam.video([1, 2, 3, 4, 5], headers: [('X-Data-PTS', '${s * kPtsClock}')]);
      }
      pump(async);
      expect(r.c.items, hasLength(1));
      r.elapse(1000);
      expect(r.c.items, hasLength(2));
      r.elapse(1000);
      expect(r.c.items, hasLength(3));
      expect(r.c.items.last, [1, 2, 3, 4, 5]);
      r.c.sub.cancel();
      pump(async, 400);
    });
  });

  test('order is kept and the queued tail plays out before the end of recordings', () {
    fakeAsync((async) {
      final r = _Rig(async);
      for (var s = 0; s < 3; s++) {
        r.frame(s.toDouble());
      }
      r.cam.notify({'event_type': 'stream_status', 'status': 'finished'});
      pump(async);
      expect(r.c.done, isFalse);
      expect(r.session.state, isNot(VodState.stopped));
      r.elapse(2100);
      expect(r.c.items, hasLength(3));
      for (var i = 0; i < 3; i++) {
        expect(r.c.items[i], videoPacket(i * kPtsClock));
      }
      expect(r.session.endReason, kEndOfRecordings);
      expect(r.session.state, VodState.stopped);
      expect(r.c.done, isTrue);
    });
  });

  test('acks are sent when a part is forwarded, not when it arrives', () {
    fakeAsync((async) {
      final r = _Rig(async);
      for (var n = 1; n <= 30; n++) {
        r.frame(n.toDouble() - 1, sequence: n);
      }
      pump(async);
      int acks() => r.cam.parts.where((p) => p.header('X-Data-Received') != null).length;
      expect(acks(), 0);
      r.elapse(23000);
      expect(acks(), 0); // part 25 is shown at 24 s
      r.elapse(2000);
      expect(acks(), 1);
      r.c.sub.cancel();
      pump(async, 400);
    });
  });

  test('reportPosition keeps working', () {
    fakeAsync((async) {
      final r = _Rig(async);
      r.session.reportPosition(start + 42);
      expect(r.session.lastPositionUtc, start + 42);
      r.c.sub.cancel();
      pump(async, 400);
    });
  });

  test('seek rebases position and pacing', () {
    fakeAsync((async) {
      final r = _Rig(async);
      for (var s = 0; s < 3; s++) {
        r.frame(s.toDouble());
      }
      pump(async);
      r.session.seek(start + 1000);
      expect(r.session.lastPositionUtc, start + 1000);
      pump(async, 50);
      r.elapse(1000);
      expect(r.cameras.length, greaterThanOrEqualTo(2));
      r.frame(7000);
      pump(async);
      expect(r.c.items.last, videoPacket(7000 * kPtsClock));
      r.c.sub.cancel();
      pump(async, 400);
    });
  });
}
