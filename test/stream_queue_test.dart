import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/player/stream_queue.dart';

void main() {
  test('streams start one at a time, in order', () {
    fakeAsync((async) {
      final queue = StreamQueue.instance;
      final started = <int>[];
      final tickets = [for (var i = 0; i < 3; i++) queue.request()];
      for (var i = 0; i < tickets.length; i++) {
        tickets[i].ready.then((_) => started.add(i));
      }
      async.flushMicrotasks();
      expect(started, [0]);

      tickets[0].release(); // first frame arrived
      async.flushMicrotasks();
      expect(started, [0, 1]);

      tickets[2].release(); // gone before its turn: never starts
      tickets[1].release();
      async.flushMicrotasks();
      expect(started, [0, 1]);
    });
  });

  test('a slow stream hands its slot on after the timeout', () {
    fakeAsync((async) {
      final queue = StreamQueue.instance;
      final started = <int>[];
      final a = queue.request(), b = queue.request();
      a.ready.then((_) => started.add(0));
      b.ready.then((_) => started.add(1));
      async.flushMicrotasks();
      expect(started, [0]);

      async.elapse(StreamQueue.slotTimeout + const Duration(milliseconds: 1));
      expect(started, [0, 1]);
      b.release();
      a.release();
    });
  });

  test('retry skips queue', () {
    fakeAsync((async) {
      final queue = StreamQueue.instance;
      final started = <String>[];
      final busy = queue.request(); // occupies the single starting slot
      final waiting = queue.request();
      busy.ready.then((_) => started.add('busy'));
      waiting.ready.then((_) => started.add('waiting'));
      async.flushMicrotasks();
      expect(started, ['busy']);

      final retry = queue.request(skipQueue: true); // manual Retry
      retry.ready.then((_) => started.add('retry'));
      async.flushMicrotasks();
      expect(started, ['busy', 'retry'], reason: 'retry starts at once, without waiting for the slot');

      retry.release(); // does not free the slot held by the busy stream
      async.flushMicrotasks();
      expect(started, ['busy', 'retry']);

      busy.release();
      async.flushMicrotasks();
      expect(started, ['busy', 'retry', 'waiting']);
      waiting.release();
    });
  });
}
