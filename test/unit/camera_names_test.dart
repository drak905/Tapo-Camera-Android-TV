// Spec hc.dto.rename (tier 1). Name rules: NFC, trim, no control characters,
// at most 32 UTF-8 bytes. NFC needs a Unicode normalisation package.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/camera_dtos.dart';
import 'package:tapo_tv/state/camera_names.dart';

void main() {
  test('set device alias request exact', () {
    const name = 'Cổng trước';
    expect(normalizeCameraName(name), name);
    expect(
      jsonEncode(buildSetDeviceAlias(normalizeCameraName(name))),
      '{"method":"setDeviceAlias","params":{"system":{"sys":{"dev_alias":"Cổng trước"}}}}',
    );
  });

  test('limit is 32 utf8 bytes', () {
    const ok = 'CổngCổngCổngCổng'; // 24 bytes
    expect(utf8.encode(ok).length, 24);
    expect(normalizeCameraName(ok), ok);
    expect(normalizeCameraName('a' * 32), 'a' * 32);
    for (final bad in ['ổổổổổổổổổổổ', 'a' * 33]) {
      expect(utf8.encode(bad).length, 33);
      expect(() => normalizeCameraName(bad), throwsA(isA<CameraNameError>()), reason: bad);
    }
  });

  test('empty and blank names are refused, whitespace is trimmed', () {
    expect(() => normalizeCameraName(''), throwsA(isA<CameraNameError>()));
    expect(() => normalizeCameraName('   '), throwsA(isA<CameraNameError>()));
    expect(normalizeCameraName('  Garage  '), 'Garage');
  });

  test('control characters refused', () {
    for (final bad in ['a\u0000b', 'a\nb', 'a\tb', 'a\u007fb', 'a\u0085b']) {
      expect(() => normalizeCameraName(bad), throwsA(isA<CameraNameError>()), reason: bad.codeUnits.join(','));
    }
  });

  test('decomposed vietnamese composed before counting', () {
    // "Cổng trước" typed with combining marks (NFD).
    const nfd = 'Co\u0302\u0309ng tru\u031Bo\u031B\u0301c';
    expect(normalizeCameraName(nfd), 'Cổng trước');
    // Ten decomposed ổ are 50 bytes raw but 30 bytes composed: valid only after NFC.
    final ten = List.filled(10, 'o\u0302\u0309').join();
    expect(normalizeCameraName(ten), 'ổ' * 10);
    final eleven = List.filled(11, 'o\u0302\u0309').join(); // 33 bytes composed
    expect(() => normalizeCameraName(eleven), throwsA(isA<CameraNameError>()));
  });

  test('only owned cloud cameras rename on camera', () {
    expect(renamesOnCamera(isCloudCamera: true, role: 0), isTrue);
    expect(renamesOnCamera(isCloudCamera: true, role: 1), isFalse);
    expect(renamesOnCamera(isCloudCamera: false, role: 0), isFalse);
  });

  test('pending rename wins until cloud matches', () {
    var now = DateTime.utc(2025, 1, 1, 12);
    final names = CameraNames(clock: () => now);
    names.setPending('cam1', 'Gate');
    expect(names.display('cam1', 'Old name'), 'Gate');
    now = now.add(const Duration(hours: 2));
    expect(names.display('cam1', 'Old name'), 'Gate');
    expect(names.display('cam1', 'Gate'), 'Gate');
    // Once the cloud alias matched, the pending entry is gone for good.
    expect(names.display('cam1', 'Something else'), 'Something else');
    expect(names.display('cam2', 'Other'), 'Other');
  });

  test('pending rename expires after 24 hours', () {
    var now = DateTime.utc(2025, 1, 1, 12);
    final names = CameraNames(clock: () => now);
    names.setPending('cam1', 'Gate');
    now = now.add(const Duration(hours: 23, minutes: 59));
    expect(names.display('cam1', 'Old name'), 'Gate');
    now = now.add(const Duration(minutes: 2));
    expect(names.display('cam1', 'Old name'), 'Old name');
  });

  test('local names for shared cameras beat the cloud alias', () {
    final names = CameraNames();
    names.setLocalName('shared1', 'Neighbour cam');
    expect(names.display('shared1', 'Their alias'), 'Neighbour cam');
  });
}
