// Spec hc.cloud.trust_roots. Barrier 2 decision: keep the baseline asset name
// assets/tapo-cloud-roots.pem (already in pubspec.yaml and .gitignore allow-list)
// instead of renaming it to the spec's tplink_roots.pem.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/tapo_cloud.dart';

const _asset = 'assets/tapo-cloud-roots.pem';

void main() {
  test('asset holds two certificates', () {
    final f = File(_asset);
    expect(f.existsSync(), isTrue, reason: '$_asset is missing');
    final pem = f.readAsStringSync();
    expect('-----BEGIN CERTIFICATE-----'.allMatches(pem), hasLength(2));
    expect('-----END CERTIFICATE-----'.allMatches(pem), hasLength(2));
  });

  test('context builds from asset', () {
    final bytes = File(_asset).readAsBytesSync();
    expect(() => TapoCloud.buildContext(bytes), returnsNormally);
  });
}
