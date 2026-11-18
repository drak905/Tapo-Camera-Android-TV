// ui.recordings.screen (new) - the timeline mode of VodTimelineScreen
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/screens/vod_timeline_screen.dart';
import 'package:tapo_tv/state/camera_actions.dart';
import 'package:tapo_tv/ui/tv.dart';

import 'recordings_support.dart';
import 'support.dart';

void main() {
  group('layout', () {
    testWidgets('shows the day label, the 24 h bar and the cursor time', (tester) async {
      await openRecordings(tester);
      expect(dayLabel(tester), '2026-05-04');
      expect(find.byKey(const ValueKey('timeline-bar')), findsOneWidget);
      expect(cursorLabel(tester), '08:00:00', reason: 'the cursor starts at the first clip');
    });

    testWidgets('lists the clips as "HH:MM:SS - HH:MM:SS" local times', (tester) async {
      await openRecordings(tester);
      expect(find.text('08:00:00 - 08:10:00'), findsOneWidget);
      expect(find.text('10:00:00 - 11:00:00'), findsOneWidget);
    });

    testWidgets('requests exactly the local day (midnight to midnight, UTC)', (tester) async {
      final fake = await openRecordings(tester);
      expect(fake.clipRequests, hasLength(1));
      final (id, from, to) = fake.clipRequests.single;
      expect(id, 'cam-a');
      expect(from, local(4, 0).toUtc());
      expect(to, local(5, 0).toUtc());
    });

    testWidgets('timeline is inside tvSafePadding', (tester) async {
      await openRecordings(tester);
      final bar = tester.getRect(find.byKey(const ValueKey('timeline-bar')));
      expect(bar.left, greaterThanOrEqualTo(safeRect.left));
      expect(bar.right, lessThanOrEqualTo(safeRect.right));
      expect(bar.top, greaterThanOrEqualTo(safeRect.top));
      expect(bar.bottom, lessThanOrEqualTo(safeRect.bottom));
    });

    testWidgets('a camera without an SD card shows "No SD card" and loads nothing', (tester) async {
      final fake = await openRecordings(tester, camera: viewCam('cam-a', 'Home Camera A'));
      expect(find.text('No SD card'), findsOneWidget);
      expect(fake.clipRequests, isEmpty);
    });
  });

  group('scrubbing', () {
    testWidgets('ArrowRight KeyDown moves the cursor +1 minute, ArrowLeft -1 minute', (tester) async {
      await openRecordings(tester);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(cursorLabel(tester), '08:01:00');
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(cursorLabel(tester), '08:00:00');
    });

    testWidgets('KeyRepeat accelerates: +5 min for the first repeats, +15 min after four', (tester) async {
      await openRecordings(tester, days: {'2026-05-04': [fullDay(4)]});
      await keyDown(tester, LogicalKeyboardKey.arrowRight);
      expect(cursorLabel(tester), '00:01:00');
      for (final label in ['00:06:00', '00:11:00', '00:16:00', '00:31:00', '00:46:00']) {
        await keyRepeat(tester, LogicalKeyboardKey.arrowRight);
        expect(cursorLabel(tester), label);
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    });

    testWidgets('ArrowLeft clamps at 00:00:00', (tester) async {
      await openRecordings(tester, days: {'2026-05-04': [fullDay(4)]});
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(cursorLabel(tester), '00:00:00');
    });

    testWidgets('ArrowRight clamps at 24:00:00', (tester) async {
      await openRecordings(tester, days: {'2026-05-04': [fullDay(4)]});
      await keyDown(tester, LogicalKeyboardKey.arrowRight);
      for (var i = 0; i < 120; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      }
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 100));
      expect(cursorLabel(tester), '24:00:00');
    });

    testWidgets('CH+ / CH- jump to the next and previous segment start', (tester) async {
      await openRecordings(tester);
      await key(tester, LogicalKeyboardKey.channelUp);
      expect(cursorLabel(tester), '10:00:00');
      await key(tester, LogicalKeyboardKey.channelDown);
      expect(cursorLabel(tester), '08:00:00');
      await key(tester, LogicalKeyboardKey.mediaTrackNext);
      expect(cursorLabel(tester), '10:00:00');
      await key(tester, LogicalKeyboardKey.mediaTrackPrevious);
      expect(cursorLabel(tester), '08:00:00');
    });
  });

  group('days', () {
    testWidgets('ArrowDown goes to the earlier day and reloads its clips', (tester) async {
      final days = {
        ...twoSegmentsToday(),
        '2026-05-03': [clipOf(local(3, 7, 30), local(3, 8))],
      };
      final fake = await openRecordings(tester, days: days);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 300));
      expect(dayLabel(tester), '2026-05-03');
      expect(fake.clipRequests.last.$2, local(3, 0).toUtc());
      expect(cursorLabel(tester), '07:30:00', reason: 'a changed day starts at its first clip');
      expect(find.text('07:30:00 - 08:00:00'), findsOneWidget);
    });

    testWidgets('ArrowUp goes to the later day, capped at tomorrow', (tester) async {
      final fake = await openRecordings(tester);
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(dayLabel(tester), '2026-05-05');
      expect(fake.clipRequests, hasLength(2));
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(dayLabel(tester), '2026-05-05', reason: 'later than tomorrow is refused');
      expect(fake.clipRequests, hasLength(2), reason: 'a refused day does not reload');
    });

    testWidgets('an empty day shows "No recordings on this day"', (tester) async {
      await openRecordings(tester, days: {});
      expect(find.text('No recordings on this day'), findsOneWidget);
      expect(cursorLabel(tester), '00:00:00');
    });

    testWidgets('select on an empty day plays nothing', (tester) async {
      final fake = await openRecordings(tester, days: {});
      await ok(tester);
      expect(fake.playbackRequests, isEmpty);
    });
  });

  group('playing', () {
    testWidgets('select inside a segment starts playback at that time until the end of the day', (tester) async {
      final fake = await openRecordings(tester);
      for (var i = 0; i < 5; i++) {
        await key(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(cursorLabel(tester), '08:05:00');
      await ok(tester);
      await tester.pump(const Duration(milliseconds: 300));
      final (id, start, end) = fake.playbackRequests.single;
      expect(id, 'cam-a');
      expect(start, local(4, 8, 5).toUtc());
      expect(end, local(5, 0).toUtc());
      expect(find.byKey(const ValueKey('fake-video')), findsOneWidget);
    });

    testWidgets('select in a gap jumps to the next segment', (tester) async {
      final fake = await openRecordings(tester);
      for (var i = 0; i < 15; i++) {
        await key(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(cursorLabel(tester), '08:15:00');
      await ok(tester);
      expect(fake.playbackRequests.single.$2, local(4, 10).toUtc());
    });

    testWidgets('select after the last segment starts nothing', (tester) async {
      final fake = await openRecordings(tester, days: {'2026-05-04': [clipOf(local(4, 8), local(4, 8, 10))]});
      for (var i = 0; i < 20; i++) {
        await key(tester, LogicalKeyboardKey.arrowRight);
      }
      await ok(tester);
      expect(fake.playbackRequests, isEmpty);
    });
  });

  group('errors', () {
    testWidgets('a load error shows the message and a Reload button; one retry per press', (tester) async {
      final fake = FakeCameraActions();
      var fail = true;
      fake.clipLoader = (id, from, to) async {
        if (fail) throw const CameraActionException('network down');
        return [clipOf(local(4, 8), local(4, 9))];
      };
      await openRecordings(tester, actions: fake);
      expect(find.text('Could not load recordings: network down'), findsOneWidget);
      expect(tvButton('Reload'), findsOneWidget);
      expect(fake.clipRequests, hasLength(1), reason: 'no automatic retry loop');
      fail = false;
      await focusOn(tester, tvButton('Reload'));
      await ok(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(fake.clipRequests, hasLength(2));
      expect(find.text('08:00:00 - 09:00:00'), findsOneWidget);
      expect(find.text('Could not load recordings: network down'), findsNothing);
    });

    testWidgets('Reload is the focused item on the error state (D-pad reachable)', (tester) async {
      final fake = FakeCameraActions()..clipLoader = (id, from, to) async => throw const CameraActionException('boom');
      await openRecordings(tester, actions: fake);
      expect(focusedText(tester), 'Reload');
    });
  });

  group('Back', () {
    testWidgets('Back pops to the caller', (tester) async {
      await openRecordings(tester);
      await back(tester);
      expect(find.byType(VodTimelineScreen), findsNothing);
      expect(find.byType(TvButton), findsWidgets, reason: 'the home page is back');
    });
  });
}
