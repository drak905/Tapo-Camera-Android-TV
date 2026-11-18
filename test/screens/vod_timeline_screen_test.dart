// vod.ui.day_timeline (new): pure helpers and screen behaviour
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/state/camera_actions.dart';
import 'package:tapo_tv/ui/day_timeline.dart';

import '../widget_tv/recordings_support.dart';
import '../widget_tv/support.dart';

void main() {
  group('local day range', () {
    test('is 24 h on a normal day, midnight to midnight local', () {
      final r = localDayRange(DateTime(2026, 5, 4, 13, 30));
      expect(r.start, DateTime(2026, 5, 4));
      expect(r.end, DateTime(2026, 5, 5));
      expect(r.end.difference(r.start), DateTime(2026, 5, 5).difference(DateTime(2026, 5, 4)));
    });

    test('is 23 h on a spring-forward day (seam simulates a UTC-5/-4 zone)', () {
      DateTime midnight(int y, int m, int d) => d == 8 ? DateTime.utc(y, m, d, 5) : DateTime.utc(y, m, d, 4);
      final r = localDayRange(DateTime.utc(2026, 3, 8, 12), midnightOf: midnight);
      expect(r.end.difference(r.start), const Duration(hours: 23));
    });

    test('is 25 h on a fall-back day', () {
      DateTime midnight(int y, int m, int d) => d == 1 ? DateTime.utc(y, m, d, 4) : DateTime.utc(y, m, d, 5);
      final r = localDayRange(DateTime.utc(2026, 11, 1, 12), midnightOf: midnight);
      expect(r.end.difference(r.start), const Duration(hours: 25));
    });
  });

  group('x to UTC mapping', () {
    final day = (start: DateTime.utc(2026, 5, 4), end: DateTime.utc(2026, 5, 5));

    test('maps the bar linearly and clamps to the day', () {
      expect(timelineXToUtc(0, 800, day), day.start);
      expect(timelineXToUtc(800, 800, day), day.end);
      expect(timelineXToUtc(400, 800, day), DateTime.utc(2026, 5, 4, 12));
      expect(timelineXToUtc(-50, 800, day), day.start);
      expect(timelineXToUtc(1000, 800, day), day.end);
    });

    test('a 23 h day spans the full width', () {
      final short = (start: DateTime.utc(2026, 3, 8, 5), end: DateTime.utc(2026, 3, 9, 4));
      expect(timelineXToUtc(800, 800, short), short.end);
      expect(timelineXToUtc(400, 800, short), short.start.add(const Duration(hours: 11, minutes: 30)));
    });
  });

  group('snapToClips', () {
    final clips = [clipOf(local(4, 8), local(4, 9)), clipOf(local(4, 10), local(4, 11))];

    test('a time inside a clip stays', () => expect(snapToClips(local(4, 8, 30).toUtc(), clips), local(4, 8, 30).toUtc()));
    test('a time in a gap moves to the next clip start', () => expect(snapToClips(local(4, 9, 30).toUtc(), clips), local(4, 10).toUtc()));
    test('before the first clip moves to its start', () => expect(snapToClips(local(4, 6).toUtc(), clips), local(4, 8).toUtc()));
    test('after the last clip moves to its end', () => expect(snapToClips(local(4, 12).toUtc(), clips), local(4, 11).toUtc()));
  });

  group('screen', () {
    testWidgets('a day change reloads clips and starts at the first clip', (tester) async {
      final days = {
        ...twoSegmentsToday(),
        '2026-05-03': [clipOf(local(3, 6, 15), local(3, 7))],
      };
      final fake = await openRecordings(tester, days: days);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 300));
      expect(fake.clipRequests.last.$2, local(3, 0).toUtc());
      expect(cursorLabel(tester), '06:15:00');
      await ok(tester);
      expect(fake.playbackRequests.single.$2, local(3, 6, 15).toUtc());
    });

    testWidgets('an empty day shows the no-recordings message', (tester) async {
      await openRecordings(tester, days: {'2026-05-04': const []});
      expect(find.text('No recordings on this day'), findsOneWidget);
    });

    testWidgets('D-pad seek while playing calls seek with a snapped time', (tester) async {
      final days = {
        '2026-05-04': [clipOf(local(4, 8), local(4, 8, 30)), clipOf(local(4, 9), local(4, 10))],
      };
      final fake = await openRecordings(tester, days: days);
      final player = await startPlayback(tester, fake);
      player.emit(PlaybackState(position: local(4, 8, 29, 55).toUtc()));
      await tester.pump(const Duration(milliseconds: 100));
      await key(tester, LogicalKeyboardKey.arrowRight); // +10 s lands in the gap
      expect(player.seeks.last, local(4, 9).toUtc());
      expect(find.byKey(const ValueKey('fake-video')), findsOneWidget);
    });

    testWidgets('the event type of a clip is shown as text, not colour alone', (tester) async {
      await openRecordings(tester, days: {
        '2026-05-04': [clipOf(local(4, 8), local(4, 9), type: 2), clipOf(local(4, 10), local(4, 11), type: 6)],
      });
      expect(find.text('Motion'), findsOneWidget);
      expect(find.text('Person'), findsOneWidget);
    });
  });
}
