// SD-card recording search (days, clips) over the control channel and the
// playback transport choice. Spec: vod.search.*, vod.transport.routing.
// Playback itself (vod_session.dart) belongs to the player lane.

import 'dart:math';

import 'camera_dtos.dart';
import 'camera_router.dart';
import 'tapo_errors.dart';
import 'vod_transport.dart';

export 'vod_transport.dart';

/// One recorded clip; times are UTC epoch seconds.
class RecordingClip {
  const RecordingClip({required this.start, required this.end, required this.eventType});
  final int start;
  final int end;

  /// 1 timing, 2 motion, 6 person, others per spec; 0 when missing.
  final int eventType;
  int get durationSeconds => end - start;
}

String _two(int v) => v.toString().padLeft(2, '0');

String _yyyymmdd(DateTime d) => '${d.year.toString().padLeft(4, '0')}${_two(d.month)}${_two(d.day)}';

/// `searchDateWithVideo` with `channel:[0]` and `yyyyMMdd` dates.
Map<String, dynamic> buildSearchDaysRequest({required DateTime start, required DateTime end}) => {
      'method': 'searchDateWithVideo',
      'params': {
        'playback': {
          'search_year_utility': {
            'channel': [0],
            'start_date': _yyyymmdd(start),
            'end_date': _yyyymmdd(end),
          },
        },
      },
    };

/// Single-key maps (`{"x_1": {...}}`) become their inner map; flat maps stay.
List<Map<String, dynamic>> _unwrap(Object? items, String what) {
  if (items == null) return const [];
  if (items is! List) throw TapoProtocolError('playback.$what is not a list');
  final out = <Map<String, dynamic>>[];
  for (final item in items) {
    if (item is! Map) throw TapoProtocolError('$what item is not an object');
    if (item.length == 1 && item.values.first is Map) {
      out.add(Map<String, dynamic>.from(item.values.first as Map));
    } else {
      out.add(Map<String, dynamic>.from(item));
    }
  }
  return out;
}

Map<String, dynamic> _playback(Map<String, dynamic> result) {
  final p = result['playback'];
  if (p is! Map) throw TapoProtocolError("Camera reply is missing 'playback'");
  return Map<String, dynamic>.from(p);
}

/// `result.playback.search_results` (list of single-key maps holding `date`)
/// -> sorted `yyyyMMdd`. A date that is not 8 digits is a `TapoProtocolError`.
List<String> parseDays(Map<String, dynamic> result) {
  final days = <String>{};
  for (final item in _unwrap(_playback(result)['search_results'], 'search_results')) {
    final value = item['date'];
    if (value is! String || !RegExp(r'^\d{8}$').hasMatch(value)) {
      throw TapoProtocolError('search_results date is not yyyyMMdd');
    }
    days.add(value);
  }
  return days.toList()..sort();
}

/// `yyyyMMdd` -> `YYYY-MM-DD`; throws `TapoProtocolError` for an impossible date.
String isoDay(String yyyymmdd) {
  if (!RegExp(r'^\d{8}$').hasMatch(yyyymmdd)) throw TapoProtocolError('search_results date is not yyyyMMdd');
  final y = int.parse(yyyymmdd.substring(0, 4));
  final m = int.parse(yyyymmdd.substring(4, 6));
  final d = int.parse(yyyymmdd.substring(6, 8));
  final date = DateTime(y, m, d);
  if (date.year != y || date.month != m || date.day != d) {
    throw TapoProtocolError('search_results date is not a valid date');
  }
  return '${yyyymmdd.substring(0, 4)}-${yyyymmdd.substring(4, 6)}-${yyyymmdd.substring(6, 8)}';
}

/// `searchVideoWithUTC` page. Uses `id: 1` unless [playerId] is given.
Map<String, dynamic> buildDayClipsRequest({
  required int startTime,
  required int endTime,
  required int startIndex,
  required int endIndex,
  String? playerId,
}) =>
    buildSearchVideoWithUtc(
      startTime: startTime,
      endTime: endTime,
      startIndex: startIndex,
      endIndex: endIndex,
      playerId: playerId,
    );

int _timeValue(Object? value, String what) {
  if (value is int) return value;
  if (value is String) {
    final p = int.tryParse(value.trim());
    if (p != null) return p;
  }
  throw TapoProtocolError('$what is not an integer');
}

/// `result.playback.search_video_results` (single-key maps with
/// startTime/endTime as int or numeric string, `video_type` or misspelled
/// `vedio_type`), sorted by start. Non-numeric times are a `TapoProtocolError`.
List<RecordingClip> parseDayClips(Map<String, dynamic> result) {
  final clips = <RecordingClip>[];
  for (final item in _unwrap(_playback(result)['search_video_results'], 'search_video_results')) {
    final kind = item.containsKey('video_type') ? item['video_type'] : item['vedio_type'];
    clips.add(RecordingClip(
      start: _timeValue(item['startTime'], 'startTime'),
      end: _timeValue(item['endTime'], 'endTime'),
      eventType: kind == null ? 0 : _timeValue(kind, 'video_type'),
    ));
  }
  clips.sort((a, b) => a.start.compareTo(b.start));
  return clips;
}

/// `playback.to_be_continued != 0`.
bool hasMoreClips(Map<String, dynamic> result) {
  final playback = result['playback'];
  if (playback is! Map) return false;
  final flag = playback['to_be_continued'] ?? 0;
  if (flag is bool) return flag;
  if (flag is int) return flag != 0;
  final parsed = int.tryParse('$flag'.trim());
  return parsed != null && parsed != 0;
}

/// Local midnight of [localDay] and +86399 s, as UTC epoch seconds.
(int start, int end) dayWindowSeconds(DateTime localDay) {
  final start = DateTime(localDay.year, localDay.month, localDay.day).millisecondsSinceEpoch ~/ 1000;
  return (start, start + 86399);
}

/// Control path used for searches (local client or cloud passthrough).
abstract class VodControl {
  /// Returns every item, errors included (not thrown).
  Future<List<ControlItem>> send(List<Map<String, dynamic>> requests);
}

const _clipSearchFormError = -71103;
const _pageSize = 100;
const _maxPages = 100;

class VodClient {
  /// [terminalUuid] feeds the player_id (used when it is 32 hex, else a stable
  /// per-client uuid4 hex).
  VodClient({required VodControl control, String? terminalUuid})
      : _control = control,
        _playerId = _derivePlayerId(terminalUuid);

  final VodControl _control;
  final String _playerId;
  bool _usePlayerId = false;

  static String _derivePlayerId(String? terminalUuid) {
    if (terminalUuid != null && RegExp(r'^[0-9A-Fa-f]{32}$').hasMatch(terminalUuid)) {
      return terminalUuid.toLowerCase();
    }
    final rng = Random.secure();
    return List.generate(16, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// 32 lower-case hex, stable per client.
  String get playerId => _playerId;

  Future<ControlItem> _one(Map<String, dynamic> request) async {
    final items = await _control.send([request]);
    if (items.isEmpty) throw TapoProtocolError('The camera sent no answer');
    return items.first;
  }

  /// Days with recordings as ISO `YYYY-MM-DD` (Windows `parse_days` returns
  /// `datetime.date`; this is its `isoformat`). A `yyyyMMdd` value that is not
  /// a real date is a `TapoProtocolError` (Windows dtos.py:323).
  Future<List<String>> daysWithRecordings(DateTime start, DateTime end) async {
    final item = await _one(buildSearchDaysRequest(start: start, end: end));
    item.ensureOk();
    return [for (final d in parseDays(item.result)) isoDay(d)];
  }

  Future<ControlItem> _searchPage(int startTime, int endTime, int first, int last) async {
    Map<String, dynamic> request(bool withPlayerId) => buildDayClipsRequest(
          startTime: startTime,
          endTime: endTime,
          startIndex: first,
          endIndex: last,
          playerId: withPlayerId ? _playerId : null,
        );
    final item = await _one(request(_usePlayerId));
    if (item.errorCode != _clipSearchFormError) {
      item.ensureOk();
      return item;
    }
    final retry = await _one(request(!_usePlayerId));
    retry.ensureOk();
    _usePlayerId = !_usePlayerId;
    return retry;
  }

  /// Pages of 100 (start_index/end_index 0..99, 100..199, ...) while
  /// `to_be_continued != 0` and the page is non-empty; cap 100 pages. A first
  /// -71103 retries that page once with `player_id` and remembers the form; a
  /// second -71103 is raised (`TapoDeviceError`).
  Future<List<RecordingClip>> recordingsForDay(DateTime localDay) async {
    final (start, end) = dayWindowSeconds(localDay);
    final clips = <RecordingClip>[];
    for (var page = 0; page < _maxPages; page++) {
      final first = page * _pageSize;
      final item = await _searchPage(start, end, first, first + _pageSize - 1);
      final pageClips = parseDayClips(item.result);
      clips.addAll(pageClips);
      if (pageClips.isEmpty || !hasMoreClips(item.result)) break;
    }
    clips.sort((a, b) => a.start.compareTo(b.start));
    return clips;
  }
}

/// Relay when the camera is cloud-routed and a signed-in relay provider
/// exists (shared cameras on the LAN too); local :8800 for owned cameras on
/// the LAN. Otherwise failed with a reason.
VodTransportChoice chooseVodTransport(TapoCamera camera, {required bool relayAvailable}) {
  final localPossible = !camera.isShared &&
      camera.route == CameraRoute.local &&
      (camera.lanIp != null && camera.lanIp!.isNotEmpty);
  if (localPossible) return const VodTransportChoice.use(VodTransportKind.local);
  if (!camera.online) return const VodTransportChoice.failed(VodFailReason.cameraOffline);
  if (relayAvailable) return const VodTransportChoice.use(VodTransportKind.relay);
  return VodTransportChoice.failed(
    camera.isShared ? VodFailReason.sharedCameraCloudOnly : VodFailReason.notOnThisNetwork,
  );
}
