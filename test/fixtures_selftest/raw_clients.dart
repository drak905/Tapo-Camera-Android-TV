// Raw wire clients used ONLY to drive the fixtures in the self-tests (port of
// tests/fixtures/raw_clients.py). They speak bytes / JSON with no app code, so a
// fixture bug cannot hide behind a matching client bug.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../fixtures/fx_crypto.dart';
import '../fixtures/fx_io.dart';
import '../fixtures/tpap_server.dart';

// ---------------------------------------------------------------- HTTPS control
class RawHttps {
  RawHttps(this.host, this.port) {
    _client = HttpClient()
      ..badCertificateCallback = (cert, h, p) {
        peerDer = cert.der;
        return true;
      };
  }
  final String host;
  final int port;
  late final HttpClient _client;
  Uint8List? peerDer;

  Future<(int, Uint8List, HttpHeaders)> postRaw(String path, List<int> body,
      {Map<String, String> headers = const {},
      String contentType = 'application/json'}) async {
    final req = await _client.postUrl(Uri.parse('https://$host:$port$path'));
    req.headers.set('content-type', contentType);
    headers.forEach(req.headers.set);
    req.contentLength = body.length;
    req.add(body);
    final res = await req.close();
    final b = BytesBuilder();
    await for (final d in res) {
      b.add(d);
    }
    return (res.statusCode, b.toBytes(), res.headers);
  }

  Future<(int, Map<String, dynamic>?)> post(String path, String body,
      {Map<String, String> headers = const {}}) async {
    final (status, bytes, _) = await postRaw(path, utf8.encode(body), headers: headers);
    try {
      return (status, jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
    } catch (_) {
      return (status, null);
    }
  }

  void close() => _client.close(force: true);
}

String rawNewCnonce() => randomHex(8, upper: true);

/// v3 client (encrypt_type "3").
class SecureClient extends RawHttps {
  SecureClient(super.host, super.port, this.password, {String? cnonce})
      : cnonce = cnonce ?? rawNewCnonce();
  final String password;
  final String cnonce;
  String stok = '';
  int seq = 0;
  String nonce = '';
  Uint8List lsk = Uint8List(0);
  Uint8List ivb = Uint8List(0);

  Future<Map<String, dynamic>> step1() async => (await post(
          '/',
          compactJson({
            'method': 'login',
            'params': {'cnonce': cnonce, 'encrypt_type': '3', 'username': 'admin'}
          })))
      .$2!;

  Future<Map<String, dynamic>> step2(String nonce, [String? pw]) async {
    final dp = digestPasswd(pw ?? password, cnonce, nonce);
    return (await post(
            '/',
            compactJson({
              'method': 'login',
              'params': {
                'cnonce': cnonce,
                'encrypt_type': '3',
                'username': 'admin',
                'digest_passwd': dp
              }
            })))
        .$2!;
  }

  Future<Map<String, dynamic>> login() async {
    final r1 = await step1();
    if (r1['error_code'] != -40413) throw StateError('step1: $r1');
    nonce = r1['result']['data']['nonce'] as String;
    final r2 = await step2(nonce);
    if (r2['error_code'] != 0) throw StateError('step2: $r2');
    stok = r2['result']['stok'] as String;
    seq = (r2['result']['start_seq'] as num).toInt();
    final k = sessionKeys(password, cnonce, nonce);
    lsk = k.lsk;
    ivb = k.ivb;
    return r2;
  }

  String outerBody(Map inner) => compactJson({
        'method': 'securePassthrough',
        'params': {'request': b64Encrypt(lsk, ivb, compactJson(inner))}
      });

  String tag(String body, int s) => tapoTag(password, cnonce, body, s);

  /// Decrypted inner reply, or the outer reply (plus _status) when it is an error.
  Future<Map<String, dynamic>> send(Map inner, {int? seqOverride, String? tagOverride, String? body}) async {
    final use = seqOverride ?? seq;
    if (seqOverride == null) seq++;
    final b = body ?? outerBody(inner);
    final (status, r) = await post('/stok=$stok/ds', b,
        headers: {'seq': '$use', 'tapo_tag': tagOverride ?? tag(b, use)});
    if (status != 200 || r == null || r['error_code'] != 0) {
      return {'_status': status, ...?r};
    }
    return jsonDecode(b64Decrypt(lsk, ivb, r['result']['response'] as String))
        as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> multi(List<Map> reqs) async {
    final r = await send({
      'method': 'multipleRequest',
      'params': {'requests': reqs}
    });
    if (r['error_code'] != 0) throw StateError('multi: $r');
    return (r['result']['responses'] as List).cast<Map<String, dynamic>>();
  }
}

class LegacyClient extends RawHttps {
  LegacyClient(super.host, super.port, this.password);
  final String password;
  String stok = '';

  Future<Map<String, dynamic>> login([String? pw]) async {
    final r = (await post(
            '/',
            compactJson({
              'method': 'login',
              'params': {
                'hashed': true,
                'password': md5Upper(pw ?? password),
                'username': 'admin'
              }
            })))
        .$2!;
    if (r['error_code'] == 0) stok = r['result']['stok'] as String;
    return r;
  }

  Future<Map<String, dynamic>> send(Map inner) async =>
      (await post('/stok=$stok/ds', compactJson(inner))).$2!;
}

// ---------------------------------------------------------------- SPAKE2+ prover (RFC 9383)
class ProverResult {
  ProverResult(this.shareP, this.z, this.v, this.kMain, this.kConfirmP,
      this.kConfirmV, this.confirmP, this.confirmV, this.kShared);
  final Uint8List shareP, z, v, kMain, kConfirmP, kConfirmV, confirmP, confirmV, kShared;
}

Uint8List _lp(List<List<int>> parts) {
  final b = BytesBuilder();
  for (final p in parts) {
    final l = ByteData(8)..setUint64(0, p.length, Endian.little);
    b.add(l.buffer.asUint8List());
    b.add(p);
  }
  return b.toBytes();
}

ProverResult spakeProve({
  required BigInt w0,
  required BigInt w1,
  required BigInt x,
  required Uint8List shareV,
  required List<int> context,
  List<int> idProver = const [],
  List<int> idVerifier = const [],
}) {
  final shareP = p256Encode(p256Add(p256Mul(p256G, x), p256Mul(spakeM, w0)));
  final y = p256Decode(shareV);
  final h = p256Add(y, -p256Mul(spakeN, w0));
  final z = p256Encode(p256Mul(h, x));
  final v = p256Encode(p256Mul(h, w1));
  final tt = _lp([
    context, idProver, idVerifier,
    p256Encode(spakeM), p256Encode(spakeN), shareP, shareV, z, v,
    bigToBytes(w0, 32),
  ]);
  final kMain = sha256Raw(tt);
  final conf = hkdfSha256(kMain, null, utf8.encode('ConfirmationKeys'), 64);
  final kp = conf.sublist(0, 32);
  final kv = conf.sublist(32);
  return ProverResult(
    shareP, z, v, kMain, kp, kv,
    hmacSha256(kp, shareV),
    hmacSha256(kv, shareP),
    hkdfSha256(kMain, null, utf8.encode('SharedKey'), 32),
  );
}

BigInt bigFromHex(String h) => BigInt.parse(h, radix: 16);

/// TPAP client: register + share + CCM /ds.
class TpapClient extends RawHttps {
  TpapClient(super.host, super.port);
  String stok = '';
  int seq = 0;
  Uint8List key = Uint8List(0);
  Uint8List nonceBase = Uint8List(0);
  Map<String, dynamic>? lastRegister;

  Future<Map<String, dynamic>> v3Probe() async => (await post(
          '/',
          compactJson({
            'method': 'login',
            'params': {'cnonce': rawNewCnonce(), 'encrypt_type': '3', 'username': 'admin'}
          })))
      .$2!;

  Future<Map<String, dynamic>> register({String? username}) async {
    final userRandom = randomBytes(32);
    _userRandom = userRandom;
    final r = (await post(
            '/',
            compactJson({
              'method': 'login',
              'params': {
                'sub_method': 'pake_register',
                'username': username ?? md5Hex('admin'),
                'user_random': b64e(userRandom),
                'cipher_suites': [1],
                'encryption': ['aes_128_ccm'],
                'passcode_type': 'userpw',
              }
            })))
        .$2!;
    lastRegister = r;
    return r;
  }

  Uint8List _userRandom = Uint8List(0);

  /// Full login with [passcode]; returns the pake_share reply.
  Future<Map<String, dynamic>> login(String passcode, {String? username}) async {
    final reg = await register(username: username);
    if (reg['error_code'] != 0) return reg;
    final res = reg['result'] as Map<String, dynamic>;
    final salt = b64d(res['dev_salt'] as String);
    final devRandom = b64d(res['dev_random'] as String);
    final shareV = b64d(res['dev_share'] as String);
    final w = tpapW0W1(passcode, salt, (res['iterations'] as num).toInt());
    final x = bigFromHex(randomHex(40)) % (p256Order - BigInt.one) + BigInt.one;
    final context =
        sha256Raw([...utf8.encode('PAKE V1'), ..._userRandom, ...devRandom]);
    final pr = spakeProve(
        w0: w.w0, w1: w.w1, x: x, shareV: shareV, context: context);
    final r = (await post(
            '/',
            compactJson({
              'method': 'login',
              'params': {
                'sub_method': 'pake_share',
                'user_share': b64e(pr.shareP),
                'user_confirm': b64e(pr.confirmP),
              }
            })))
        .$2!;
    if (r['error_code'] == 0) {
      final rr = r['result'] as Map<String, dynamic>;
      if (!constTimeEq(b64d(rr['dev_confirm'] as String), pr.confirmV)) {
        throw StateError('dev_confirm mismatch');
      }
      stok = rr['stok'] as String;
      seq = (rr['start_seq'] as num).toInt();
      key = hkdfSha256(pr.kShared, utf8.encode('tp-kdf-salt-aes128-key'),
              utf8.encode('tp-kdf-info-aes128-key'), 32)
          .sublist(0, 16);
      nonceBase = hkdfSha256(pr.kShared, utf8.encode('tp-kdf-salt-aes128-iv'),
              utf8.encode('tp-kdf-info-aes128-iv'), 32)
          .sublist(0, 12);
    }
    return r;
  }

  Uint8List _nonce(int s) {
    final n = Uint8List(12)..setRange(0, 8, nonceBase);
    ByteData.sublistView(n).setUint32(8, s, Endian.big);
    return n;
  }

  /// Sends one inner request; returns the decrypted reply or the plaintext refusal.
  Future<Map<String, dynamic>> send(Map inner, {int? seqOverride}) async {
    final use = seqOverride ?? seq;
    if (seqOverride == null) seq++;
    final head = ByteData(4)..setUint32(0, use, Endian.big);
    final body = concatBytes(
        [head.buffer.asUint8List(), ccmSeal(key, _nonce(use), utf8.encode(compactJson(inner)))]);
    final (_, bytes, headers) = await postRaw('/stok=$stok/ds', body,
        contentType: 'application/octet-stream');
    if (headers.contentType?.mimeType == 'application/json') {
      return {'_plain': true, ...jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>};
    }
    final rs = ByteData.sublistView(bytes).getUint32(0, Endian.big);
    final plain = ccmOpen(key, _nonce(rs), bytes.sublist(4));
    if (plain == null) throw StateError('CCM tag mismatch in reply');
    return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
  }
}

Map<String, dynamic> getDeviceInfoReq() => {
      'method': 'getDeviceInfo',
      'params': {
        'device_info': {
          'name': ['basic_info']
        }
      }
    };

// ---------------------------------------------------------------- multipart + digest helpers
/// A client multipart part (spec mb.local.multipart_framing): delimiter, extra
/// headers in order, Content-Type, Content-Length, blank line, body, CRLF.
Uint8List clientPart(List<int> body,
    {String contentType = 'application/json', List<(String, String)> headers = const []}) {
  final head = StringBuffer('----client-stream-boundary--\r\n');
  for (final (k, v) in headers) {
    head.write('$k: $v\r\n');
  }
  head.write('Content-Type: $contentType\r\nContent-Length: ${body.length}\r\n\r\n');
  return concatBytes([latin1.encode(head.toString()), body, [13, 10]]);
}

Uint8List jsonPart(Map msg, {List<(String, String)> headers = const []}) =>
    clientPart(utf8.encode(compactJson(msg)), headers: headers);

Uint8List ackPart(int received, String sessionId) => clientPart(
    utf8.encode('{"type":"notification","params":{"event_type":"stream_sequence"}}'),
    headers: [('X-Data-Received', '$received'), ('X-Session-Id', sessionId)]);

/// RFC 7616 / 2617 digest response (qop=auth).
String digestResponse(String alg, String user, String realm, String password,
    String method, String uri, String nonce, String nc, String cnonce, String qop) {
  String h(String s) => alg.toUpperCase().startsWith('SHA-256')
      ? sha256Hex(s)
      : md5Hex(s);
  final ha1 = h('$user:$realm:$password');
  final ha2 = h('$method:$uri');
  return h('$ha1:$nonce:$nc:$cnonce:$qop:$ha2');
}

Map<String, String> parseKv(String s) {
  final out = <String, String>{};
  for (final m in RegExp(r'([A-Za-z_][\w-]*)\s*=\s*(?:"([^"]*)"|([^,\s]*))').allMatches(s)) {
    out[m.group(1)!.toLowerCase()] = m.group(2) ?? m.group(3) ?? '';
  }
  return out;
}

class DevicePart {
  DevicePart(this.headers, this.body);
  final Map<String, String> headers; // lower-case names
  final Uint8List body;
  String get contentType => headers['content-type'] ?? '';
  Map<String, dynamic>? get json {
    try {
      return jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}

/// Reads device multipart parts (delimiter "----device-stream-boundary--").
Future<DevicePart?> readDevicePart(ByteReader r) async {
  while (true) {
    final ln = await r.readLine();
    if (ln == null) return null;
    if (ln.trim() == '----device-stream-boundary--') break;
  }
  final h = await r.readHeaders();
  if (h == null) return null;
  final n = int.parse(h['content-length'] ?? '0');
  final body = await r.readExact(n);
  if (body == null) return null;
  return DevicePart(h, body);
}

/// Raw TCP client of :8800.
class MediaRaw {
  MediaRaw._(this.sock) : reader = ByteReader(sock);
  final Socket sock;
  final ByteReader reader;
  String? sessionId;

  static Future<MediaRaw> connect(String host, int port, {bool tls = false}) async {
    final Socket s = tls
        ? await SecureSocket.connect(host, port, onBadCertificate: (_) => true)
        : await Socket.connect(host, port);
    s.setOption(SocketOption.tcpNoDelay, true);
    return MediaRaw._(s);
  }

  /// Sends POST /stream; returns (status, lower-case headers, body).
  Future<(int, Map<String, String>, Uint8List)> post({String? authorization, bool keyExchange = true}) async {
    final b = StringBuffer('POST /stream HTTP/1.1\r\nHost: 127.0.0.1\r\n'
        'Content-Type: multipart/mixed; boundary=--client-stream-boundary--\r\n'
        'Connection: keep-alive\r\nContent-Length: 0\r\n');
    if (keyExchange) b.write('X-Key-Exchange: 1\r\n');
    if (authorization != null) b.write('Authorization: $authorization\r\n');
    b.write('\r\n');
    sock.add(latin1.encode(b.toString()));
    final status = await reader.readLine();
    if (status == null) throw StateError('closed');
    final h = (await reader.readHeaders())!;
    final n = int.tryParse(h['content-length'] ?? '0') ?? 0;
    final body = n > 0 ? (await reader.readExact(n))! : Uint8List(0);
    return (int.parse(status.split(' ')[1]), h, body);
  }

  /// Full handshake. Returns the final (status, headers, body).
  Future<(int, Map<String, String>, Uint8List)> handshake(String secret,
      {bool keyExchange = true, String? overrideSecret}) async {
    final first = await post(keyExchange: keyExchange);
    if (first.$1 != 401) return first;
    final ch = parseKv(first.$2['www-authenticate']!.substring(7));
    final enc3 = ch.containsKey('encrypt_type');
    final pwd = overrideSecret ?? (enc3 ? sha256Upper(secret) : md5Upper(secret));
    const cnonce = 'a1b2c3d4e5f6g7h8';
    final alg = ch['algorithm'] ?? 'MD5';
    final resp = digestResponse(alg, 'admin', ch['realm']!, pwd, 'POST', '/stream',
        ch['nonce']!, '00000001', cnonce, 'auth');
    final auth = 'Digest username="admin",realm="${ch['realm']}",uri="/stream",algorithm=$alg,'
        'nonce="${ch['nonce']}",nc=00000001,cnonce="$cnonce",qop=auth,response="$resp",opaque="${ch['opaque']}"';
    return post(authorization: auth, keyExchange: keyExchange);
  }

  void sendRequest(Map<String, dynamic> params, int seq) {
    sock.add(jsonPart({'type': 'request', 'params': params, 'seq': seq},
        headers: [if (sessionId != null) ('X-Session-Id', sessionId!)]));
  }

  Future<DevicePart?> readPart() => readDevicePart(reader);

  Future<void> close() async {
    try {
      await sock.close();
    } catch (_) {}
    sock.destroy();
  }
}

// ---------------------------------------------------------------- cloud / relay helpers
const String testAccessKey = '4d11b6b9d5ea4d19a829adbb9714b057';
const String testSecretKey = '6ed7d97f3e73467f8a5bab90b577ba4c';

/// Content-MD5 + X-Authorization (spec hc.cloud.signing). [body] "" is hashed as "{}".
Map<String, String> cloudSignedHeaders(String path, String body, {String? nonce}) {
  final n = nonce ?? '2f1a6c3e-8b7d-4e21-9a55-0c4d3b2a1f00';
  final md5b64 = base64.encode(md5Raw(body.isEmpty ? '{}' : body));
  final msg = '$md5b64\n9999999999\n$n\n$path';
  final sig = toHex(Hmac(sha1, utf8.encode(testSecretKey)).convert(utf8.encode(msg)).bytes);
  return {
    'Content-MD5': md5b64,
    'X-Authorization':
        'Timestamp=9999999999, Nonce=$n, AccessKey=$testAccessKey, Signature=$sig',
  };
}

/// One plain HTTP request (the cloud mock). Returns (status, json-or-null).
Future<(int, Map<String, dynamic>?)> rawHttp(String method, String url,
    {Map<String, String> headers = const {}, String? body}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, Uri.parse(url));
    headers.forEach(req.headers.set);
    if (body != null) {
      final b = utf8.encode(body);
      req.contentLength = b.length;
      req.add(b);
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    try {
      return (res.statusCode, jsonDecode(text) as Map<String, dynamic>);
    } catch (_) {
      return (res.statusCode, null);
    }
  } finally {
    client.close(force: true);
  }
}

/// Signed POST to the account API. [url] must include query + the path used for signing.
Future<(int, Map<String, dynamic>?)> cloudPost(String base, String path, Map<String, dynamic> body,
    {Map<String, String> query = const {}, String? token}) async {
  final q = {'appName': 'TP-Link_Tapo_Android', 'termID': 'term-0001', ...query, 'token': ?token};
  final qs = q.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&');
  final text = compactJson(body);
  return rawHttp('POST', '$base$path?$qs',
      headers: {'Content-Type': 'application/json', ...cloudSignedHeaders(path, text)}, body: text);
}

Map<String, String> iotHeaders(String token) => {
      'Authorization': 'ut|$token',
      'app-cid': 'app:TP-Link_Tapo_Android:term-0001',
      'x-app-name': 'TP-Link_Tapo_Android',
      'x-app-version': '3.22.806',
      'x-term-id': 'term-0001',
      'x-strict': '0',
    };

/// Raw TLS tunnel client of the relay.
class RelayRaw {
  RelayRaw._(this.sock) : reader = ByteReader(sock);
  final Socket sock;
  final ByteReader reader;
  String? sessionId;

  static Future<RelayRaw> connect(int port, SecurityContext ctx, {String host = 'localhost'}) async {
    final raw = await Socket.connect('127.0.0.1', port);
    raw.setOption(SocketOption.tcpNoDelay, true);
    final tls = await SecureSocket.secure(raw, host: host, context: ctx);
    return RelayRaw._(tls);
  }

  /// The tunnel request lines in the spec's exact order (mb.relay.tunnel_headers).
  static List<String> tunnelRequestLines({
    required String path,
    required String token,
    required String trackId,
    String relayHost = 'localhost',
    String model = 'Windows',
    String uuid = 'terminal-uuid-0001',
    int redirectTimes = 0,
    int latencyMs = 42,
    String? cookie,
    bool withVersion = true,
    bool swapAcceptAndKeepRelay = false,
  }) {
    final sep = path.contains('?') ? '&' : '?';
    final lines = [
      'POST $path${sep}retryTime=0 HTTP/1.1',
      'User-Agent: Client=TP-Link_Tapo_Android Android 3.22.806/1.3',
      'Keep-Relay: 3600',
      'Accept: */*',
      'Content-Type: multipart/mixed;boundary=--client-stream-boundary--',
      'Host: $relayHost',
      'Content-Length: 9223372036854775807',
      'X-token: $token',
      'X-Client-Model: $model',
      'X-Client-UUID: $uuid',
      'X-Track-Id: $trackId',
      'X-Redirect-Times: $redirectTimes',
      'X-Pull-Mode: 2',
      if (cookie != null) 'Cookie: $cookie',
      if (withVersion) 'X-Version: 2.0',
      'X-Arrive-Latency: $latencyMs',
    ];
    if (swapAcceptAndKeepRelay) {
      final t = lines[2];
      lines[2] = lines[3];
      lines[3] = t;
    }
    return lines;
  }

  void sendHead(List<String> lines) => sock.add(latin1.encode('${lines.join('\r\n')}\r\n\r\n'));

  /// Reads the HTTP answer head (+ JSON body when Content-Length is present).
  Future<(String, Map<String, String>, Map<String, dynamic>?)> readHead() async {
    final status = (await reader.readLine())!;
    final h = (await reader.readHeaders())!;
    Map<String, dynamic>? body;
    final n = int.tryParse(h['content-length'] ?? '');
    if (n != null && n > 0) {
      body = jsonDecode(utf8.decode((await reader.readExact(n))!)) as Map<String, dynamic>;
    }
    return (status, h, body);
  }

  void sendRequest(Map<String, dynamic> params, int seq) {
    sock.add(jsonPart({'type': 'request', 'params': params, 'seq': seq},
        headers: [if (sessionId != null) ('X-Session-Id', sessionId!)]));
  }

  Future<DevicePart?> readPart() => readDevicePart(reader);

  Future<void> close() async {
    sock.destroy();
  }
}
