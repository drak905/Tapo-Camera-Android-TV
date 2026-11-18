// ui.settings.panel (existing) and ui.settings.new_entries (new)
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tapo_tv/state/camera_sort.dart';
import 'package:tapo_tv/ui/tv.dart';

import 'support.dart';

Future<TestAppState> _settings(WidgetTester tester, {List<Camera>? cameras, Map<String, Object> prefs = const {}, FakeCameraActions? actions}) async {
  final app = await pumpApp(tester, cameras: cameras, prefs: prefs, actions: actions);
  await focusOn(tester, find.text('Settings'));
  await ok(tester);
  await settle(tester, const Duration(milliseconds: 500));
  return app;
}

String? _pill(WidgetTester tester, String title) {
  final tile = tester.widget<TvTile>(tvTile(title));
  final trailing = tile.trailing;
  if (trailing == null) return null;
  final text = find.descendant(of: find.byWidget(trailing), matching: find.byType(Text));
  return text.evaluate().isEmpty ? null : tester.widget<Text>(text.first).data;
}

Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

void main() {
  group('existing entries', () {
    testWidgets('first focus below the nav row is Tapo account', (tester) async {
      await _settings(tester);
      await arrow(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedText(tester), 'Tapo account');
    });

    testWidgets('items keep their order', (tester) async {
      await _settings(tester);
      final ys = [
        for (final t in ['Tapo account', 'Live previews on the camera list', 'Pan & tilt step', 'Remote control guide', 'Sign out'])
          tester.getTopLeft(find.text(t)).dy,
      ];
      expect(ys, orderedEquals([...ys]..sort()));
    });

    testWidgets('select on Live previews toggles AppState.livePreviews once', (tester) async {
      final app = await _settings(tester, prefs: {'live_previews': true});
      await focusOn(tester, tvTile('Live previews on the camera list'));
      await ok(tester);
      expect(app.livePreviews, isFalse);
      await ok(tester);
      expect(app.livePreviews, isTrue);
    });

    testWidgets('the switch itself never takes focus', (tester) async {
      await _settings(tester);
      await focusOn(tester, tvTile('Live previews on the camera list'));
      await arrow(tester, LogicalKeyboardKey.arrowRight);
      expect(find.byType(Switch), findsOneWidget);
      expect(Focus.of(tester.element(find.byType(Switch))).hasPrimaryFocus, isFalse);
    });

    testWidgets('select on Pan & tilt step cycles 10 -> 20 -> 5 -> 10', (tester) async {
      final app = await _settings(tester);
      await focusOn(tester, tvTile('Pan & tilt step'));
      for (final step in [20, 5, 10]) {
        await ok(tester);
        expect(app.ptzStep, step);
        expect(find.text('$step°'), findsOneWidget);
      }
    });

    testWidgets('Sign out opens a confirm with Cancel focused; Back cancels', (tester) async {
      final app = await _settings(tester);
      await focusOn(tester, tvTile('Sign out'));
      await ok(tester);
      expect(find.text('Sign out?'), findsOneWidget);
      expect(focusedText(tester), 'Cancel');
      await back(tester);
      expect(find.text('Sign out?'), findsNothing);
      expect(app.stage, AuthStage.signedIn);
    });

    testWidgets('the info card shows the app version', (tester) async {
      await _settings(tester);
      expect(find.text('Topo TV 1.2.0'), findsOneWidget);
    });
  });

  group('NEW entries', () {
    testWidgets('Camera sort tile cycles Name A-Z -> Name Z-A -> Account order and persists', (tester) async {
      final app = await _settings(tester);
      await focusOn(tester, tvTile('Camera sort'));
      expect(_pill(tester, 'Camera sort'), 'Name A-Z');
      await ok(tester);
      expect(app.cameraSort, CameraSort.nameDesc);
      expect(_pill(tester, 'Camera sort'), 'Name Z-A');
      expect((await _prefs()).getString('camera_sort'), 'name_desc');
      await ok(tester);
      expect(app.cameraSort, CameraSort.account);
      expect((await _prefs()).getString('camera_sort'), 'account');
      await ok(tester);
      expect(app.cameraSort, CameraSort.nameAsc);
      expect((await _prefs()).getString('camera_sort'), 'name_asc');
    });

    testWidgets('Max remote streams defaults to 4 and cycles within 1..8, persisting', (tester) async {
      final app = await _settings(tester);
      await focusOn(tester, tvTile('Max remote streams'));
      expect(app.maxRemoteStreams, 4);
      expect(_pill(tester, 'Max remote streams'), '4');
      final seen = <int>[];
      for (var i = 0; i < 8; i++) {
        await ok(tester);
        seen.add(app.maxRemoteStreams);
      }
      expect(seen, [5, 6, 7, 8, 1, 2, 3, 4]);
      expect((await _prefs()).getInt('max_remote_streams'), 4);
    });

    testWidgets('a stored out-of-range value is clamped to 1..8', (tester) async {
      final app = await _settings(tester, prefs: {'max_remote_streams': 99});
      expect(app.maxRemoteStreams, inInclusiveRange(1, 8));
    });

    testWidgets('Remember password on this TV is off by default and toggles on select', (tester) async {
      final app = await _settings(tester);
      await focusOn(tester, tvTile('Remember password on this TV'));
      expect(app.rememberPassword, isFalse);
      await ok(tester);
      expect(app.rememberPassword, isTrue);
      await ok(tester);
      expect(app.rememberPassword, isFalse);
    });

    group('Camera account', () {
      Future<(TestAppState, FakeCameraActions)> open(WidgetTester tester) async {
        final fake = FakeCameraActions();
        final app = await _settings(tester, actions: fake);
        await focusOn(tester, tvTile('Camera account'));
        expect(tester.widget<TvTile>(tvTile('Camera account')).subtitle, 'Not set (optional)');
        await ok(tester);
        // The account is per camera: pick the camera first.
        await focusOn(tester, tvTile('Home Camera B'));
        await ok(tester);
        await settle(tester, const Duration(milliseconds: 600));
        return (app, fake);
      }

      Future<void> enter(WidgetTester tester, String label, String text) async {
        await focusOn(tester, find.byWidgetPredicate((w) => w is TvTextField && w.label == label));
        await ok(tester);
        await tester.enterText(find.byType(TextField), text);
        await tester.tap(tvButton('Done'));
        await settle(tester);
      }

      testWidgets('select picks a camera first, then shows username and password fields', (tester) async {
        await open(tester);
        expect(find.byWidgetPredicate((w) => w is TvTextField && w.label == 'Username'), findsOneWidget);
        expect(find.byWidgetPredicate((w) => w is TvTextField && w.label == 'Password'), findsOneWidget);
        expect(find.textContaining('Home Camera B'), findsWidgets);
      });

      testWidgets('the password field is obscured and select on username opens the TV keyboard', (tester) async {
        await open(tester);
        final password = tester.widget<TvTextField>(find.byWidgetPredicate((w) => w is TvTextField && w.label == 'Password'));
        expect(password.obscure, isTrue);
        await focusOn(tester, find.byWidgetPredicate((w) => w is TvTextField && w.label == 'Username'));
        await ok(tester);
        expect(find.byType(TextField), findsOneWidget);
      });

      testWidgets('Save with empty fields clears the account', (tester) async {
        final (_, fake) = await open(tester);
        await tester.tap(tvButton('Save'));
        await settle(tester);
        expect(fake.accountClears, ['cam-b']);
        expect(fake.accountSaves, isEmpty);
        expect(fake.accountTests, isEmpty);
      });

      testWidgets('Save performs at most one login attempt when it fails', (tester) async {
        final (_, fake) = await open(tester);
        fake.accountTestResult = false;
        await enter(tester, 'Username', 'camuser');
        await enter(tester, 'Password', 'S3cret-pass');
        await tester.tap(tvButton('Save'));
        await settle(tester);
        await tester.pump(const Duration(seconds: 30));
        expect(fake.accountTests, hasLength(1));
        expect(fake.accountSaves, isEmpty, reason: 'a failed test is not saved');
        expect(find.text('Could not sign in to the camera with this account.'), findsOneWidget);
      });

      testWidgets('a successful save stores through the secure interface, never in SharedPreferences', (tester) async {
        final (_, fake) = await open(tester);
        fake.accountTestResult = true;
        await enter(tester, 'Username', 'camuser');
        await enter(tester, 'Password', 'S3cret-pass');
        await tester.tap(tvButton('Save'));
        await settle(tester, const Duration(milliseconds: 800));
        expect(fake.accountSaves, [('cam-b', 'camuser', 'S3cret-pass')]);
        final prefs = await _prefs();
        for (final k in prefs.getKeys()) {
          expect('${prefs.get(k)}', isNot(contains('S3cret-pass')), reason: 'key $k');
        }
        expect(tester.widget<TvTile>(tvTile('Camera account')).subtitle, isNot('Not set (optional)'));
      });
    });

    testWidgets('every settings tile is reachable with the D-pad inside the safe area', (tester) async {
      await _settings(tester);
      final titles = <String>{};
      await arrow(tester, LogicalKeyboardKey.arrowDown);
      for (var i = 0; i < 12; i++) {
        final t = focusedText(tester);
        if (t != null) titles.add(t);
        final r = FocusManager.instance.primaryFocus!.rect;
        expect(r.left, greaterThanOrEqualTo(safeRect.left));
        expect(r.right, lessThanOrEqualTo(safeRect.right));
        await arrow(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(titles, containsAll(['Camera sort', 'Max remote streams', 'Camera account', 'Remember password on this TV', 'Sign out']));
    });
  });
}