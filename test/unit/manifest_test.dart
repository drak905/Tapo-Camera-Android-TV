// ui.android.manifest (existing behaviour)
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

  test('manifest contains the LEANBACK_LAUNCHER category on the main activity', () {
    expect(manifest, contains('android.intent.category.LEANBACK_LAUNCHER'));
    expect(manifest, contains('android.intent.category.LAUNCHER'));
    expect(manifest, contains('android.intent.action.MAIN'));
  });

  test('android:banner is set and the drawable exists', () {
    expect(manifest, contains('android:banner="@drawable/tv_banner"'));
    final banners = Directory('android/app/src/main/res')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => RegExp(r'tv_banner\.(png|xml|webp|jpg)$').hasMatch(f.path));
    expect(banners, isNotEmpty);
  });

  test('touchscreen and leanback are not required', () {
    expect(manifest, matches(RegExp(r'android\.software\.leanback"\s+android:required="false"')));
    expect(manifest, matches(RegExp(r'android\.hardware\.touchscreen"\s+android:required="false"')));
  });

  test('landscape, singleTask, exported main activity', () {
    expect(manifest, contains('android:screenOrientation="landscape"'));
    expect(manifest, contains('android:launchMode="singleTask"'));
    expect(manifest, contains('android:exported="true"'));
    expect(manifest, contains('keyboard'));
    expect(manifest, contains('navigation'));
  });

  test('uses-permission stays within the allow-list', () {
    const allowed = {
      'android.permission.INTERNET',
      'android.permission.ACCESS_NETWORK_STATE',
      'android.permission.CHANGE_WIFI_MULTICAST_STATE',
    };
    final used = RegExp(r'<uses-permission android:name="([^"]+)"').allMatches(manifest).map((m) => m.group(1)!).toSet();
    expect(used, contains('android.permission.INTERNET'));
    expect(allowed.containsAll(used), isTrue, reason: 'unexpected permissions: ${used.difference(allowed)}');
  });

  test('cleartext is limited through a network security config', () {
    expect(manifest, contains('android:networkSecurityConfig="@xml/network_security_config"'));
    expect(manifest, isNot(contains('usesCleartextTraffic="true"')));
  });
}