// Specs hc.dto.* (tier 1). Wire strings are byte exact: key order and string
// typing matter to the camera.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/camera_dtos.dart';
import 'package:tapo_tv/api/tapo_errors.dart';

String _j(Object o) => jsonEncode(o);

const _devInfoReq =
    '{"method":"getDeviceInfo","params":{"device_info":{"name":["basic_info"]}}}';

void main() {
  group('envelope', () {
    test('multiple request matches spec', () {
      expect(
        _j(buildMultipleRequest([buildGetDeviceInfo()])),
        '{"method":"multipleRequest","params":{"requests":[$_devInfoReq]}}',
      );
    });

    test('multiple request preserves order and empty', () {
      final m = buildMultipleRequest([buildGetLed(), buildGetPrivacy(), buildGetDeviceInfo()]);
      final names = ((m['params'] as Map)['requests'] as List).map((e) => (e as Map)['method']);
      expect(names, ['getLedStatus', 'getLensMaskConfig', 'getDeviceInfo']);
      expect(_j(buildMultipleRequest(const [])),
          '{"method":"multipleRequest","params":{"requests":[]}}');
    });

    test('normalize item error code string', () {
      final a = ControlItem.normalize({'method': 'x', 'result': {'a': 1}, 'error_code': '-40106'});
      expect(a.errorCode, -40106);
      expect(a.method, 'x');
      expect(a.ok, isFalse);
      final b = ControlItem.normalize({'method': 'x', 'result': 'nope', 'error_code': 0});
      expect(b.result, isEmpty);
      expect(b.ok, isTrue);
      expect(() => ControlItem.normalize({'error_code': true}), throwsA(isA<TapoProtocolError>()));
      expect(() => ControlItem.normalize('x'), throwsA(isA<TapoProtocolError>()));
    });

    test('item ensureOk raises a device error with code and method', () {
      final item = ControlItem.normalize({'method': 'motorMove', 'error_code': -64304});
      expect(
        item.ensureOk,
        throwsA(isA<TapoDeviceError>()
            .having((e) => e.code, 'code', -64304)
            .having((e) => e.method, 'method', 'motorMove')),
      );
    });

    test('top level error is a multipleRequest device error', () {
      expect(
        () => parseMultipleResponse({'error_code': -40210}),
        throwsA(isA<TapoDeviceError>().having((e) => e.method, 'method', 'multipleRequest')),
      );
      final items = parseMultipleResponse({
        'error_code': 0,
        'result': {
          'responses': [
            {'method': 'a', 'result': {}, 'error_code': 0},
          ],
        },
      });
      expect(items.single.method, 'a');
    });

    test('parsers never throw non protocol errors', () {
      final garbage = <Object?>[
        null,
        42,
        'x',
        <Object?>[],
        {'result': 5},
        {'result': {'responses': 'x'}},
        {'result': {'responses': [1, null, 'x']}},
        {'error_code': 'abc'},
      ];
      final parsers = <void Function(Object?)>[
        (g) => parseMultipleResponse(g),
        (g) => parseDeviceInfo(g is Map<String, dynamic> ? g : <String, dynamic>{}),
        (g) => parsePrivacy(g is Map<String, dynamic> ? g : <String, dynamic>{}),
        (g) => parsePresets(g is Map<String, dynamic> ? g : <String, dynamic>{}),
        (g) => parseDayNight(g is Map<String, dynamic> ? g : <String, dynamic>{}),
        (g) => parseMotion(g is Map<String, dynamic> ? g : <String, dynamic>{}),
        (g) => parseAppComponents(g is Map<String, dynamic> ? g : <String, dynamic>{}),
        (g) => parseLed(g is Map<String, dynamic> ? g : <String, dynamic>{}),
        (g) => parseLastAlarmInfo(g is Map<String, dynamic> ? g : <String, dynamic>{}),
      ];
      for (final parse in parsers) {
        for (final g in garbage) {
          try {
            parse(g);
          } on TapoError {
            // protocol/device errors are fine
          }
        }
      }
    });
  });

  group('device info and components', () {
    test('device info request matches spec', () {
      expect(_j(buildGetDeviceInfo()), _devInfoReq);
      expect(
        _j(buildGetAppComponentList()),
        '{"method":"getAppComponentList","params":{"app_component":{"name":["app_component_list"]}}}',
      );
    });

    test('parse device info', () {
      final info = parseDeviceInfo({
        'device_info': {
          'basic_info': {
            'device_model': 'C200',
            'device_alias': 'Porch',
            'sw_version': '1.3.9',
            'hw_version': '2.0',
            'mac': 'A0-B1-C2-00-00-01',
            'dev_id': '8022ABCD',
            'extra': 1,
          },
        },
      });
      expect(info.deviceModel, 'C200');
      expect(info.deviceAlias, 'Porch');
      expect(info.swVersion, '1.3.9');
      expect(info.hwVersion, '2.0');
      expect(info.mac, 'A0-B1-C2-00-00-01');
      expect(info.devId, '8022ABCD');
      expect(info.raw['extra'], 1);
    });

    test('parse device info unusable', () {
      for (final bad in <Map<String, dynamic>>[
        {},
        {'device_info': 5},
        {'device_info': {'basic_info': {}}},
        {'device_info': {'basic_info': {'device_model': ''}}},
      ]) {
        expect(() => parseDeviceInfo(bad), throwsA(isA<TapoProtocolError>()), reason: '$bad');
      }
    });

    test('parse component list string versions', () {
      final c = parseAppComponents({
        'app_component': {
          'app_component_list': [
            {'name': 'ptz', 'version': 1},
            {'name': 'lensMask', 'version': '2'},
            {'name': 'siren', 'version': '1'},
          ],
        },
      });
      expect(c, {'ptz': 1, 'lensMask': 2, 'siren': 1});
    });
  });

  group('privacy', () {
    test('get privacy request', () {
      expect(_j(buildGetPrivacy()),
          '{"method":"getLensMaskConfig","params":{"lens_mask":{"name":["lens_mask_info"]}}}');
    });

    test('set privacy off request', () {
      expect(
        _j(buildSetPrivacy(false)),
        '{"method":"setLensMaskConfig","params":{"lens_mask":{"lens_mask_info":{"enabled":"off"}}}}',
      );
      expect(_j(buildSetPrivacy(true)), contains('"enabled":"on"'));
    });

    test('parse privacy on off', () {
      Map<String, dynamic> r(String v) => {
            'lens_mask': {'lens_mask_info': {'enabled': v}},
          };
      expect(parsePrivacy(r('on')), isTrue);
      expect(parsePrivacy(r('off')), isFalse);
    });

    test('parse privacy unusable', () {
      for (final bad in <Map<String, dynamic>>[
        {},
        {'lens_mask': {'lens_mask_info': {'enabled': 'maybe'}}},
        {'lens_mask': {'lens_mask_info': {'enabled': true}}},
        {'lens_mask': 'x'},
      ]) {
        expect(() => parsePrivacy(bad), throwsA(isA<TapoProtocolError>()), reason: '$bad');
      }
    });
  });

  group('ptz', () {
    test('motor move coords are signed int strings', () {
      expect(
        _j(buildMotorMove(-5, 7)),
        '{"method":"motorMove","params":{"motor":{"move":{"x_coord":"-5","y_coord":"7"}}}}',
      );
    });

    test('motor step all directions', () {
      expect(
        _j(buildMotorStep(90)),
        '{"method":"singalMove","params":{"motor":{"movestep":{"direction":"90"}}}}',
      );
      for (final d in [0, 90, 180, 270]) {
        expect(_j(buildMotorStep(d)), contains('"direction":"$d"'));
      }
    });

    test('motor step invalid direction', () {
      for (final d in [-90, 45, 360, 1]) {
        expect(() => buildMotorStep(d), throwsArgumentError, reason: '$d');
      }
    });

    test('stop move request', () {
      expect(_j(buildStopMove()),
          '{"method":"stopMove","params":{"motor":{"stop":"null"}}}');
    });

    test('presets parse parallel arrays', () {
      final presets = parsePresets({
        'preset': {
          'preset': {
            'id': ['1', '2'],
            'name': ['Door', 'Gate'],
            'position_pan': ['0.1', '0.2'],
            'position_tilt': ['-0.1', '0.3'],
            'read_only': ['0', '1'],
          },
        },
      });
      expect(presets.map((p) => p.id), ['1', '2']);
      expect(presets.map((p) => p.name), ['Door', 'Gate']);
      expect(presets[1].positionPan, '0.2');
      expect(presets[1].readOnly, isTrue);
      expect(_j(buildGetPresets()),
          '{"method":"getPresetConfig","params":{"preset":{"name":["preset"]}}}');
    });

    test('goto and delete preset ids are strings', () {
      expect(_j(buildGotoPreset('3')),
          '{"method":"motorMoveToPreset","params":{"preset":{"goto_preset":{"id":"3"}}}}');
      expect(_j(buildDeletePreset('3')),
          '{"method":"deletePreset","params":{"preset":{"remove_preset":{"id":["3"]}}}}');
      expect(_j(buildAddPreset('Door')),
          '{"method":"addMotorPostion","params":{"preset":{"set_preset":{"name":"Door","save_ptz":"1"}}}}');
    });
  });

  group('night vision', () {
    test('get day night request', () {
      expect(_j(buildGetDayNight()),
          '{"method":"getDayNightModeConfig","params":{"image":{"name":"common"}}}');
    });

    test('set day night values', () {
      expect(
        _j(buildSetDayNight(DayNightMode.auto)),
        '{"method":"setDayNightModeConfig","params":{"image":{"common":{"inf_type":"auto"}}}}',
      );
      expect(_j(buildSetDayNight(DayNightMode.on)), contains('"inf_type":"on"'));
      expect(_j(buildSetDayNight(DayNightMode.off)), contains('"inf_type":"off"'));
    });

    test('parse day night unknown value', () {
      Map<String, dynamic> r(Object v) => {
            'image': {'common': {'inf_type': v}},
          };
      expect(parseDayNight(r('auto')), DayNightMode.auto);
      expect(parseDayNight(r('on')), DayNightMode.on);
      expect(parseDayNight(r('off')), DayNightMode.off);
      expect(() => parseDayNight(r('infrared')), throwsA(isA<TapoProtocolError>()));
      expect(() => parseDayNight({}), throwsA(isA<TapoProtocolError>()));
    });
  });

  group('led, siren, motion', () {
    test('set led on', () {
      expect(_j(buildSetLed(true)),
          '{"method":"setLedStatus","params":{"led":{"config":{"enabled":"on"}}}}');
      expect(_j(buildGetLed()),
          '{"method":"getLedStatus","params":{"led":{"name":["config"]}}}');
      expect(parseLed({'led': {'config': {'enabled': 'off'}}}), isFalse);
    });

    test('manual alarm stop', () {
      expect(
        _j(buildManualAlarm(false)),
        '{"method":"doManualAlarm","params":{"msg_alarm":{"manual_alarm":{"action":"stop"}}}}',
      );
      expect(_j(buildManualAlarm(true)), contains('"action":"start"'));
    });

    test('set motion detection levels', () {
      expect(
        _j(buildSetMotion(true, sensitivity: 60)),
        '{"method":"setDetectionConfig","params":{"motion_detection":'
        '{"motion_det":{"enabled":"on","digital_sensitivity":"60"}}}}',
      );
      for (final s in [20, 60, 80]) {
        expect(_j(buildSetMotion(true, sensitivity: s)), contains('"digital_sensitivity":"$s"'));
      }
      expect(_j(buildSetMotion(false)), isNot(contains('digital_sensitivity')));
      expect(
        _j(buildGetMotion()),
        '{"method":"getDetectionConfig","params":{"motion_detection":'
        '{"name":["motion_det"],"table":["region_info"]}}}',
      );
    });

    test('set motion detection invalid sensitivity', () {
      for (final s in [0, 10, 50, 100]) {
        expect(() => buildSetMotion(true, sensitivity: s), throwsArgumentError, reason: '$s');
      }
    });

    test('parse motion detection without sensitivity', () {
      final m = parseMotion({'motion_detection': {'motion_det': {'enabled': 'on'}}});
      expect(m.enabled, isTrue);
      expect(m.sensitivity, isNull);
      final s = parseMotion({
        'motion_detection': {'motion_det': {'enabled': 'off', 'digital_sensitivity': '80'}},
      });
      expect(s.sensitivity, 80);
    });
  });

  group('rename and alarms', () {
    test('set device alias request exact', () {
      expect(
        _j(buildSetDeviceAlias('Cổng trước')),
        '{"method":"setDeviceAlias","params":{"system":{"sys":{"dev_alias":"Cổng trước"}}}}',
      );
    });

    test('last alarm info request and response', () {
      expect(_j(buildGetLastAlarmInfo()),
          '{"method":"getLastAlarmInfo","params":{"system":{"name":["last_alarm_info"]}}}');
      final a = parseLastAlarmInfo({
        'system': {'last_alarm_info': {'last_alarm_time': '1735900000', 'last_alarm_type': 'person'}},
      });
      expect(a.time, '1735900000');
      expect(a.type, 'person');
    });
  });

  group('clip search shapes (P2)', () {
    test('search day clips matches spec legacy utc shape', () {
      expect(
        _j(buildSearchVideoWithUtc(startTime: 100, endTime: 200, startIndex: 0, endIndex: 99)),
        '{"method":"searchVideoWithUTC","params":{"playback":{"search_video_with_utc":'
        '{"id":1,"channel":0,"start_time":100,"end_time":200,"start_index":0,"end_index":99}}}}',
      );
      expect(
        _j(buildSearchVideoWithUtc(
          startTime: 100,
          endTime: 200,
          startIndex: 0,
          endIndex: 49,
          playerId: 'abababababababababababababababab',
        )),
        '{"method":"searchVideoWithUTC","params":{"playback":{"search_video_with_utc":'
        '{"player_id":"abababababababababababababababab","channel":0,"start_time":100,'
        '"end_time":200,"start_index":0,"end_index":49}}}}',
      );
    });
  });
}
