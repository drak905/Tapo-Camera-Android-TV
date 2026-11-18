/// Per-camera concurrent media session limit (live and SD playback share it).
library;

/// A held slot. [release] is idempotent.
class StreamLease {
  StreamLease(this.key, this._onRelease);
  final String key;
  // ignore: unused_field
  final void Function(String key) _onRelease;
  // ignore: prefer_final_fields
  bool _released = false;

  bool get released => _released;

  void release() => throw UnimplementedError();
}

/// Counting limiter keyed by camera id (local: host, relay: cloud deviceId).
class StreamLimiter {
  StreamLimiter({this.maxPerKey = 2});

  final int maxPerKey;

  /// Takes one slot for [key]. Waits up to [timeout] for a free slot (zero =
  /// do not wait), then throws `StreamLimitException`. Limit errors are fatal:
  /// callers must not retry in a loop.
  Future<StreamLease> acquire(String key, {Duration timeout = Duration.zero}) => throw UnimplementedError();

  /// Number of leases currently held for [key].
  int active(String key) => throw UnimplementedError();
}
