// Specs hc.discovery.tdp_packet / tdp_reply / tdp_encrypt_info / targets.
// Vectors from tests/phase2/test_tdp_packet.py in the Windows repo.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:tapo_tv/api/lan_matcher.dart';
import 'package:tapo_tv/api/tdp_discovery.dart';

import '_support/helpers.dart';

const _probePayload = '{"params":{"rsa_key":"TEST"}}';
const _probeHex =
    '02000001001d1100012345671acf25777b22706172616d73223a7b227273615f6b6579223a2254455354227d7d';
const _serial = 0x01234567;
const _fullId = '802200000000000000000000000000000000ABCD';

Map<String, dynamic> _reply(Map<String, dynamic> result) => {'error_code': 0, 'result': result};

/// encrypt_info the way a camera builds it.
Map<String, dynamic> _encryptInfo(RSAPublicKey pub, Map<String, dynamic> data) {
  final rnd = Random(7);
  final keyIv = Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256)));
  final oaep = OAEPEncoding.withSHA1(RSAEngine())
    ..init(true, PublicKeyParameter<RSAPublicKey>(pub));
  final wrapped = oaep.process(keyIv);
  final enc = aesCbc(
    true,
    Uint8List.sublistView(keyIv, 0, 16),
    Uint8List.sublistView(keyIv, 16, 32),
    Uint8List.fromList(utf8.encode(jsonEncode(data))),
  );
  return {'sym_schm': 'AES', 'key': base64.encode(wrapped), 'data': base64.encode(enc)};
}

void main() {
  group('probe packet', () {
    test('probe golden vector byte exact', () {
      final p = buildTdpProbe(payloadJson: _probePayload, serial: _serial);
      expect(hex(p), _probeHex);
    });

    test('unicast flags', () {
      final p = buildTdpProbe(payloadJson: _probePayload, serial: _serial, flags: tdpFlagsUnicast);
      expect(p[6], 0x21);
    });

    test('crc over seeded header', () {
      final p = unhex(_probeHex);
      expect(tdpCrc32(p), 0x1acf2577);
      // The CRC slot content is ignored: the seed is written first.
      final zeroed = Uint8List.fromList(p)..setRange(12, 16, [0, 0, 0, 0]);
      expect(tdpCrc32(zeroed), 0x1acf2577);
    });

    test('serial out of range rejected', () {
      for (final bad in [-1, 1 << 28, 0xFFFFFFFF]) {
        expect(
          () => buildTdpProbe(payloadJson: _probePayload, serial: bad),
          throwsArgumentError,
          reason: '$bad',
        );
      }
      expect(buildTdpProbe(payloadJson: _probePayload, serial: (1 << 28) - 1).length,
          16 + _probePayload.length);
    });

    test('probe payload is compact json with the pem', () {
      expect(tdpProbePayload('PEM'), '{"params":{"rsa_key":"PEM"}}');
    });
  });

  group('reply parsing without keys', () {
    test('plain reply lowercases md5', () {
      final pkt = tdpPacket(
        _reply({
          'ip': '192.168.1.20',
          'mac': 'a0:b1:c2:00:00:01',
          'device_type': 'SMART.IPCAMERA',
          'device_model': 'C200',
          'device_id': 'E4247A931858B38594790FC6606441AA',
          'encrypt_type': ['3'],
        }),
        serial: _serial,
      );
      final out = parseTdpDatagram(pkt, serial: _serial, senderIp: '192.168.1.99');
      expect(out, hasLength(1));
      expect(out.single.ip, '192.168.1.20');
      expect(out.single.mac, 'A0-B1-C2-00-00-01');
      expect(out.single.md5, 'e4247a931858b38594790fc6606441aa');
      expect(out.single.httpPort, isNull);
      expect(out.single.deviceModel, 'C200');
    });

    test('sender address used when result ip is missing or invalid', () {
      for (final ip in [null, 'not-an-ip', '999.1.1.1']) {
        final pkt = tdpPacket(
          _reply({'mac': 'A0-B1-C2-00-00-01', 'ip': ?ip}),
          serial: _serial,
        );
        final out = parseTdpDatagram(pkt, serial: _serial, senderIp: '192.168.1.99');
        expect(out.single.ip, '192.168.1.99', reason: '$ip');
      }
    });

    test('tpap hints are kept', () {
      final pkt = tdpPacket(
        _reply({
          'ip': '192.168.1.20',
          'mac': 'A0-B1-C2-00-00-01',
          'encrypt_type': ['3', '4'],
          'tpap': {
            'pake': [1],
            'user_hash_type': 1,
          },
        }),
        serial: _serial,
      );
      final d = parseTdpDatagram(pkt, serial: _serial, senderIp: '192.168.1.99').single;
      expect(d.tpap?['user_hash_type'], 1);
      expect(tpapRequested(d.tpap, d.encryptTypes), isTrue);
    });

    test('bad crc rejected', () {
      final pkt = tdpPacket(_reply({'ip': '192.168.1.20', 'mac': 'A0-B1-C2-00-00-01'}),
          serial: _serial, badCrc: true);
      expect(parseTdpDatagram(pkt, serial: _serial, senderIp: '192.168.1.99'), isEmpty);
    });

    test('serial and version mismatch ignored', () {
      final r = _reply({'ip': '192.168.1.20', 'mac': 'A0-B1-C2-00-00-01'});
      expect(parseTdpDatagram(tdpPacket(r, serial: _serial + 1), serial: _serial, senderIp: 'x'),
          isEmpty);
      expect(parseTdpDatagram(tdpPacket(r, serial: _serial, version: 1), serial: _serial,
          senderIp: 'x'), isEmpty);
      expect(parseTdpDatagram(tdpPacket(r, serial: _serial, ret: 5), serial: _serial,
          senderIp: 'x'), isEmpty);
    });

    test('error code or missing result ignored', () {
      final a = tdpPacket({'error_code': -1, 'result': {'mac': 'A0-B1-C2-00-00-01'}}, serial: _serial);
      final b = tdpPacket({'error_code': 0}, serial: _serial);
      expect(parseTdpDatagram(a, serial: _serial, senderIp: '192.168.1.9'), isEmpty);
      expect(parseTdpDatagram(b, serial: _serial, senderIp: '192.168.1.9'), isEmpty);
    });

    test('concatenated packets', () {
      final a = tdpPacket(_reply({'ip': '192.168.1.20', 'mac': 'A0-B1-C2-00-00-01'}), serial: _serial);
      final b = tdpPacket(_reply({'ip': '192.168.1.21', 'mac': 'A0-B1-C2-00-00-02'}), serial: _serial);
      final dup = tdpPacket(_reply({'ip': '192.168.1.22', 'mac': 'a0:b1:c2:00:00:01'}), serial: _serial);
      final out = parseTdpDatagram(
        Uint8List.fromList([...a, ...b, ...dup]),
        serial: _serial,
        senderIp: '192.168.1.99',
      );
      expect(out.map((d) => d.ip), ['192.168.1.20', '192.168.1.21']); // dup MAC: first wins
    });

    test('truncated tail stops without throwing', () {
      final a = tdpPacket(_reply({'ip': '192.168.1.20', 'mac': 'A0-B1-C2-00-00-01'}), serial: _serial);
      final cut = Uint8List.fromList([...a, ...a.sublist(0, 20)]);
      expect(parseTdpDatagram(cut, serial: _serial, senderIp: 'x'), hasLength(1));
    });

    test('random bytes never throw', () {
      final rnd = Random(42);
      for (var i = 0; i < 300; i++) {
        final n = rnd.nextInt(200);
        final bytes = Uint8List.fromList(List.generate(n, (_) => rnd.nextInt(256)));
        expect(() => parseTdpDatagram(bytes, serial: _serial, senderIp: '192.168.1.9'),
            returnsNormally, reason: 'iteration $i');
      }
      // Valid header + CRC around hostile JSON.
      for (final body in ['not json', '[]', '{"result":5}', '{"error_code":"x","result":{}}', '']) {
        final pkt = tdpPacket(body, serial: _serial);
        expect(() => parseTdpDatagram(pkt, serial: _serial, senderIp: '192.168.1.9'),
            returnsNormally, reason: body);
      }
    });
  });

  group('encrypt_info (needs an RSA key pair)', () {
    late TdpKeyPair keys;

    setUpAll(() async {
      keys = await generateTdpKeyPair();
    });

    test('key pair exposes an SPKI pem with 64 char lines', () {
      final lines = keys.publicKeyPem.trimRight().split('\n');
      expect(lines.first, '-----BEGIN PUBLIC KEY-----');
      expect(lines.last, '-----END PUBLIC KEY-----');
      expect(lines.sublist(1, lines.length - 2).every((l) => l.length == 64), isTrue);
      expect(keys.publicKeyPem.endsWith('\n'), isTrue);
      expect(keys.publicKey.modulus!.bitLength, 2048);
    });

    test('decrypt_info roundtrip with generated key', () {
      final info = _encryptInfo(keys.publicKey, {'device_id': _fullId, 'http_port': 8443});
      final out = decryptEncryptInfo(info, keys);
      expect(out['device_id'], _fullId);
      expect(out['http_port'], 8443);
    });

    test('wrong key falls back to top level md5', () async {
      final other = await generateTdpKeyPair();
      final info = _encryptInfo(other.publicKey, {'device_id': _fullId});
      expect(decryptEncryptInfo(info, keys), isEmpty);
      expect(decryptEncryptInfo({'key': '!!', 'data': '!!'}, keys), isEmpty);
      final pkt = tdpPacket(
        _reply({
          'ip': '192.168.1.20',
          'mac': 'A0-B1-C2-00-00-01',
          'device_id': 'E4247A931858B38594790FC6606441AA',
          'encrypt_info': info,
        }),
        serial: _serial,
      );
      final d = parseTdpDatagram(pkt, serial: _serial, senderIp: 'x', keys: keys).single;
      expect(d.md5, 'e4247a931858b38594790fc6606441aa');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('encrypted reply yields md5 and port', () {
      final info = _encryptInfo(keys.publicKey, {'device_id': _fullId, 'http_port': 8443});
      final pkt = tdpPacket(
        _reply({'ip': '192.168.1.20', 'mac': 'A0-B1-C2-00-00-01', 'encrypt_info': info}),
        serial: _serial,
      );
      final d = parseTdpDatagram(pkt, serial: _serial, senderIp: 'x', keys: keys).single;
      expect(d.md5, deviceIdMd5(_fullId));
      expect(d.md5, 'e4247a931858b38594790fc6606441aa');
      expect(d.httpPort, 8443);
    });

    test('zero or invalid http port becomes null', () {
      for (final port in [0, -5, 70000, 'x']) {
        final info = _encryptInfo(keys.publicKey, {'device_id': _fullId, 'http_port': port});
        final pkt = tdpPacket(
          _reply({'ip': '192.168.1.20', 'mac': 'A0-B1-C2-00-00-01', 'encrypt_info': info}),
          serial: _serial,
        );
        expect(parseTdpDatagram(pkt, serial: _serial, senderIp: 'x', keys: keys).single.httpPort,
            isNull, reason: '$port');
      }
    });
  });

  group('targets', () {
    test('targets from interface list', () {
      final t = tdpTargets(const [
        TdpInterface('192.168.1.50', 24),
        TdpInterface('10.0.0.7', 16),
        TdpInterface('127.0.0.1', 8), // loopback
        TdpInterface('169.254.3.4', 16), // link local
        TdpInterface('192.168.1.9', 31), // prefix too long
      ]);
      expect(t, [
        ('255.255.255.255', 20002),
        ('255.255.255.255', 20004),
        ('192.168.1.255', 20002),
        ('192.168.1.255', 20004),
        ('10.0.255.255', 20002),
        ('10.0.255.255', 20004),
      ]);
    });
  });
}
