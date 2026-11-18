// ui.camera.controls_night_siren_privacy_ptz (new). Fakes only: no real alarm is ever switched.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/state/camera_actions.dart';
import 'package:tapo_tv/state/camera_view_model.dart';
import 'package:tapo_tv/ui/tv.dart';

import 'support.dart';

const _both = {CameraCapability.nightVision, CameraCapability.siren};

Future<void> _menu(WidgetTester tester, String name) async {
  await focusOn(tester, find.text(name));
  await holdOk(tester);
}

void main() {
  testWidgets('AppState.setDayNight keeps the new value on success', (tester) async {
    final fake = FakeCameraActions();
    final app = await pumpApp(tester, cameras: [viewCam('cam-a', 'Home Camera A', caps: _both)], actions: fake);
    await app.setDayNight(app.cameras.first, DayNightMode.on);
    expect(app.cameras.first.dayNight, DayNightMode.on);
    expect(fake.dayNightCalls, [('cam-a', DayNightMode.on)]);
  });

  testWidgets('AppState.setDayNight rolls back and rethrows when the camera refuses', (tester) async {
    final fake = FakeCameraActions()..failDayNight = const CameraActionException('The camera did not answer');
    final app = await pumpApp(tester, cameras: [viewCam('cam-a', 'Home Camera A', caps: _both)], actions: fake);
    await expectLater(app.setDayNight(app.cameras.first, DayNightMode.on), throwsA(isA<CameraActionException>()));
    expect(app.cameras.first.dayNight, DayNightMode.auto);
  });

  testWidgets('AppState.setAlarm rolls back and rethrows on failure', (tester) async {
    final fake = FakeCameraActions()..failAlarm = const CameraActionException('offline');
    final app = await pumpApp(tester, cameras: [viewCam('cam-a', 'Home Camera A', caps: _both)], actions: fake);
    await expectLater(app.setAlarm(app.cameras.first, true), throwsA(isA<CameraActionException>()));
    expect(app.cameras.first.alarm, false);
  });

  testWidgets('night vision select with a failing client rolls back and shows an error toast', (tester) async {
    final fake = FakeCameraActions()..failDayNight = const CameraActionException('The camera did not answer');
    final app = await pumpApp(tester, cameras: [viewCam('cam-a', 'Home Camera A', caps: _both)], actions: fake);
    await _menu(tester, 'Home Camera A');
    await focusOn(tester, tvTile('Night vision'));
    await ok(tester);
    await settle(tester);
    expect(app.cameras.first.dayNight, DayNightMode.auto);
    expect(tester.widget<TvTile>(tvTile('Night vision')).subtitle, 'Auto');
    expect(find.text('The camera did not answer'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('siren select toggles the state and the label', (tester) async {
    final fake = FakeCameraActions();
    final app = await pumpApp(tester, cameras: [viewCam('cam-a', 'Home Camera A', caps: _both)], actions: fake);
    await _menu(tester, 'Home Camera A');
    await focusOn(tester, tvTile('Siren'));
    expect(tester.widget<TvTile>(tvTile('Siren')).subtitle, 'Off');
    await ok(tester);
    expect(app.cameras.first.alarm, true);
    expect(tester.widget<TvTile>(tvTile('Siren')).subtitle, 'On');
    await ok(tester);
    expect(app.cameras.first.alarm, false);
    expect(fake.alarmCalls, [('cam-a', true), ('cam-a', false)]);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('a failing siren request leaves the siren off and shows the error', (tester) async {
    final fake = FakeCameraActions()..failAlarm = const CameraActionException('offline');
    final app = await pumpApp(tester, cameras: [viewCam('cam-a', 'Home Camera A', caps: _both)], actions: fake);
    await _menu(tester, 'Home Camera A');
    await focusOn(tester, tvTile('Siren'));
    await ok(tester);
    await settle(tester);
    expect(app.cameras.first.alarm, false);
    expect(find.text('offline'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('controls are hidden when the camera lacks the capability', (tester) async {
    await pumpApp(tester, cameras: [viewCam('cam-a', 'Home Camera A')], actions: FakeCameraActions());
    await _menu(tester, 'Home Camera A');
    expect(tvTile('Night vision'), findsNothing);
    expect(tvTile('Siren'), findsNothing);
    expect(tvTile('Rename'), findsOneWidget, reason: 'rename needs no capability');
    expect(LogicalKeyboardKey.select, isNotNull);
  });

  testWidgets('capability is checked per camera', (tester) async {
    await pumpApp(tester, cameras: [
      viewCam('cam-a', 'Home Camera A', caps: _both),
      viewCam('cam-b', 'Home Camera B'),
    ]);
    await _menu(tester, 'Home Camera B');
    expect(tvTile('Siren'), findsNothing);
    await back(tester);
    await _menu(tester, 'Home Camera A');
    expect(tvTile('Siren'), findsOneWidget);
  });
}