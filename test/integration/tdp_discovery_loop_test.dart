// Tier 2: the production TDP discovery loop (discoverTdp) against MockTdp on
// loopback UDP. Windows: core/discovery/tdp.py discover() - probe the targets
// 3 times 0.3 s apart, collect replies until the timeout, dedupe by MAC, sort
// by IP, never raise for network problems.
// Specs: hc.discovery.tdp, hc.discovery.targets.
@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/lan_matcher.dart';
import 'package:tapo_tv/api/tdp_discovery.dart';

import '../fixtures/mock_cloud.dart' show makeCloudDevice;
import '../fixtures/mock_tdp.dart' as fx;

String _id(int i) => makeCloudDevice(i)['deviceId'] as String;

List<fx.TdpDevice> _fleet() => [
      fx.TdpDevice(ip: '192.168.1.53', mac: '00-11-22-33-44-03', deviceId: _id(3), httpPort: 8443),
      fx.TdpDevice(ip: '192.168.1.51', mac: 'aa:bb:cc:00:00:01', deviceId: _id(1)),
      fx.TdpDevice(ip: '192.168.1.52', mac: '00-11-22-33-44-02', deviceId: _id(2), encrypt: false),
    ];

void main() {
  late TdpKeyPair keys;

  setUpAll(() async {
    keys = await sharedTdpKeyPair();
  });

  test('probes the targets, decrypts the replies, dedupes by MAC and sorts by IP', () async {
    final mock = await fx.MockTdp(devices: _fleet()).start();
    addTearDown(mock.stop);
    final clock = Stopwatch()..start();

    final found = await discoverTdp(
      targets: [('127.0.0.1', mock.port)],
      timeout: const Duration(milliseconds: 1200),
      keys: keys,
    );

    expect(clock.elapsed, lessThan(const Duration(seconds: 3)), reason: 'the timeout bounds the loop');
    expect(mock.badProbes, 0, reason: 'valid version/opcode/CRC');
    expect(mock.requests.length, inInclusiveRange(1, 3), reason: 'at most 3 probe rounds');
    expect(mock.requests.map((r) => r.serial).toSet(), hasLength(1), reason: 'one serial per discovery');
    expect(found.map((d) => d.ip).toList(), ['192.168.1.51', '192.168.1.52', '192.168.1.53']);
    expect(found.first.md5, deviceIdMd5(_id(1)));
    expect(found.last.httpPort, 8443);
    final lan = found.map((d) => d.toLanDevice()).toList();
    expect(matchLan([CloudDeviceRef(deviceId: _id(2))], lan)[_id(2)]?.host, '192.168.1.52');
  });

  test('no camera answers: an empty list after the timeout, no exception', () async {
    final silent = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(silent.close);
    final found = await discoverTdp(
      targets: [('127.0.0.1', silent.port)],
      timeout: const Duration(milliseconds: 500),
      keys: keys,
    );
    expect(found, isEmpty);
  });

  test('an unreachable target is skipped', () async {
    final mock = await fx.MockTdp(devices: _fleet()).start();
    addTearDown(mock.stop);
    final found = await discoverTdp(
      targets: [('255.255.255.256', 20002), ('127.0.0.1', mock.port)],
      timeout: const Duration(milliseconds: 800),
      keys: keys,
    );
    expect(found, hasLength(3));
  });
}
