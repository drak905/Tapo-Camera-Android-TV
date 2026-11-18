// vod.playback.timeline_position: PTS timeline, splitter and pacer (pure logic).
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/vod_timeline.dart';

const _t0 = 1700000000.0;

/// One aligned TS packet starting a video PES with [pts] (90 kHz) on [pid].
Uint8List videoPacket(int pts, {int pid = 0x100, int streamId = 0xE0}) {
  final p = Uint8List(188)..fillRange(0, 188, 0xFF);
  p[0] = 0x47;
  p[1] = 0x40 | (pid >> 8);
  p[2] = pid & 0xFF;
  p[3] = 0x10;
  p.setAll(4, [0, 0, 1, streamId, 0, 0, 0x80, 0x80, 5]);
  p[13] = 0x21 | (((pts >> 30) & 7) << 1);
  p[14] = (pts >> 22) & 0xFF;
  p[15] = (((pts >> 15) & 0x7F) << 1) | 1;
  p[16] = (pts >> 7) & 0xFF;
  p[17] = ((pts & 0x7F) << 1) | 1;
  return p;
}

/// A continuation packet (no payload unit start) on [pid].
Uint8List contPacket({int pid = 0x100}) {
  final p = Uint8List(188)..fillRange(0, 188, 0x11);
  p[0] = 0x47;
  p[1] = pid >> 8;
  p[2] = pid & 0xFF;
  p[3] = 0x10;
  return p;
}

Uint8List cat(List<Uint8List> parts) => Uint8List.fromList([for (final p in parts) ...p]);

int sec(double s) => (s * kPtsClock).round();

void main() {
  group('normalizeSegments', () {
    test('normalizeSegments merges within 0.5 s and drops inverted', () {
      final out = normalizeSegments([(300, 400), (100, 200), (200.4, 250), (500, 500), (600, 550), (400.5, 410)]);
      expect(out, [(100.0, 250.0), (300.0, 410.0)]);
    });
    test('null and empty input give an empty list', () {
      expect(normalizeSegments(null), isEmpty);
      expect(normalizeSegments(const []), isEmpty);
    });
    test('overlapping clips keep the larger end', () {
      expect(normalizeSegments([(0, 100), (10, 20)]), [(0.0, 100.0)]);
    });
  });

  group('PtsTimeline', () {
    final segs = normalizeSegments([(_t0, _t0 + 60), (_t0 + 600, _t0 + 660)]);

    test('snap to next clip start in gap', () {
      expect(PtsTimeline.snap(_t0 + 100, segs), _t0 + 600);
      expect(PtsTimeline.snap(_t0 + 30, segs), _t0 + 30);
      expect(PtsTimeline.snap(_t0 - 50, segs), _t0);
      expect(PtsTimeline.snap(_t0 + 9999, segs), _t0 + 9999);
      expect(PtsTimeline(segs, _t0 + 100).position, _t0 + 600);
    });

    test('PTS step <=3 s advances position', () {
      final t = PtsTimeline(segs, _t0);
      expect(t.advance(sec(10)), isTrue); // first frame anchors
      expect(t.position, _t0);
      expect(t.advance(sec(11)), isFalse);
      expect(t.advance(sec(13)), isFalse);
      expect(t.position, closeTo(_t0 + 3, 1e-6));
      expect(t.advance(sec(16.0)), isFalse); // exactly 3 s
      expect(t.position, closeTo(_t0 + 6, 1e-6));
    });

    test('PTS jump moves to next clip', () {
      final t = PtsTimeline(segs, _t0)..advance(sec(10));
      expect(t.advance(sec(10.04)), isFalse);
      expect(t.advance(sec(500)), isTrue); // forward jump
      expect(t.position, _t0 + 600);
      final b = PtsTimeline(segs, _t0 + 10)..advance(sec(10));
      expect(b.advance(sec(2)), isTrue); // backwards step = new file
      expect(b.position, _t0 + 600);
    });

    test('running past the clip end + 1.5 s moves to the next clip', () {
      final t = PtsTimeline(segs, _t0 + 58)..advance(sec(0));
      for (var s = 1; s <= 3; s++) {
        expect(t.advance(sec(s.toDouble())), isFalse);
      }
      expect(t.position, closeTo(_t0 + 61, 1e-6)); // still within end + 1.5 s
      expect(t.advance(sec(4)), isTrue); // 62 > 61.5: jump into the next clip
      expect(t.position, closeTo(_t0 + 600.5, 1e-6));
    });

    test('33-bit PTS wrap', () {
      final t = PtsTimeline(segs, _t0)..advance((1 << 33) - sec(1));
      expect(t.advance(sec(1)), isFalse); // wrapped, +2 s
      expect(t.position, closeTo(_t0 + 2, 1e-6));
    });

    test('without a clip list a step below 86400 s advances, bigger does not', () {
      final t = PtsTimeline(const [], _t0)..advance(0);
      expect(t.advance(sec(100)), isTrue);
      expect(t.position, closeTo(_t0 + 100, 1e-6));
      expect(t.advance(sec(100 + 90000)), isTrue);
      expect(t.position, closeTo(_t0 + 100, 1e-6));
    });

    test('nextStart finds the clip after the current one', () {
      final t = PtsTimeline(segs, _t0);
      expect(t.nextStart(_t0 + 10), _t0 + 600);
      expect(t.nextStart(_t0 + 300), _t0 + 600);
      expect(t.nextStart(_t0 + 640), isNull);
    });
  });

  group('VideoSplitter', () {
    test('splits at video PES starts and learns the video PID', () {
      final s = VideoSplitter();
      final data = cat([contPacket(), videoPacket(1000), contPacket(), contPacket(), videoPacket(4000)]);
      final pieces = s.split(data)!;
      expect(pieces.map((p) => p.pts), [null, 1000, 4000]);
      expect(pieces.map((p) => p.data.length), [188, 188 * 3, 188]);
      expect(s.videoPid, 0x100);
    });

    test('other PIDs and non-video stream ids are ignored once known', () {
      final s = VideoSplitter();
      s.split(videoPacket(90));
      final pieces = s.split(cat([videoPacket(100, pid: 0x101), videoPacket(200, streamId: 0xC0), videoPacket(300)]))!;
      expect(pieces.map((p) => p.pts), [null, 300]);
    });

    test('unaligned data is not TS', () {
      expect(VideoSplitter().split(Uint8List(100)), isNull);
      expect(VideoSplitter().split(Uint8List(0)), isNull);
      expect(VideoSplitter().split(Uint8List(188)), isNull); // no sync byte
    });

    test('chunk without PES start is one piece with no pts', () {
      final pieces = VideoSplitter().split(cat([contPacket(), contPacket()]))!;
      expect(pieces.single.pts, isNull);
    });
  });

  group('Pacer', () {
    // Frames every second of media time; returns the wall seconds each is released.
    List<double> run(FakeAsync async, Pacer pacer, double speed, int frames) {
      final out = <double>[];
      pacer.rebase(0, speed, async.elapsed);
      for (var m = 0; m < frames; m++) {
        final w = pacer.wait(m.toDouble(), async.elapsed);
        async.elapse(w);
        out.add(async.elapsed.inMicroseconds / 1e6);
      }
      return out;
    }

    for (final (speed, gap) in [(1.0, 1.0), (2.0, 0.5), (4.0, 0.25), (8.0, 0.125)]) {
      test('${speed.toInt()}x releases a media second every $gap s', () {
        fakeAsync((async) {
          final w = run(async, Pacer(), speed, 5);
          expect(w, [for (var i = 0; i < 5; i++) closeTo(i * gap, 1e-6)]);
        });
      });
    }

    test('pause/resume rebase: no burst after a pause', () {
      fakeAsync((async) {
        final p = Pacer()..rebase(0, 1, async.elapsed);
        async.elapse(const Duration(seconds: 1));
        expect(p.wait(1, async.elapsed), Duration.zero);
        async.elapse(const Duration(seconds: 30)); // paused
        p.rebase(2, 1, async.elapsed); // resume at media 2
        expect(p.wait(2, async.elapsed), Duration.zero);
        expect(p.wait(3, async.elapsed), const Duration(seconds: 1));
      });
    });

    test('speed change rebases at the current media time', () {
      fakeAsync((async) {
        final p = Pacer()..rebase(0, 1, async.elapsed);
        async.elapse(const Duration(seconds: 2));
        p.rebase(2, 4, async.elapsed);
        expect(p.wait(3, async.elapsed), const Duration(milliseconds: 250));
      });
    });

    test('more than 1 s late restarts the clock instead of racing', () {
      fakeAsync((async) {
        final p = Pacer()..rebase(0, 1, async.elapsed);
        async.elapse(const Duration(seconds: 5));
        expect(p.wait(1, async.elapsed), Duration.zero); // rebased at media 1
        expect(p.wait(2, async.elapsed), const Duration(seconds: 1));
      });
    });
  });
}
