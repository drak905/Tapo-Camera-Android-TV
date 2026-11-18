// ui.home.camera_grid_cards (existing behaviour)
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/screens/live_screen.dart';

import 'support.dart';

int _liveIndex(WidgetTester tester) => tester.widget<LiveScreen>(find.byType(LiveScreen)).initialIndex;

void main() {
  testWidgets('digit3 pushes LiveScreen(initialIndex 2)', (tester) async {
    await pumpApp(tester);
    await key(tester, LogicalKeyboardKey.digit3);
    expect(find.byType(LiveScreen), findsOneWidget);
    expect(_liveIndex(tester), 2);
  });

  testWidgets('digit9 with 5 cameras does nothing', (tester) async {
    await pumpApp(tester);
    await key(tester, LogicalKeyboardKey.digit9);
    expect(find.byType(LiveScreen), findsNothing);
  });

  testWidgets('numpad1 behaves like digit1', (tester) async {
    await pumpApp(tester);
    await key(tester, LogicalKeyboardKey.numpad1);
    expect(_liveIndex(tester), 0);
  });

  testWidgets('select on a card pushes LiveScreen with that index', (tester) async {
    await pumpApp(tester);
    await focusOn(tester, find.text('Home Camera B'));
    await ok(tester);
    expect(find.byType(LiveScreen), findsOneWidget);
    expect(_liveIndex(tester), 1);
  });

  testWidgets('the camera grid has 3 columns at 960x540', (tester) async {
    await pumpApp(tester);
    final a = tester.getTopLeft(find.text('Home Camera A'));
    final b = tester.getTopLeft(find.text('Home Camera B'));
    final c = tester.getTopLeft(find.text('Home Camera C'));
    expect(a.dy, b.dy);
    expect(b.dy, c.dy);
    expect(a.dx < b.dx && b.dx < c.dx, isTrue);
    final cardA = find.ancestor(of: find.text('Home Camera A'), matching: find.byType(AnimatedContainer)).first;
    final cardB = find.ancestor(of: find.text('Home Camera B'), matching: find.byType(AnimatedContainer)).first;
    final w = tester.getSize(cardA);
    expect(tester.getTopLeft(cardB).dx - tester.getTopLeft(cardA).dx, closeTo(w.width + 20, 0.5));
    // aspect ratio 1.25
    expect(w.width / w.height, closeTo(1.25, 0.01));
  });

  testWidgets('cards are numbered 1..n', (tester) async {
    await pumpApp(tester);
    for (final n in ['1', '2', '3']) {
      expect(find.text(n), findsWidgets);
    }
  });

  testWidgets('a camera with privacy on shows the placeholder, not a stream', (tester) async {
    await pumpApp(tester, cameras: [plainCam('a', 'Home Camera A', privacy: true)]);
    expect(find.text('Privacy mode on'), findsOneWidget);
  });
}