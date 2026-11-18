import 'package:flutter/material.dart';

import '../state/camera_actions.dart';
import 'theme.dart';

typedef LocalMidnight = DateTime Function(int year, int month, int day);

DateTime _defaultMidnight(int year, int month, int day) => DateTime(year, month, day);

/// Local midnight to next local midnight of the day containing [day].
/// 24 h normally, 23/25 h on DST days. [midnightOf] is a test seam.
({DateTime start, DateTime end}) localDayRange(DateTime day, {LocalMidnight? midnightOf}) {
  final midnight = midnightOf ?? _defaultMidnight;
  final next = DateTime.utc(day.year, day.month, day.day + 1); // calendar arithmetic only
  return (start: midnight(day.year, day.month, day.day), end: midnight(next.year, next.month, next.day));
}

/// Maps x (0..width) on the timeline bar to a UTC instant, clamped to the day.
DateTime timelineXToUtc(double x, double width, ({DateTime start, DateTime end}) day) {
  if (width <= 0 || x <= 0) return day.start;
  if (x >= width) return day.end;
  final span = day.end.difference(day.start).inMicroseconds;
  return day.start.add(Duration(microseconds: (span * (x / width)).round()));
}

/// Moves [target] to the start of the next clip when it falls in a gap.
/// Before the first clip: its start. After the last clip: its end.
DateTime snapToClips(DateTime target, List<RecordingClip> clips) {
  if (clips.isEmpty) return target;
  final sorted = [...clips]..sort((a, b) => a.start.compareTo(b.start));
  for (final c in sorted) {
    if (!target.isBefore(c.start) && target.isBefore(c.end)) return target;
    if (target.isBefore(c.start)) return c.start;
  }
  return sorted.map((c) => c.end).reduce((a, b) => a.isAfter(b) ? a : b);
}

/// Short text name of a clip's event type (never colour alone).
String eventTypeName(int type) => switch (type) {
      2 => 'Motion',
      6 => 'Person',
      8 => 'Vehicle',
      9 => 'Pet',
      _ => 'Continuous',
    };

Color eventTypeColor(int type) => switch (type) {
      2 => const Color(0xFFE08A00),
      6 => const Color(0xFF7B3FC4),
      8 => const Color(0xFF147D52),
      9 => const Color(0xFFC2185B),
      _ => TopoColors.primaryAction,
    };

/// The 24 h bar with recorded segments, hour ticks and the cursor.
class DayTimeline extends StatelessWidget {
  const DayTimeline({super.key, required this.day, required this.clips, required this.cursor});
  final ({DateTime start, DateTime end}) day;
  final List<RecordingClip> clips;
  final DateTime cursor;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          key: const ValueKey('timeline-bar'),
          height: 40,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(TopoRadius.sm),
            child: CustomPaint(painter: _BarPainter(day: day, clips: clips, cursor: cursor)),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final h in const ['00', '06', '12', '18', '24']) Text(h, style: TopoText.caption.copyWith(fontSize: 14)),
          ],
        ),
      ],
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({required this.day, required this.clips, required this.cursor});
  final ({DateTime start, DateTime end}) day;
  final List<RecordingClip> clips;
  final DateTime cursor;

  double _x(DateTime t, double w) {
    final span = day.end.difference(day.start).inMicroseconds;
    if (span <= 0) return 0;
    return (w * t.difference(day.start).inMicroseconds / span).clamp(0.0, w);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = TopoColors.surfaceSelected);
    for (final c in clips) {
      final l = _x(c.start, size.width), r = _x(c.end, size.width);
      canvas.drawRect(Rect.fromLTRB(l, 0, r < l + 2 ? l + 2 : r, size.height), Paint()..color = eventTypeColor(c.eventType));
    }
    final tick = Paint()
      ..color = const Color(0x66000000)
      ..strokeWidth = 1;
    for (var i = 1; i < 24; i++) {
      final x = size.width * i / 24;
      canvas.drawLine(Offset(x, size.height - (i % 6 == 0 ? 14 : 7)), Offset(x, size.height), tick);
    }
    final cx = _x(cursor, size.width);
    canvas.drawRect(Rect.fromLTWH((cx - 2).clamp(0.0, size.width - 4), 0, 4, size.height), Paint()..color = Colors.black);
  }

  @override
  bool shouldRepaint(_BarPainter old) => old.day != day || old.clips != clips || old.cursor != cursor;
}
