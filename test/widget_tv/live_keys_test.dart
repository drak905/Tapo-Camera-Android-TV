// ui.live.keys (existing behaviour)
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/screens/live_screen.dart';

import 'support.dart';

Future<TestAppState> _live(WidgetTester tester, {int index = 0, List<Camera>? cameras}) async {
  final app = await pumpApp(tester, cameras: cameras);
  await pushScreen(tester, LiveScreen(initialIndex: index));
  return app;
}

Finder _counter(int n, [int of = 5]) => find.text('Camera $n of $of');

void main() {
  group('pan & tilt', () {
    testWidgets('arrowLeft with a PTZ camera calls move(-step, 0)', (tester) async {
      final app = await _live(tester);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(app.moves, [('cam-a', -10, 0)]);
    });

    testWidgets('arrowUp moves (0,+step), arrowDown (0,-step), arrowRight (+step,0)', (tester) async {
      final app = await _live(tester);
      await key(tester, LogicalKeyboardKey.arrowUp);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(app.moves, [('cam-a', 0, 10), ('cam-a', 0, -10), ('cam-a', 10, 0)]);
    });

    testWidgets('KeyRepeat keeps moving; KeyUp does not', (tester) async {
      final app = await _live(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 20));
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 20));
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 20));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 600));
      expect(app.moves, hasLength(3));
    });

    testWidgets('PTZ step comes from AppState.ptzStep', (tester) async {
      final app = await _live(tester);
      await app.setPtzStep(20);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(app.moves.single, ('cam-a', -20, 0));
    });

    testWidgets('privacy on disables pan & tilt', (tester) async {
      final app = await _live(tester, cameras: [plainCam('cam-a', 'Home Camera A', ptz: true, privacy: true), plainCam('cam-b', 'Home Camera B')]);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(app.moves, isEmpty);
    });
  });

  group('without PTZ', () {
    testWidgets('arrowRight switches to the next camera', (tester) async {
      await _live(tester, index: 1);
      expect(_counter(2), findsOneWidget);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(_counter(3), findsOneWidget);
    });

    testWidgets('arrowLeft switches to the previous camera', (tester) async {
      await _live(tester, index: 1);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(_counter(1), findsOneWidget);
    });

    testWidgets('arrowDown shows the controls', (tester) async {
      await _live(tester, index: 1);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedText(tester), 'Turn privacy on');
    });
  });

  group('controls and Back', () {
    testWidgets('select shows the controls and focuses the first control', (tester) async {
      await _live(tester);
      await ok(tester);
      expect(focusedText(tester), 'Turn privacy on');
    });

    testWidgets('Back with controls hides them; a second Back pops the route', (tester) async {
      await _live(tester);
      await ok(tester);
      await back(tester);
      expect(find.byType(LiveScreen), findsOneWidget);
      await back(tester);
      expect(find.byType(LiveScreen), findsNothing);
    });

    testWidgets('Back without controls pops the route', (tester) async {
      await _live(tester);
      await back(tester);
      expect(find.byType(LiveScreen), findsNothing);
    });

    testWidgets('the controls auto-hide after 8 s', (tester) async {
      await _live(tester);
      await ok(tester);
      await tester.pump(const Duration(seconds: 7));
      await back(tester);
      expect(find.byType(LiveScreen), findsOneWidget, reason: 'Back at 7 s only hides the controls');
      await ok(tester);
      await tester.pump(const Duration(seconds: 9));
      await back(tester);
      expect(find.byType(LiveScreen), findsNothing, reason: 'controls were gone after 8 s, Back pops');
    });

    testWidgets('select on the privacy cover turns privacy off', (tester) async {
      final app = await _live(tester, cameras: [plainCam('cam-a', 'Home Camera A', privacy: true)]);
      expect(find.text('Privacy mode is on'), findsOneWidget);
      await ok(tester);
      expect(app.privacyCalls, [('cam-a', false)]);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('select on a failed stream reconnects instead of showing the controls', (tester) async {
      await _live(tester);
      await tester.pump(const Duration(seconds: 26)); // LiveVideo gives up after 25 s without a picture
      expect(find.text("The camera didn't respond"), findsOneWidget);
      await ok(tester);
      expect(find.text("The camera didn't respond"), findsNothing);
      expect(find.text('Connecting to camera through Tapo cloud…'), findsOneWidget);
      expect(focusedText(tester), isNot('Turn privacy on'));
    });
  });

  group('switching cameras', () {
    for (final k in [
      LogicalKeyboardKey.channelUp,
      LogicalKeyboardKey.pageUp,
      LogicalKeyboardKey.mediaTrackNext,
      LogicalKeyboardKey.mediaFastForward,
    ]) {
      testWidgets('${k.debugName} goes to the next camera and wraps', (tester) async {
        await _live(tester, index: 3);
        await key(tester, k);
        expect(_counter(5), findsOneWidget);
        await key(tester, k);
        expect(_counter(1), findsOneWidget);
      });
    }

    for (final k in [
      LogicalKeyboardKey.channelDown,
      LogicalKeyboardKey.pageDown,
      LogicalKeyboardKey.mediaTrackPrevious,
      LogicalKeyboardKey.mediaRewind,
    ]) {
      testWidgets('${k.debugName} goes to the previous camera and wraps', (tester) async {
        await _live(tester, index: 1);
        await key(tester, k);
        expect(_counter(1), findsOneWidget);
        await key(tester, k);
        expect(_counter(5), findsOneWidget);
      });
    }

    testWidgets('digit2 jumps to camera 2', (tester) async {
      await _live(tester);
      await key(tester, LogicalKeyboardKey.digit2);
      expect(_counter(2), findsOneWidget);
      expect(find.text('Home Camera B'), findsWidgets);
    });

    testWidgets('digit1 on camera 1 only flashes the title', (tester) async {
      await _live(tester);
      await key(tester, LogicalKeyboardKey.digit1);
      expect(_counter(1), findsOneWidget);
    });

    testWidgets('channel keys also work while the controls are shown', (tester) async {
      await _live(tester);
      await ok(tester);
      await key(tester, LogicalKeyboardKey.channelUp);
      expect(_counter(2), findsOneWidget);
    });
  });
}