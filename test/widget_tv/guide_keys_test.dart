// ui.keys.guide_keys (existing behaviour)
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/screens/live_screen.dart';
import 'package:tapo_tv/ui/guide.dart';

import 'support.dart';

void main() {
  for (final k in [
    LogicalKeyboardKey.contextMenu,
    LogicalKeyboardKey.info,
    LogicalKeyboardKey.guide,
    LogicalKeyboardKey.f1,
  ]) {
    testWidgets('${k.debugName} opens the remote guide', (tester) async {
      await pumpApp(tester);
      await key(tester, k);
      expect(find.byType(RemoteGuide), findsOneWidget);
    });
  }

  testWidgets('a second press while the guide is open does not push another route', (tester) async {
    await pumpApp(tester);
    await key(tester, LogicalKeyboardKey.info);
    await key(tester, LogicalKeyboardKey.info);
    await key(tester, LogicalKeyboardKey.contextMenu);
    expect(find.byType(RemoteGuide), findsOneWidget);
    await back(tester);
    expect(find.byType(RemoteGuide), findsNothing);
  });

  testWidgets('Back closes the guide and it can be opened again', (tester) async {
    await pumpApp(tester);
    await key(tester, LogicalKeyboardKey.info);
    await back(tester);
    expect(find.byType(RemoteGuide), findsNothing);
    await key(tester, LogicalKeyboardKey.info);
    expect(find.byType(RemoteGuide), findsOneWidget);
  });

  testWidgets('the guide opens on guideSection (live screen -> Live view)', (tester) async {
    await pumpApp(tester);
    await pushScreen(tester, const LiveScreen(initialIndex: 0));
    expect(guideSection.value, GuideSection.live);
    await key(tester, LogicalKeyboardKey.info);
    expect(tester.widget<RemoteGuide>(find.byType(RemoteGuide)).initial, GuideSection.live);
  });

  testWidgets('the guide opens on Cameras from the home list', (tester) async {
    await pumpApp(tester);
    await key(tester, LogicalKeyboardKey.f1);
    expect(tester.widget<RemoteGuide>(find.byType(RemoteGuide)).initial, GuideSection.home);
  });
}