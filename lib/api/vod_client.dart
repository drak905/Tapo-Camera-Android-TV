// SD-card recording search (days, clips) over the control channel and the
// playback transport choice. Spec: vod.search.*, vod.transport.routing.
// Playback itself (vod_session.dart) belongs to the player lane.

import 'camera_dtos.dart';
import 'camera_router.dart';

/// One recorded clip; times are UTC epoch seconds.
class RecordingClip {
  const RecordingClip({required this.start, required this.end, required this.eventType});
  final int start;
  final int end;

  /// 1 timing, 2 motion, 6 person, others per spec; 0 when missing.
  final int eventType;
  int get durationSeconds => end - start;
}

/// `searchDateWithVideo` with `channel:[0]` and `yyyyMMdd` dates.
Map<String, dynamic> buildSearchDaysRequest({required DateTime start, required DateTime end}) =>
    throw UnimplementedError();

/// `result.playback.search_results` (list of single-key maps holding `date`)
/// -> sorted `yyyyMMdd`. A date that is not 8 digits is a `TapoProtocolError`.
List<String> parseDays(Map<String, dynamic> result) => throw UnimplementedError();

/// `searchVideoWithUTC` page. Uses `id: 1` unless [playerId] is given.
Map<String, dynamic> buildDayClipsRequest({
  required int startTime,
  required int endTime,
  required int startIndex,
  required int endIndex,
  String? playerId,
}) =>
    throw UnimplementedError();

/// `result.playback.search_video_results` (single-key maps with
/// startTime/endTime as int or numeric string, `video_type` or misspelled
/// `vedio_type`), sorted by start. Non-numeric times are a `TapoProtocolError`.
List<RecordingClip> parseDayClips(Map<String, dynamic> result) => throw UnimplementedError();

/// `playback.to_be_continued != 0`.
bool hasMoreClips(Map<String, dynamic> result) => throw UnimplementedError();

/// Local midnight of [localDay] and +86399 s, as UTC epoch seconds.
(int start, int end) dayWindowSeconds(DateTime localDay) => throw UnimplementedError();

/// Control path used for searches (local client or cloud passthrough).
abstract class VodControl {
  /// Returns every item, errors included (not thrown).
  Future<List<ControlItem>> send(List<Map<String, dynamic>> requests);
}

class VodClient {
  /// [terminalUuid] feeds the player_id (used when it is 32 hex, else a stable
  /// per-client uuid4 hex).
  VodClient({required VodControl control, String? terminalUuid});

  /// 32 lower-case hex, stable per client.
  String get playerId => throw UnimplementedError();

  Future<List<String>> daysWithRecordings(DateTime start, DateTime end) =>
      throw UnimplementedError();

  /// Pages of 100 (start_index/end_index 0..99, 100..199, ...) while
  /// `to_be_continued != 0` and the page is non-empty; cap 100 pages. A first
  /// -71103 retries that page once with `player_id` and remembers the form; a
  /// second -71103 is raised (`TapoDeviceError`).
  Future<List<RecordingClip>> recordingsForDay(DateTime localDay) =>
      throw UnimplementedError();
}

enum VodTransportKind { local, relay }

/// Why playback is impossible.
enum VodFailReason { notOnThisNetwork, cameraOffline, sharedCameraCloudOnly }

class VodTransportChoice {
  const VodTransportChoice.use(this.kind) : failure = null;
  const VodTransportChoice.failed(this.failure) : kind = null;
  final VodTransportKind? kind;
  final VodFailReason? failure;
}

/// Relay when the camera is cloud-routed and a signed-in relay provider
/// exists (shared cameras on the LAN too); local :8800 for owned cameras on
/// the LAN. Otherwise failed with a reason.
VodTransportChoice chooseVodTransport(TapoCamera camera, {required bool relayAvailable}) =>
    throw UnimplementedError();