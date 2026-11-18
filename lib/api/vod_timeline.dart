/// Pure logic of SD playback pacing and position tracking, ported from the
/// Windows app (`playback_stream.py`): clip list normalisation, the video PES
/// splitter, the PTS -> recording time timeline and the wall clock pacer.
///
/// No I/O and no real clock here: callers pass the current monotonic time
/// as a [Duration], so tests drive it with fake_async.
library;

import 'dart:typed_data';

/// PTS clock rate (Hz).
const int kPtsClock = 90000;
const int _ptsMask = (1 << 33) - 1;
const int _ptsHalf = 1 << 32;

/// A PTS step larger than this (seconds) means another recording file.
const double kMaxPtsStepSeconds = 3.0;

/// Slack when matching a position to a recording of the clip list.
const double kClipEdgeSeconds = 1.5;

/// Behind schedule by more than this (slow link): restart the clock instead of racing.
const Duration kLateRebase = Duration(seconds: 1);

const int _tsPacket = 188;

/// Sorted, merged `(start, end)` epoch seconds; inverted or empty entries are
/// dropped and entries within 0.5 s of each other are merged.
List<(double, double)> normalizeSegments(Iterable<(num, num)>? items) {
  final spans = <(double, double)>[];
  for (final (s, e) in items ?? const <(num, num)>[]) {
    final start = s.toDouble(), end = e.toDouble();
    if (end > start) spans.add((start, end));
  }
  spans.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  final merged = <(double, double)>[];
  for (final (start, end) in spans) {
    if (merged.isNotEmpty && start <= merged.last.$2 + 0.5) {
      final last = merged.last;
      merged[merged.length - 1] = (last.$1, end > last.$2 ? end : last.$2);
    } else {
      merged.add((start, end));
    }
  }
  return merged;
}

/// 33-bit PTS of a PES header at [i] (the five PTS bytes).
int readPts(Uint8List b, int i) =>
    (((b[i] >> 1) & 7) << 30) | (b[i + 1] << 22) | ((b[i + 2] >> 1) << 15) | (b[i + 3] << 7) | (b[i + 4] >> 1);

/// One piece of a TS chunk: [pts] is null for a continuation of a frame.
class TsPiece {
  const TsPiece(this.pts, this.data);
  final int? pts;
  final Uint8List data;
}

/// Splits a chunk of whole TS packets at the video PES starts (stream_id
/// 0xE0..0xEF with a PTS). The video PID is the first PID carrying such a PES.
class VideoSplitter {
  int? videoPid;

  /// Null when [data] is not a whole number of aligned TS packets.
  List<TsPiece>? split(Uint8List data) {
    final n = data.length;
    if (n == 0 || n % _tsPacket != 0 || data[0] != 0x47) return null;
    final pieces = <TsPiece>[];
    var start = 0;
    int? pts;
    for (var off = 0; off < n; off += _tsPacket) {
      if (data[off] != 0x47) return null;
      final b1 = data[off + 1];
      if (b1 & 0x40 == 0) continue; // no payload unit start
      final pid = ((b1 & 0x1F) << 8) | data[off + 2];
      if (videoPid != null && pid != videoPid) continue;
      final afc = (data[off + 3] >> 4) & 3;
      if (afc & 1 == 0) continue;
      final idx = off + 4 + (afc & 2 != 0 ? 1 + data[off + 4] : 0);
      if (idx + 14 > off + _tsPacket) continue;
      if (data[idx] != 0 || data[idx + 1] != 0 || data[idx + 2] != 1) continue;
      final sid = data[idx + 3];
      if (sid < 0xE0 || sid > 0xEF || data[idx + 7] & 0x80 == 0) continue;
      final value = readPts(data, idx + 9);
      videoPid = pid;
      if (off > start) pieces.add(TsPiece(pts, Uint8List.sublistView(data, start, off)));
      start = off;
      pts = value;
    }
    pieces.add(TsPiece(pts, Uint8List.sublistView(data, start)));
    return pieces;
  }
}

/// Maps the media PTS of one playback request to recording time (UTC seconds).
class PtsTimeline {
  PtsTimeline(List<(double, double)> segments, double start)
      : _segs = segments,
        position = snap(start, segments);

  final List<(double, double)> _segs;
  int? _lastPts;

  /// Recording time of the last frame (UTC epoch seconds).
  double position;

  /// [t] when inside a recording, else the start of the next one ([t] when none).
  static double snap(double t, List<(double, double)> segments) {
    for (final (start, end) in segments) {
      if (t < end) return t > start ? t : start;
    }
    return t;
  }

  int? _containing(double t) {
    for (var i = 0; i < _segs.length; i++) {
      final (start, end) = _segs[i];
      if (start - kClipEdgeSeconds <= t && t <= end + kClipEdgeSeconds) return i;
    }
    return null;
  }

  /// Start of the recording after the one containing [t] (or after [t]); null if none.
  double? nextStart(double t) {
    final i = _containing(t);
    if (i != null) return i + 1 < _segs.length ? _segs[i + 1].$1 : null;
    for (final (s, _) in _segs) {
      if (s > t) return s;
    }
    return null;
  }

  /// Accounts for a frame with [pts]; true when the position jumped (the pacer must restart).
  bool advance(int pts) {
    final last = _lastPts;
    if (last == null) {
      _lastPts = pts;
      return true;
    }
    var delta = (pts - last) & _ptsMask;
    if (delta >= _ptsHalf) delta -= _ptsMask + 1;
    _lastPts = pts;
    final step = delta / kPtsClock;
    if (step >= 0.0 && step <= kMaxPtsStepSeconds) {
      final next = position + step;
      final i = _containing(position);
      if (i != null && next > _segs[i].$2 + kClipEdgeSeconds) {
        // PTS ran on past the end of this recording: continue in the next one.
        if (i + 1 < _segs.length) {
          final over = next - _segs[i].$2 - kClipEdgeSeconds;
          position = _segs[i + 1].$1 + (over > 0 ? over : 0);
          return true;
        }
      }
      position = next;
      return false;
    }
    final nxt = nextStart(position); // a new recording file
    if (nxt != null) {
      position = nxt;
    } else if (_segs.isEmpty && step > 0.0 && step < 86400.0) {
      position += step;
    }
    return true;
  }
}

/// Wall clock schedule of recording time: when should a media second be shown.
class Pacer {
  Duration _wall = Duration.zero;
  double _media = 0;
  double _speed = 1;

  double get speed => _speed;

  void rebase(double media, double speed, Duration now) {
    _wall = now;
    _media = media;
    _speed = speed < 0.01 ? 0.01 : speed;
  }

  /// Time to wait before [media] is due at [now]; zero when due. A frame more
  /// than [kLateRebase] late restarts the schedule at [media].
  Duration wait(double media, Duration now) {
    final dueMicros = _wall.inMicroseconds + ((media - _media) / _speed * 1e6).round();
    final left = dueMicros - now.inMicroseconds;
    if (left > 0) return Duration(microseconds: left);
    if (left < -kLateRebase.inMicroseconds) rebase(media, _speed, now);
    return Duration.zero;
  }
}
