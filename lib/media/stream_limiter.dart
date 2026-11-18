/// Per-camera concurrent media session limit (live and SD playback share it).
library;

import 'dart:async';

import 'media_errors.dart';

/// A held slot. [release] is idempotent.
class StreamLease {
  StreamLease(this.key, this._onRelease);
  final String key;
  final void Function(String key) _onRelease;
  bool _released = false;

  bool get released => _released;

  void release() {
    if (_released) return;
    _released = true;
    _onRelease(key);
  }
}

/// Counting limiter keyed by camera id (local: host, relay: cloud deviceId).
class StreamLimiter {
  StreamLimiter({this.maxPerKey = 2});

  final int maxPerKey;
  final Map<String, int> _active = {};
  final Map<String, List<Completer<void>>> _waiters = {};

  /// Takes one slot for [key]. Waits up to [timeout] for a free slot (zero =
  /// do not wait), then throws `StreamLimitException`. Limit errors are fatal:
  /// callers must not retry in a loop.
  Future<StreamLease> acquire(String key, {Duration timeout = Duration.zero}) async {
    if (_tryTake(key)) return StreamLease(key, _release);
    if (timeout <= Duration.zero) throw _limit(key);
    final waiter = Completer<void>();
    _waiters.putIfAbsent(key, () => []).add(waiter);
    final timer = Timer(timeout, () {
      if (!waiter.isCompleted) waiter.complete();
    });
    await waiter.future;
    timer.cancel();
    _waiters[key]?.remove(waiter);
    if (_tryTake(key)) return StreamLease(key, _release);
    throw _limit(key);
  }

  /// Number of leases currently held for [key].
  int active(String key) => _active[key] ?? 0;

  bool _tryTake(String key) {
    final n = active(key);
    if (n >= maxPerKey) return false;
    _active[key] = n + 1;
    return true;
  }

  void _release(String key) {
    final n = active(key);
    if (n <= 1) {
      _active.remove(key);
    } else {
      _active[key] = n - 1;
    }
    final queue = _waiters[key];
    if (queue != null) {
      for (final w in queue) {
        if (!w.isCompleted) {
          w.complete();
          break;
        }
      }
    }
  }

  StreamLimitException _limit(String key) =>
      StreamLimitException('camera already has $maxPerKey active media sessions');
}