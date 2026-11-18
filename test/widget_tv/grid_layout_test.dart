// ui.grid.layouts (existing behaviour, widget part)
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/screens/multiview_screen.dart';
import 'package:tapo_tv/state/grids.dart';
import 'package:tapo_tv/ui/tv.dart';

import 'support.dart';

void main() {
  testWidgets('TileLayout puts the 1+5 big tile on 2x2 cells and the rest on 1x1 cells', (tester) async {
    useTvSurface(tester);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 300,
            height: 300,
            child: TileLayout(layout: GridLayout.onePlusFive, gap: 0, builder: (i) => SizedBox(key: ValueKey('tile-$i'))),
          ),
        ),
      ),
    );
    final origin = tester.getTopLeft(find.byType(TileLayout));
    expect(tester.getSize(find.byKey(const ValueKey('tile-0'))), const Size(200, 200));
    expect(tester.getTopLeft(find.byKey(const ValueKey('tile-1'))) - origin, const Offset(200, 0));
    expect(tester.getSize(find.byKey(const ValueKey('tile-1'))), const Size(100, 100));
    expect(tester.getTopLeft(find.byKey(const ValueKey('tile-5'))) - origin, const Offset(200, 200));
  });

  testWidgets('"two" tiles sit in the vertical middle of a 2x2 canvas', (tester) async {
    useTvSurface(tester);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 200,
            height: 200,
            child: TileLayout(layout: GridLayout.two, gap: 0, builder: (i) => SizedBox(key: ValueKey('tile-$i'))),
          ),
        ),
      ),
    );
    final origin = tester.getTopLeft(find.byType(TileLayout));
    expect(tester.getTopLeft(find.byKey(const ValueKey('tile-0'))) - origin, const Offset(0, 50));
    expect(tester.getSize(find.byKey(const ValueKey('tile-0'))), const Size(100, 100));
  });

  testWidgets('the All cameras grid is automatic and Hold OK on a tile explains it', (tester) async {
    final app = await pumpApp(tester);
    expect(app.allCamerasGrid.layout, GridLayout.onePlusFive);
    await pushScreen(tester, const GridViewScreen(gridId: 'all'));
    await holdOk(tester);
    expect(find.text('All cameras is automatic'), findsOneWidget);
    expect(find.descendant(of: find.byType(TvDialog), matching: tvButton('Save a copy')), findsOneWidget);
    expect(focusedText(tester), 'Cancel');
  });

  testWidgets('a saved grid can be the active grid on start', (tester) async {
    final app = await pumpApp(tester, prefs: {
      'grids': jsonEncode([
        {'id': 'g1', 'name': 'Downstairs', 'layout': 'two', 'slots': ['cam-a', 'cam-b']},
      ]),
      'active_grid': 'g1',
    });
    expect(app.activeGridId, 'g1');
    expect(app.gridById('g1').name, 'Downstairs');
    expect(tvButton('x'), findsNothing);
    expect(find.byType(TvCard), findsWidgets);
    expect(LogicalKeyboardKey.select, isNotNull);
  });
}