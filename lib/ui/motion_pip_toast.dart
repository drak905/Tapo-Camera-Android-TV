import 'package:flutter/material.dart';

import '../state/camera_actions.dart';

/// Shows a transient card at top 27 / right 48 for motion events:
/// "`<camera name>`: Motion at HH:MM:SS". Only active events of known cameras,
/// only when notifications are on, at most one per camera per [minInterval].
/// Never takes focus.
class MotionToastHost extends StatefulWidget {
  const MotionToastHost({
    super.key,
    required this.events,
    required this.cameraName,
    required this.notificationsEnabled,
    required this.child,
    this.now,
    this.minInterval = const Duration(seconds: 10),
  });

  final Stream<MotionEvent> events;

  /// Name of a known camera, or null for an unknown id.
  final String? Function(String cameraId) cameraName;
  final bool Function() notificationsEnabled;
  final Widget child;

  /// Clock seam (local time). Defaults to DateTime.now.
  final DateTime Function()? now;
  final Duration minInterval;

  @override
  State<MotionToastHost> createState() => _MotionToastHostState();
}

class _MotionToastHostState extends State<MotionToastHost> {
  @override
  Widget build(BuildContext context) => widget.child; // RED stub: never shows a toast
}