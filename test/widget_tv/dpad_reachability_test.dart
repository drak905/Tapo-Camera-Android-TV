// D-pad reachability: from the initial focus every focusable is reachable with
// the arrow keys and no arrow press lands on a non-focusable node (dead end).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/screens/live_screen.dart';
import 'package:tapo_tv/screens/multiview_screen.dart';
import 'package:tapo_tv/state/camera_view_model.dart';

import 'support.dart';

void expectNoDeadEnds(FocusExploration e) {
  expect(e.all, isNotEmpty);
  expect(e.escapes, isEmpty, reason: 'arrow presses that left the focusables: ${e.escapes}');
  expect(e.unreachable, isEmpty, reason: '${e.unreachable.length} focusables unreachable with arrows');
}

void main() {
  final grids = {
    'grids': jsonEncode([
      {'id': 'g1', 'name': 'Downstairs', 'layout': 'quad', 'slots': ['cam-c', 'cam-b', null, 'cam-a']},
    ]),
  };

  testWidgets('home: cameras tab', (tester) async {
    await pumpApp(tester);
    expectNoDeadEnds(await exploreFocus(tester));
  });

  testWidgets('home: multi-view tab', (tester) async {
    await pumpApp(tester, prefs: grids);
    await tester.tap(find.text('Multi-view'));
    await settle(tester, const Duration(milliseconds: 500));
    await focusOn(tester, find.text('All cameras'));
    expectNoDeadEnds(await exploreFocus(tester));
  });

  testWidgets('home: settings tab', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Settings'));
    await settle(tester, const Duration(milliseconds: 500));
    await focusOn(tester, find.text('Tapo account'));
    expectNoDeadEnds(await exploreFocus(tester));
  });

  testWidgets('live controls', (tester) async {
    await pumpApp(tester, cameras: [
      viewCam('cam-a', 'Home Camera A', ptz: true, caps: {CameraCapability.nightVision, CameraCapability.siren, CameraCapability.sdCard}),
      viewCam('cam-b', 'Home Camera B'),
    ]);
    await pushScreen(tester, const LiveScreen(initialIndex: 0));
    await ok(tester);
    expectNoDeadEnds(await exploreFocus(tester));
  });

  testWidgets('grid view bar and tiles', (tester) async {
    await pumpApp(tester, prefs: grids);
    await pushScreen(tester, const GridViewScreen(gridId: 'g1'));
    expectNoDeadEnds(await exploreFocus(tester));
  });

  testWidgets('quick actions with every new entry', (tester) async {
    await pumpApp(tester, cameras: [
      viewCam('cam-a', 'Home Camera A', shared: true, localName: 'Porch', caps: {CameraCapability.nightVision, CameraCapability.siren}),
    ]);
    await focusOn(tester, find.text('Porch'));
    await holdOk(tester);
    final e = await exploreFocus(tester);
    expectNoDeadEnds(e);
    expect(e.all.length, greaterThanOrEqualTo(7));
  });
}
