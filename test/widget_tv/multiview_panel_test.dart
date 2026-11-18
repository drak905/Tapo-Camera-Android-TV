// ui.grid.panel_options (existing behaviour)
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/screens/multiview_screen.dart';
import 'package:tapo_tv/ui/tv.dart';

import 'support.dart';

final _prefs = {
  'grids': jsonEncode([
    {'id': 'g1', 'name': 'Downstairs', 'layout': 'quad', 'slots': ['cam-c', 'cam-b', null, 'cam-a']},
  ]),
};

Future<TestAppState> _panel(WidgetTester tester) async {
  final app = await pumpApp(tester, prefs: _prefs);
  await tester.tap(find.text('Multi-view'));
  await settle(tester, const Duration(milliseconds: 400));
  return app;
}

void main() {
  testWidgets('Multi-view lists All cameras, saved grids and New grid', (tester) async {
    await _panel(tester);
    expect(find.text('All cameras'), findsOneWidget);
    expect(find.text('Downstairs'), findsOneWidget);
    expect(find.text('New grid'), findsOneWidget);
  });

  testWidgets('Hold OK on the auto grid lists exactly Watch, Pin, Save a copy', (tester) async {
    await _panel(tester);
    await focusOn(tester, find.text('All cameras'));
    await holdOk(tester);
    expect(find.descendant(of: find.byType(TvDialog), matching: find.byType(TvTile)), findsNWidgets(3));
    expect(tvTile('Watch'), findsOneWidget);
    expect(tvTile('Pin to home'), findsOneWidget);
    expect(tvTile('Save a copy to customise'), findsOneWidget);
    expect(focusedText(tester), 'Watch');
  });

  testWidgets('Hold OK on a saved grid lists Watch, Pin, Edit, Duplicate, Delete', (tester) async {
    await _panel(tester);
    await focusOn(tester, find.text('Downstairs'));
    await holdOk(tester);
    for (final t in ['Watch', 'Pin to home', 'Edit', 'Duplicate', 'Delete']) {
      expect(tvTile(t), findsOneWidget, reason: t);
    }
    expect(tester.widget<TvTile>(tvTile('Delete')).danger, isTrue);
  });

  testWidgets('Pin to home sets favoriteGridId and the home page shows it', (tester) async {
    final app = await _panel(tester);
    await focusOn(tester, find.text('Downstairs'));
    await holdOk(tester);
    await focusOn(tester, tvTile('Pin to home'));
    await ok(tester);
    expect(app.favoriteGridId, 'g1');
    await tester.pump(const Duration(seconds: 4));
    await tester.tap(find.text('Cameras'));
    await settle(tester, const Duration(milliseconds: 400));
    expect(find.text('Favourite grid'), findsOneWidget);
    expect(find.text('Downstairs'), findsOneWidget);
  });

  testWidgets('Delete asks for confirmation (Cancel focused) and removes the grid', (tester) async {
    final app = await _panel(tester);
    await focusOn(tester, find.text('Downstairs'));
    await holdOk(tester);
    await focusOn(tester, tvTile('Delete'));
    await ok(tester);
    expect(find.text('Delete "Downstairs"?'), findsOneWidget);
    expect(focusedText(tester), 'Cancel');
    await back(tester);
    expect(app.savedGrids, hasLength(1));
    await focusOn(tester, find.text('Downstairs'));
    await holdOk(tester);
    await focusOn(tester, tvTile('Delete'));
    await ok(tester);
    await focusOn(tester, tvButton('Delete'));
    await ok(tester);
    expect(app.savedGrids, isEmpty);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('Back closes the options without acting', (tester) async {
    final app = await _panel(tester);
    await focusOn(tester, find.text('Downstairs'));
    await holdOk(tester);
    await back(tester);
    expect(find.byType(TvDialog), findsNothing);
    expect(app.savedGrids, hasLength(1));
  });

  testWidgets('Save a copy of All cameras opens the editor with a copy name', (tester) async {
    await _panel(tester);
    await focusOn(tester, find.text('All cameras'));
    await holdOk(tester);
    await focusOn(tester, tvTile('Save a copy to customise'));
    await ok(tester);
    expect(find.byType(GridEditorScreen), findsOneWidget);
    expect(tester.widget<GridEditorScreen>(find.byType(GridEditorScreen)).initial!.name, 'All cameras copy');
  });
}