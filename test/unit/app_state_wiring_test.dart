// Wiring between AppState, the secure store and the api/media lanes.
// Spec: ui.camera.*, hc.storage.secure (password opt-in, default off),
// ev.source.no_camera_account (motion toast feed).
//
// Only fakes: no network, no camera. Code that calls api-lane functions is
// covered by the lanes' own tests.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tapo_tv/api/camera_router.dart' as api;
import 'package:tapo_tv/api/tapo_cloud.dart';
import 'package:tapo_tv/api/tapo_errors.dart';
import 'package:tapo_tv/state/app_state.dart';
import 'package:tapo_tv/state/camera_actions.dart';
import 'package:tapo_tv/state/camera_actions_impl.dart';
import 'package:tapo_tv/state/camera_view_model.dart';
import 'package:tapo_tv/state/secure_store.dart';

/// Records what AppState asks of the secure store.
class _FakeStore implements SecureStore {
  int migrations = 0;
  String? legacyValue;

  @override
  Future<bool> migrateLegacySession(LegacySessionPrefs prefs) async {
    migrations++;
    legacyValue = prefs.getString('session');
    await prefs.remove('session');
    return legacyValue != null;
  }

  @override
  Future<StoredSession?> loadSession() async => null;

  @override
  Future<String> terminalUuid() async => 'A1B2C3D4E5F60718293A4B5C6D7E8F90';

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

class _Actions extends DemoCameraActions {
  final events = StreamController<MotionEvent>.broadcast();
  @override
  Stream<MotionEvent> get motionEvents => events.stream;
}

Future<AppState> _boot(Map<String, Object> prefs, {SecureStore? store}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final app = AppState(secureStore: store);
  await app.init();
  return app;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('remember password', () {
    test('is off by default and the choice is stored in the preferences', () async {
      final app = await _boot({});
      expect(app.rememberPassword, isFalse);
      await app.setRememberPassword(true);
      expect(app.rememberPassword, isTrue);
      expect((await SharedPreferences.getInstance()).getBool('remember_password'), isTrue);
      final again = await _boot({'remember_password': true});
      expect(again.rememberPassword, isTrue);
    });
  });

  group('secure storage', () {
    test('a legacy shared_preferences session is handed to the secure store and removed', () async {
      final store = _FakeStore();
      final app = await _boot({'session': '{"base_url":"https://eu.example.com","token":"tok"}'}, store: store);
      expect(store.migrations, 1);
      expect(store.legacyValue, contains('tok'));
      expect((await SharedPreferences.getInstance()).containsKey('session'), isFalse);
      expect(app.stage, AuthStage.signedOut, reason: 'the fake store holds no session');
    });
  });

  group('motion feed', () {
    test('events of the control interface reach AppState.motionEvents', () async {
      final app = await _boot({});
      final actions = _Actions();
      app.actions = actions;
      final seen = <MotionEvent>[];
      app.motionEvents.listen(seen.add);
      actions.events.add(MotionEvent(cameraId: 'cam-a', active: true, time: DateTime.utc(2026)));
      await Future<void>.delayed(Duration.zero);
      expect(seen.single.cameraId, 'cam-a');
    });

    test('motion alerts are on by default and persist', () async {
      final app = await _boot({});
      expect(app.motionNotifications, isTrue);
      await app.setMotionNotifications(false);
      expect((await _boot({'motion_notifications': false})).motionNotifications, isFalse);
    });
  });

  group('camera actions', () {
    test('a missing control interface gives a readable error, not a crash', () async {
      final app = await _boot({});
      final camera = Camera({'deviceId': 'a', 'alias': 'A'})..dayNight = DayNightMode.auto;
      await expectLater(app.setDayNight(camera, DayNightMode.on), throwsA(isA<CameraActionException>()));
      expect(camera.dayNight, DayNightMode.auto);
    });

    test('renaming an owned camera clears a leftover local name; a shared one keeps it local', () async {
      final app = await _boot({});
      app.actions = DemoCameraActions();
      final owned = Camera({'deviceId': 'a', 'alias': 'A', 'role': 0});
      await app.renameCamera(owned, 'Porch');
      expect(owned.name, 'Porch');
      expect(owned.localName, isNull);
      final shared = Camera({'deviceId': 'b', 'alias': 'B', 'role': 1});
      await app.renameCamera(shared, 'Garage');
      expect(shared.name, 'Garage');
      expect(shared.localName, 'Garage');
      await app.resetCameraName(shared);
      expect(shared.name, 'B');
      expect(shared.localName, isNull);
    });

    test('a camera account is tested once and saved only when the test passes', () async {
      final app = await _boot({});
      final demo = DemoCameraActions();
      app.actions = demo;
      final camera = Camera({'deviceId': 'a', 'alias': 'A'});
      expect(await app.saveCameraAccount(camera, 'user', 'pw'), isTrue);
      expect(await app.cameraAccountUser(camera), 'user');
      expect(await app.saveCameraAccount(camera, '', ''), isTrue);
      expect(await app.cameraAccountUser(camera), isNull);
    });
  });

  group('capabilities from the component list', () {
    test('maps the optional controls and ignores unknown names', () {
      expect(capabilitiesFromComponents(['ptz', 'nightVision', 'msg_alarm']), {CameraCapability.nightVision, CameraCapability.siren});
      expect(capabilitiesFromComponents(['playback']), {CameraCapability.sdCard});
      expect(capabilitiesFromComponents(['ptz', 'whatever']), isEmpty);
    });
  });

  group('error messages', () {
    test('keep the cloud error code (a refused name is -63103)', () {
      final e = describeCameraError(TapoException('rejected', code: -63103));
      expect(e.code, -63103);
      expect(describeCameraError(TapoDeviceError('x', code: -63103)).code, -63103);
    });

    test('route failures explain what to do', () {
      for (final reason in api.RouteFailure.values) {
        final text = describeCameraError(api.CameraRouteError(reason)).message;
        expect(text, isNotEmpty);
      }
    });

    test('unknown errors never leak their text', () {
      expect(describeCameraError(StateError('secret-token-123')).message, isNot(contains('secret-token-123')));
    });
  });
}
