import 'package:flutter/material.dart';

import '../state/camera_actions.dart';

typedef LocalMidnight = DateTime Function(int year, int month, int day);

/// Local midnight to next local midnight of the day containing [day].
/// 24 h normally, 23/25 h on DST days. [midnightOf] is a test seam.
({DateTime start, DateTime end}) localDayRange(DateTime day, {LocalMidnight? midnightOf}) =>
    throw UnimplementedError('ui lane GREEN: localDayRange');

/// Maps x (0..width) on the timeline bar to a UTC instant, clamped to the day.
DateTime timelineXToUtc(double x, double width, ({DateTime start, DateTime end}) day) =>
    throw UnimplementedError('ui lane GREEN: timelineXToUtc');

/// Moves [target] to the start of the next clip when it falls in a gap.
DateTime snapToClips(DateTime target, List<RecordingClip> clips) =>
    throw UnimplementedError('ui lane GREEN: snapToClips');

/// The 24 h bar with recorded segments, hour ticks and the cursor.
class DayTimeline extends StatelessWidget {
  const DayTimeline({super.key, required this.day, required this.clips, required this.cursor});
  final ({DateTime start, DateTime end}) day;
  final List<RecordingClip> clips;
  final DateTime cursor;

  @override
  Widget build(BuildContext context) => throw UnimplementedError('ui lane GREEN: DayTimeline');
}