// ui.dialogs.back_and_focus (existing behaviour)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/ui/theme.dart';
import 'package:tapo_tv/ui/tv.dart';

import 'support.dart';

Future<ValueNotifier<bool?>> _open(WidgetTester tester) async {
  await tester.runAsync(loadTestFonts);
  useTvSurface(tester);
  final result = ValueNotifier<bool?>(null);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TvButton(
              label: 'Open',
              autofocus: true,
              onPressed: () async => result.value = await confirmDialog(
                context,
                title: 'Delete it?',
                message: 'Really delete the thing.',
                confirmLabel: 'Delete',
                danger: true,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await ok(tester);
  await tester.pump(const Duration(milliseconds: 400));
  return result;
}

void main() {
  testWidgets('confirmDialog autofocus is Cancel', (tester) async {
    await _open(tester);
    expect(find.text('Delete it?'), findsOneWidget);
    expect(focusedText(tester), 'Cancel');
  });

  testWidgets('Back closes the dialog and returns false', (tester) async {
    final result = await _open(tester);
    await back(tester);
    expect(find.text('Delete it?'), findsNothing);
    expect(result.value, false);
  });

  testWidgets('select on Delete returns true', (tester) async {
    final result = await _open(tester);
    await focusOn(tester, tvButton('Delete'));
    await ok(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(result.value, true);
  });

  testWidgets('dialog width is at most 560 at 960x540', (tester) async {
    await _open(tester);
    final width = tester.getSize(find.descendant(of: find.byType(TvDialog), matching: find.byType(SingleChildScrollView))).width;
    expect(width, lessThanOrEqualTo(560));
  });
}