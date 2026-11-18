import 'package:fake_async/fake_async.dart';

/// Runs microtasks and advances fake time in 1 ms steps (default 20 ms).
void pump(FakeAsync async, [int rounds = 20]) {
  for (var i = 0; i < rounds; i++) {
    async.flushMicrotasks();
    async.elapse(const Duration(milliseconds: 1));
  }
}
