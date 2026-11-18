// ui.guide.remote_table (existing rows pass; new Recordings rows and changed details fail)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/ui/guide.dart';
import 'package:tapo_tv/ui/theme.dart';

import 'support.dart';

Future<void> _open(WidgetTester tester, GuideSection s) async {
  await tester.runAsync(loadTestFonts);
  tolerateBaselineGuideOverflow();
  useTvSurface(tester);
  await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: RemoteGuide(initial: s)));
  await tester.pump(const Duration(milliseconds: 400));
}

Finder _rowLabel(String text) => find.text(text);

/// Rows are in a lazy list: scroll until the label is built.
Future<void> _expectRow(WidgetTester tester, String label) async {
  if (_rowLabel(label).evaluate().isEmpty) {
    await tester.scrollUntilVisible(_rowLabel(label), 80, scrollable: find.byType(Scrollable).last);
  }
  expect(_rowLabel(label), findsOneWidget, reason: label);
}

void main() {
  const expected = <GuideSection, List<String>>{
    GuideSection.basics: ['Move around', 'Select', 'Go back', 'Remote guide', 'Typing'],
    GuideSection.home: ['Watch live', 'Quick actions', 'Jump to camera', 'Top menu'],
    GuideSection.multiview: ['Open a grid', 'Switch grid', 'Grid bar', 'Full screen', 'Change a tile'],
    GuideSection.live: ['Pan & tilt', 'Show controls', 'Switch camera', 'Back'],
  };

  for (final entry in expected.entries) {
    testWidgets('${entry.key.name} lists its rows', (tester) async {
      await _open(tester, entry.key);
      for (final label in entry.value) {
        await _expectRow(tester, label);
      }
    });
  }

  testWidgets('the autofocused chip is the initial section', (tester) async {
    await _open(tester, GuideSection.multiview);
    expect(focusedText(tester), 'Multi-view');
    await tester.pumpWidget(const SizedBox());
    await _open(tester, GuideSection.live);
    expect(focusedText(tester), 'Live view');
  });

  testWidgets('selecting a chip switches the rows', (tester) async {
    await _open(tester, GuideSection.basics);
    await tester.tap(tvChip('Cameras'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_rowLabel('Quick actions'), findsOneWidget);
    expect(_rowLabel('Move around'), findsNothing);
  });

  testWidgets('NEW: Recordings section lists scrub, day and play rows', (tester) async {
    await _open(tester, GuideSection.recordings);
    expect(focusedText(tester), 'Recordings');
    for (final label in ['Scrub', 'Change day', 'Play']) {
      await _expectRow(tester, label);
    }
    expect(find.textContaining('Left'), findsWidgets);
    expect(find.textContaining('Right'), findsWidgets);
  });

  testWidgets('NEW: Quick actions row names the new entries', (tester) async {
    await _open(tester, GuideSection.home);
    final detail = find.byWidgetPredicate((w) => w is Text && (w.data ?? '').toLowerCase().contains('night vision'));
    expect(detail, findsOneWidget);
  });

  testWidgets('NEW: Show controls row mentions Recordings', (tester) async {
    await _open(tester, GuideSection.live);
    expect(find.byWidgetPredicate((w) => w is Text && (w.data ?? '').length > 25 && w.data!.contains('Recordings')), findsOneWidget);
  });
}