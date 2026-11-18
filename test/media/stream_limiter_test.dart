// mb.limits.per_camera
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/media/media_errors.dart';
import 'package:tapo_tv/media/stream_limiter.dart';

void main() {
  test('default limit is 2 per key', () {
    expect(StreamLimiter().maxPerKey, 2);
  });

  test('third acquire throws StreamLimitException', () async {
    final l = StreamLimiter();
    await l.acquire('cam1');
    await l.acquire('cam1');
    expect(l.active('cam1'), 2);
    await expectLater(l.acquire('cam1'), throwsA(isA<StreamLimitException>()));
  });

  test('release is idempotent', () async {
    final l = StreamLimiter();
    final a = await l.acquire('cam1');
    await l.acquire('cam1');
    a.release();
    a.release();
    expect(a.released, isTrue);
    expect(l.active('cam1'), 1);
    await l.acquire('cam1'); // slot free again
    expect(l.active('cam1'), 2);
  });

  test('acquire waits for timeout then throws', () {
    fakeAsync((async) {
      final l = StreamLimiter(maxPerKey: 1);
      late StreamLease first;
      l.acquire('c').then((v) => first = v);
      async.flushMicrotasks();
      Object? error;
      var done = false;
      l.acquire('c', timeout: const Duration(seconds: 2)).then((_) => done = true, onError: (Object e) {
        error = e;
        return false;
      });
      async.elapse(const Duration(seconds: 1));
      expect(done, isFalse);
      expect(error, isNull);
      async.elapse(const Duration(seconds: 2));
      expect(error, isA<StreamLimitException>());
      expect(first.released, isFalse);
    });
  });

  test('waiting acquire succeeds when a lease is released in time', () {
    fakeAsync((async) {
      final l = StreamLimiter(maxPerKey: 1);
      late StreamLease first;
      l.acquire('c').then((v) => first = v);
      async.flushMicrotasks();
      StreamLease? second;
      l.acquire('c', timeout: const Duration(seconds: 5)).then((v) => second = v);
      async.elapse(const Duration(seconds: 1));
      first.release();
      async.flushMicrotasks();
      expect(second, isNotNull);
    });
  });

  test('keys are independent', () async {
    final l = StreamLimiter();
    await l.acquire('a');
    await l.acquire('a');
    final b = await l.acquire('b');
    expect(b.key, 'b');
    expect(l.active('a'), 2);
    expect(l.active('b'), 1);
  });
}
