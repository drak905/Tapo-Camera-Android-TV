import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/camera_actions.dart';

/// Builds the video surface of a running playback (tests inject a fake).
typedef PlaybackVideoBuilder = Widget Function(BuildContext context, PlaybackControl control);

/// SD-card recordings of one camera: 24 h timeline (Left/Right scrub, Up =
/// later day, Down = earlier day, OK plays) and the playback view (OK shows
/// controls with speed chips, Back returns to the timeline, then pops).
class VodTimelineScreen extends StatefulWidget {
  const VodTimelineScreen({super.key, required this.camera, this.actions, this.videoBuilder, this.now});
  final Camera camera;

  /// Defaults to AppState.actions.
  final CameraActions? actions;
  final PlaybackVideoBuilder? videoBuilder;

  /// Clock seam (local time). Defaults to DateTime.now.
  final DateTime Function()? now;

  @override
  State<VodTimelineScreen> createState() => _VodTimelineScreenState();
}

class _VodTimelineScreenState extends State<VodTimelineScreen> {
  @override
  Widget build(BuildContext context) => throw UnimplementedError('ui lane GREEN: VodTimelineScreen');
}