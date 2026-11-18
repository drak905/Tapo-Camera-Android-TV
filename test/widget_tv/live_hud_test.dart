// ui.live.controls_hud (existing) and ui.live.controls_hud_new (new)
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/screens/live_screen.dart';
import 'package:tapo_tv/screens/rename_dialog.dart';
import 'package:tapo_tv/screens/vod_timeline_screen.dart';
import 'package:tapo_tv/state/camera_view_model.dart';
import 'package:tapo_tv/ui/tv.dart';

import 'support.dart';

const _all = {CameraCapability.nightVision, CameraCapability.siren, CameraCapability.sdCard};

Future<TestAppState> _hud(WidgetTester tester, {List<Camera>? cameras, FakeCameraActions? actions}) async {
  final app = await pumpApp(tester, cameras: cameras, actions: actions);
  await pushScreen(tester, const LiveScreen(initialIndex: 0));
  await ok(tester);
  return app;
}

/// Presses Right (or Down when Right goes nowhere) until the focused text is
/// [target]. Returns the focused rects visited.
Future<List<Rect>> _walkTo(WidgetTester tester, String target) async {
  final visited = <Rect>[FocusManager.instance.primaryFocus!.rect];
  for (var i = 0; i < 24 && focusedText(tester) != target; i++) {
    final before = FocusManager.instance.primaryFocus;
    await arrow(tester, LogicalKeyboardKey.arrowRight);
    if (identical(FocusManager.instance.primaryFocus, before)) {
      await arrow(tester, LogicalKeyboardKey.arrowDown);
    }
    visited.add(FocusManager.instance.primaryFocus!.rect);
  }
  return visited;
}

void main() {
  group('existing buttons', () {
    testWidgets('focus starts on the privacy button', (tester) async {
      await _hud(tester);
      expect(focusedText(tester), 'Turn privacy on');
    });

    testWidgets('Step button cycles 10 -> 20 -> 5 -> 10 via select', (tester) async {
      final app = await _hud(tester);
      await focusOn(tester, find.text('Step 10°'));
      for (final (step, label) in [(20, 'Step 20°'), (5, 'Step 5°'), (10, 'Step 10°')]) {
        await ok(tester);
        expect(app.ptzStep, step);
        expect(find.text(label), findsOneWidget);
      }
    });

    testWidgets('Pan & tilt hides the controls', (tester) async {
      await _hud(tester);
      await focusOn(tester, tvButton('Pan & tilt'));
      await ok(tester);
      await back(tester);
      expect(find.byType(LiveScreen), findsNothing, reason: 'controls were hidden, so Back pops the screen');
    });

    testWidgets('Previous and Next are absent with a single camera', (tester) async {
      await _hud(tester, cameras: [plainCam('cam-a', 'Home Camera A', ptz: true)]);
      expect(tvButton('Previous'), findsNothing);
      expect(tvButton('Next'), findsNothing);
    });

    testWidgets('Previous and Next are present with several cameras', (tester) async {
      await _hud(tester);
      expect(tvButton('Previous'), findsOneWidget);
      expect(tvButton('Next'), findsOneWidget);
    });

    testWidgets('Step and Pan & tilt exist only for PTZ cameras', (tester) async {
      await _hud(tester, cameras: [plainCam('cam-a', 'Home Camera A'), plainCam('cam-b', 'Home Camera B')]);
      expect(find.textContaining('Step '), findsNothing);
      expect(tvButton('Pan & tilt'), findsNothing);
    });

    testWidgets('HUD buttons use the on-media focus ring', (tester) async {
      await _hud(tester);
      expect(tester.widget<TvButton>(tvButton('Reconnect')).onMedia, isTrue);
    });
  });

  group('NEW buttons', () {
    testWidgets('baseline defect: arrowRight moves between HUD buttons and never to the live root', (tester) async {
      await _hud(tester, cameras: [plainCam('cam-a', 'Home Camera A')]);
      expect(focusedText(tester), 'Turn privacy on');
      await arrow(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedText(tester), 'Reconnect');
    });

    testWidgets('the controls row does not overflow at 960x540 (wraps or scrolls)', (tester) async {
      await pumpApp(tester, allowHudOverflow: false);
      await pushScreen(tester, const LiveScreen(initialIndex: 0));
      await ok(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('HUD lists Night vision, Siren, Rename, Recordings', (tester) async {
      await _hud(tester, cameras: [viewCam('cam-a', 'Home Camera A', caps: _all, ptz: true), viewCam('cam-b', 'Home Camera B')]);
      expect(find.textContaining('Night vision'), findsOneWidget);
      expect(tvButton('Siren'), findsOneWidget);
      expect(tvButton('Rename'), findsOneWidget);
      expect(tvButton('Recordings'), findsOneWidget);
    });

    testWidgets('Recordings is hidden for a camera without an SD card', (tester) async {
      await _hud(tester, cameras: [viewCam('cam-a', 'Home Camera A', caps: {CameraCapability.siren})]);
      expect(tvButton('Recordings'), findsNothing);
      expect(tvButton('Rename'), findsOneWidget);
    });

    testWidgets('arrowRight traversal from privacy reaches Recordings inside the safe area', (tester) async {
      await _hud(tester, cameras: [viewCam('cam-a', 'Home Camera A', caps: _all, ptz: true), viewCam('cam-b', 'Home Camera B')]);
      final visited = await _walkTo(tester, 'Recordings');
      expect(focusedText(tester), 'Recordings');
      for (final r in visited) {
        expect(safeRect.contains(r.topLeft) && safeRect.contains(r.bottomRight), isTrue, reason: '$r outside $safeRect');
      }
    });

    testWidgets('every HUD button is reachable and inside the safe area', (tester) async {
      await _hud(tester, cameras: [viewCam('cam-a', 'Home Camera A', caps: _all, ptz: true), viewCam('cam-b', 'Home Camera B')]);
      final labels = <String>{};
      for (var i = 0; i < 24; i++) {
        final t = focusedText(tester);
        if (t != null) labels.add(t);
        final before = FocusManager.instance.primaryFocus;
        await arrow(tester, LogicalKeyboardKey.arrowRight);
        if (identical(FocusManager.instance.primaryFocus, before)) await arrow(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(labels, containsAll(['Siren', 'Rename', 'Recordings', 'Previous', 'Next', 'Reconnect']));
      expect(labels.any((l) => l.startsWith('Night vision')), isTrue);
    });

    testWidgets('select Recordings pushes the recordings screen for this camera', (tester) async {
      await _hud(tester, cameras: [viewCam('cam-a', 'Home Camera A', caps: _all), viewCam('cam-b', 'Home Camera B')], actions: FakeCameraActions());
      await focusOn(tester, tvButton('Recordings'));
      await ok(tester);
      final screen = tester.widget<VodTimelineScreen>(find.byType(VodTimelineScreen));
      expect(screen.camera.deviceId, 'cam-a');
    });

    testWidgets('select Night vision cycles the mode and the label shows it', (tester) async {
      final fake = FakeCameraActions();
      await _hud(tester, cameras: [viewCam('cam-a', 'Home Camera A', caps: _all)], actions: fake);
      final button = find.byWidgetPredicate((w) => w is TvButton && w.label.startsWith('Night vision'));
      await focusOn(tester, button);
      await ok(tester);
      expect(fake.dayNightCalls, [('cam-a', DayNightMode.on)]);
      expect(find.text('Night vision: On'), findsOneWidget);
    });

    testWidgets('Siren button shows the pressed (primary) style after select', (tester) async {
      final fake = FakeCameraActions();
      await _hud(tester, cameras: [viewCam('cam-a', 'Home Camera A', caps: _all)], actions: fake);
      expect(tester.widget<TvButton>(tvButton('Siren')).style, isNot(TvButtonStyle.primary));
      await focusOn(tester, tvButton('Siren'));
      await ok(tester);
      expect(fake.alarmCalls, [('cam-a', true)]);
      expect(tester.widget<TvButton>(tvButton('Siren')).style, TvButtonStyle.primary);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('select Rename opens the rename dialog', (tester) async {
      await _hud(tester, cameras: [viewCam('cam-a', 'Home Camera A', caps: _all)], actions: FakeCameraActions());
      await focusOn(tester, tvButton('Rename'));
      await ok(tester);
      expect(find.byType(RenameDialog), findsOneWidget);
    });

    testWidgets('the new buttons carry semantic labels', (tester) async {
      await _hud(tester, cameras: [viewCam('cam-a', 'Home Camera A', caps: _all)]);
      for (final label in ['Siren', 'Rename', 'Recordings']) {
        expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
      }
    });
  });
}