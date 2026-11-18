// Spec hc.local.headers_tls (tier 2): TOFU pin, stale socket, timeouts.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/camera_transport.dart';
import 'package:tapo_tv/api/tapo_errors.dart';

class _MemoryPins implements PinStore {
  final Map<String, String> map = {};
  @override
  String? read(String hostPort) => map[hostPort];
  @override
  Future<void> write(String hostPort, String sha256Hex) async => map[hostPort] = sha256Hex;
}

class _Sent {
  _Sent(this.path, this.body, this.headers);
  final String path;
  final String body;
  final Map<String, String> headers;
}

class _FakeLink implements CameraLink {
  _FakeLink(this.der, this.behaviour);
  final Uint8List der;
  final Future<ChannelResponse> Function(int callIndex) behaviour;
  final List<_Sent> sent = [];
  bool closed = false;

  @override
  Uint8List get peerCertificateDer => der;

  @override
  Future<ChannelResponse> send(
    String path,
    List<int> body,
    Map<String, String> headers, {
    required Duration timeout,
  }) {
    sent.add(_Sent(path, utf8.decode(body), headers));
    return behaviour(sent.length);
  }

  @override
  void close() => closed = true;
}

ChannelResponse _ok() => ChannelResponse(200, Uint8List.fromList(utf8.encode('{"error_code":0}')));

final _certA = Uint8List.fromList(List.generate(64, (i) => i));
final _certB = Uint8List.fromList(List.generate(64, (i) => 255 - i));

CameraTransport _transport(_MemoryPins pins, List<_FakeLink> links, List<int> connects) {
  var next = 0;
  return CameraTransport(
    host: '192.168.1.20',
    pins: pins,
    linkFactory: (host, port) async {
      connects.add(port);
      return links[next++];
    },
  );
}

void main() {
  test('first contact pins fingerprint', () async {
    final pins = _MemoryPins();
    final link = _FakeLink(_certA, (_) async => _ok());
    final t = _transport(pins, [link], []);
    final r = await t.post('/', utf8.encode('{}'));
    expect(r.status, 200);
    expect(pins.map['192.168.1.20:443'], sha256.convert(_certA).toString());
  });

  test('same certificate is accepted on the next connection', () async {
    final pins = _MemoryPins()..map['192.168.1.20:443'] = sha256.convert(_certA).toString();
    final t = _transport(pins, [_FakeLink(_certA, (_) async => _ok())], []);
    expect((await t.post('/', const [])).status, 200);
  });

  test('changed cert raises mismatch', () async {
    final pins = _MemoryPins()..map['192.168.1.20:443'] = sha256.convert(_certA).toString();
    final link = _FakeLink(_certB, (_) async => _ok());
    final t = _transport(pins, [link], []);
    await expectLater(t.post('/', const []), throwsA(isA<CertificateMismatch>()));
    expect(link.sent, isEmpty, reason: 'nothing is sent to a camera whose certificate changed');
    expect(link.closed, isTrue);
    expect(pins.map['192.168.1.20:443'], sha256.convert(_certA).toString(), reason: 'pin is kept');
  });

  test('stale socket resent once', () async {
    final pins = _MemoryPins();
    final stale = _FakeLink(_certA, (_) async => throw const SocketException('reset'));
    final fresh = _FakeLink(_certA, (_) async => _ok());
    final connects = <int>[];
    final t = _transport(pins, [stale, fresh], connects);
    final r = await t.post('/stok=abc/ds', utf8.encode('{"a":1}'));
    expect(r.status, 200);
    expect(connects, hasLength(2));
    expect(stale.sent, hasLength(1));
    expect(fresh.sent, hasLength(1));
    expect(fresh.sent.single.body, '{"a":1}', reason: 'the same body is resent');
  });

  test('stale socket is only resent once', () async {
    final pins = _MemoryPins();
    final links = [
      for (var i = 0; i < 3; i++) _FakeLink(_certA, (_) async => throw const SocketException('reset')),
    ];
    final connects = <int>[];
    final t = _transport(pins, links, connects);
    await expectLater(t.post('/', const []), throwsA(isA<SocketException>()));
    expect(connects, hasLength(2));
  });

  test('timeout not retried', () async {
    final pins = _MemoryPins();
    final link = _FakeLink(_certA, (_) async => throw TimeoutException('slow'));
    final connects = <int>[];
    final t = _transport(pins, [link, _FakeLink(_certA, (_) async => _ok())], connects);
    await expectLater(t.post('/', const []), throwsA(isA<TapoTimeoutError>()));
    expect(connects, hasLength(1));
    expect(link.sent, hasLength(1));
  });

  test('request headers match the app', () async {
    final link = _FakeLink(_certA, (_) async => _ok());
    final t = _transport(_MemoryPins(), [link], []);
    await t.post('/', utf8.encode('{}'));
    final h = link.sent.single.headers;
    expect(h['Accept'], 'application/json');
    expect(h['User-Agent'], 'Tapo CameraClient Android');
    expect(h['requestByApp'], 'true');
    expect(h['Referer'], 'https://192.168.1.20:443');
    expect(h['Content-Type'], 'application/json; charset=UTF-8');
  });

  test('tpap ds path uses octet-stream', () async {
    final link = _FakeLink(_certA, (_) async => _ok());
    final t = _transport(_MemoryPins(), [link], []);
    await t.post('/stok=abc/ds', const [1, 2, 3], headers: {
      'Content-Type': 'application/octet-stream',
      'Accept': 'application/octet-stream',
    });
    expect(link.sent.single.headers['Content-Type'], 'application/octet-stream');
    expect(link.sent.single.headers['Accept'], 'application/octet-stream');
  });

  test('requests are serialised per camera', () async {
    final gate = Completer<void>();
    final order = <String>[];
    final link = _FakeLink(_certA, (call) async {
      order.add('start$call');
      if (call == 1) await gate.future;
      order.add('end$call');
      return _ok();
    });
    final t = _transport(_MemoryPins(), [link], []);
    final a = t.post('/', const []);
    final b = t.post('/', const []);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(order, ['start1'], reason: 'second request waits for the first');
    gate.complete();
    await Future.wait([a, b]);
    expect(order, ['start1', 'end1', 'start2', 'end2']);
  });
}
