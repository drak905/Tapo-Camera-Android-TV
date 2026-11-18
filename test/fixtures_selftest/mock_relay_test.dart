// Self-test of test/fixtures/mock_relay.dart (CIPC tunnel) with raw TLS bytes.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../fixtures/fx_crypto.dart';
import '../fixtures/fx_io.dart';
import '../fixtures/mock_media8800.dart' show loadSampleTs;
import '../fixtures/mock_relay.dart';
import 'raw_clients.dart';

const trackId = '11111111-2222-3333-4444-555555555555';
const previewVga = {
  'method': 'get',
  'preview': {
    'channels': [0],
    'resolutions': ['VGA'],
    'audio': ['default']
  }
};

Future<MockRelay> startRelay() async {
  final r = await MockRelay().start();
  addTearDown(r.stop);
  return r;
}

/// (relay path with query, token) of a fresh slot.
(String, String) slotOf(MockRelay r, {int cloudType = 2, int streamType = 0, String res = 'VGA'}) {
  final s = r.issueSlot('DEV0001', res, cloudType, trackId, streamType: streamType);
  final url = Uri.parse(s['relayUrl'] as String);
  return ('${url.path}?${url.query}', s['relayToken'] as String);
}

Future<RelayRaw> open(MockRelay r) => RelayRaw.connect(r.port, r.clientSecurityContext());

void main() {
  test('golden: tunnel header order and heartbeat part', () {
    final lines = RelayRaw.tunnelRequestLines(
        path: '/relayservice?deviceid=DEV&type=video&resolution=VGA',
        token: 'TOKEN123',
        trackId: trackId,
        relayHost: 'relay.example.com',
        uuid: '<uuid>',
        redirectTimes: 1,
        cookie: 'AWSELB=xyz');
    expect(lines, [
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
    ]);
    expect(relayHeartbeatBody.length, 63);
    expect(latin1.decode(clientPart(relayHeartbeatBody)),
        '----client-stream-boundary--\r\nContent-Type: application/json\r\nContent-Length: 63\r\n\r\n{"type": "notification", "params": {"event_type": "heartbeat"}}\r\n');
  });

  test('exact header order accepted -> 200; live preview, heartbeat, acks, stop', () async {
    final relay = await startRelay();
    final (path, token) = slotOf(relay);
    final c = await open(relay);
    addTearDown(c.close);
    c.sendHead(RelayRaw.tunnelRequestLines(path: path, token: token, trackId: trackId));
    final (status, h, _) = await c.readHead();
    expect(status, 'HTTP/1.1 200 OK');
    expect(h['content-type'], contains('device-stream-boundary'));
    expect(relay.tunnels.single.status, '200');
    expect(relay.tunnels.single.headers.first.$1, 'User-Agent');
    expect(relay.openTunnels, 1);

    c.sendRequest(previewVga, 1);
    final resp = (await c.readPart())!.json!;
    expect(resp['type'], 'response');
    expect(resp['result']['error_code'], 0);
    c.sessionId = resp['params']['session_id'] as String;
    expect(relay.previews.single['resolution'], 'VGA');
    expect(relay.previews.single['slot_resolution'], 'VGA');

    c.sock.add(clientPart(relayHeartbeatBody));
    var n = 0;
    while (n < 10) {
      final p = (await c.readPart())!;
      if (p.contentType != 'video/mp2t') continue;
      expect(p.headers['x-if-encrypt'], '0');
      expect(p.headers['x-session-id'], c.sessionId);
      expect(p.body[0], 0x47);
      n++;
      if (n == 5) c.sock.add(ackPart(25, c.sessionId!));
    }
    expect(await waitFor(() => relay.heartbeats.length == 1 && relay.acks.contains('25')), isTrue);
    expect(relay.heartbeats.single.$2, relayHeartbeatBody);
    c.sendRequest({'method': 'do', 'stop': 'null'}, 2);
    expect(await waitFor(() => relay.stops == 1), isTrue);
    await c.close();
    expect(await waitFor(() => relay.openTunnels == 0), isTrue);
  });

  test('a client that does not trust the relay certificate cannot connect', () async {
    final relay = await startRelay();
    await expectLater(
        RelayRaw.connect(relay.port, SecurityContext(withTrustedRoots: false)),
        throwsA(isA<HandshakeException>()));
    await expectLater(
        RelayRaw.connect(relay.port, relay.clientSecurityContext(), host: 'wrong.example.com'),
        throwsA(isA<HandshakeException>()));
  });

  test('misordered / missing headers -> 400 errorCode 3; reused token still valid', () async {
    final relay = await startRelay();
    final (path, token) = slotOf(relay);
    for (final bad in [
      RelayRaw.tunnelRequestLines(path: path, token: token, trackId: trackId, swapAcceptAndKeepRelay: true),
      RelayRaw.tunnelRequestLines(path: path, token: token, trackId: trackId, withVersion: false),
      RelayRaw.tunnelRequestLines(path: path, token: token, trackId: trackId, cookie: 'unexpected=1'),
      RelayRaw.tunnelRequestLines(path: path, token: token, trackId: 'other-track'),
    ]) {
      final c = await open(relay);
      c.sendHead(bad);
      final (status, _, body) = await c.readHead();
      expect(status, 'HTTP/1.1 400 Bad Request');
      expect(body, {'errorCode': 3, 'closeReason': 'illegal_request'});
      await c.close();
    }
    final c = await open(relay);
    c.sendHead(RelayRaw.tunnelRequestLines(path: path, token: 'unknown', trackId: trackId));
    expect((await c.readHead()).$1, 'HTTP/1.1 403 Forbidden');
    await c.close();
    final ok = await open(relay);
    ok.sendHead(RelayRaw.tunnelRequestLines(path: path, token: token, trackId: trackId));
    expect((await ok.readHead()).$1, 'HTTP/1.1 200 OK');
    await ok.close();
  });

  test('line without &retryTime=0 is refused', () async {
    final relay = await startRelay();
    final (path, token) = slotOf(relay);
    final c = await open(relay);
    final lines = RelayRaw.tunnelRequestLines(path: path, token: token, trackId: trackId);
    lines[0] = 'POST $path HTTP/1.1';
    c.sendHead(lines);
    expect((await c.readHead()).$1, 'HTTP/1.1 400 Bad Request');
    await c.close();
  });

  test('offline mode and wrong cloudType -> 500 -1007', () async {
    final relay = await startRelay();
    for (final mode in [RelayMode.offline, RelayMode.ok]) {
      relay.mode = mode;
      final (path, token) = slotOf(relay, cloudType: mode == RelayMode.ok ? 1 : 2);
      final c = await open(relay);
      c.sendHead(RelayRaw.tunnelRequestLines(path: path, token: token, trackId: trackId));
      final (status, _, body) = await c.readHead();
      expect(status, 'HTTP/1.1 500 Internal Server Error');
      expect(body!['errorCode'], -1007);
      await c.close();
    }
  });

  test('redirects: 304 with a new slot, reconnect with X-Redirect-Times 1', () async {
    final relay = await startRelay();
    relay.redirects = 1;
    final (path, token) = slotOf(relay);
    final c = await open(relay);
    c.sendHead(RelayRaw.tunnelRequestLines(path: path, token: token, trackId: trackId));
    final (status, _, body) = await c.readHead();
    expect(status, 'HTTP/1.1 304 Not Modified');
    await c.close();
    final url = Uri.parse(body!['relayUrl'] as String);
    final c2 = await open(relay);
    // same redirect count as before -> refused
    c2.sendHead(RelayRaw.tunnelRequestLines(
        path: '${url.path}?${url.query}', token: body['relayToken'] as String, trackId: trackId));
    expect((await c2.readHead()).$1, 'HTTP/1.1 400 Bad Request');
    await c2.close();
    final c3 = await open(relay);
    c3.sendHead(RelayRaw.tunnelRequestLines(
        path: '${url.path}?${url.query}', token: body['relayToken'] as String, trackId: trackId, redirectTimes: 1));
    expect((await c3.readHead()).$1, 'HTTP/1.1 200 OK');
    await c3.close();
    expect(relay.tunnels.map((t) => t.status), ['304', '400 Bad Request', '200']);
  });

  test('drop mode closes without an answer; ELB cookie is required when issued', () async {
    final relay = await startRelay();
    relay.mode = RelayMode.drop;
    var (path, token) = slotOf(relay);
    var c = await open(relay);
    c.sendHead(RelayRaw.tunnelRequestLines(path: path, token: token, trackId: trackId));
    expect(await c.reader.readLine(), isNull);
    expect(relay.tunnels.last.status, 'dropped');
    relay.mode = RelayMode.ok;
    relay.elbCookie = 'AWSELB=abc';
    (path, token) = slotOf(relay);
    c = await open(relay);
    c.sendHead(RelayRaw.tunnelRequestLines(path: path, token: token, trackId: trackId, cookie: 'AWSELB=abc'));
    expect((await c.readHead()).$1, 'HTTP/1.1 200 OK');
    await c.close();
  });

  test('dropAll closes open tunnels', () async {
    final relay = await startRelay();
    final (path, token) = slotOf(relay);
    final c = await open(relay);
    c.sendHead(RelayRaw.tunnelRequestLines(path: path, token: token, trackId: trackId));
    await c.readHead();
    relay.dropAll();
    expect(await c.readPart(), isNull);
  });

  test('encrypted mode: X-If-Encrypt 1 + X-Nonce + X-Data-Hmac, decryptable with encryptedKeys', () async {
    final relay = await startRelay();
    relay.mode = RelayMode.encrypted;
    final (path, token) = slotOf(relay);
    final c = await open(relay);
    addTearDown(c.close);
    c.sendHead(RelayRaw.tunnelRequestLines(path: path, token: token, trackId: trackId));
    await c.readHead();
    c.sendRequest(previewVga, 1);
    await c.readPart();
    var p = (await c.readPart())!;
    while (p.contentType != 'video/mp2t') {
      p = (await c.readPart())!;
    }
    expect(p.headers['x-if-encrypt'], '1');
    final k = relay.encryptedKeys;
    expect(constTimeEq(b64d(p.headers['x-data-hmac']!), hmacSha256(k.hmacKey, p.body)), isTrue);
    final plain = aesCbcDecrypt(k.aesKey, fromHex(p.headers['x-nonce']!), p.body);
    expect(plain[0], 0x47);
  });

  group('VOD tunnels', () {
    test('streamType 1: first request must be get playback; clip then finished', () async {
      final relay = await startRelay();
      final (path, token) = slotOf(relay, streamType: 1);
      expect(path, contains('type=sdvod'));
      final c = await open(relay);
      addTearDown(c.close);
      c.sendHead(RelayRaw.tunnelRequestLines(path: path, token: token, trackId: trackId));
      await c.readHead();
      c.sendRequest(previewVga, 1); // wrong verb for a playback slot
      expect((await c.readPart())!.json!['result']['error_code'], -40106);
      c.sendRequest({
        'method': 'get',
        'playback': {
          'client_id': 1,
          'channels': [0],
          'scale': '1/1',
          'start_time': '1700000000',
          'end_time': '1700086399',
          'event_type': [1, 2]
        }
      }, 2);
      final r = (await c.readPart())!.json!;
      expect(r['result']['speed'], '1/1');
      expect(r['params']['session_id'], isNotEmpty);
      final out = BytesBuilder();
      Map<String, dynamic>? fin;
      DevicePart? p;
      while ((p = await c.readPart()) != null) {
        if (p!.contentType == 'video/mp2t') {
          expect(p.headers['x-if-encrypt'], '0');
          out.add(p.body);
        } else {
          fin = p.json;
          break;
        }
      }
      expect(out.toBytes(), loadSampleTs());
      expect(fin!['params']['status'], 'finished');
      expect(relay.vodRequests.single['verb'], 'playback');
    });

    test('streamType 3 download and vodRefuse', () async {
      final relay = await startRelay();
      relay.vodRefuse.add('download');
      final (path, token) = slotOf(relay, streamType: 3);
      expect(path, contains('type=download'));
      final c = await open(relay);
      addTearDown(c.close);
      c.sendHead(RelayRaw.tunnelRequestLines(path: path, token: token, trackId: trackId));
      await c.readHead();
      c.sendRequest({
        'method': 'get',
        'download': {'start_time': '1700000000', 'end_time': '1700000060'}
      }, 1);
      expect((await c.readPart())!.json!['result']['error_code'], -52402);
    });
  });
}
