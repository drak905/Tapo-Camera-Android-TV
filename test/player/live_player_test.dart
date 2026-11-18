// mb.exo.ts_flags_and_source (error mapping), mb.exo.focus_emulator (focus-less view).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/player/live_player.dart';

void main() {
  group('error mapping uses bridge lastErrors', () {
    test('bridge error wins over the player message', () {
      expect(mapPlayerError(bridgeError: 'Camera is offline', playerMessage: 'HTTP 502'), 'Camera is offline');
    });

    test('player message is used without a bridge error', () {
      expect(mapPlayerError(playerMessage: 'Source error'), 'Source error');
    });

    test('fallback text when neither is known', () {
      expect(mapPlayerError(), 'Stream interrupted');
      expect(mapPlayerError(bridgeError: '', playerMessage: ''), 'Stream interrupted');
    });
  });

  testWidgets('native view excluded from focus traversal', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: Focus(autofocus: true, child: excludeNativeFocus(const SizedBox(width: 10, height: 10)))),
    );
    final exclude = tester.widget<ExcludeFocus>(find.byType(ExcludeFocus).last);
    expect(exclude.excluding, isTrue);
  });

  test('creation params carry url and snapshot path', () {
    expect(
      nativeVideoParams(url: 'http://127.0.0.1:1/camera/D.ts?k=x', snapshotPath: '/cache/D.jpg'),
      {'url': 'http://127.0.0.1:1/camera/D.ts?k=x', 'snapshot': '/cache/D.jpg'},
    );
  });
}
