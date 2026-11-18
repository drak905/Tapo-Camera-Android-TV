/// Caps simultaneous relay streams outside the current view.
library;

const int kDefaultMaxRemoteStreams = 4;
const int kMaxRemoteStreamsLimit = 8;

/// Validated `max remote streams` setting: 1..8, anything else (null, 0, 9,
/// non-int, bool) gives the default 4.
int validMaxRemoteStreams(Object? value) => throw UnimplementedError();

/// Counting gate keyed by camera id, in acquisition order.
///
/// A camera in the current view is reserved ([reserve]): it always gets a slot
/// (holders may then exceed capacity) and is never evicted. Capacity only
/// limits the other cameras.
class RemoteStreamGate {
  RemoteStreamGate({int capacity = kDefaultMaxRemoteStreams});

  int get capacity => throw UnimplementedError();

  /// Throws [ArgumentError] unless 1..8.
  void setCapacity(int capacity) => throw UnimplementedError();

  /// True when [key] holds (or now holds) a slot. When full and [preempt] is
  /// true, the oldest non-reserved holder is removed first and its stored
  /// onEvict callback runs. Without [preempt] a full gate returns false.
  bool acquire(String key, void Function() onEvict, {bool preempt = false}) => throw UnimplementedError();

  void release(String key) => throw UnimplementedError();
  bool holds(String key) => throw UnimplementedError();

  /// Holders, oldest first.
  List<String> holders() => throw UnimplementedError();

  /// Replaces the reserved keys (cameras in the view).
  void reserve(Iterable<String> keys) => throw UnimplementedError();
  Set<String> reserved() => throw UnimplementedError();
}
