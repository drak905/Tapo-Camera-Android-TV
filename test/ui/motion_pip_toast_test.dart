// ev.ui.motion_toast (new): policy of the motion toast
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/state/camera_actions.dart';
import 'package:tapo_tv/ui/motion_pip_toast.dart';

MotionEvent _event(String id, {bool active = true}) => MotionEvent(cameraId: id, active: active, time: DateTime.utc(2026, 1, 1));

Future<StreamController<MotionEvent>> _host(
  WidgetTester tester, {
  required DateTime Function() now,
  bool Function()? enabled,
  Map<String, String> known = const {'cam-a': 'Home Camera A', 'cam-b': 'Home Camera B'},
}) async {
  tester.view.physicalSize = const Size(960, 540);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final events = StreamController<MotionEvent>.broadcast();
  addTearDown(events.close);
  await tester.pumpWidget(
    MaterialApp(
      home: MotionToastHost(
        events: events.stream,
        cameraName: (id) => known[id],
        notificationsEnabled: enabled ?? () => true,
        now: now,
        child: const Scaffold(body: SizedBox.expand()),
      ),
    ),
  );
  await tester.pump();
  return events;
}

Finder get _toast => find.textContaining('Motion');

void main() {
  testWidgets('an active event of a known camera shows a toast', (tester) async {
    final events = await _host(tester, now: () => DateTime(2026, 2, 3, 9, 8, 7));
    events.add(_event('cam-a'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Home Camera A: Motion at 09:08:07'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('an inactive event never shows (control: an active one does)', (tester) async {
    final events = await _host(tester, now: () => DateTime(2026, 2, 3, 9, 8, 7));
    events.add(_event('cam-a', active: false));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_toast, findsNothing);
    events.add(_event('cam-b'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_toast, findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('throttled to one per camera per 10 s, other cameras are independent', (tester) async {
    var clock = DateTime(2026, 2, 3, 9, 0, 0);
    final events = await _host(tester, now: () => clock);
    events.add(_event('cam-a'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Home Camera A'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    clock = DateTime(2026, 2, 3, 9, 0, 9);
    events.add(_event('cam-a'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_toast, findsNothing, reason: '9 s after the first');
    events.add(_event('cam-b'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Home Camera B'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    clock = DateTime(2026, 2, 3, 9, 0, 10);
    events.add(_event('cam-a'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Home Camera A'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('the notifications setting off shows nothing', (tester) async {
    var enabled = false;
    final events = await _host(tester, now: () => DateTime(2026, 2, 3, 9, 0, 0), enabled: () => enabled);
    events.add(_event('cam-a'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_toast, findsNothing);
    enabled = true;
    events.add(_event('cam-b'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_toast, findsOneWidget, reason: 'the setting is read per event');
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('an unknown camera id is ignored (control: a known one shows)', (tester) async {
    final events = await _host(tester, now: () => DateTime(2026, 2, 3, 9, 0, 0));
    events.add(_event('stranger'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_toast, findsNothing);
    events.add(_event('cam-a'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_toast, findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });
}