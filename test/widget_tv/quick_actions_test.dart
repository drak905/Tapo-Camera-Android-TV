// ui.home.quick_actions (existing) and ui.home.quick_actions_new_entries (new)
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/screens/live_screen.dart';
import 'package:tapo_tv/screens/rename_dialog.dart';
import 'package:tapo_tv/state/camera_view_model.dart';
import 'package:tapo_tv/ui/tv.dart';

import 'support.dart';

const _both = {CameraCapability.nightVision, CameraCapability.siren};

Future<void> _openMenu(WidgetTester tester, String cameraName) async {
  await focusOn(tester, find.text(cameraName));
  await holdOk(tester);
}

double _y(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

void main() {
  group('existing entries', () {
    testWidgets('Hold OK (KeyDown, KeyRepeat) on a card shows a TvDialog titled with the camera name', (tester) async {
      await pumpApp(tester);
      await focusOn(tester, find.text('Home Camera B'));
      await keyDown(tester, LogicalKeyboardKey.select);
      expect(find.byType(TvDialog), findsNothing);
      await keyRepeat(tester, LogicalKeyboardKey.select);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await settle(tester);
      final dialog = find.byType(TvDialog);
      expect(dialog, findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.text('Home Camera B')), findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.text('C320WS')), findsOneWidget);
    });

    testWidgets('first focus is Watch live', (tester) async {
      await pumpApp(tester);
      await _openMenu(tester, 'Home Camera A');
      expect(focusedText(tester), 'Watch live');
    });

    testWidgets('select Watch live pops the dialog and pushes LiveScreen', (tester) async {
      await pumpApp(tester);
      await _openMenu(tester, 'Home Camera C');
      await ok(tester);
      await settle(tester, const Duration(milliseconds: 400));
      expect(find.byType(TvDialog), findsNothing);
      expect(tester.widget<LiveScreen>(find.byType(LiveScreen)).initialIndex, 2);
    });

    testWidgets('privacy tile is disabled while camera.privacy is null', (tester) async {
      await pumpApp(tester);
      await _openMenu(tester, 'Home Camera D');
      final tile = tester.widget<TvTile>(tvTile('Turn privacy mode on'));
      expect(tile.onSelect, isNull);
      expect(tile.subtitle, 'Checking the camera…');
    });

    testWidgets('privacy tile toggles privacy and toasts', (tester) async {
      final app = await pumpApp(tester);
      await _openMenu(tester, 'Home Camera A');
      await focusOn(tester, tvTile('Turn privacy mode on'));
      await ok(tester);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Privacy mode is on'), findsOneWidget);
      expect(app.privacyCalls, [('cam-a', true)]);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('Back closes the dialog with no route push', (tester) async {
      await pumpApp(tester);
      await _openMenu(tester, 'Home Camera A');
      await back(tester);
      expect(find.byType(TvDialog), findsNothing);
      expect(find.byType(LiveScreen), findsNothing);
    });

    testWidgets('Hold OK is the only entry gesture: plain OK opens live, not the menu', (tester) async {
      await pumpApp(tester);
      await focusOn(tester, find.text('Home Camera A'));
      await ok(tester);
      expect(find.byType(TvDialog), findsNothing);
      expect(find.byType(LiveScreen), findsOneWidget);
    });

    testWidgets('arrowDown traversal visits Watch live, Privacy, Reconnect for a plain camera', (tester) async {
      await pumpApp(tester);
      await _openMenu(tester, 'Home Camera A');
      final seen = <String?>[focusedText(tester)];
      for (var i = 0; i < 2; i++) {
        await arrow(tester, LogicalKeyboardKey.arrowDown);
        seen.add(focusedText(tester));
      }
      expect(seen, ['Watch live', 'Turn privacy mode on', 'Reconnect preview']);
      await back(tester);
      expect(find.byType(TvDialog), findsNothing);
    });
  });

  group('NEW entries', () {
    testWidgets('dialog lists Night vision, Siren, Rename after Privacy, before Reconnect', (tester) async {
      await pumpApp(tester, cameras: [viewCam('cam-a', 'Home Camera A', caps: _both)]);
      await _openMenu(tester, 'Home Camera A');
      final order = [
        'Watch live',
        'Turn privacy mode on',
        'Night vision',
        'Siren',
        'Rename',
        'Reconnect preview',
      ];
      for (final t in order) {
        expect(tvTile(t), findsOneWidget, reason: t);
      }
      final ys = [for (final t in order) _y(tester, tvTile(t))];
      expect(ys, orderedEquals([...ys]..sort()));
    });

    testWidgets('Night vision and Siren are hidden when the camera lacks the capability', (tester) async {
      await pumpApp(tester, cameras: [viewCam('cam-a', 'Home Camera A')]);
      await _openMenu(tester, 'Home Camera A');
      expect(tvTile('Night vision'), findsNothing);
      expect(tvTile('Siren'), findsNothing);
      expect(tvTile('Rename'), findsOneWidget);
    });

    testWidgets('select Night vision cycles auto -> on -> off -> auto via the actions', (tester) async {
      final fake = FakeCameraActions();
      await pumpApp(tester, cameras: [viewCam('cam-a', 'Home Camera A', caps: _both)], actions: fake);
      await _openMenu(tester, 'Home Camera A');
      await focusOn(tester, tvTile('Night vision'));
      expect(tester.widget<TvTile>(tvTile('Night vision')).subtitle, 'Auto');
      for (final (expectedMode, subtitle) in [
        (DayNightMode.on, 'Night vision on'),
        (DayNightMode.off, 'Day mode'),
        (DayNightMode.auto, 'Auto'),
      ]) {
        await ok(tester);
        expect(fake.dayNightCalls.last, ('cam-a', expectedMode));
        expect(tester.widget<TvTile>(tvTile('Night vision')).subtitle, subtitle);
      }
      expect(fake.dayNightCalls, hasLength(3));
    });

    testWidgets('select Siren sets the alarm on, then off, with a toast', (tester) async {
      final fake = FakeCameraActions();
      await pumpApp(tester, cameras: [viewCam('cam-a', 'Home Camera A', caps: _both)], actions: fake);
      await _openMenu(tester, 'Home Camera A');
      await focusOn(tester, tvTile('Siren'));
      await ok(tester);
      expect(fake.alarmCalls, [('cam-a', true)]);
      expect(find.text('Siren is on'), findsOneWidget);
      await ok(tester);
      expect(fake.alarmCalls, [('cam-a', true), ('cam-a', false)]);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('select Rename pops the menu and opens the rename dialog', (tester) async {
      await pumpApp(tester, cameras: [viewCam('cam-a', 'Home Camera A')], actions: FakeCameraActions());
      await _openMenu(tester, 'Home Camera A');
      await focusOn(tester, tvTile('Rename'));
      await ok(tester);
      expect(find.byType(TvDialog), findsNothing);
      expect(find.byType(RenameDialog), findsOneWidget);
    });

    testWidgets('shared camera shows "Reset to camera name" only when a local name exists', (tester) async {
      await pumpApp(tester, cameras: [
        viewCam('cam-a', 'Home Camera A', shared: true, route: CameraRoute.cloud),
        viewCam('cam-b', 'Home Camera B', shared: true, route: CameraRoute.cloud, localName: 'Porch'),
        viewCam('cam-c', 'Home Camera C', localName: 'Porch 2'),
      ]);
      await _openMenu(tester, 'Home Camera A');
      expect(tvTile('Reset to camera name'), findsNothing);
      await back(tester);
      await _openMenu(tester, 'Porch');
      expect(tvTile('Reset to camera name'), findsOneWidget);
      await back(tester);
      // An owned camera never offers the reset, even with a leftover local name.
      await _openMenu(tester, 'Porch 2');
      expect(tvTile('Reset to camera name'), findsNothing);
    });

    testWidgets('arrowDown traversal visits every entry and Back exits', (tester) async {
      await pumpApp(tester, cameras: [viewCam('cam-a', 'Home Camera A', caps: _both, shared: true, localName: 'Porch')]);
      await _openMenu(tester, 'Porch');
      final seen = <String?>[focusedText(tester)];
      for (var i = 0; i < 6; i++) {
        await arrow(tester, LogicalKeyboardKey.arrowDown);
        seen.add(focusedText(tester));
      }
      expect(seen, [
        'Watch live',
        'Turn privacy mode on',
        'Night vision',
        'Siren',
        'Rename',
        'Reset to camera name',
        'Reconnect preview',
      ]);
      await back(tester);
      expect(find.byType(TvDialog), findsNothing);
    });

    testWidgets('new entries expose semantic labels', (tester) async {
      await pumpApp(tester, cameras: [viewCam('cam-a', 'Home Camera A', caps: _both)]);
      await _openMenu(tester, 'Home Camera A');
      for (final label in ['Night vision', 'Siren', 'Rename']) {
        expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
      }
    });
  });
}