// ui.grid.keys (existing behaviour)
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/screens/live_screen.dart';
import 'package:tapo_tv/screens/multiview_screen.dart';
import 'package:tapo_tv/ui/tv.dart';

import 'support.dart';

final _grids = {
  'grids': jsonEncode([
    {'id': 'g1', 'name': 'Downstairs', 'layout': 'quad', 'slots': ['cam-c', 'cam-b', null, 'cam-a']},
    {'id': 'g2', 'name': 'Garden', 'layout': 'two', 'slots': ['cam-e', 'cam-d']},
  ]),
};

Future<TestAppState> _grid(WidgetTester tester, {String id = 'all'}) async {
  final app = await pumpApp(tester, prefs: _grids);
  await pushScreen(tester, GridViewScreen(gridId: id));
  return app;
}

String? _label() => FocusManager.instance.primaryFocus?.debugLabel;

void main() {
  testWidgets('channelUp switches to the next grid', (tester) async {
    final app = await _grid(tester);
    await key(tester, LogicalKeyboardKey.channelUp);
    expect(app.activeGridId, 'g1');
    await key(tester, LogicalKeyboardKey.channelUp);
    expect(app.activeGridId, 'g2');
  });

  testWidgets('channelDown from All wraps to the last grid', (tester) async {
    final app = await _grid(tester);
    await key(tester, LogicalKeyboardKey.channelDown);
    expect(app.activeGridId, 'g2');
    await key(tester, LogicalKeyboardKey.channelUp);
    expect(app.activeGridId, 'all');
  });

  for (final k in [LogicalKeyboardKey.pageUp, LogicalKeyboardKey.mediaTrackNext, LogicalKeyboardKey.mediaFastForward]) {
    testWidgets('${k.debugName} also steps to the next grid', (tester) async {
      final app = await _grid(tester);
      await key(tester, k);
      expect(app.activeGridId, 'g1');
    });
  }

  testWidgets('digit1 opens the LiveScreen of the camera in slot 0', (tester) async {
    await _grid(tester, id: 'g1');
    await key(tester, LogicalKeyboardKey.digit1);
    expect(tester.widget<LiveScreen>(find.byType(LiveScreen)).initialIndex, 2); // cam-c
  });

  testWidgets('digit5 on a quad grid does nothing', (tester) async {
    await _grid(tester, id: 'g1');
    await key(tester, LogicalKeyboardKey.digit5);
    expect(find.byType(LiveScreen), findsNothing);
    expect(find.byType(TvDialog), findsNothing);
  });

  testWidgets('digit3 on an empty tile opens the camera picker', (tester) async {
    await _grid(tester, id: 'g1');
    await key(tester, LogicalKeyboardKey.digit3);
    expect(find.text('Camera for tile 3'), findsOneWidget);
  });

  testWidgets('select on a tile opens that camera live', (tester) async {
    await _grid(tester, id: 'g1');
    expect(_label(), 'grid-first-tile');
    await ok(tester);
    expect(tester.widget<LiveScreen>(find.byType(LiveScreen)).initialIndex, 2);
  });

  testWidgets('arrowUp on the top row focuses the bar entry chip', (tester) async {
    await _grid(tester);
    expect(_label(), 'grid-first-tile');
    await arrow(tester, LogicalKeyboardKey.arrowUp);
    expect(_label(), 'grid-bar-entry');
  });

  testWidgets('arrowDown on the bar focuses the first tile', (tester) async {
    await _grid(tester);
    await arrow(tester, LogicalKeyboardKey.arrowUp);
    await arrow(tester, LogicalKeyboardKey.arrowDown);
    expect(_label(), 'grid-first-tile');
  });

  testWidgets('Back on the bar returns to the tiles; Back again pops GridViewScreen', (tester) async {
    await _grid(tester);
    await arrow(tester, LogicalKeyboardKey.arrowUp);
    await back(tester);
    expect(find.byType(GridViewScreen), findsOneWidget);
    expect(_label(), 'grid-first-tile');
    await back(tester);
    expect(find.byType(GridViewScreen), findsNothing);
  });

  testWidgets('bar chips switch grids on select and keep bar focus', (tester) async {
    final app = await _grid(tester);
    await arrow(tester, LogicalKeyboardKey.arrowUp);
    await arrow(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedText(tester), 'Downstairs');
    await ok(tester);
    expect(app.activeGridId, 'g1');
  });

  testWidgets('Hold OK on an All-grid tile explains the grid is automatic', (tester) async {
    await _grid(tester);
    await holdOk(tester);
    expect(find.text('All cameras is automatic'), findsOneWidget);
  });

  testWidgets('Hold OK on a saved-grid tile opens the camera picker and updates the slot', (tester) async {
    final app = await _grid(tester, id: 'g1');
    await holdOk(tester);
    expect(find.text('Camera for tile 1'), findsOneWidget);
    await focusOn(tester, tvTile('Home Camera E'));
    await ok(tester);
    expect(app.savedGrids.first.slots.first, 'cam-e');
  });

  testWidgets('Back with the picker open closes only the picker', (tester) async {
    await _grid(tester, id: 'g1');
    await holdOk(tester);
    await back(tester);
    expect(find.text('Camera for tile 1'), findsNothing);
    expect(find.byType(GridViewScreen), findsOneWidget);
  });
}