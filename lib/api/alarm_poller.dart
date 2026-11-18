// Motion alerts without a camera account: poll getLastAlarmInfo.
// Spec: ev.source.no_camera_account.

import 'dart:async';

import 'camera_dtos.dart';

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
  })  : _cameraId = cameraId,
        _readAlarm = readAlarm,
        _onEvent = onEvent,
        _cloudRouted = cloudRouted,
        _clock = clock ?? DateTime.now,
        _log = log;

  static const localInterval = Duration(seconds: 5);
  static const cloudInterval = Duration(seconds: 30);

  final String _cameraId;
  final Future<Map<String, dynamic>> Function() _readAlarm;
  final void Function(MotionEvent event) _onEvent;
  final bool _cloudRouted;
  final DateTime Function() _clock;
  final void Function(String message)? _log;

  Timer? _timer;
  bool _polling = false;
  bool _baselineSet = false;
  String? _lastTime;
  int _failures = 0;

  Duration get interval => _cloudRouted ? cloudInterval : localInterval;

  /// Starts periodic polling (first poll immediately). Idempotent.
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => pollOnce());
    pollOnce();
  }

  /// One poll; never throws.
  Future<void> pollOnce() async {
    if (_polling) return;
    _polling = true;
    try {
      final info = parseLastAlarmInfo(await _readAlarm());
      _failures = 0;
      final time = info.time;
      if (!_baselineSet) {
        _baselineSet = true;
        _lastTime = time;
        return;
      }
      if (time != null && time != _lastTime) {
        _lastTime = time;
        _emit(time, info.type ?? 'motion');
      }
    } catch (e) {
      _failures++;
      if (_failures == 1 || _failures == 10 || (_failures > 10 && _failures % 60 == 0)) {
        _log?.call('Motion polling failed ($_failures in a row): ${e.runtimeType}');
      }
    } finally {
      _polling = false;
    }
  }

  void _emit(String time, String type) {
    final seconds = int.tryParse(time);
    final stamp = seconds == null
        ? _clock()
        : DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
    try {
      _onEvent(MotionEvent(
        cameraId: _cameraId,
        active: true,
        type: type,
        timestamp: stamp,
        topic: 'tapo:LastAlarmInfo/$type',
        source: 'last_alarm_info',
      ));
    } catch (_) {
      // a listener bug must not stop polling
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
