// ui.grid.editor (existing behaviour)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/screens/multiview_screen.dart';
import 'package:tapo_tv/state/grids.dart';
import 'package:tapo_tv/ui/tv.dart';

import 'support.dart';

Future<(TestAppState, ValueNotifier<GridPreset?>)> _open(WidgetTester tester, {GridPreset? initial}) async {
  final app = await pumpApp(tester);
  final result = ValueNotifier<GridPreset?>(null);
  navigatorKey.currentState!
      .push<GridPreset>(MaterialPageRoute(builder: (_) => GridEditorScreen(initial: initial)))
      .then((v) => result.value = v);
  await settle(tester, const Duration(milliseconds: 1000));
  return (app, result);
}

void main() {
  testWidgets('Save with no cameras shows the error and does not pop', (tester) async {
    await _open(tester);
    await tester.tap(tvButton('Save grid'));
    await settle(tester);
    expect(find.text('Add at least one camera to the grid.'), findsOneWidget);
    expect(find.byType(GridEditorScreen), findsOneWidget);
  });

  testWidgets('choosing a layout chip resizes the slot list', (tester) async {
    final (_, result) = await _open(tester);
    await tester.tap(tvChip('3 × 3'));
    await settle(tester);
    await tester.tap(tvButton('Fill with all cameras'));
    await settle(tester);
    await tester.tap(tvButton('Save grid'));
    await settle(tester, const Duration(milliseconds: 1000));
    expect(result.value!.layout, GridLayout.nine);
    expect(result.value!.slots, hasLength(9));
  });

  testWidgets('Save returns a GridPreset with the generated "Grid N" name', (tester) async {
    final (app, result) = await _open(tester);
    await tester.tap(tvButton('Fill with all cameras'));
    await settle(tester);
    await tester.tap(tvButton('Save grid'));
    await settle(tester, const Duration(milliseconds: 1000));
    expect(result.value!.name, 'Grid 1');
    expect(result.value!.id, matches(RegExp(r'^g\d+$')));
    expect(app.savedGrids, hasLength(1));
  });

  testWidgets('Fill with all cameras uses account order', (tester) async {
    final (_, result) = await _open(tester);
    await tester.tap(tvChip('1 + 5'));
    await settle(tester);
    await tester.tap(tvButton('Fill with all cameras'));
    await settle(tester);
    await tester.tap(tvButton('Save grid'));
    await settle(tester, const Duration(milliseconds: 1000));
    expect(result.value!.slots, ['cam-a', 'cam-b', 'cam-c', 'cam-d', 'cam-e', null]);
  });

  testWidgets('editing keeps the grid id', (tester) async {
    final app = await pumpApp(tester);
    final saved = await app.saveGrid(GridPreset(id: '', name: 'Porch', layout: GridLayout.two, slots: ['cam-a', 'cam-b']));
    ValueNotifier<GridPreset?> result = ValueNotifier(null);
    navigatorKey.currentState!
        .push<GridPreset>(MaterialPageRoute(builder: (_) => GridEditorScreen(initial: saved)))
        .then((v) => result.value = v);
    await settle(tester, const Duration(milliseconds: 1000));
    expect(find.text('Edit grid'), findsOneWidget);
    await tester.tap(tvButton('Save grid'));
    await settle(tester, const Duration(milliseconds: 1000));
    expect(result.value!.id, saved.id);
    expect(app.savedGrids, hasLength(1));
  });

  testWidgets('select on a tile opens the camera picker', (tester) async {
    await _open(tester);
    await tester.tap(find.text('Tile 1'));
    await settle(tester);
    expect(find.text('Camera for tile 1'), findsOneWidget);
    await focusOn(tester, tvTile('Home Camera B'));
    await ok(tester);
    expect(find.text('Home Camera B'), findsWidgets);
  });

  testWidgets('Back pops without saving', (tester) async {
    final (app, result) = await _open(tester);
    await back(tester);
    expect(find.byType(GridEditorScreen), findsNothing);
    expect(result.value, isNull);
    expect(app.savedGrids, isEmpty);
    expect(find.byType(TvDialog), findsNothing);
  });
}