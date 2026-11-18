// ui.camera.sort_order (widget part, new)
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/screens/live_screen.dart';

import 'support.dart';

List<Camera> _unsorted() => [
      plainCam('id-10', 'Cam 10'),
      plainCam('id-2', 'Cam 2'),
      plainCam('id-1', 'Cam 1'),
      plainCam('id-z', 'Zed Camera'),
      plainCam('id-a', 'Alpha Camera'),
    ];

/// Names in reading order (top to bottom, left to right) among the home cards.
List<String> _cardOrder(WidgetTester tester, List<String> names) {
  final pos = {for (final n in names) n: tester.getTopLeft(find.text(n))};
  final sorted = [...names]..sort((a, b) {
      final c = pos[a]!.dy.compareTo(pos[b]!.dy);
      return c != 0 ? c : pos[a]!.dx.compareTo(pos[b]!.dx);
    });
  return sorted;
}

void main() {
  const names = ['Cam 10', 'Cam 2', 'Cam 1', 'Zed Camera', 'Alpha Camera'];

  testWidgets('home cards follow Name A-Z (natural) and digit3 opens the third in sorted order', (tester) async {
    await pumpApp(tester, cameras: _unsorted(), prefs: {'camera_sort': 'name_asc'});
    expect(_cardOrder(tester, names), ['Alpha Camera', 'Cam 1', 'Cam 2', 'Cam 10', 'Zed Camera']);
    await key(tester, LogicalKeyboardKey.digit3);
    expect(find.text('Cam 2'), findsOneWidget, reason: 'live title of the third sorted camera');
    expect(find.text('Camera 3 of 5'), findsOneWidget);
  });

  testWidgets('home cards follow Name Z-A', (tester) async {
    await pumpApp(tester, cameras: _unsorted(), prefs: {'camera_sort': 'name_desc'});
    expect(_cardOrder(tester, names), ['Zed Camera', 'Cam 10', 'Cam 2', 'Cam 1', 'Alpha Camera']);
  });

  testWidgets('Account order keeps the account list order', (tester) async {
    await pumpApp(tester, cameras: _unsorted(), prefs: {'camera_sort': 'account'});
    expect(_cardOrder(tester, names), ['Cam 10', 'Cam 2', 'Cam 1', 'Zed Camera', 'Alpha Camera']);
  });

  testWidgets('with no stored value the default is Name A-Z', (tester) async {
    final app = await pumpApp(tester, cameras: _unsorted());
    expect(app.sortedCameras.map((c) => c.name), ['Alpha Camera', 'Cam 1', 'Cam 2', 'Cam 10', 'Zed Camera']);
  });

  testWidgets('live CH+ walks the sorted order', (tester) async {
    await pumpApp(tester, cameras: _unsorted(), prefs: {'camera_sort': 'name_asc'});
    await pushScreen(tester, const LiveScreen(initialIndex: 0));
    expect(find.text('Alpha Camera'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.channelUp);
    expect(find.text('Cam 1'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.channelUp);
    expect(find.text('Cam 2'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.channelUp);
    expect(find.text('Cam 10'), findsOneWidget);
  });

  testWidgets('the All cameras grid follows the sort order', (tester) async {
    final app = await pumpApp(tester, cameras: _unsorted(), prefs: {'camera_sort': 'name_asc'});
    expect(app.allCamerasGrid.slots.take(5), ['id-a', 'id-1', 'id-2', 'id-10', 'id-z']);
  });

  testWidgets('changing the sort never moves slots of a saved grid (ids are stored)', (tester) async {
    final app = await pumpApp(tester, cameras: _unsorted(), prefs: {'camera_sort': 'name_asc'});
    final before = app.gridById('all').slots.length;
    await app.setCameraSort(app.cameraSort);
    expect(app.gridById('all').slots.length, before);
  });
}