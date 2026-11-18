// vod.playback.controls: pause, resume, seek, speed.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/vod_session.dart';

import '../media/helpers/crypto_fixtures.dart';
import '../media/helpers/fakes.dart';
import '../media/helpers/pump.dart';

const start = 1700000000;
const end = 1700086399;

class _Rig {
  _Rig() {
    connector = FakeConnector(
      onConnect: (t, i) => cameras.add(FakeCamera(t, keyExchange: kMd5KeyExchangeAdmin, sessionId: '9')),
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
  test('pause and resume request json', () {
    fakeAsync((async) {
      final r = _Rig();
      final c = Collector(r.session.openTs());
      pump(async);
      r.session.pause();
      pump(async);
      r.session.resume();
      pump(async);
      final cam = r.cameras.single;
      final pause = cam.requestsOf('do', 'pause').single;
      final play = cam.requestsOf('do', 'play').single;
      expect(pause['type'], 'request');
      expect(pause['params'], {'method': 'do', 'pause': 'null'});
      expect(play['params'], {'method': 'do', 'play': 'null'});
      expect(pause['seq'], lessThan(play['seq'] as int));
      c.sub.cancel();
      pump(async, 400);
    });
  });

  test('state follows pause and resume', () {
    fakeAsync((async) {
      final r = _Rig();
      final c = Collector(r.session.openTs());
      pump(async);
      expect(r.session.state, VodState.playing);
      r.session.pause();
      pump(async);
      expect(r.session.state, VodState.paused);
      r.session.resume();
      pump(async);
      expect(r.session.state, VodState.playing);
      c.sub.cancel();
      pump(async, 400);
    });
  });

  test('seek issues a new range request and resumes', () {
    fakeAsync((async) {
      final r = _Rig();
      final c = Collector(r.session.openTs());
      pump(async);
      r.session.pause();
      pump(async);
      r.session.seek(1700040000);
      pump(async, 400);
      final starts = r.playbackRequests.map((q) => ((q['params'] as Map)['playback'] as Map)['start_time']).toList();
      expect(starts, ['1700000000', '1700040000']);
      expect(((r.playbackRequests.last['params'] as Map)['playback'] as Map)['scale'], '1/1');
      expect(r.session.state, VodState.playing, reason: 'seek also resumes a paused playback');
      c.sub.cancel();
      pump(async, 400);
    });
  });

  test('unsupported speed raises', () {
    final r = _Rig();
    expect(() => r.session.setSpeed('3/1'), throwsArgumentError);
    expect(() => r.session.setSpeed('16/1'), throwsArgumentError);
    expect(() => paceInterval(const Duration(milliseconds: 40), '0/1'), throwsArgumentError);
  });

  test('supported speeds are 1/1 2/1 4/1 8/1', () {
    expect(kVodSpeeds, ['1/1', '2/1', '4/1', '8/1']);
    final r = _Rig();
    for (final s in kVodSpeeds) {
      r.session.setSpeed(s);
      expect(r.session.speed, s);
    }
  });

  test('the request always asks 1/1, speed is client side', () {
    fakeAsync((async) {
      final r = _Rig();
      final c = Collector(r.session.openTs());
      pump(async);
      r.session.setSpeed('4/1');
      r.session.seek(1700001000);
      pump(async, 400);
      for (final q in r.playbackRequests) {
        expect(((q['params'] as Map)['playback'] as Map)['scale'], '1/1');
      }
      c.sub.cancel();
      pump(async, 400);
    });
  });

  test('2x pace halves frame interval', () {
    const base = Duration(milliseconds: 40);
    expect(paceInterval(base, '1/1'), base);
    expect(paceInterval(base, '2/1'), const Duration(milliseconds: 20));
    expect(paceInterval(base, '4/1'), const Duration(milliseconds: 10));
    expect(paceInterval(base, '8/1'), const Duration(milliseconds: 5));
  });
}
