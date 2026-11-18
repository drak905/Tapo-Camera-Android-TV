// vod.playback.end_of_recordings: finished, disk offline, tunnel close.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/vod_session.dart';
import 'package:tapo_tv/media/media_errors.dart';

import '../media/helpers/crypto_fixtures.dart';
import '../media/helpers/fakes.dart';
import '../media/helpers/pump.dart';

const dayStart = 1700000000;
const dayEnd = 1700086399;
const clipA = VodClipRange(1700000000, 1700000600);
const clipB = VodClipRange(1700003600, 1700004200);

class _Local {
  _Local(List<VodClipRange> clips) {
    connector = FakeConnector(
      onConnect: (t, i) => cameras.add(FakeCamera(t, keyExchange: kMd5KeyExchangeAdmin, sessionId: '9')),
    );
    session = VodSession.local(
      host: kCameraHost,
      localAuth: FakeLocalAuth(),
      connector: connector.connect,
      startUtc: dayStart,
      endUtc: dayEnd,
      clips: clips,
    );
  }
  late FakeConnector connector;
  late VodSession session;
  final List<FakeCamera> cameras = [];
  List<Object?> get playbackStarts => cameras
      .expand((c) => c.requestsOf('get', 'playback'))
      .map((q) => ((q['params'] as Map)['playback'] as Map)['start_time'])
      .toList();
}

class _Relay {
  _Relay(FakeAsync async, List<VodClipRange> clips) {
    connector = FakeConnector(
      clock: () => async.elapsed,
      onConnect: (t, i) => cameras.add(FakeCamera(t, mode: CameraMode.relay, sessionId: '9')),
    );
    session = VodSession.relay(
      deviceId: 'DEV',
      auth: cloud,
      connector: connector.connect,
      startUtc: dayStart,
      endUtc: dayEnd,
      clips: clips,
    );
  }
  final cloud = FakeCloudAuth();
  late FakeConnector connector;
  late VodSession session;
  final List<FakeCamera> cameras = [];
}

void main() {
  test('finished with later clip restarts there', () {
    fakeAsync((async) {
      final r = _Local([clipA, clipB]);
      final c = Collector(r.session.openTs());
      pump(async);
      r.session.reportPosition(1700000590);
      r.cameras.single.notify({'event_type': 'stream_status', 'status': 'finished'});
      pump(async, 400);
      expect(r.playbackStarts, ['1700000000', '1700003600'], reason: 'continues at the start of the next clip');
      expect(r.session.state, isNot(VodState.stopped));
      expect(r.session.endReason, isNull);
      c.sub.cancel();
      pump(async, 400);
    });
  });

  test('finished without later clip is end of recordings', () {
    fakeAsync((async) {
      final r = _Local([clipA, clipB]);
      final c = Collector(r.session.openTs());
      pump(async);
      r.session.reportPosition(1700004190);
      r.cameras.single.notify({'event_type': 'stream_status', 'status': 'finished'});
      pump(async, 400);
      expect(r.session.state, VodState.stopped);
      expect(r.session.endReason, kEndOfRecordings);
      expect(r.session.endReason, 'end of recordings');
      expect(r.playbackStarts, hasLength(1), reason: 'no further request');
      expect(c.done, isTrue);
    });
  });

  test('seek restarts after end of recordings', () {
    fakeAsync((async) {
      final r = _Local([clipA]);
      final c = Collector(r.session.openTs());
      pump(async);
      r.session.reportPosition(1700000599);
      r.cameras.single.notify({'event_type': 'stream_status', 'status': 'finished'});
      pump(async, 400);
      expect(r.session.state, VodState.stopped);
      r.session.seek(1700000100);
      pump(async, 400);
      expect(r.playbackStarts.last, '1700000100');
      expect(r.session.state, isNot(VodState.stopped));
      expect(r.session.endReason, isNull);
      c.sub.cancel();
      pump(async, 400);
    });
  });

  test('disk offline is fatal', () {
    fakeAsync((async) {
      final r = _Local([clipA]);
      final c = Collector(r.session.openTs());
      pump(async);
      r.cameras.single.notify({'event_type': 'disk_status', 'status': 'offline'});
      pump(async, 400);
      async.elapse(const Duration(seconds: 30));
      expect(r.session.state, VodState.failed);
      expect(r.session.failure, isA<SdCardOfflineException>());
      expect(c.errors.single, isA<SdCardOfflineException>());
      expect(r.connector.calls, hasLength(1), reason: 'no reconnect after a fatal condition');
    });
  });

  test('tunnel close near last clip end is end of recordings', () {
    fakeAsync((async) {
      final r = _Relay(async, [clipA, clipB]);
      final c = Collector(r.session.openTs());
      pump(async);
      r.session.reportPosition(1700004199); // within 1.5 s of the last clip end (1700004200)
      r.cameras.single.t.end();
      pump(async, 400);
      async.elapse(const Duration(seconds: 30));
      expect(r.session.state, VodState.stopped);
      expect(r.session.endReason, kEndOfRecordings);
      expect(r.cloud.posts, hasLength(1), reason: 'no new slot at the end of recordings');
      expect(c.done, isTrue);
    });
  });

  test('tunnel close in the middle of a clip reconnects with a new slot at the last position', () {
    fakeAsync((async) {
      final r = _Relay(async, [clipA, clipB]);
      final c = Collector(r.session.openTs());
      pump(async);
      r.session.reportPosition(1700000300);
      r.cameras.single.t.end();
      async.elapse(const Duration(seconds: 12));
      pump(async, 400);
      expect(r.cloud.posts, hasLength(2));
      final second = r.cameras[1].requestsOf('get', 'playback').single;
      expect(((second['params'] as Map)['playback'] as Map)['start_time'], '1700000300');
      expect(r.session.state, isNot(VodState.stopped));
      c.sub.cancel();
      pump(async, 400);
    });
  });
}
