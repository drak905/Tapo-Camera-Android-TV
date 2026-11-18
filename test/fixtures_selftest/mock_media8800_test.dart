// Self-test of test/fixtures/mock_media8800.dart with raw TCP bytes.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../fixtures/camera_state.dart';
import '../fixtures/fx_crypto.dart';
import '../fixtures/fx_io.dart';
import '../fixtures/mock_camera.dart';
import '../fixtures/mock_media8800.dart';
import 'raw_clients.dart';

/// true when HTTP-inspecting security software on this machine rejects the plain :8800 multipart traffic.
bool tlsNeeded = false;

Future<MediaRaw> conn(MockMedia8800 m) => MediaRaw.connect('127.0.0.1', m.port, tls: m.useTls);

Future<bool> probePlainBlocked() async {
  final m = await MockMedia8800().start();
  final c = await MediaRaw.connect('127.0.0.1', m.port);
  try {
    await c.handshake('cloudpass');
    c.sendRequest(previewVga, 1);
    final line = await c.reader.readLine().timeout(const Duration(seconds: 3));
    return line != null && line.startsWith('HTTP/');
  } catch (_) {
    return false;
  } finally {
    await c.close();
    await m.stop();
  }
}

Future<MockMedia8800> startMedia(MockMedia8800 m) async {
  m.useTls = tlsNeeded;
  await m.start();
  addTearDown(m.stop);
  return m;
}

const previewVga = {
  'method': 'get',
  'preview': {
    'channels': [0],
    'resolutions': ['VGA'],
    'audio': ['default']
  }
};

/// Decrypts a media part according to the Key-Exchange header of the 200 answer.
Uint8List? decryptPart(DevicePart p, Map<String, String> hs, String secret, bool enc3) {
  final kx = hs['key-exchange'];
  if (p.headers['x-if-encrypt'] != '1' || kx == null) return p.body;
  final kv = parseKv(kx);
  final pwd = mediaPassword(secret, enc3);
  if ((kv['algorithm'] ?? '') == 'HKDF') {
    final k = mediaHkdfKeys(kv['nonce']!, pwd, kv['salt']!);
    final mac = p.headers['x-data-hmac'];
    if (mac != null && !constTimeEq(b64d(mac), hmacSha256(k.hmacKey, p.body))) return null;
    return aesCbcDecrypt(k.aesKey, fromHex(p.headers['x-nonce']!), p.body);
  }
  final k = mediaKeys(kv['nonce']!, pwd, kv['username']!);
  return aesCbcDecrypt(k.key, k.iv, p.body);
}

void expectTs(Uint8List b) {
  expect(b.length % 188, 0);
  for (var i = 0; i < b.length; i += 188) {
    expect(b[i], 0x47);
  }
}

void main() {
  setUpAll(() async {
    tlsNeeded = await probePlainBlocked();
    if (tlsNeeded) {
      // ignore: avoid_print
      print('NOTE: plain :8800 traffic is rejected by local HTTP inspection; self-tests use TLS mode.');
    }
  });

  group('golden helpers (mb.local.*)', () {
    test('RFC digest vectors and client part framing', () {
      expect(
          digestResponse('MD5', 'Mufasa', 'http-auth@example.org', 'Circle of Life', 'GET',
              '/dir/index.html', '7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v', '00000001',
              'f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ', 'auth'),
          '8ca523f5e9506fed4657c9700eebdbec');
      expect(
          digestResponse('SHA-256', 'Mufasa', 'http-auth@example.org', 'Circle of Life', 'GET',
              '/dir/index.html', '7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v', '00000001',
              'f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ', 'auth'),
          '753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1');
      expect(latin1.decode(clientPart(utf8.encode('{"type":"request","seq":1}'))),
          '----client-stream-boundary--\r\nContent-Type: application/json\r\nContent-Length: 26\r\n\r\n{"type":"request","seq":1}\r\n');
      expect(
          latin1.decode(clientPart(utf8.encode('ab'),
              contentType: 'audio/mp2t', headers: [('X-If-Encrypt', '1'), ('X-Session-Id', '9')])),
          '----client-stream-boundary--\r\nX-If-Encrypt: 1\r\nX-Session-Id: 9\r\nContent-Type: audio/mp2t\r\nContent-Length: 2\r\n\r\nab\r\n');
      expect(latin1.decode(ackPart(25, '9')),
          '----client-stream-boundary--\r\nX-Data-Received: 25\r\nX-Session-Id: 9\r\nContent-Type: application/json\r\nContent-Length: 65\r\n\r\n{"type":"notification","params":{"event_type":"stream_sequence"}}\r\n');
      expect(
          compactJson({
            'type': 'request',
            'seq': 1,
            'params': previewVga
          }),
          contains('"resolutions":["VGA"]'));
    });
  });

  test('sample.ts is a short, valid MPEG-TS under 200 KB', () {
    final ts = loadSampleTs();
    expect(ts.length, inInclusiveRange(188 * 100, 200 * 1024));
    expectTs(ts);
  });

  group('handshake', () {
    test('401 challenge, wrong digest counted, MD5 digest accepted, exact challenge fields', () async {
      final m = await startMedia(MockMedia8800());
      final c = await conn(m);
      addTearDown(c.close);
      final (s1, h1, _) = await c.post();
      expect(s1, 401);
      final ch = parseKv(h1['www-authenticate']!.substring(7));
      expect(ch['qop'], 'auth');
      expect(ch['algorithm'], 'MD5');
      expect(ch.containsKey('encrypt_type'), isTrue);
      final (sBad, _, _) = await c.handshake('WRONG');
      expect(sBad, 401);
      expect(m.authFailures, 1);
      final (sOk, hOk, _) = await c.handshake('cloudpass');
      expect(sOk, 200);
      expect(parseKv(hOk['key-exchange']!)['nonce'], isNotEmpty);
      expect(m.authFailures, 1);
      expect(m.activeSessions, 1);
    });

    test('SHA-256 algorithm and MD5U secret (no encrypt_type)', () async {
      final m = await startMedia(MockMedia8800(digestAlgorithm: 'SHA-256', encryptType3: false));
      final c = await conn(m);
      addTearDown(c.close);
      final (s, _, _) = await c.handshake('cloudpass');
      expect(s, 200);
    });

    test('LAT camera: digest secret is SHA256U(LAT)', () async {
      final cam = MockCamera(
          protocol: CameraProtocol.tpap,
          tpapCredential: TpapCredential.lat,
          localToken: 'local-access-token');
      final m = await startMedia(MockMedia8800.forCamera(cam));
      final bad = await conn(m);
      addTearDown(bad.close);
      expect((await bad.handshake('cloudpass')).$1, 401);
      final c = await conn(m);
      addTearDown(c.close);
      expect((await c.handshake('local-access-token')).$1, 200);
    });

    test('third session -> 503 -52407; closing one frees a slot', () async {
      final m = await startMedia(MockMedia8800());
      final a = await conn(m);
      final b = await conn(m);
      expect((await a.handshake('cloudpass')).$1, 200);
      expect((await b.handshake('cloudpass')).$1, 200);
      final c = await conn(m);
      final (s, _, body) = await c.handshake('cloudpass');
      expect(s, 503);
      expect(utf8.decode(body), '{"error_code":-52407}');
      expect(m.limitRejections, 1);
      await c.close();
      await a.close();
      expect(await waitFor(() => m.activeSessions == 1), isTrue);
      final d = await conn(m);
      expect((await d.handshake('cloudpass')).$1, 200);
      await d.close();
      await b.close();
    });
  });

  group('live preview', () {
    test('MD5 keys: encrypted TS parts, session_id in params, acks, stop', () async {
      final m = await startMedia(MockMedia8800());
      final c = await conn(m);
      addTearDown(c.close);
      final (s, hs, _) = await c.handshake('cloudpass');
      expect(s, 200);
      c.sendRequest(previewVga, 1);
      final resp = (await c.readPart())!;
      final j = resp.json!;
      expect(j['type'], 'response');
      expect(j['seq'], 1);
      expect(j['result']['error_code'], 0);
      c.sessionId = j['params']['session_id'] as String;
      expect(c.sessionId, isNotEmpty);
      var got = 0;
      var lastSeq = 0;
      while (got < 30) {
        final p = (await c.readPart())!;
        if (p.contentType != 'video/mp2t') continue;
        expect(p.headers['x-session-id'], c.sessionId);
        expect(p.headers['x-if-encrypt'], '1');
        lastSeq = int.parse(p.headers['x-data-sequence']!);
        expectTs(decryptPart(p, hs, 'cloudpass', true)!);
        got++;
        if (lastSeq % 25 == 0) c.sock.add(ackPart(lastSeq, c.sessionId!));
      }
      expect(await waitFor(() => m.acks.contains(25)), isTrue);
      expect(m.previewRequests, 1);
      c.sendRequest({'method': 'do', 'stop': 'null'}, 2);
      DevicePart? stopResp;
      while ((stopResp = await c.readPart()) != null) {
        if (stopResp!.json?['seq'] == 2) break;
      }
      expect(stopResp!.json!['result']['error_code'], 0);
      expect(m.stopRequests, 1);
      final sent = m.partsSent;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(m.partsSent - sent, lessThanOrEqualTo(2));
    });

    test('plaintext parts without X-Key-Exchange; session id in result / header modes', () async {
      for (final mode in SessionIdIn.values) {
        final m = await startMedia(MockMedia8800(sessionIdIn: mode));
        final c = await conn(m);
        addTearDown(c.close);
        final (s, hs, _) = await c.handshake('cloudpass', keyExchange: false);
        expect(s, 200);
        expect(hs.containsKey('key-exchange'), isFalse);
        c.sendRequest(previewVga, 1);
        final resp = (await c.readPart())!;
        final j = resp.json!;
        switch (mode) {
          case SessionIdIn.params:
            expect(j['params']['session_id'], isNotEmpty);
          case SessionIdIn.result:
            expect(j['result']['session_id'], isNotEmpty);
          case SessionIdIn.header:
            expect(resp.headers['x-session-id'], isNotEmpty);
        }
        var p = (await c.readPart())!;
        while (p.contentType != 'video/mp2t') {
          p = (await c.readPart())!;
        }
        expect(p.headers['x-if-encrypt'], '0');
        expectTs(p.body);
        await c.close();
      }
    });

    test('HKDF keys: X-Nonce / X-Data-Hmac verify; corruptHmacEvery breaks every Nth', () async {
      final m = await startMedia(MockMedia8800(kex: MediaKex.hkdf, corruptHmacEvery: 3));
      final c = await conn(m);
      addTearDown(c.close);
      final (s, hs, _) = await c.handshake('cloudpass');
      expect(s, 200);
      final kx = parseKv(hs['key-exchange']!);
      expect(kx['algorithm'], 'HKDF');
      expect(kx['salt'], isNotEmpty);
      c.sendRequest(previewVga, 1);
      await c.readPart();
      var good = 0, bad = 0;
      while (good + bad < 9) {
        final p = (await c.readPart())!;
        if (p.contentType != 'video/mp2t') continue;
        final plain = decryptPart(p, hs, 'cloudpass', true);
        if (plain == null) {
          bad++;
        } else {
          expectTs(plain);
          good++;
        }
      }
      expect(bad, 3);
      expect(good, 6);
    });

    test('ack window: no acks -> connection_closed notification then close', () async {
      final m = await startMedia(MockMedia8800(
          ackWindow: 3, ackTimeout: const Duration(milliseconds: 300)));
      final c = await conn(m);
      addTearDown(c.close);
      await c.handshake('cloudpass');
      c.sendRequest(previewVga, 1);
      var videoParts = 0;
      Map<String, dynamic>? closed;
      DevicePart? p;
      while ((p = await c.readPart()) != null) {
        if (p!.contentType == 'video/mp2t') videoParts++;
        final j = p.json;
        if (j?['type'] == 'notification') {
          closed = j;
          break;
        }
      }
      expect(videoParts, 3);
      expect(closed!['params']['event_type'], 'connection_closed');
      expect(closed['params']['close_reason'], 'data timeout');
    });

    test('invalid preview request -> -52402; dropConnections resets the socket', () async {
      final m = await startMedia(MockMedia8800());
      final c = await conn(m);
      addTearDown(c.close);
      await c.handshake('cloudpass');
      c.sendRequest({'method': 'get', 'preview': {'channels': [0], 'resolutions': ['4K']}}, 1);
      expect((await c.readPart())!.json!['result']['error_code'], -52402);
      m.dropConnections();
      expect(await c.readPart(), isNull);
    });
  });

  group('playback', () {
    test('get playback streams the whole clip then stream_status finished', () async {
      final cam = MockCamera();
      final m = await startMedia(MockMedia8800.forCamera(cam));
      final c = await conn(m);
      addTearDown(c.close);
      final (_, hs, _) = await c.handshake('cloudpass');
      final clip = cam.state.recordings[1];
      c.sendRequest({
        'method': 'get',
        'playback': {
          'client_id': 1,
          'channels': [0],
          'scale': '1/1',
          'start_time': '${clip.startEpoch}',
          'end_time': '${clip.startEpoch + 86399}',
          'event_type': [1, 2]
        }
      }, 1);
      final r = (await c.readPart())!.json!;
      expect(r['result']['error_code'], 0);
      expect(r['result']['speed'], '1/1');
      final out = BytesBuilder();
      Map<String, dynamic>? fin;
      DevicePart? p;
      while ((p = await c.readPart()) != null) {
        if (p!.contentType == 'video/mp2t') {
          out.add(decryptPart(p, hs, 'cloudpass', true)!);
        } else {
          fin = p.json;
          break;
        }
      }
      expect(out.toBytes(), loadSampleTs());
      expect(fin!['params']['status'], 'finished');
      expect(m.playbackRequests, 1);
    });

    test('start before any recording -> -52402; numeric start_time is refused', () async {
      final m = await startMedia(MockMedia8800());
      final c = await conn(m);
      addTearDown(c.close);
      await c.handshake('cloudpass');
      c.sendRequest({'method': 'get', 'playback': {'start_time': '5', 'end_time': '6'}}, 1);
      expect((await c.readPart())!.json!['result']['error_code'], -52402);
      c.sendRequest({'method': 'get', 'playback': {'start_time': 1700000000}}, 2);
      expect((await c.readPart())!.json!['result']['error_code'], -52402);
    });
  });

  test('shadow recordings are shared with the camera', () {
    final cam = MockCamera(recordings: [Recording(DateTime.utc(2025), DateTime.utc(2025, 1, 1, 0, 1), 2)]);
    final m = MockMedia8800.forCamera(cam);
    expect(m.recordings, same(cam.state.recordings));
  });
}
