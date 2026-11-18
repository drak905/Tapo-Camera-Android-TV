// ui.camera.badge_local_cloud (new)
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/screens/live_screen.dart';
import 'package:tapo_tv/screens/multiview_screen.dart';
import 'package:tapo_tv/state/camera_view_model.dart';
import 'package:tapo_tv/ui/route_badge.dart';
import 'package:tapo_tv/ui/theme.dart';

import 'support.dart';

Future<void> _badge(WidgetTester tester, CameraRoute route, bool online) async {
  useTvSurface(tester);
  await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: Center(child: RouteBadge(route: route, online: online)))));
  await tester.pump();
}

void main() {
  group('the badge widget', () {
    testWidgets('online + local shows "Local"', (tester) async {
      await _badge(tester, CameraRoute.local, true);
      expect(find.text('Local'), findsOneWidget);
      expect(find.byType(Icon), findsOneWidget, reason: 'colour is not the only cue');
    });

    testWidgets('online + cloud shows "Cloud"', (tester) async {
      await _badge(tester, CameraRoute.cloud, true);
      expect(find.text('Cloud'), findsOneWidget);
    });

    testWidgets('offline shows "Offline" for any route', (tester) async {
      await _badge(tester, CameraRoute.cloud, false);
      expect(find.text('Offline'), findsOneWidget);
      await _badge(tester, CameraRoute.local, false);
      expect(find.text('Offline'), findsOneWidget);
    });

    testWidgets('the badge exposes a Semantics label', (tester) async {
      final handle = tester.ensureSemantics();
      await _badge(tester, CameraRoute.local, true);
      expect(find.bySemanticsLabel(RegExp('Local')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('Local uses the success colour', (tester) async {
      await _badge(tester, CameraRoute.local, true);
      final text = tester.widget<Text>(find.text('Local'));
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(text.style?.color == TopoColors.success || icon.color == TopoColors.success, isTrue);
    });
  });

  group('on screens', () {
    testWidgets('home cards: LAN-found owned camera shows Local; shared and remote show Cloud', (tester) async {
      await pumpApp(tester, cameras: [
        viewCam('cam-a', 'Home Camera A', route: CameraRoute.local),
        viewCam('cam-b', 'Home Camera B', route: CameraRoute.cloud),
        viewCam('cam-c', 'Home Camera C', route: CameraRoute.local, shared: true),
        viewCam('cam-d', 'Home Camera D', route: CameraRoute.cloud, online: false),
      ]);
      expect(find.byType(RouteBadge), findsNWidgets(4));
      expect(find.text('Local'), findsOneWidget);
      expect(find.text('Cloud'), findsNWidgets(2));
      expect(find.text('Offline'), findsOneWidget);
    });

    testWidgets('a shared camera is always Cloud, even if the route says local', (tester) async {
      await pumpApp(tester, cameras: [viewCam('cam-c', 'Home Camera C', route: CameraRoute.local, shared: true)]);
      expect(find.text('Cloud'), findsOneWidget);
      expect(find.text('Local'), findsNothing);
    });

    testWidgets('live top bar shows the badge', (tester) async {
      await pumpApp(tester, cameras: [viewCam('cam-a', 'Home Camera A', route: CameraRoute.local)]);
      await pushScreen(tester, const LiveScreen(initialIndex: 0));
      expect(find.descendant(of: find.byType(LiveScreen), matching: find.byType(RouteBadge)), findsOneWidget);
      expect(find.text('Local'), findsOneWidget);
    });

    testWidgets('grid tiles show a badge in the corner', (tester) async {
      await pumpApp(tester, cameras: [
        viewCam('cam-a', 'Home Camera A', route: CameraRoute.local),
        viewCam('cam-b', 'Home Camera B', route: CameraRoute.cloud),
      ], prefs: {
        'grids': jsonEncode([
          {'id': 'g1', 'name': 'Pair', 'layout': 'two', 'slots': ['cam-a', 'cam-b']},
        ]),
      });
      await pushScreen(tester, const GridViewScreen(gridId: 'g1'));
      expect(find.byType(RouteBadge), findsNWidgets(2));
    });

    testWidgets('the badge follows route changes (discovery flips)', (tester) async {
      final app = await pumpApp(tester, cameras: [viewCam('cam-a', 'Home Camera A', route: CameraRoute.cloud)]);
      expect(find.text('Cloud'), findsOneWidget);
      final cam = app.cameras.first;
      cam.view = CameraViewModel(id: 'cam-a', displayName: 'Home Camera A', model: 'C200', route: CameraRoute.local);
      app.notifyListeners();
      await settle(tester);
      expect(find.text('Local'), findsOneWidget);
    });
  });
}