// Spec ev.source.no_camera_account (tier 1): motion events without a camera
// account by polling getLastAlarmInfo. Request/response vectors from the
// Windows repo (tests/phase2/test_camera_service_transport.py, app_fakes.py).

import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/alarm_poller.dart';
import 'package:tapo_tv/api/camera_dtos.dart';

Map<String, dynamic> _alarm(String? time, [String? type]) => {
      'system': {
        'last_alarm_info': {'last_alarm_time': ?time, 'last_alarm_type': ?type},
      },
    };

class _Rig {
  _Rig(this.async, {this.cloud = false, required this.readings}) {
    clockNow = async.getClock(DateTime.utc(2025, 1, 3, 10)).now;
    poller = AlarmPoller(
      cameraId: 'cam-1',
      cloudRouted: cloud,
      clock: clockNow,
      log: logs.add,
      onEvent: events.add,
      readAlarm: () async {
        reads++;
        final r = readings(reads);
        if (r is Exception) throw r;
        return r as Map<String, dynamic>;
      },
    );
  }

  final FakeAsync async;
  final bool cloud;
  final Object Function(int call) readings;
  late final DateTime Function() clockNow;
  late final AlarmPoller poller;
  final events = <MotionEvent>[];
  final logs = <String>[];
  int reads = 0;
}

void main() {
  test('request and response vectors', () {
    expect(
      jsonEncode(buildGetLastAlarmInfo()),
      '{"method":"getLastAlarmInfo","params":{"system":{"name":["last_alarm_info"]}}}',
    );
    final info = parseLastAlarmInfo({
      'system': {'last_alarm_info': {'last_alarm_time': '1735900000', 'last_alarm_type': 'person'}},
    });
    expect(info.time, '1735900000');
    expect(info.type, 'person');
  });

  test('first reading is baseline, no event', () {
    fakeAsync((async) {
      final rig = _Rig(async, readings: (_) => _alarm('1735900000', 'person'));
      rig.poller.start();
      async.flushMicrotasks();
      expect(rig.reads, 1);
      expect(rig.events, isEmpty);
      rig.poller.stop();
    });
  });

  test('changed last_alarm_time emits one active event', () {
    fakeAsync((async) {
      final rig = _Rig(async, readings: (n) => n < 3 ? _alarm('1735900000', 'person') : _alarm('1735900100', 'person'));
      rig.poller.start();
      async.flushMicrotasks();
      async.elapse(AlarmPoller.localInterval); // read 2: unchanged
      expect(rig.events, isEmpty);
      async.elapse(AlarmPoller.localInterval); // read 3: changed
      expect(rig.events, hasLength(1));
      final e = rig.events.single;
      expect(e.cameraId, 'cam-1');
      expect(e.active, isTrue);
      expect(e.type, 'person');
      expect(e.topic, 'tapo:LastAlarmInfo/person');
      expect(e.source, 'last_alarm_info');
      expect(e.timestamp, DateTime.fromMillisecondsSinceEpoch(1735900100 * 1000, isUtc: true));
      async.elapse(AlarmPoller.localInterval * 3); // unchanged again: no more events
      expect(rig.events, hasLength(1));
      rig.poller.stop();
    });
  });

  test('type person is carried in the event, missing type is motion', () {
    fakeAsync((async) {
      final rig = _Rig(async, readings: (n) => switch (n) {
            1 => _alarm('100', 'person'),
            2 => _alarm('200', 'person'),
            _ => _alarm('300'),
          });
      rig.poller.start();
      async.elapse(AlarmPoller.localInterval * 2);
      expect(rig.events.map((e) => e.type), ['person', 'motion']);
      expect(rig.events.last.topic, 'tapo:LastAlarmInfo/motion');
      rig.poller.stop();
    });
  });

  test('errors do not stop polling', () {
    fakeAsync((async) {
      final rig = _Rig(async, readings: (n) {
        if (n >= 2 && n <= 11) return Exception('camera busy $n');
        return _alarm(n == 1 ? '100' : '200', 'motion');
      });
      rig.poller.start();
      async.elapse(AlarmPoller.localInterval * 12);
      expect(rig.reads, greaterThanOrEqualTo(12));
      expect(rig.events, hasLength(1), reason: 'polling resumed after the failures');
      // Logged: 1st and 10th consecutive failure only.
      expect(rig.logs, hasLength(2));
      rig.poller.stop();
    });
  });

  test('cloud-routed interval is at least 30 s', () {
    fakeAsync((async) {
      final cloud = _Rig(async, cloud: true, readings: (_) => _alarm('100'));
      final local = _Rig(async, readings: (_) => _alarm('100'));
      expect(cloud.poller.interval, const Duration(seconds: 30));
      expect(local.poller.interval, const Duration(seconds: 5));
      cloud.poller.start();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 29));
      expect(cloud.reads, 1);
      async.elapse(const Duration(seconds: 1));
      expect(cloud.reads, 2);
      cloud.poller.stop();
    });
  });

  test('unparsable time falls back to now', () {
    fakeAsync((async) {
      final rig = _Rig(async, readings: (n) => _alarm(n == 1 ? 'x1' : 'x2', 'motion'));
      rig.poller.start();
      async.elapse(AlarmPoller.localInterval);
      expect(rig.events, hasLength(1));
      expect(rig.events.single.timestamp, rig.clockNow());
      rig.poller.stop();
    });
  });

  test('stop is idempotent and ends polling', () {
    fakeAsync((async) {
      final rig = _Rig(async, readings: (_) => _alarm('100'));
      rig.poller.start();
      rig.poller.start(); // idempotent
      async.elapse(AlarmPoller.localInterval);
      final reads = rig.reads;
      rig.poller.stop();
      rig.poller.stop();
      async.elapse(AlarmPoller.localInterval * 5);
      expect(rig.reads, reads);
    });
  });
}
