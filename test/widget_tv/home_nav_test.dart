// ui.nav.home_tabs (existing behaviour)
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/screens/home_screen.dart';
import 'package:tapo_tv/screens/multiview_screen.dart';
import 'package:tapo_tv/screens/settings_screen.dart';
import 'package:tapo_tv/ui/guide.dart';

import 'support.dart';

void main() {
  testWidgets('arrowRight moves focus Cameras -> Multi-view without switching tab', (tester) async {
    await pumpApp(tester);
    await focusOn(tester, find.text('Cameras'));
    expect(focusedText(tester), 'Cameras');
    await arrow(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedText(tester), 'Multi-view');
    expect(find.byType(CamerasPanel), findsOneWidget);
    expect(find.byType(MultiviewPanel), findsNothing);
  });

  testWidgets('select on Multi-view shows the multiview panel', (tester) async {
    await pumpApp(tester);
    await focusOn(tester, find.text('Multi-view'));
    await ok(tester);
    expect(find.byType(MultiviewPanel), findsOneWidget);
    expect(guideSection.value, GuideSection.multiview);
  });

  testWidgets('select on Settings shows SettingsPanel', (tester) async {
    await pumpApp(tester);
    await focusOn(tester, find.text('Settings'));
    await ok(tester);
    expect(find.byType(SettingsPanel), findsOneWidget);
    expect(find.byType(CamerasPanel), findsNothing);
  });

  testWidgets('first run shows RemoteGuide and marks it seen', (tester) async {
    final app = await pumpApp(tester, guideSeen: false);
    expect(find.byType(RemoteGuide), findsOneWidget);
    await back(tester);
    expect(find.byType(RemoteGuide), findsNothing);
    expect(app.guideSeen, isTrue);
  });

  testWidgets('second run does not show the guide (guideSeen)', (tester) async {
    await pumpApp(tester, guideSeen: true);
    expect(find.byType(RemoteGuide), findsNothing);
  });

  testWidgets('Refresh button exists on the cameras tab only', (tester) async {
    await pumpApp(tester);
    expect(find.bySemanticsLabel('Refresh cameras'), findsOneWidget);
    await tester.tap(find.text('Settings'));
    await settle(tester);
    expect(find.bySemanticsLabel('Refresh cameras'), findsNothing);
  });

  testWidgets('arrowUp from a camera card reaches the nav row', (tester) async {
    await pumpApp(tester);
    await focusOn(tester, find.text('Home Camera A'));
    await arrow(tester, LogicalKeyboardKey.arrowUp, 2);
    expect(['Cameras', 'Multi-view', 'Settings', 'Guide'], contains(focusedText(tester)));
  });
}