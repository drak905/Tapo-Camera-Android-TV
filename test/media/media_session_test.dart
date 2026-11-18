// mb.local.session_connect: :8800 handshake against a scripted camera.
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/media/local8800/media_session.dart';
import 'package:tapo_tv/media/media_errors.dart';
import 'package:tapo_tv/media/part_decryptor.dart';

import 'helpers/crypto_fixtures.dart';
import 'helpers/fakes.dart';

String _md5(String s) => md5.convert(s.codeUnits).toString();

void main() {
  late List<FakeCamera> cameras;
  late FakeConnector connector;

  FakeConnector make({bool requireAuth = true, String? keyExchange, bool always401 = false}) {
    cameras = [];
    return connector = FakeConnector(onConnect: (t, i) {
      cameras.add(FakeCamera(t,
          requireAuth: requireAuth, keyExchange: keyExchange, http401Always: always401, sessionId: null));
    });
  }

  test('401 then 200 against a fake socket', () async {
    make(keyExchange: kMd5KeyExchangeAdmin);
    final s = await MediaSession.connect(
      host: kCameraHost,
      auth: FakeLocalAuth(),
      connector: connector.connect,
      cnonce: () => 'a1b2c3d4e5f6g7h8',
    );
    expect(connector.calls, hasLength(1));
    expect(connector.calls.single.host, kCameraHost);
    expect(connector.calls.single.port, 8800);
    expect(connector.calls.single.tls, isFalse);
    final heads = cameras.single.heads;
    expect(heads, hasLength(2));
    expect(
      heads[0],
      'POST /stream HTTP/1.1\r\n'
      'Host: $kCameraHost:8800\r\n'
      'Content-Type: multipart/mixed; boundary=--client-stream-boundary--\r\n'
      'Connection: keep-alive\r\n'
      'Content-Length: 0\r\n'
      'X-Key-Exchange: 1',
    );
    final ha1 = _md5('admin:TP-LINK IP-CAM:0318564DA313CFBFF096FE8CE56FA912');
    final response = _md5('$ha1:8c5d1f22:00000001:a1b2c3d4e5f6g7h8:auth:${_md5('POST:/stream')}');
    expect(
      heads[1],
      '${heads[0]}\r\nAuthorization: Digest username="admin",realm="TP-LINK IP-CAM",uri="/stream",algorithm=MD5,'
      'nonce="8c5d1f22",nc=00000001,cnonce="a1b2c3d4e5f6g7h8",qop=auth,response="$response",opaque="6494321"',
    );
    expect(s.keyExchange?.nonce, kMd5NonceAdmin);
    expect(s.decryptor, isA<Md5PartDecryptor>());
    await s.close();
  });

  test('hkdf key exchange selects the hkdf decryptor', () async {
    make(keyExchange: kHkdfKeyExchange);
    final s = await MediaSession.connect(
      host: kCameraHost,
      auth: FakeLocalAuth(digestSecret: kHkdfLat),
      connector: connector.connect,
    );
    expect(s.decryptor, isA<HkdfPartDecryptor>());
    await s.close();
  });

  test('second 401 throws auth error without a third attempt', () async {
    make(always401: true);
    await expectLater(
      MediaSession.connect(host: kCameraHost, auth: FakeLocalAuth(), connector: connector.connect),
      throwsA(isA<MediaAuthException>()),
    );
    expect(cameras.single.heads, hasLength(2), reason: 'one unauthenticated and one authorized try only');
    expect(connector.calls, hasLength(1), reason: 'no third attempt on a new socket either');
  });

  test('connection: close on the 401 reopens the socket before the retry', () async {
    cameras = [];
    connector = FakeConnector(onConnect: (t, i) {
      t.onWrite = (data) {
        final head = String.fromCharCodes(data);
        if (!head.contains('Authorization:')) {
          t.push(bytesOf('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n'
              'WWW-Authenticate: Digest realm="TP-LINK IP-CAM", qop="auth", nonce="n1", opaque="o", algorithm=MD5\r\n'
              'Content-Length: 0\r\n\r\n'));
        } else {
          t.push(bytesOf('HTTP/1.1 200 OK\r\n\r\n'));
        }
      };
    });
    final s = await MediaSession.connect(host: kCameraHost, auth: FakeLocalAuth(), connector: connector.connect);
    expect(connector.calls, hasLength(2));
    expect(connector.transports[0].closed, isTrue);
    await s.close();
  });

  test('http 503 is a fatal stream limit', () async {
    connector = FakeConnector(onConnect: (t, i) {
      t.onWrite = (_) => t.push(bytesOf('HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n'));
    });
    await expectLater(
      MediaSession.connect(host: kCameraHost, auth: FakeLocalAuth(), connector: connector.connect),
      throwsA(isA<StreamLimitException>()),
    );
    expect(connector.calls, hasLength(1));
  });

  test('session id is learned from params.session_id and X-Session-Id', () async {
    make(keyExchange: kMd5KeyExchangeAdmin);
    final s = await MediaSession.connect(host: kCameraHost, auth: FakeLocalAuth(), connector: connector.connect);
    expect(s.sessionId, isNull);
    final collected = Collector(s.parts);
    cameras.single.t.push(jsonPart({
      'type': 'response',
      'seq': 1,
      'params': {'session_id': '12'},
      'result': {'error_code': 0},
    }));
    await settle();
    expect(s.sessionId, '12');
    await collected.sub.cancel();
    await s.close();
  });
}
