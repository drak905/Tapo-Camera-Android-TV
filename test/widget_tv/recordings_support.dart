// Shared helpers for the recordings (VodTimelineScreen) tests.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/screens/vod_timeline_screen.dart';
import 'package:tapo_tv/state/camera_actions.dart';
import 'package:tapo_tv/state/camera_view_model.dart';

import 'support.dart';

/// Local wall-clock time on May [d] 2026 (the fake "today" is May 4, 10:00).
DateTime local(int d, int h, [int m = 0, int s = 0]) => DateTime(2026, 5, d, h, m, s);

DateTime get fakeNow => local(4, 10);

RecordingClip clipOf(DateTime localStart, DateTime localEnd, {int type = 1}) =>
    RecordingClip(start: localStart.toUtc(), end: localEnd.toUtc(), eventType: type);

String dayKey(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Two segments on May 4: 08:00-08:10 and 10:00-11:00 (a gap in between).
Map<String, List<RecordingClip>> twoSegmentsToday() => {
      '2026-05-04': [clipOf(local(4, 8), local(4, 8, 10)), clipOf(local(4, 10), local(4, 11))],
    };

/// One continuous clip for the whole local day May [d].
RecordingClip fullDay(int d) => clipOf(local(d, 0), local(d + 1, 0));

FakeCameraActions fakeWithClips(Map<String, List<RecordingClip>> days) {
  final fake = FakeCameraActions();
  fake.clipLoader = (id, from, to) async => days[dayKey(from.toLocal())] ?? const [];
  return fake;
}

Camera sdCam() => viewCam('cam-a', 'Home Camera A', caps: {CameraCapability.sdCard});

/// Opens the recordings screen over the home page and waits for the first load.
Future<FakeCameraActions> openRecordings(
  WidgetTester tester, {
  Map<String, List<RecordingClip>>? days,
  FakeCameraActions? actions,
  Camera? camera,
}) async {
  final fake = actions ?? fakeWithClips(days ?? twoSegmentsToday());
  final cam = camera ?? sdCam();
  await pumpApp(tester, cameras: [cam], actions: fake);
  await pushScreen(
    tester,
    VodTimelineScreen(camera: cam, actions: fake, videoBuilder: fakeVideo, now: () => fakeNow),
  );
  await tester.pump(const Duration(milliseconds: 300));
  return fake;
}

String text(WidgetTester tester, String keyName) => tester.widget<Text>(find.byKey(ValueKey(keyName))).data!;

String cursorLabel(WidgetTester tester) => text(tester, 'timeline-cursor-label');
String dayLabel(WidgetTester tester) => text(tester, 'timeline-day-label');

/// Starts playback with OK and waits for the fake player to be created.
Future<FakePlayback> startPlayback(WidgetTester tester, FakeCameraActions fake) async {
  await ok(tester);
  await tester.pump(const Duration(milliseconds: 300));
  return fake.players.last;
}
