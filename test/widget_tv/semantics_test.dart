// ui.a11y.reduce_motion_semantics
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/screens/live_screen.dart';
import 'package:tapo_tv/state/camera_view_model.dart';
import 'package:tapo_tv/ui/theme.dart';
import 'package:tapo_tv/ui/tv.dart';

import 'support.dart';

List<TvButton> _unlabeledButtons(WidgetTester tester) => [
      for (final b in tester.widgetList<TvButton>(find.byType(TvButton, skipOffstage: false)))
        if (b.label.isEmpty && (b.semanticLabel == null || b.semanticLabel!.trim().isEmpty)) b,
    ];

void main() {
  testWidgets('every TvButton with an empty label has a semanticLabel (home)', (tester) async {
    await pumpApp(tester);
    expect(find.byType(TvButton), findsWidgets);
    expect(_unlabeledButtons(tester), isEmpty);
    expect(find.bySemanticsLabel('Refresh cameras'), findsOneWidget);
  });

  testWidgets('baseline defect: the icon-only guide button of the live controls has no semanticLabel', (tester) async {
    await pumpApp(tester);
    await pushScreen(tester, const LiveScreen(initialIndex: 0));
    await ok(tester);
    expect(_unlabeledButtons(tester), isEmpty);
  });

  testWidgets('TvChip exposes button, selected and label semantics', (tester) async {
    final handle = tester.ensureSemantics();
    useTvSurface(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: const Scaffold(
          body: Row(children: [TvChip(label: 'Chosen', selected: true), TvChip(label: 'Other', selected: false)]),
        ),
      ),
    );
    final chosen = tester.getSemantics(find.text('Chosen'));
    final other = tester.getSemantics(find.text('Other'));
    expect(chosen.label, contains('Chosen'));
    expect(chosen.flagsCollection.isSelected.name, isNot(other.flagsCollection.isSelected.name));
    expect(chosen.flagsCollection.isButton, isTrue);
    handle.dispose();
  });

  testWidgets('TvButton exposes enabled state and label', (tester) async {
    final handle = tester.ensureSemantics();
    useTvSurface(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: Row(children: [TvButton(label: 'Go', onPressed: () {}), const TvButton(label: 'Stop')]),
        ),
      ),
    );
    expect(tester.getSemantics(find.text('Go')).label, contains('Go'));
    expect(tester.getSemantics(find.text('Go')).flagsCollection.isEnabled.name, isNot(tester.getSemantics(find.text('Stop')).flagsCollection.isEnabled.name));
    handle.dispose();
  });

  testWidgets('camera cards carry "<number>. <name>, <status>" labels', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpApp(tester);
    expect(find.bySemanticsLabel(RegExp(r'^1\. Home Camera A, ')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^2\. Home Camera B, ')), findsOneWidget);
    handle.dispose();
  });

  testWidgets('NEW: HUD and quick-action buttons for rename, siren, night vision and recordings expose labels', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpApp(tester, cameras: [
      viewCam('cam-a', 'Home Camera A', caps: {CameraCapability.nightVision, CameraCapability.siren, CameraCapability.sdCard}),
      viewCam('cam-b', 'Home Camera B'),
    ]);
    await pushScreen(tester, const LiveScreen(initialIndex: 0));
    await ok(tester);
    for (final label in ['Rename', 'Siren', 'Recordings']) {
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
    }
    expect(find.bySemanticsLabel(RegExp('^Night vision')), findsOneWidget);
    handle.dispose();
  });

  testWidgets('reduce motion: focus ring does not scale', (tester) async {
    useTvSurface(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: tvSize, disableAnimations: true),
          child: Scaffold(body: Center(child: TvButton(label: 'Go', autofocus: true, onPressed: () {}))),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1.0);
  });
}