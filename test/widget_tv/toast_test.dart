// ui.toast.motion: showToast (existing) and the motion toast (new)
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/state/camera_actions.dart';
import 'package:tapo_tv/ui/motion_pip_toast.dart';
import 'package:tapo_tv/ui/theme.dart';
import 'package:tapo_tv/ui/tv.dart';

import 'support.dart';

void main() {
  group('showToast (existing)', () {
    testWidgets('is anchored top 27 right 48 with max width 440', (tester) async {
      await pumpApp(tester);
      showToast(appContext(tester), 'A fairly long message ' * 8);
      await tester.pump(const Duration(milliseconds: 300));
      final box = find.ancestor(of: find.textContaining('A fairly long'), matching: find.byType(Container)).first;
      final rect = tester.getRect(box);
      expect(rect.top, 27);
      expect(rect.right, 912);
      expect(rect.width, lessThanOrEqualTo(440));
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('disappears after about 3.2 s', (tester) async {
      await pumpApp(tester);
      showToast(appContext(tester), 'Short lived');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Short lived'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 2700)); // 3.0 s
      expect(find.text('Short lived'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 900)); // 3.9 s
      expect(find.text('Short lived'), findsNothing);
    });

    testWidgets('only one toast at a time: a new one replaces the last', (tester) async {
      await pumpApp(tester);
      showToast(appContext(tester), 'First');
      await tester.pump(const Duration(milliseconds: 100));
      showToast(appContext(tester), 'Second');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('First'), findsNothing);
      expect(find.text('Second'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('is a live region for screen readers', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpApp(tester);
      showToast(appContext(tester), 'Announce me');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.ancestor(of: find.text('Announce me'), matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.liveRegion == true)), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      handle.dispose();
    });

    testWidgets('never takes focus and never blocks keys', (tester) async {
      await pumpApp(tester);
      await focusOn(tester, find.text('Home Camera B'));
      final before = FocusManager.instance.primaryFocus;
      showToast(appContext(tester), 'Hello');
      await tester.pump(const Duration(milliseconds: 300));
      expect(FocusManager.instance.primaryFocus, same(before));
      await ok(tester);
      expect(find.text('Camera 2 of 5'), findsOneWidget, reason: 'OK still reached the focused card');
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('NEW motion toast', () {
    Future<StreamController<MotionEvent>> pumpHost(
      WidgetTester tester, {
      required DateTime Function() now,
      bool enabled = true,
      Map<String, String> known = const {'cam-a': 'Home Camera A', 'cam-b': 'Home Camera B'},
    }) async {
      await tester.runAsync(loadTestFonts);
      useTvSurface(tester);
      final events = StreamController<MotionEvent>.broadcast();
      addTearDown(events.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: MotionToastHost(
            events: events.stream,
            cameraName: (id) => known[id],
            notificationsEnabled: () => enabled,
            now: now,
            child: Scaffold(body: Center(child: TvButton(label: 'Focused', autofocus: true, onPressed: () {}))),
          ),
        ),
      );
      await tester.pump();
      return events;
    }

    MotionEvent motion(String id, {bool active = true}) => MotionEvent(cameraId: id, active: active, time: DateTime.utc(2026, 1, 1));

    testWidgets('an active event shows "<camera>: Motion at HH:MM:SS" at top 27 right 48', (tester) async {
      final events = await pumpHost(tester, now: () => DateTime(2026, 5, 4, 14, 3, 9));
      events.add(motion('cam-a'));
      await tester.pump(const Duration(milliseconds: 400));
      final text = find.text('Home Camera A: Motion at 14:03:09');
      expect(text, findsOneWidget);
      final rect = tester.getRect(find.ancestor(of: text, matching: find.byType(Container)).first);
      expect(rect.top, 27);
      expect(rect.right, 912);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('the toast disappears after about 3.2 s', (tester) async {
      final events = await pumpHost(tester, now: () => DateTime(2026, 5, 4, 14, 3, 9));
      events.add(motion('cam-a'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Motion at'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(find.textContaining('Motion at'), findsNothing);
    });

    testWidgets('a second event for the same camera within the interval is suppressed', (tester) async {
      var clock = DateTime(2026, 5, 4, 14, 0, 0);
      final events = await pumpHost(tester, now: () => clock);
      events.add(motion('cam-a'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('14:00:00'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      clock = DateTime(2026, 5, 4, 14, 0, 5);
      events.add(motion('cam-a'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Motion at'), findsNothing);
      clock = DateTime(2026, 5, 4, 14, 0, 11);
      events.add(motion('cam-a'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Home Camera A: Motion at 14:00:11'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('the notifications setting off suppresses the toast', (tester) async {
      final events = await pumpHost(tester, now: () => DateTime(2026, 5, 4, 14, 0, 0), enabled: false);
      events.add(motion('cam-a'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Motion at'), findsNothing);
    });

    testWidgets('an inactive event shows nothing, a later active one does', (tester) async {
      final events = await pumpHost(tester, now: () => DateTime(2026, 5, 4, 14, 0, 0));
      events.add(motion('cam-a', active: false));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Motion at'), findsNothing);
      events.add(motion('cam-a'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Motion at'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('the toast does not steal focus; the focused widget stays focused', (tester) async {
      final events = await pumpHost(tester, now: () => DateTime(2026, 5, 4, 14, 0, 0));
      final before = FocusManager.instance.primaryFocus;
      expect(before, isNotNull);
      events.add(motion('cam-a'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Motion at'), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, same(before));
      await tester.pump(const Duration(seconds: 4));
    });
  });
}