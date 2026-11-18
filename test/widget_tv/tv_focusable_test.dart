// ui.focus.ok_long_press (existing behaviour)
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/ui/tv.dart';

import 'support.dart';

Future<(List<String>, FocusNode, FocusNode)> _pump(WidgetTester tester, {bool withLong = true}) async {
  useTvSurface(tester);
  final events = <String>[];
  final a = FocusNode(), b = FocusNode();
  addTearDown(a.dispose);
  addTearDown(b.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            TvFocusable(
              focusNode: a,
              autofocus: true,
              onSelect: () => events.add('select-a'),
              onLongSelect: withLong ? () => events.add('long-a') : null,
              builder: (_, _) => const SizedBox(width: 100, height: 50),
            ),
            TvFocusable(
              focusNode: b,
              onSelect: () => events.add('select-b'),
              builder: (_, _) => const SizedBox(width: 100, height: 50),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
  return (events, a, b);
}

void main() {
  testWidgets('KeyDown+KeyUp select calls onSelect once', (tester) async {
    final (events, _, _) = await _pump(tester);
    await key(tester, LogicalKeyboardKey.select);
    expect(events, ['select-a']);
  });

  testWidgets('KeyDown, KeyRepeat, KeyUp calls onLongSelect once and not onSelect', (tester) async {
    final (events, _, _) = await _pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    expect(events, ['long-a']);
  });

  testWidgets('KeyDown, wait 700 ms, KeyUp calls onLongSelect', (tester) async {
    final (events, _, _) = await _pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    expect(events, ['long-a']);
  });

  testWidgets('KeyUp without a KeyDown on the same item is ignored', (tester) async {
    final (events, _, b) = await _pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select); // pressed on A
    b.requestFocus(); // the screen changed under the key
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select); // released on B
    expect(events, isNot(contains('select-b')));
  });

  for (final k in [
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.gameButtonA,
    LogicalKeyboardKey.space,
  ]) {
    testWidgets('${k.debugName} acts like select', (tester) async {
      final (events, _, _) = await _pump(tester);
      await key(tester, k);
      expect(events, ['select-a']);
    });
  }

  testWidgets('a focusable without callbacks ignores select keys', (tester) async {
    useTvSurface(tester);
    var bubbled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Focus(
            onKeyEvent: (_, e) {
              bubbled = true;
              return KeyEventResult.ignored;
            },
            child: TvFocusable(autofocus: true, builder: (_, _) => const SizedBox(width: 50, height: 50)),
          ),
        ),
      ),
    );
    await tester.pump();
    await key(tester, LogicalKeyboardKey.select);
    expect(bubbled, isTrue);
  });
}