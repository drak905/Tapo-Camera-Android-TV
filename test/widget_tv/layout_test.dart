// ui.layout.canvas_960x540 (existing) and ui.layout.new_screens_safe_area (new screens fail until built)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/screens/rename_dialog.dart';
import 'package:tapo_tv/screens/vod_timeline_screen.dart';
import 'package:tapo_tv/state/camera_view_model.dart';
import 'package:tapo_tv/ui/theme.dart';
import 'package:tapo_tv/ui/tv.dart';

import 'support.dart';

void expectInsideSafeArea(WidgetTester tester, {bool checkBottom = false, bool allowNone = false}) {
  final rects = focusableRects(tester);
  if (!allowNone) expect(rects, isNotEmpty, reason: 'screen has no focusable item');
  for (final r in rects) {
    expect(r.left, greaterThanOrEqualTo(safeRect.left), reason: 'left of $r');
    expect(r.right, lessThanOrEqualTo(safeRect.right), reason: 'right of $r');
    expect(r.top, greaterThanOrEqualTo(safeRect.top), reason: 'top of $r');
    if (checkBottom && r.top < tvSize.height) {
      expect(r.bottom, lessThanOrEqualTo(safeRect.bottom), reason: 'bottom of $r');
    }
  }
}

void main() {
  test('tvSafePadding is 48 x 27', () {
    expect(tvSafePadding.left, 48);
    expect(tvSafePadding.right, 48);
    expect(tvSafePadding.top, 27);
    expect(tvSafePadding.bottom, 27);
  });

  testWidgets('HomeScreen content stays inside 48..912 x 27..513 at 960x540', (tester) async {
    await pumpApp(tester, cameras: [plainCam('a', 'Home Camera A'), plainCam('b', 'Home Camera B'), plainCam('c', 'Home Camera C')]);
    expect(tester.view.physicalSize, tvSize);
    expect(tester.view.devicePixelRatio, 1.0);
    expectInsideSafeArea(tester, checkBottom: true);
  });

  testWidgets('toast anchored top 27 right 48', (tester) async {
    await pumpApp(tester);
    showToast(appContext(tester), 'Hello toast');
    await tester.pump(const Duration(milliseconds: 300));
    final box = find.ancestor(of: find.text('Hello toast'), matching: find.byType(Container)).first;
    final rect = tester.getRect(box);
    expect(rect.top, 27);
    expect(rect.right, 912);
    await tester.pump(const Duration(seconds: 4));
  });

  group('new screens respect the safe area', () {
    testWidgets('settings panel', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.text('Settings'));
      await tester.pump(const Duration(milliseconds: 400));
      expectInsideSafeArea(tester);
    });

    testWidgets('quick-action menu', (tester) async {
      await pumpApp(tester, cameras: [viewCam('a', 'Home Camera A', caps: {CameraCapability.nightVision, CameraCapability.siren})]);
      await focusOn(tester, find.text('Home Camera A'));
      await holdOk(tester);
      expect(find.byType(TvDialog), findsOneWidget);
      expectInsideSafeArea(tester);
    });

    testWidgets('rename dialog', (tester) async {
      await pumpApp(tester, cameras: [viewCam('a', 'Home Camera A')]);
      showRenameDialog(appContext(tester), currentName: 'Home Camera A', localOnly: false);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(RenameDialog), findsOneWidget);
      expectInsideSafeArea(tester);
    });

    testWidgets('recordings timeline screen', (tester) async {
      final app = await pumpApp(tester, cameras: [viewCam('a', 'Home Camera A', caps: {CameraCapability.sdCard})], actions: FakeCameraActions());
      await pushScreen(tester, VodTimelineScreen(camera: app.cameras.first, videoBuilder: fakeVideo));
      // The timeline is driven by ONE screen-level Focus (scrub/day/OK keys,
      // spec ui.recordings.screen), so it has no TvFocusable rows; check the
      // interactive surface itself: day label, cursor label and the 24 h bar.
      final rects = [
        for (final k in const ['timeline-day-label', 'timeline-cursor-label', 'timeline-bar'])
          tester.getRect(find.byKey(ValueKey(k))),
      ];
      expect(Focus.of(tester.element(find.byKey(const ValueKey('timeline-bar')))).hasFocus, isTrue,
          reason: 'the screen owns the focus');
      for (final r in rects) {
        expect(r.left, greaterThanOrEqualTo(safeRect.left), reason: 'left of $r');
        expect(r.right, lessThanOrEqualTo(safeRect.right), reason: 'right of $r');
        expect(r.top, greaterThanOrEqualTo(safeRect.top), reason: 'top of $r');
        expect(r.bottom, lessThanOrEqualTo(safeRect.bottom), reason: 'bottom of $r');
      }
      expectInsideSafeArea(tester, allowNone: true);
    });
  });
}