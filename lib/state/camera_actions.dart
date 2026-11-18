/// What the UI needs from the api lane. Tests fake this interface; the
/// orchestrator adapts lib/api/camera_router.dart to it.
library;

import 'package:flutter/foundation.dart';

import 'camera_view_model.dart';

/// One recorded segment on the SD card (UTC instants).
class RecordingClip {
  const RecordingClip({required this.start, required this.end, this.eventType = 1});
  final DateTime start;
  final DateTime end;

  /// 1 Continuous, 2 Motion, 6 Person, 8 Vehicle, 9 Pet.
  final int eventType;
}

class MotionEvent {
  const MotionEvent({required this.cameraId, required this.active, required this.time});
  final String cameraId;
  final bool active;
  final DateTime time;
}

/// Raised by [CameraActions]; [code] is the cloud error code if any
/// (for example -63103 for a refused camera name).
class CameraActionException implements Exception {
  const CameraActionException(this.message, {this.code});
  final String message;
  final int? code;
  @override
  String toString() => message;
}

/// State of a recordings player (all instants UTC).
class PlaybackState {
  const PlaybackState({required this.position, this.paused = false, this.ended = false, this.speed = 1});
  final DateTime position;
  final bool paused;
  final bool ended;
  final int speed;

  PlaybackState copyWith({DateTime? position, bool? paused, bool? ended, int? speed}) => PlaybackState(
        position: position ?? this.position,
        paused: paused ?? this.paused,
        ended: ended ?? this.ended,
        speed: speed ?? this.speed,
      );
}

/// A running SD-card playback session. The video itself is drawn by a
/// widget built from it (see VodTimelineScreen.videoBuilder).
abstract class PlaybackControl {
  ValueListenable<PlaybackState> get state;
  Future<void> pause();
  Future<void> resume();
  Future<void> seekTo(DateTime utc);
  Future<void> setSpeed(int speed);
  Future<void> stop();
}

abstract class CameraActions {
  /// Sets the IR mode; returns the mode now in effect.
  Future<DayNightMode> setDayNight(String cameraId, DayNightMode mode);

  /// Siren on/off; returns the state now in effect.
  Future<bool> setAlarm(String cameraId, bool on);

  /// Owned cameras only: renames on the camera (cloud alias).
  Future<void> renameOnCamera(String cameraId, String name);

  /// Local display name on this TV; null removes it.
  Future<void> setLocalName(String cameraId, String? name);

  /// Clips between [fromUtc] and [toUtc]; throws on failure.
  Future<List<RecordingClip>> listClips(String cameraId, DateTime fromUtc, DateTime toUtc);

  /// Starts playback of [startUtc]..[endUtc].
  Future<PlaybackControl> openPlayback(String cameraId, DateTime startUtc, DateTime endUtc);

  Stream<MotionEvent> get motionEvents;

  /// Optional per-camera account (RTSP/ONVIF). One login test only.
  Future<bool> testCameraAccount(String cameraId, String username, String password);
  Future<void> saveCameraAccount(String cameraId, String username, String password);
  Future<void> clearCameraAccount(String cameraId);
  Future<String?> cameraAccountUser(String cameraId);
}