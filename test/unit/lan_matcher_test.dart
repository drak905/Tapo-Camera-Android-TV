// Specs hc.discovery.matcher and hc.discovery.tpap_hint (tier 1).
// Vectors from tests/phase2/test_matcher.py in the Windows repo.

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/lan_matcher.dart';

const _cloudId = '802200000000000000000000000000000000ABCD';
const _md5 = 'e4247a931858b38594790fc6606441aa';

LanDevice _lan(String ip, String mac, {String md5 = '', int? port, Map<String, dynamic>? raw}) =>
    LanDevice(ip: ip, mac: mac, md5: md5, httpPort: port, raw: raw ?? const {});

void main() {
  test('normalise mac formats', () {
    for (final raw in [
      'a0:b1:c2:00:00:01',
      'A0-B1-C2-00-00-01',
      'a0b1c2000001',
      'A0B1.C200.0001',
      ' A0:B1:C2:00:00:01 ',
    ]) {
      expect(normaliseMac(raw), 'A0-B1-C2-00-00-01', reason: raw);
    }
  });

  test('invalid mac is empty', () {
    for (final raw in ['', 'xyz', 'A0:B1:C2', 'A0B1C2000001FF', 'G0:B1:C2:00:00:01']) {
      expect(normaliseMac(raw), '', reason: raw);
    }
  });

  test('device id md5 is lower case hex of the utf8 id', () {
    expect(deviceIdMd5(_cloudId), _md5);
    expect(deviceIdMd5('0123456789ABCDEF0123456789ABCDEF01234567'),
        'ac80b0ccea9b65429ad9c7a0b903c025');
  });

  test('match by md5 golden', () {
    final m = matchLan(
      [const CloudDeviceRef(deviceId: _cloudId)],
      [_lan('192.168.1.20', 'A0-B1-C2-00-00-01', md5: _md5, port: 8443)],
    );
    expect(m.keys, [_cloudId]);
    expect(m[_cloudId]!.host, '192.168.1.20');
    expect(m[_cloudId]!.httpsPort, 8443);
    expect(m[_cloudId]!.lanFound, isTrue);
    expect(m[_cloudId]!.byMd5, isTrue);
  });

  test('default https port is 443', () {
    final m = matchLan(
      [const CloudDeviceRef(deviceId: _cloudId)],
      [_lan('192.168.1.20', 'A0-B1-C2-00-00-01', md5: _md5)],
    );
    expect(m[_cloudId]!.httpsPort, 443);
  });

  test('md5 case insensitive', () {
    final m = matchLan(
      [const CloudDeviceRef(deviceId: _cloudId)],
      [_lan('192.168.1.20', 'A0-B1-C2-00-00-01', md5: _md5.toUpperCase())],
    );
    expect(m.containsKey(_cloudId), isTrue);
  });

  test('mac fallback', () {
    final m = matchLan(
      [const CloudDeviceRef(deviceId: _cloudId, mac: 'a0:b1:c2:00:00:01')],
      [_lan('192.168.1.21', 'A0-B1-C2-00-00-01')],
    );
    expect(m[_cloudId]!.host, '192.168.1.21');
    expect(m[_cloudId]!.byMd5, isFalse);
  });

  test('unmatched cloud devices are absent', () {
    final m = matchLan(
      [const CloudDeviceRef(deviceId: _cloudId, mac: 'A0-B1-C2-00-00-01')],
      [_lan('192.168.1.22', 'AA-AA-AA-AA-AA-AA', md5: 'f' * 32)],
    );
    expect(m, isEmpty);
  });

  test('md5 wins and lan used once', () {
    const other = '802200000000000000000000000000000000EEEE';
    final m = matchLan(
      [
        const CloudDeviceRef(deviceId: other, mac: 'A0-B1-C2-00-00-01'),
        const CloudDeviceRef(deviceId: _cloudId, mac: 'A0-B1-C2-00-00-02'),
      ],
      [
        // md5 belongs to _cloudId, its MAC belongs to `other`.
        _lan('192.168.1.30', 'A0-B1-C2-00-00-01', md5: _md5),
      ],
    );
    expect(m.keys, [_cloudId]);
    expect(m[_cloudId]!.host, '192.168.1.30');
  });

  test('control protocol from raw', () {
    expect(controlProtocolFromRaw({'tpap': {'pake': [1]}}), 'tpap');
    expect(controlProtocolFromRaw({'encrypt_type': ['3', '4']}), 'tpap');
    expect(controlProtocolFromRaw({'encrypt_type': ['3']}), '');
    expect(controlProtocolFromRaw({}), '');
  });

  test('matched camera carries the tpap hint', () {
    final m = matchLan(
      [const CloudDeviceRef(deviceId: _cloudId)],
      [
        _lan('192.168.1.20', 'A0-B1-C2-00-00-01', md5: _md5, raw: {
          'tpap': {'pake': [1]},
        }),
      ],
    );
    expect(m[_cloudId]!.controlProtocol, 'tpap');
  });

  test('tpap requested hints', () {
    expect(tpapRequested({'pake': [1]}), isTrue);
    expect(tpapRequested({'pake': []}), isFalse);
    expect(tpapRequested(null, ['3', '4']), isTrue);
    expect(tpapRequested(null, [4]), isTrue);
    expect(tpapRequested(null, '4'), isTrue);
    expect(tpapRequested(null, 4), isTrue);
    expect(tpapRequested(null, ['3']), isFalse);
    expect(tpapRequested(null), isFalse);
  });
}
