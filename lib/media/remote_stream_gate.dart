/// Caps simultaneous relay streams outside the current view.
library;

const int kDefaultMaxRemoteStreams = 4;
const int kMaxRemoteStreamsLimit = 8;

/// Validated `max remote streams` setting: 1..8, anything else (null, 0, 9,
/// non-int, bool) gives the default 4.
int validMaxRemoteStreams(Object? value) {
  if (value is int && value >= 1 && value <= kMaxRemoteStreamsLimit) return value;
  return kDefaultMaxRemoteStreams;
}

/// Counting gate keyed by camera id, in acquisition order.
///
/// A camera in the current view is reserved ([reserve]): it always gets a slot
/// (holders may then exceed capacity) and is never evicted. Capacity only
/// limits the other cameras.
class RemoteStreamGate {
  RemoteStreamGate({int capacity = kDefaultMaxRemoteStreams}) : _capacity = capacity;

  int _capacity;
  final Map<String, void Function()> _holders = {}; // insertion ordered
  Set<String> _reserved = {};

  int get capacity => _capacity;

  /// Throws [ArgumentError] unless 1..8.
  void setCapacity(int capacity) {
    if (capacity < 1 || capacity > kMaxRemoteStreamsLimit) {
      throw ArgumentError.value(capacity, 'capacity', 'must be 1..$kMaxRemoteStreamsLimit');
    }
    _capacity = capacity;
  }

  /// True when [key] holds (or now holds) a slot. When full and [preempt] is
  /// true, the oldest non-reserved holder is removed first and its stored
  /// onEvict callback runs. Without [preempt] a full gate returns false.
  bool acquire(String key, void Function() onEvict, {bool preempt = false}) {
    if (_holders.containsKey(key)) return true;
    if (_reserved.contains(key)) {
      _holders[key] = onEvict;
      return true;
    }
    if (_holders.length < _capacity) {
      _holders[key] = onEvict;
      return true;
    }
    if (!preempt) return false;
    String? victim;
    for (final k in _holders.keys) {
      if (!_reserved.contains(k)) {
        victim = k;
        break;
      }
    }
    if (victim == null) return false;
    final cb = _holders.remove(victim)!;
    _holders[key] = onEvict;
    cb();
    return true;
  }

  void release(String key) => _holders.remove(key);
  bool holds(String key) => _holders.containsKey(key);

  /// Holders, oldest first.
  List<String> holders() => _holders.keys.toList();

  /// Replaces the reserved keys (cameras in the view).
  void reserve(Iterable<String> keys) => _reserved = keys.toSet();
  Set<String> reserved() => Set.of(_reserved);
}