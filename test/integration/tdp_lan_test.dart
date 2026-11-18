// Tier 2, scenario 3: TDP discovery against MockTdp (real UDP on loopback) and
// the cloud <-> LAN matcher. The production discovery socket is not written
// yet, so the test sends the probe itself with buildTdpProbe and feeds the
// datagrams to parseTdpDatagram, exactly what the discovery loop will do.
// Specs: hc.discovery.tdp, hc.discovery.matcher, hc.discovery.tpap_hint.
@Timeout(Duration(seconds: 90))
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/lan_matcher.dart';
import 'package:tapo_tv/api/tdp_discovery.dart' as tdp;

import '../fixtures/mock_cloud.dart' show makeCloudDevice;
import '../fixtures/mock_tdp.dart' as fx;

String _id(int i) => makeCloudDevice(i)['deviceId'] as String;

Future<List<tdp.TdpDevice>> _probe(
  fx.MockTdp mock,
  tdp.TdpKeyPair keys, {
  required int serial,
  int expect = 3,
}) async {
  final sock = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final found = <tdp.TdpDevice>[];
  final done = Completer<void>();
  sock.listen((e) {
    if (e != RawSocketEvent.read) return;
    Datagram? d;
    while ((d = sock.receive()) != null) {
      found.addAll(tdp.parseTdpDatagram(d!.data, serial: serial, senderIp: d.address.address, keys: keys));
    }
    if (found.length >= expect && !done.isCompleted) done.complete();
  });
  final packet = tdp.buildTdpProbe(
    payloadJson: tdp.tdpProbePayload(keys.publicKeyPem),
    serial: serial,
    flags: tdp.tdpFlagsUnicast,
  );
  sock.send(packet, InternetAddress.loopbackIPv4, mock.port);
  try {
    await done.future.timeout(const Duration(seconds: 3));
  } on TimeoutException {
    // fewer replies than expected: the assertions below report it
  } finally {
    sock.close();
  }
  return found;
}

List<fx.TdpDevice> _fleet() => [
      fx.TdpDevice(
        ip: '192.168.1.51',
        mac: 'aa:bb:cc:00:00:01',
        deviceId: _id(1),
        httpPort: 443,
      ),
      // no encrypt_info: only the top-level MD5(deviceId) identifies it
      fx.TdpDevice(
        ip: '192.168.1.52',
        mac: '00-11-22-33-44-02',
        deviceId: _id(2),
        encrypt: false,
        httpPort: 8443,
      ),
      // TPAP-only firmware hint
      fx.TdpDevice(
        ip: '192.168.1.53',
        mac: '0011.2233.4403',
        deviceId: _id(3),
        extra: const {
          'tpap': {
            'pake': [1],
          },
        },
      ),
    ];

LanDevice _lan(tdp.TdpDevice d) => LanDevice(
      ip: d.ip,
      mac: d.mac,
      md5: d.md5,
      httpPort: d.httpPort,
      raw: d.raw,
    );

void main() {
  late tdp.TdpKeyPair keys;

  setUpAll(() async {
    keys = await tdp.generateTdpKeyPair();
  });

  test('probe is a valid TDP packet, replies decrypt, devices carry ip/mac/md5/port', () async {
    final mock = await fx.MockTdp(devices: _fleet()).start();
    addTearDown(mock.stop);

    final devices = await _probe(mock, keys, serial: 4242);

    expect(mock.badProbes, 0, reason: 'version/opcode/CRC of the probe must be valid');
    expect(mock.requests, hasLength(1));
    expect(mock.requests.single.serial, 4242);
    expect(mock.requests.single.rsaKey, isNotEmpty);
    expect(devices.map((d) => d.ip).toSet(), {'192.168.1.51', '192.168.1.52', '192.168.1.53'});

    final a = devices.firstWhere((d) => d.ip == '192.168.1.51');
    expect(a.mac, 'AA-BB-CC-00-00-01');
    expect(a.md5, deviceIdMd5(_id(1)));
    expect(a.httpPort, anyOf(isNull, 443));
    final b = devices.firstWhere((d) => d.ip == '192.168.1.52');
    expect(b.md5, deviceIdMd5(_id(2)), reason: 'top-level md5 only, lower-cased');
    expect(b.mac, '00-11-22-33-44-02');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('concatenated replies and a junk datagram do not lose devices', () async {
    final mock = await fx.MockTdp(devices: _fleet(), concat: true, garbage: true).start();
    addTearDown(mock.stop);
    final devices = await _probe(mock, keys, serial: 7);
    expect(devices.map((d) => d.ip).toSet(), hasLength(3));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('matchLan pairs cloud devices by md5(deviceId) then MAC and sets the TPAP hint', () async {
    final mock = await fx.MockTdp(devices: _fleet()).start();
    addTearDown(mock.stop);
    final devices = await _probe(mock, keys, serial: 99);

    final cloud = [
      CloudDeviceRef(deviceId: _id(1), mac: 'AA:BB:CC:00:00:01'),
      CloudDeviceRef(deviceId: _id(2)),
      CloudDeviceRef(deviceId: _id(3), mac: '00:11:22:33:44:03'),
      CloudDeviceRef(deviceId: _id(4), mac: 'FF:EE:DD:CC:BB:04'), // not on this LAN
    ];
    final matches = matchLan(cloud, devices.map(_lan).toList());

    expect(matches.keys.toSet(), {_id(1), _id(2), _id(3)});
    expect(matches.containsKey(_id(4)), isFalse);

    final m1 = matches[_id(1)]!;
    expect(m1.lanFound, isTrue);
    expect(m1.host, '192.168.1.51');
    expect(m1.httpsPort, 443);
    expect(m1.byMd5, isTrue);
    expect(m1.controlProtocol, '', reason: 'no hint: probe v3 first');

    final m2 = matches[_id(2)]!;
    expect(m2.host, '192.168.1.52');
    expect(m2.httpsPort, 8443);
    expect(m2.byMd5, isTrue);

    final m3 = matches[_id(3)]!;
    expect(m3.host, '192.168.1.53');
    expect(m3.controlProtocol, 'tpap');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a probe with a corrupted CRC is ignored by the camera', () async {
    final mock = await fx.MockTdp(devices: _fleet()).start();
    addTearDown(mock.stop);
    final probe = tdp.buildTdpProbe(
      payloadJson: tdp.tdpProbePayload(keys.publicKeyPem),
      serial: 5,
    );
    final broken = Uint8List.fromList(probe)..[13] ^= 0xFF;
    final sock = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(sock.close);
    sock.send(broken, InternetAddress.loopbackIPv4, mock.port);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(mock.requests, isEmpty);
    expect(mock.badProbes, 1);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
