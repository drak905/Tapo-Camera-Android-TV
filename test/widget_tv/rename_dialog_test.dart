// ui.camera.rename and ui.camera.local_name_shared (new)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/screens/rename_dialog.dart';
import 'package:tapo_tv/state/camera_actions.dart';
import 'package:tapo_tv/ui/theme.dart';
import 'package:tapo_tv/ui/tv.dart';

import 'support.dart';

/// Hosts the dialog; the result lands in the returned notifier.
Future<ValueNotifier<String?>> _open(WidgetTester tester, {String name = 'Home Camera A', bool localOnly = false}) async {
  await tester.runAsync(loadTestFonts);
  useTvSurface(tester);
  final result = ValueNotifier<String?>('(pending)');
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TvButton(
              label: 'Open',
              autofocus: true,
              onPressed: () async => result.value = await showRenameDialog(context, currentName: name, localOnly: localOnly),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await ok(tester);
  return result;
}

/// Types [text] through the TV keyboard dialog of the name field.
Future<void> _type(WidgetTester tester, String text) async {
  await tester.tap(find.byType(TvTextField));
  await settle(tester);
  await tester.enterText(find.byType(TextField), text);
  await tester.tap(tvButton('Done'));
  await settle(tester);
}

bool _saveEnabled(WidgetTester tester) => tester.widget<TvButton>(tvButton('Save')).onPressed != null;

void main() {
  group('rename dialog', () {
    testWidgets('is pre-filled with the current name and Save is disabled when unchanged', (tester) async {
      await _open(tester);
      expect(find.text('Home Camera A'), findsWidgets);
      expect(_saveEnabled(tester), isFalse);
    });

    testWidgets('select on the name field opens the TV text entry; a valid name enables Save; Save pops the name', (tester) async {
      final result = await _open(tester);
      await _type(tester, 'Front Porch');
      expect(_saveEnabled(tester), isTrue);
      await tester.tap(tvButton('Save'));
      await settle(tester, const Duration(milliseconds: 600));
      expect(result.value, 'Front Porch');
    });

    testWidgets('an empty name shows "Enter a name." and disables Save', (tester) async {
      await _open(tester);
      await _type(tester, '   ');
      expect(find.text('Enter a name.'), findsOneWidget);
      expect(_saveEnabled(tester), isFalse);
    });

    testWidgets('a tab or line break is rejected', (tester) async {
      await _open(tester);
      await _type(tester, 'Front\tPorch');
      expect(find.text('The name cannot contain line breaks or tabs.'), findsOneWidget);
      expect(_saveEnabled(tester), isFalse);
    });

    testWidgets('32 ASCII bytes are valid, 33 are not (with the byte count)', (tester) async {
      await _open(tester);
      await _type(tester, 'A' * 32);
      expect(_saveEnabled(tester), isTrue);
      await _type(tester, 'A' * 33);
      expect(find.text('The name is too long (33 of 32 bytes). Letters with accents count as 2-3 bytes.'), findsOneWidget);
      expect(_saveEnabled(tester), isFalse);
    });

    testWidgets('accented letters count by their UTF-8 bytes', (tester) async {
      await _open(tester);
      await _type(tester, 'é' * 16); // 32 bytes
      expect(_saveEnabled(tester), isTrue);
      await _type(tester, 'é' * 17); // 34 bytes
      expect(find.textContaining('34 of 32 bytes'), findsOneWidget);
    });

    testWidgets('a decomposed accent is composed (NFC) and trimmed before saving', (tester) async {
      final result = await _open(tester);
      await _type(tester, '  Cafe\u0301 Door ');
      await tester.tap(tvButton('Save'));
      await settle(tester, const Duration(milliseconds: 600));
      expect(result.value, 'Caf\u00e9 Door');
    });

    testWidgets('an owned camera explains the name is saved on the camera', (tester) async {
      await _open(tester);
      expect(find.textContaining('Tapo app'), findsOneWidget);
      expect(find.textContaining('only used on this TV'), findsNothing);
    });

    testWidgets('a shared camera explains the name is only used on this TV', (tester) async {
      await _open(tester, localOnly: true);
      expect(find.textContaining('only used on this TV'), findsOneWidget);
      expect(find.textContaining('Tapo app'), findsNothing);
    });

    testWidgets('Back cancels without a result', (tester) async {
      final result = await _open(tester);
      await back(tester);
      expect(find.byType(RenameDialog), findsNothing);
      expect(result.value, isNull);
    });

    testWidgets('Cancel button cancels without a result', (tester) async {
      final result = await _open(tester);
      await tester.tap(tvButton('Cancel'));
      await settle(tester, const Duration(milliseconds: 600));
      expect(result.value, isNull);
    });

    testWidgets('initial focus is on the name field and the dialog fits the safe area', (tester) async {
      await _open(tester);
      expect(focusedText(tester), 'Home Camera A');
      for (final r in focusableRects(tester)) {
        expect(safeRect.contains(r.topLeft) && safeRect.contains(r.bottomRight), isTrue, reason: '$r');
      }
    });
  });

  group('rename through the quick actions', () {
    Future<void> rename(WidgetTester tester, String card, String newName) async {
      await focusOn(tester, find.text(card));
      await holdOk(tester);
      await focusOn(tester, tvTile('Rename'));
      await ok(tester);
      await _type(tester, newName);
      await tester.tap(tvButton('Save'));
      await settle(tester, const Duration(milliseconds: 800));
    }

    testWidgets('owned camera: renames on the camera and the card title updates immediately', (tester) async {
      final fake = FakeCameraActions();
      await pumpApp(tester, cameras: [viewCam('cam-a', 'Home Camera A')], actions: fake);
      await rename(tester, 'Home Camera A', 'Porch');
      expect(fake.renameOnCameraCalls, [('cam-a', 'Porch')]);
      expect(fake.localNameCalls, isEmpty);
      expect(find.text('Porch'), findsOneWidget);
      expect(find.text('Home Camera A'), findsNothing);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('shared camera: stores a local name only, no passthrough call', (tester) async {
      final fake = FakeCameraActions();
      await pumpApp(tester, cameras: [viewCam('cam-a', 'Home Camera A', shared: true)], actions: fake);
      await rename(tester, 'Home Camera A', 'Porch');
      expect(fake.localNameCalls, [('cam-a', 'Porch')]);
      expect(fake.renameOnCameraCalls, isEmpty);
      expect(find.text('Porch'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('Reset to camera name removes the local name', (tester) async {
      final fake = FakeCameraActions();
      await pumpApp(tester, cameras: [viewCam('cam-a', 'Home Camera A', shared: true, localName: 'Porch')], actions: fake);
      await focusOn(tester, find.text('Porch'));
      await holdOk(tester);
      await focusOn(tester, tvTile('Reset to camera name'));
      await ok(tester);
      await settle(tester, const Duration(milliseconds: 800));
      expect(fake.localNameCalls, [('cam-a', null)]);
      expect(find.text('Home Camera A'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('the cloud refusing the name (-63103) shows a friendly message and keeps the old name', (tester) async {
      final fake = FakeCameraActions()..failRename = const CameraActionException('refused', code: -63103);
      await pumpApp(tester, cameras: [viewCam('cam-a', 'Home Camera A')], actions: fake);
      await rename(tester, 'Home Camera A', 'Porch');
      expect(find.text('The camera refused this name. Use a shorter name with letters, numbers and spaces.'), findsOneWidget);
      expect(find.text('Home Camera A'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });
  });
}