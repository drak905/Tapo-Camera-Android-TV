// Motion alerts without a camera account: poll getLastAlarmInfo.
// Spec: ev.source.no_camera_account.

import 'dart:async';

/// A motion notification.
class MotionEvent {
  const MotionEvent({
    required this.cameraId,
    required this.active,
    required this.type,
    required this.timestamp,
    required this.topic,
    required this.source,
  });
  final String cameraId;
  final bool active;

  /// motion, person, ...
  final String type;
  final DateTime timestamp;

  /// `tapo:LastAlarmInfo/<type or motion>`.
  final String topic;

  /// `last_alarm_info` here, `onvif` for PullPoint events.
  final String source;
}

/// Polls `getLastAlarmInfo`. The first reading is a baseline (no event); each
/// later change of `last_alarm_time` emits one active event.
class AlarmPoller {
  /// [readAlarm] returns the `result` map of the getLastAlarmInfo item and may
  /// throw. [cloudRouted] fixes the interval at 30 s (else 5 s). [log] gets
  /// error messages for the 1st, 10th and every 60th consecutive failure.
  AlarmPoller({
    required String cameraId,
    required Future<Map<String, dynamic>> Function() readAlarm,
    required void Function(MotionEvent event) onEvent,
    required bool cloudRouted,
    DateTime Function()? clock,
    void Function(String message)? log,
  });

  static const localInterval = Duration(seconds: 5);
  static const cloudInterval = Duration(seconds: 30);

  Duration get interval => throw UnimplementedError();

  /// Starts periodic polling (first poll immediately). Idempotent.
  void start() => throw UnimplementedError();

  /// One poll; never throws.
  Future<void> pollOnce() => throw UnimplementedError();

  void stop() => throw UnimplementedError();
}