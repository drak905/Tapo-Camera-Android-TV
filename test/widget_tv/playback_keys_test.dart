// ui.recordings.player_keys (new) - the playing mode of VodTimelineScreen
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/screens/vod_timeline_screen.dart';
import 'package:tapo_tv/state/camera_actions.dart';
import 'package:tapo_tv/ui/tv.dart';

import 'recordings_support.dart';
import 'support.dart';

Future<(FakeCameraActions, FakePlayback)> _playing(WidgetTester tester, {Map<String, List<RecordingClip>>? days}) async {
  final fake = await openRecordings(tester, days: days);
  final player = await startPlayback(tester, fake);
  return (fake, player);
}

void main() {
  testWidgets('playback shows the video and the local playback time', (tester) async {
    final (_, player) = await _playing(tester);
    expect(find.byKey(const ValueKey('fake-video')), findsOneWidget);
    expect(text(tester, 'playback-time'), '08:00:00');
    player.emit(player.state.value.copyWith(position: local(4, 8, 4, 30).toUtc()));
    await tester.pump(const Duration(milliseconds: 100));
    expect(text(tester, 'playback-time'), '08:04:30');
  });

  group('OK shows the controls (play/pause and speed menu)', () {
    testWidgets('select shows the controls with the Pause button focused', (tester) async {
      await _playing(tester);
      await ok(tester);
      expect(focusedText(tester), 'Pause');
      for (final s in ['1x', '2x', '4x', '8x']) {
        expect(tvChip(s), findsOneWidget);
      }
    });

    testWidgets('select on the focused Pause button toggles pause on the player', (tester) async {
      final (_, player) = await _playing(tester);
      await ok(tester);
      await ok(tester);
      expect(player.pauses, 1);
      expect(focusedText(tester), 'Play');
      await ok(tester);
      expect(player.resumes, 1);
    });

    testWidgets('selecting a speed chip changes the player speed', (tester) async {
      final (_, player) = await _playing(tester);
      await ok(tester);
      await focusOn(tester, tvChip('4x'));
      await ok(tester);
      expect(player.speeds, [4]);
      expect(tester.widget<TvChip>(tvChip('4x')).selected, isTrue);
      expect(tester.widget<TvChip>(tvChip('1x')).selected, isFalse);
    });

    testWidgets('the controls are reachable with the D-pad and stay in the safe area', (tester) async {
      await _playing(tester);
      await ok(tester);
      final seen = <String?>{focusedText(tester)};
      for (var i = 0; i < 8; i++) {
        await arrow(tester, LogicalKeyboardKey.arrowRight);
        seen.add(focusedText(tester));
        final r = FocusManager.instance.primaryFocus!.rect;
        expect(safeRect.contains(r.topLeft) && safeRect.contains(r.bottomRight), isTrue, reason: '$r');
      }
      expect(seen, containsAll(['Pause', '1x', '2x', '4x', '8x']));
    });
  });

  group('keys with the controls hidden', () {
    testWidgets('mediaPlayPause toggles pause and resume', (tester) async {
      final (_, player) = await _playing(tester);
      await key(tester, LogicalKeyboardKey.mediaPlayPause);
      expect(player.pauses, 1);
      await key(tester, LogicalKeyboardKey.mediaPlayPause);
      expect(player.resumes, 1);
    });

    testWidgets('ArrowRight seeks +10 s and ArrowLeft -10 s', (tester) async {
      final (_, player) = await _playing(tester);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(player.seeks.last, local(4, 8, 0, 10).toUtc());
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(player.seeks.last, local(4, 8, 0, 20).toUtc());
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(player.seeks.last, local(4, 8, 0, 10).toUtc());
    });

    testWidgets('mediaFastForward and mediaRewind seek like Right and Left', (tester) async {
      final (_, player) = await _playing(tester, days: {'2026-05-04': [fullDay(4)]});
      await key(tester, LogicalKeyboardKey.mediaFastForward);
      expect(player.seeks.last, local(4, 0, 0, 10).toUtc());
      await key(tester, LogicalKeyboardKey.mediaFastForward);
      await key(tester, LogicalKeyboardKey.mediaRewind);
      expect(player.seeks.last, local(4, 0, 0, 10).toUtc());
    });

    testWidgets('CH+ jumps to the next clip and CH- to the previous one', (tester) async {
      final (_, player) = await _playing(tester);
      await key(tester, LogicalKeyboardKey.channelUp);
      expect(player.seeks.last, local(4, 10).toUtc());
      await key(tester, LogicalKeyboardKey.channelDown);
      expect(player.seeks.last, local(4, 8).toUtc());
    });

    testWidgets('ArrowDown shows the timeline overlay; day change is disabled while playing', (tester) async {
      final (fake, _) = await _playing(tester);
      final before = fake.clipRequests.length;
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(find.byKey(const ValueKey('timeline-bar')), findsOneWidget);
      expect(dayLabel(tester), '2026-05-04');
      expect(fake.clipRequests, hasLength(before));
      expect(find.byKey(const ValueKey('fake-video')), findsOneWidget, reason: 'still playing');
    });
  });

  group('leaving', () {
    testWidgets('end of recordings returns to the timeline and stops the player', (tester) async {
      final (_, player) = await _playing(tester);
      player.emit(player.state.value.copyWith(ended: true));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('timeline-bar')), findsOneWidget);
      expect(find.byKey(const ValueKey('fake-video')), findsNothing);
      expect(player.stops, 1);
      expect(find.byType(VodTimelineScreen), findsOneWidget);
    });

    testWidgets('Back hides the controls, then returns to the timeline, then pops', (tester) async {
      final (_, player) = await _playing(tester);
      await ok(tester);
      await back(tester);
      expect(find.byKey(const ValueKey('fake-video')), findsOneWidget, reason: 'first Back only hides the controls');
      expect(tvChip('2x'), findsNothing);
      await back(tester);
      expect(find.byKey(const ValueKey('fake-video')), findsNothing);
      expect(find.byKey(const ValueKey('timeline-bar')), findsOneWidget);
      expect(player.stops, 1);
      await back(tester);
      expect(find.byType(VodTimelineScreen), findsNothing);
    });

    testWidgets('leaving the screen while playing stops the player', (tester) async {
      final (_, player) = await _playing(tester);
      await back(tester);
      await back(tester);
      expect(player.stops, greaterThanOrEqualTo(1));
    });
  });
}
