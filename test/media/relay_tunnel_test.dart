// mb.relay.tunnel_headers: exact request order, 304 redirect, 400 mapping.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/media/media_errors.dart';
import 'package:tapo_tv/media/relay/relay_slot.dart';
import 'package:tapo_tv/media/relay/relay_tunnel.dart';

import 'helpers/fakes.dart';

RelaySlot _slot({String path = '/relayservice?deviceid=DEV&type=video&resolution=VGA', String cookie = ''}) => RelaySlot(
      deviceId: 'DEV',
      relayHost: 'relay.example.com',
      relayPort: 443,
      relayPath: path,
      relayIp: '10.0.0.9',
      trackId: '11111111-2222-3333-4444-555555555555',
      resolution: 'VGA',
      token: 'TOKEN123',
      elbCookie: cookie,
    );

List<String> _lines(List<int> bytes) => latin1.decode(bytes).split('\r\n');

String _redirectBody() => jsonEncode({
      'result': {
        'relayUrl': 'https://relay2.example.com/relayservice?deviceid=DEV',
        'relayToken': 'TOKEN2',
        'relayIp': '10.0.0.10',
      }
    });

String _http(int status, String reason, String body) =>
    'HTTP/1.1 $status $reason\r\nContent-Length: ${utf8.encode(body).length}\r\n\r\n$body';

Future<RelayTunnelConnection> _open(FakeConnector c, RelaySlot slot) => RelayTunnel.open(
      slot,
      connector: c.connect,
      clientModel: 'Windows',
      terminalUuid: '<uuid>',
      appVersion: '3.22.806',
    );

void main() {
  test('request bytes exact order with cookie', () {
    final bytes = buildTunnelRequest(
      _slot(cookie: 'AWSELB=xyz'),
      clientModel: 'Windows',
      terminalUuid: '<uuid>',
      appVersion: '3.22.806',
      redirectTimes: 1,
      arriveLatencyMs: 42,
    );
    expect(_lines(bytes), [
      'POST /relayservice?deviceid=DEV&type=video&resolution=VGA&retryTime=0 HTTP/1.1',
      'User-Agent: Client=TP-Link_Tapo_Android Android 3.22.806/1.3',
      'Keep-Relay: 3600',
      'Accept: */*',
      'Content-Type: multipart/mixed;boundary=--client-stream-boundary--',
      'Host: relay.example.com',
      'Content-Length: 9223372036854775807',
      'X-token: TOKEN123',
      'X-Client-Model: Windows',
      'X-Client-UUID: <uuid>',
      'X-Track-Id: 11111111-2222-3333-4444-555555555555',
      'X-Redirect-Times: 1',
      'X-Pull-Mode: 2',
      'Cookie: AWSELB=xyz',
      'X-Version: 2.0',
      'X-Arrive-Latency: 42',
      '',
      '',
    ]);
  });

  test('order without cookie', () {
    final lines = _lines(buildTunnelRequest(_slot(),
        clientModel: 'Windows', terminalUuid: '<uuid>', appVersion: '3.22.806', arriveLatencyMs: 7));
    expect(lines.where((l) => l.startsWith('Cookie')), isEmpty);
    final i = lines.indexOf('X-Pull-Mode: 2');
    expect(lines[i + 1], 'X-Version: 2.0');
    expect(lines[i + 2], 'X-Arrive-Latency: 7');
    expect(lines[0].startsWith('POST '), isTrue);
    expect(lines[5], 'Host: relay.example.com', reason: 'Host is the sixth line, not the first');
  });

  test('path without query uses ? before retryTime', () {
    final lines = _lines(buildTunnelRequest(_slot(path: '/relayservice'),
        clientModel: 'Windows', terminalUuid: 'u', appVersion: '3.22.806'));
    expect(lines.first, 'POST /relayservice?retryTime=0 HTTP/1.1');
  });

  test('200 opens the raw tunnel over TLS to relayIp with SNI of the relay host', () async {
    final c = FakeConnector(onConnect: (t, i) => FakeCamera(t, mode: CameraMode.relay));
    final conn = await _open(c, _slot());
    expect(c.calls.single.host, '10.0.0.9');
    expect(c.calls.single.port, 443);
    expect(c.calls.single.tls, isTrue);
    expect(c.calls.single.serverName, 'relay.example.com');
    expect(conn.redirectTimes, 0);
    // bytes after the head belong to the tunnel and are not consumed
    c.transports.single.push([1, 2, 3]);
    expect(await conn.input.first, [1, 2, 3]);
    await conn.transport.close();
  });

  test('304 redirect increments X-Redirect-Times max 3', () async {
    final c = FakeConnector(onConnect: (t, i) {
      t.onWrite = (_) => t.push(bytesOf(_http(304, 'Not Modified', _redirectBody())));
    });
    await expectLater(_open(c, _slot()), throwsA(isA<RelayException>()));
    expect(c.calls, hasLength(4), reason: 'first connect + 3 redirects');
    for (var i = 0; i < 4; i++) {
      expect(latin1.decode(c.transports[i].written), contains('X-Redirect-Times: $i\r\n'));
    }
    expect(latin1.decode(c.transports[1].written), contains('X-token: TOKEN2'));
    expect(c.calls[1].serverName, 'relay2.example.com');
  });

  test('304 then 200 follows the redirect', () async {
    final c = FakeConnector(onConnect: (t, i) {
      t.onWrite = (_) => t.push(bytesOf(i == 0 ? _http(304, 'Not Modified', _redirectBody()) : 'HTTP/1.1 200 OK\r\n\r\n'));
    });
    final conn = await _open(c, _slot());
    expect(conn.redirectTimes, 1);
    expect(conn.slot.relayHost, 'relay2.example.com');
    expect(c.transports[0].closed, isTrue);
  });

  test('400 errorCode 3 maps to illegal request', () async {
    final c = FakeConnector(onConnect: (t, i) {
      t.onWrite = (_) =>
          t.push(bytesOf(_http(400, 'Bad Request', '{"errorCode":3,"closeReason":"illegal_request"}')));
    });
    await expectLater(
      _open(c, _slot()),
      throwsA(isA<RelayException>()
          .having((e) => e.code, 'code', 3)
          .having((e) => e.fatal, 'fatal', isTrue)
          .having((e) => e.message, 'message', isNot(contains('TOKEN123')))),
    );
    expect(c.calls, hasLength(1));
  });

  test('errorCode -1007 on the tunnel is fatal camera offline', () async {
    final c = FakeConnector(onConnect: (t, i) {
      t.onWrite = (_) => t.push(bytesOf(_http(403, 'Forbidden', '{"errorCode":-1007}')));
    });
    await expectLater(_open(c, _slot()),
        throwsA(isA<RelayException>().having((e) => e.code, 'code', -1007).having((e) => e.fatal, 'fatal', isTrue)));
  });
}
