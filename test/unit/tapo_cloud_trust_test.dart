// Spec hc.cloud.trust_roots. The spec target is assets/tplink_roots.pem (the
// baseline asset assets/tapo-cloud-roots.pem must be renamed and listed in
// pubspec.yaml by the orchestrator).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/tapo_cloud.dart';

const _asset = 'assets/tplink_roots.pem';

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
