// ui.focus.ring (existing behaviour). Decoration checks, no goldens.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/ui/theme.dart';
import 'package:tapo_tv/ui/tv.dart';

import 'support.dart';

Future<void> _pumpRing(WidgetTester tester, {required bool focused, bool onMedia = false, bool reduce = false, bool pinned = false}) async {
  useTvSurface(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: tvSize, disableAnimations: reduce),
        child: Scaffold(
          body: Center(
            child: FocusRing(
              focused: focused,
              onMedia: onMedia,
              scale: !pinned,
              radius: TopoRadius.md,
              child: const SizedBox(width: 120, height: 48),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
}

BoxDecoration _outer(WidgetTester tester) {
  final box = find.descendant(of: find.byType(FocusRing), matching: find.byType(Container)).first;
  return tester.widget<Container>(box).decoration! as BoxDecoration;
}

void main() {
  testWidgets('focused FocusRing paints a 3-unit primaryPressed border inset -6', (tester) async {
    await _pumpRing(tester, focused: true, pinned: true);
    final pos = tester.widget<Positioned>(find.descendant(of: find.byType(FocusRing), matching: find.byType(Positioned)));
    expect([pos.left, pos.top, pos.right, pos.bottom], [-6.0, -6.0, -6.0, -6.0]);
    final border = _outer(tester).border! as Border;
    expect(border.top.width, 3);
    expect(border.top.color, TopoColors.primaryPressed);
    expect(TopoColors.primaryPressed, const Color(0xFF005A99));
    // The outline is drawn 6 units outside the 120x48 child.
    final ring = tester.getRect(find.descendant(of: find.byType(FocusRing), matching: find.byType(Container)).first);
    final child = tester.getRect(find.byWidgetPredicate((w) => w is SizedBox && w.width == 120));
    expect(ring, child.inflate(6));
  });

  testWidgets('an unfocused ring paints nothing', (tester) async {
    await _pumpRing(tester, focused: false);
    expect(find.descendant(of: find.byType(FocusRing), matching: find.byType(Positioned)), findsNothing);
  });

  testWidgets('onMedia adds a white inner border of width 3', (tester) async {
    await _pumpRing(tester, focused: true, onMedia: true);
    final containers = find.descendant(of: find.byType(FocusRing), matching: find.byType(Container));
    expect(containers, findsNWidgets(2));
    final inner = tester.widget<Container>(containers.last).decoration! as BoxDecoration;
    final border = inner.border! as Border;
    expect(border.top.color, Colors.white);
    expect(border.top.width, 3);
  });

  testWidgets('without onMedia there is no white inner edge', (tester) async {
    await _pumpRing(tester, focused: true);
    expect(find.descendant(of: find.byType(FocusRing), matching: find.byType(Container)), findsOneWidget);
  });

  testWidgets('scale is 1.04 on focus and 1.0 with disableAnimations', (tester) async {
    await _pumpRing(tester, focused: true);
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1.04);
    await _pumpRing(tester, focused: true, reduce: true);
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1.0);
  });

  testWidgets('moving focus with arrowRight never calls onSelect', (tester) async {
    useTvSurface(tester);
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              for (var i = 0; i < 3; i++)
                TvButton(label: 'B$i', autofocus: i == 0, onPressed: () => selected++),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await arrow(tester, LogicalKeyboardKey.arrowRight, 2);
    expect(selected, 0);
    expect(focusedText(tester), 'B2');
  });
}