// ui.keys.shortcuts_select (existing behaviour)
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  for (final k in [LogicalKeyboardKey.select, LogicalKeyboardKey.gameButtonA]) {
    testWidgets('${k.debugName} activates a focused Material button through ActivateIntent', (tester) async {
      useTvSurface(tester);
      var pressed = 0;
      await tester.pumpWidget(
        TopoTvApp(app: AppState()),
      );
      // Replace the app home with a plain Material button under the app shortcuts.
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(body: Center(child: ElevatedButton(autofocus: true, onPressed: () => pressed++, child: const Text('Go')))),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await key(tester, k);
      expect(pressed, 1);
    });
  }
}