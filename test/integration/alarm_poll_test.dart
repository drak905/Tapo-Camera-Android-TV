// Tier 2, scenario 11: motion alerts without a camera account. A real
// AlarmPoller reads getLastAlarmInfo from MockCamera, locally (real control
// client, 5 s interval) and through the cloud passthrough (30 s interval), and
// emits one MotionEvent per change of last_alarm_time.
// Decision: "poll getLastAlarmInfo every 5 s locally, every 30 s through
// passthrough; toast only". Spec: ev.source.no_camera_account.
@Timeout(Duration(seconds: 60))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/alarm_poller.dart';
import 'package:tapo_tv/api/camera_dtos.dart';
import 'package:tapo_tv/api/iot_things.dart';

import '../fixtures/mock_camera.dart';
import '../fixtures/mock_cloud.dart';
import 'support/camera_rig.dart';
import 'support/cloud_rig.dart';

void main() {
  test('local: baseline, then one event per new alarm, with type and camera id', () async {
    final cam = await MockCamera(cloudPassword: 'pw').start();
    addTearDown(cam.stop);
    final client = controlClientFor(cam, password: 'pw');
    addTearDown(client.close);
    cam.state
      ..lastAlarmTime = 1735900000
      ..lastAlarmType = 'motion';
    final events = <MotionEvent>[];
    final poller = AlarmPoller(
      cameraId: 'cam-1',
      cloudRouted: false,
      onEvent: events.add,
      readAlarm: () async => (await client.send([buildGetLastAlarmInfo()])).single.result,
    );

    expect(poller.interval, AlarmPoller.localInterval);
    await poller.pollOnce();
    expect(events, isEmpty, reason: 'first reading is the baseline');
    await poller.pollOnce();
    expect(events, isEmpty, reason: 'unchanged');

    cam.state
      ..lastAlarmTime = 1735900100
      ..lastAlarmType = 'person';
    await poller.pollOnce();
    expect(events, hasLength(1));
    final e = events.single;
    expect(e.cameraId, 'cam-1');
    expect(e.active, isTrue);
    expect(e.type, 'person');
    expect(e.topic, 'tapo:LastAlarmInfo/person');
    expect(e.source, 'last_alarm_info');
    expect(e.timestamp.toUtc(), DateTime.fromMillisecondsSinceEpoch(1735900100 * 1000, isUtc: true));

    await poller.pollOnce();
    expect(events, hasLength(1), reason: 'same alarm again: no duplicate event');

    cam.state.lastAlarmTime = 1735900200;
    await poller.pollOnce();
    expect(events.map((x) => x.type), ['person', 'person']);
    expect(cam.requestLog.where((c) => c.method == 'getLastAlarmInfo'), hasLength(5));
    expect(cam.loginAttempts, lessThanOrEqualTo(3));
  });

  test('cloud passthrough: 30 s interval, events for a shared camera, no local login', () async {
    final device = makeCloudDevice(1, overrides: {'role': 1});
    final rig = await CloudRig.start(devices: [device]);
    final cam = MockCamera(deviceId: device['deviceId'] as String, cloudPassword: 'x');
    rig.attach(device['deviceId'] as String, cam);
    await rig.signIn();
    final IotThing thing = (await (await rig.iotClient()).fetchAll()).values.single;
    final pass = rig.passthrough();
    cam.state.lastAlarmTime = 1735900000;

    final events = <MotionEvent>[];
    final poller = AlarmPoller(
      cameraId: 'shared-1',
      cloudRouted: true,
      onEvent: events.add,
      readAlarm: () async => (await pass.send(thing, [buildGetLastAlarmInfo()])).single.result,
    );

    expect(poller.interval, AlarmPoller.cloudInterval);
    await poller.pollOnce();
    cam.state.lastAlarmTime = 1735900060;
    await poller.pollOnce();

    expect(events, hasLength(1));
    expect(events.single.cameraId, 'shared-1');
    expect(events.single.type, 'motion');
    expect(rig.mock.passthroughLog, hasLength(2));
    expect(cam.loginAttempts, 0);
  });

  test('a camera error does not stop the poller or raise an event; polling recovers', () async {
    final cam = await MockCamera(cloudPassword: 'pw').start();
    addTearDown(cam.stop);
    final client = controlClientFor(cam, password: 'pw');
    addTearDown(client.close);
    cam.state.lastAlarmTime = 1735900000;
    final events = <MotionEvent>[];
    final logs = <String>[];
    final poller = AlarmPoller(
      cameraId: 'cam-1',
      cloudRouted: false,
      onEvent: events.add,
      log: logs.add,
      readAlarm: () async {
        final item = (await client.send([buildGetLastAlarmInfo()])).single..ensureOk();
        return item.result;
      },
    );
    await poller.pollOnce();

    cam.injectError('getLastAlarmInfo', -40401, times: 1);
    await poller.pollOnce();
    expect(events, isEmpty);

    cam.state.lastAlarmTime = 1735900300;
    await poller.pollOnce();
    expect(events, hasLength(1));
  });

  test('start() polls immediately and stop() ends the timer', () async {
    final cam = await MockCamera(cloudPassword: 'pw').start();
    addTearDown(cam.stop);
    final client = controlClientFor(cam, password: 'pw');
    addTearDown(client.close);
    final poller = AlarmPoller(
      cameraId: 'cam-1',
      cloudRouted: false,
      onEvent: (_) {},
      readAlarm: () async => (await client.send([buildGetLastAlarmInfo()])).single.result,
    );

    poller.start();
    addTearDown(poller.stop);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(cam.requestLog.where((c) => c.method == 'getLastAlarmInfo'), hasLength(1),
        reason: 'one immediate poll; the next one is 5 s away');

    poller.stop();
    final seen = cam.requestLog.length;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(cam.requestLog.length, seen);
  });
}
