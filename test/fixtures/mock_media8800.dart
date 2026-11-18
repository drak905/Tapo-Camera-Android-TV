// Wire-level mock of the camera's :8800 media server (POST /stream), server
// side, on loopback. Port of tests/fixtures/mock_tapo_server/media_server.py.
//
// Handshake: first POST (no Authorization) -> 401 + WWW-Authenticate: Digest
// realm, qop="auth", nonce, opaque, algorithm=MD5|SHA-256[, encrypt_type=3].
// Second POST with Authorization: Digest (user "admin", password' =
// SHA256U(secret) when encrypt_type 3 else MD5U(secret)) -> 200 plus, when the
// client sent X-Key-Exchange: 1, a Key-Exchange header (MD5 fixed IV, or HKDF).
// Then multipart parts both ways:
//   device: "----device-stream-boundary--"   client: "----client-stream-boundary--"
// Control requests: get preview, get playback, get download, do stop.
// A third authenticated connection (maxSessions = 2) -> HTTP 503 {"error_code":-52407}.
// Flow control: the sender stalls while more than ackWindow parts are
// un-acknowledged; after ackTimeout without an ack it sends connection_closed
// and closes the socket.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import 'camera_state.dart';
import 'fx_crypto.dart';
import 'fx_io.dart';
import 'mock_camera.dart';
import 'tls_cert.dart';

const String mediaDeviceBoundary = '--device-stream-boundary--';
const String mediaClientBoundary = '--client-stream-boundary--';

enum MediaKex { md5, hkdf }

/// Where the camera puts session_id in the response part.
enum SessionIdIn { params, result, header }

/// The short MPEG-TS clip (H.264 640x360 15 fps + A-law 8 kHz, 3 s) committed
/// next to the fixtures. Falls back to a synthetic TS if the file is missing.
Uint8List loadSampleTs() {
  for (final p in const ['test/fixtures/media/sample.ts', 'fixtures/media/sample.ts']) {
    final f = File(p);
    if (f.existsSync()) return f.readAsBytesSync();
  }
  final out = BytesBuilder();
  for (var i = 0; i < 64; i++) {
    final pkt = Uint8List(188)..[0] = 0x47;
    pkt[1] = 0x01;
    pkt[2] = 0x00;
    pkt[3] = 0x10 | (i & 0x0F);
    out.add(pkt);
  }
  return out.toBytes();
}

class MediaRequest {
  MediaRequest(this.headers, this.body);
  final Map<String, String> headers;
  final Map<String, dynamic>? body;
}

class MockMedia8800 {
  MockMedia8800({
    this.secret = 'cloudpass',
    this.encryptType3 = true,
    this.digestAlgorithm = 'MD5',
    this.realm = 'TP-LINK IP-CAM',
    this.kex = MediaKex.md5,
    this.corruptHmacEvery = 0,
    this.ackWindow = 50,
    this.ackTimeout = const Duration(seconds: 5),
    this.chunkSize = 188 * 32,
    this.maxSessions = 2,
    this.previewInterval = const Duration(milliseconds: 5),
    this.sessionIdIn = SessionIdIn.params,
    this.host = '127.0.0.1',
    this.port = 0,
    this.useTls = false,
    List<Recording>? recordings,
    Uint8List? ts,
  })  : recordings = recordings ?? defaultRecordings(),
        // ignore: prefer_initializing_formals
        _ts = ts;

  /// A media server that shares secret, protocol and recordings with [cam]
  /// (LAT mode included: the digest uses the camera's [MockCamera.deviceSecret]).
  factory MockMedia8800.forCamera(MockCamera cam,
          {MediaKex kex = MediaKex.md5, String digestAlgorithm = 'MD5'}) =>
      MockMedia8800(
        secret: cam.deviceSecret,
        encryptType3: cam.secure,
        kex: kex,
        digestAlgorithm: digestAlgorithm,
        recordings: cam.state.recordings,
        host: cam.host,
      );

  /// Camera secret (cloud password or LAT). May change while running.
  String secret;

  /// true: challenge carries encrypt_type=3 and the digest password is SHA256U(secret); else MD5U.
  bool encryptType3;

  /// "MD5" or "SHA-256".
  String digestAlgorithm;
  String realm;

  /// MD5 (fixed IV) or HKDF (per-part IV, X-Nonce, X-Data-Hmac) Key-Exchange.
  MediaKex kex;

  /// HKDF: every Nth part gets a wrong X-Data-Hmac (0 = never).
  int corruptHmacEvery;
  int ackWindow;
  Duration ackTimeout;
  int chunkSize;
  int maxSessions;

  /// Pause between preview parts (the live stream loops the TS clip forever).
  Duration previewInterval;
  SessionIdIn sessionIdIn;
  final String host;
  int port;

  /// Serve the :8800 protocol inside TLS (self-signed, [certPem]). The real camera speaks plain TCP;
  /// this exists only for dev machines whose HTTP-inspecting security software (e.g. AdGuard)
  /// rejects the non-HTTP multipart traffic that follows the 200 answer with a 400 page.
  bool useTls;
  List<Recording> recordings;
  final Uint8List? _ts;

  // ---- counters / logs ------------------------------------------------------
  int challenges = 0;

  /// Digest handshakes with a wrong response / unknown nonce (assert "no retry loops").
  int authFailures = 0;
  int partsSent = 0;
  int previewRequests = 0;
  int playbackRequests = 0;
  int stopRequests = 0;
  int limitRejections = 0;
  final List<int> acks = [];
  final List<MediaRequest> requestLog = [];

  /// Authorization header values received, in order.
  final List<String> authorizationLog = [];
  int activeSessions = 0;

  ServerSocket? _server;
  SecureServerSocket? _tlsServer;
  TestCert? _cert;
  String get certPem => _cert?.certPem ?? '';
  final Set<_Session> _sessions = {};
  final Map<String, String> _nonces = {};
  int _sid = 0;

  Uint8List get ts => _ts ?? (_cached ??= loadSampleTs());
  static Uint8List? _cached;

  Future<MockMedia8800> start() async {
    final Stream<Socket> incoming;
    if (useTls) {
      _cert = generateTestCert(commonName: 'Mock :8800', sanIps: [host]);
      _tlsServer = await SecureServerSocket.bind(InternetAddress(host), port, _cert!.serverContext());
      port = _tlsServer!.port;
      incoming = _tlsServer!;
    } else {
      _server = await ServerSocket.bind(InternetAddress(host), port);
      port = _server!.port;
      incoming = _server!;
    }
    incoming.listen((s) {
      s.setOption(SocketOption.tcpNoDelay, true);
      // A client that resets mid-write must not surface as an uncaught
      // 'Write failed' error in the test zone (10053/10054 on Windows).
      s.done.ignore();
      final session = _Session(this, s);
      _sessions.add(session);
      session.run().whenComplete(() => _sessions.remove(session));
    }, onError: (Object _) {});
    return this;
  }

  Future<void> stop() async {
    await _server?.close();
    await _tlsServer?.close();
    _server = null;
    _tlsServer = null;
    dropConnections();
  }

  /// Resets (destroys) every open connection, like a camera-side network drop.
  void dropConnections() {
    for (final s in _sessions.toList()) {
      s.stopStream = true;
      s.sock.destroy();
    }
  }

  int nextSessionId() => ++_sid;
}

Map<String, String> parseAuthParams(String s) {
  final out = <String, String>{};
  final re = RegExp(r'([A-Za-z_][\w-]*)\s*=\s*(?:"([^"]*)"|([^,\s]*))');
  for (final m in re.allMatches(s)) {
    out[m.group(1)!.toLowerCase()] = m.group(2) ?? m.group(3) ?? '';
  }
  return out;
}

String _hash(String alg, String s) => alg.toUpperCase().startsWith('SHA-256')
    ? c.sha256.convert(utf8.encode(s)).toString()
    : c.md5.convert(utf8.encode(s)).toString();

class _Closed implements Exception {}

class _Session {
  _Session(this.srv, this.sock) : reader = ByteReader(sock);
  final MockMedia8800 srv;
  final Socket sock;
  final ByteReader reader;
  bool authenticated = false;
  bool encrypt = false;
  Uint8List key = Uint8List(0);
  Uint8List iv = Uint8List(0);
  ({Uint8List aesKey, Uint8List hmacKey})? hkdf;
  int hkdfParts = 0;
  String? sessionId;
  bool stopStream = false;
  int lastAck = 0;
  Future<void>? sender;

  void _write(List<int> data) {
    try {
      sock.add(data);
    } catch (_) {
      throw _Closed();
    }
  }

  void sendPart(Map<String, String> headers, List<int> body) {
    final head = StringBuffer('--$mediaDeviceBoundary\r\n');
    headers.forEach((k, v) => head.write('$k: $v\r\n'));
    head.write('Content-Length: ${body.length}\r\n\r\n');
    _write([...latin1.encode(head.toString()), ...body, 13, 10]);
  }

  void sendJson(Map<String, dynamic> obj, {bool sidHeader = false}) {
    sendPart({
      'Content-Type': 'application/json',
      if (sidHeader && sessionId != null) 'X-Session-Id': sessionId!,
    }, utf8.encode(compactJson(obj)));
  }

  void http(String status, List<String> headers, [List<int> body = const []]) {
    final lines = ['HTTP/1.1 $status', 'Server: mock-tapo-media', ...headers];
    if (body.isNotEmpty || !status.startsWith('200')) {
      lines.add('Content-Length: ${body.length}');
    }
    _write([...latin1.encode('${lines.join('\r\n')}\r\n\r\n'), ...body]);
  }

  String get _passwordT => mediaPassword(srv.secret, srv.encryptType3);

  void _challenge() {
    srv.challenges++;
    final nonce = randomHex(16);
    final opaque = randomHex(8);
    srv._nonces[nonce] = opaque;
    final extra = srv.encryptType3 ? ', encrypt_type=3' : '';
    http('401 Unauthorized', [
      'WWW-Authenticate: Digest realm="${srv.realm}", qop="auth", nonce="$nonce", opaque="$opaque", algorithm=${srv.digestAlgorithm}$extra',
      'Content-Type: application/json',
    ], utf8.encode('{"error_code":-40401}'));
  }

  bool _checkDigest(String auth) {
    if (!auth.toLowerCase().startsWith('digest ')) return false;
    final p = parseAuthParams(auth.substring(7));
    final alg = p['algorithm'] ?? 'MD5';
    if (alg.toUpperCase() != srv.digestAlgorithm.toUpperCase()) return false;
    final nonce = p['nonce'] ?? '';
    if (p['username'] != 'admin' || p['realm'] != srv.realm || !srv._nonces.containsKey(nonce)) {
      return false;
    }
    if ((p['opaque'] ?? srv._nonces[nonce]) != srv._nonces[nonce]) return false;
    if (p['qop'] != 'auth' || (p['cnonce'] ?? '').isEmpty || (p['nc'] ?? '').isEmpty) return false;
    final uri = p['uri'] ?? '';
    if (!uri.startsWith('/stream')) return false;
    final ha1 = _hash(alg, 'admin:${srv.realm}:$_passwordT');
    final ha2 = _hash(alg, 'POST:$uri');
    final expected = _hash(alg, '$ha1:$nonce:${p['nc']}:${p['cnonce']}:${p['qop']}:$ha2');
    return constTimeEqStr(expected, (p['response'] ?? '').toLowerCase());
  }

  Future<void> run() async {
    try {
      while (!authenticated) {
        var req = await reader.readLine();
        while (req != null && req.isEmpty) {
          req = await reader.readLine();
        }
        if (req == null) throw _Closed();
        final parts = req.split(' ');
        final h = await reader.readHeaders();
        if (h == null) throw _Closed();
        final n = int.tryParse(h['content-length'] ?? '0') ?? 0;
        if (n > 0) await reader.readExact(n);
        if (parts.length < 2 || parts[0] != 'POST' || !parts[1].startsWith('/stream')) {
          http('404 Not Found', ['Connection: close']);
          throw _Closed();
        }
        final auth = h['authorization'];
        if (auth == null) {
          _challenge();
          continue;
        }
        srv.authorizationLog.add(auth);
        if (!_checkDigest(auth)) {
          srv.authFailures++;
          _challenge();
          continue;
        }
        if (srv.activeSessions >= srv.maxSessions) {
          srv.limitRejections++;
          http('503 Service Unavailable', ['Content-Type: application/json', 'Connection: close'],
              utf8.encode('{"error_code":-52407}'));
          throw _Closed();
        }
        authenticated = true;
        srv.activeSessions++;
        final hdrs = ['Content-Type: multipart/mixed;boundary=$mediaDeviceBoundary', 'Connection: keep-alive'];
        if (h['x-key-exchange'] == '1') {
          final knonce = randomHex(16);
          final k = mediaKeys(knonce, _passwordT);
          key = k.key;
          iv = k.iv;
          encrypt = true;
          if (srv.kex == MediaKex.hkdf) {
            final salt = randomHex(16);
            hkdf = mediaHkdfKeys(knonce, _passwordT, salt);
            hdrs.add('Key-Exchange: cipher="AES_128_CBC" username="admin" padding="PKCS7_16" '
                'algorithm="HKDF" encrypt_type="3" nonce="$knonce" salt="$salt"');
          } else {
            hdrs.add('Key-Exchange: username="admin" nonce="$knonce"');
          }
        }
        http('200 OK', hdrs);
      }
      await _parts();
    } on _Closed {
      // normal end
    } catch (_) {
      // socket error
    } finally {
      stopStream = true;
      if (authenticated) srv.activeSessions--;
      try {
        await sender;
      } catch (_) {}
      try {
        await sock.flush();
      } catch (_) {}
      sock.destroy();
    }
  }

  Future<void> _parts() async {
    while (true) {
      final ln = await reader.readLine();
      if (ln == null) return;
      if (ln.isEmpty) continue;
      if (ln.startsWith('--$mediaClientBoundary--')) return; // client close marker
      if (!ln.contains(mediaClientBoundary)) continue;
      final h = await reader.readHeaders();
      if (h == null) return;
      final body = await reader.readExact(int.tryParse(h['content-length'] ?? '0') ?? 0);
      if (body == null) return;
      Map<String, dynamic>? msg;
      if ((h['content-type'] ?? '').contains('json')) {
        try {
          msg = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
        } catch (_) {}
      }
      srv.requestLog.add(MediaRequest(h, msg));
      final recv = h['x-data-received'];
      if (recv != null) {
        final n = int.tryParse(recv) ?? 0;
        if (n > lastAck) lastAck = n;
        srv.acks.add(n);
      }
      if (msg != null && msg['type'] == 'request') _request(msg);
    }
  }

  void _respond(Object? seq, {int code = 0, bool withSession = false, Map<String, dynamic> extra = const {}}) {
    final result = <String, dynamic>{'error_code': code, ...extra};
    final obj = <String, dynamic>{'type': 'response', 'seq': seq};
    if (withSession) {
      switch (srv.sessionIdIn) {
        case SessionIdIn.params:
          obj['params'] = {'session_id': sessionId};
        case SessionIdIn.result:
          result['session_id'] = sessionId;
        case SessionIdIn.header:
          break;
      }
    }
    obj['result'] = result;
    sendJson(obj, sidHeader: withSession && srv.sessionIdIn == SessionIdIn.header);
  }

  void _request(Map<String, dynamic> msg) {
    final seq = msg['seq'];
    final params = msg['params'] is Map ? (msg['params'] as Map).cast<String, dynamic>() : <String, dynamic>{};
    final method = params['method'];
    if (method == 'do' && params.containsKey('stop')) {
      srv.stopRequests++;
      stopStream = true;
      _respond(seq);
      return;
    }
    if (method == 'get' && params.containsKey('preview')) {
      _preview(seq, params['preview']);
      return;
    }
    final verb = params.containsKey('download')
        ? 'download'
        : (params.containsKey('playback') ? 'playback' : null);
    if (method != 'get' || verb == null) {
      _respond(seq, code: -52402);
      return;
    }
    if (sender != null && !_senderDone) {
      _respond(seq, code: -52417);
      return;
    }
    final p = params[verb];
    if (_findClip(p) == null) {
      _respond(seq, code: -52402);
      return;
    }
    if (verb == 'playback') srv.playbackRequests++;
    sessionId = '${srv.nextSessionId()}';
    _respond(seq,
        withSession: true,
        extra: verb == 'playback' ? {'speed': (p as Map)['scale'] ?? '1/1'} : const {});
    stopStream = false;
    _senderDone = false;
    sender = _stream().whenComplete(() => _senderDone = true);
  }

  bool _senderDone = true;

  Recording? _findClip(Object? p) {
    if (p is! Map) return null;
    final sRaw = p['start_time'];
    if (sRaw is! String) return null;
    final st = int.tryParse(sRaw);
    final et = int.tryParse('${p['end_time'] ?? sRaw}');
    if (st == null || et == null || st <= 0 || et < st) return null;
    if ((p['download_type'] ?? 'normal') != 'normal') return null;
    final mt = p['media_type'] ?? 0;
    if (mt != 0 && mt != '0') return null;
    for (final r in srv.recordings) {
      if ((r.startEpoch <= st && st < r.endEpoch) || (st <= r.startEpoch && et > r.startEpoch)) {
        return r;
      }
    }
    return null;
  }

  ({Uint8List data, Map<String, String> headers}) _encryptPart(Uint8List data) {
    if (!encrypt) return (data: data, headers: const {});
    if (hkdf == null) return (data: aesCbcEncrypt(key, iv, data), headers: const {});
    hkdfParts++;
    final every = srv.corruptHmacEvery;
    return mediaHkdfEncrypt(hkdf!.aesKey, hkdf!.hmacKey, data,
        corruptHmac: every > 0 && hkdfParts % every == 0);
  }

  void _sendMedia(int i, Uint8List data, int pts, bool keyframe) {
    final e = _encryptPart(data);
    sendPart({
      'Content-Type': 'video/mp2t',
      'X-If-Encrypt': encrypt ? '1' : '0',
      ...e.headers,
      'X-Session-Id': sessionId ?? '',
      'X-Data-Sequence': '$i',
      'X-Data-PTS': '$pts',
      'X-If-IFrame': keyframe ? '1' : '0',
      'X-Stream-Type': '0',
    }, e.data);
    srv.partsSent++;
  }

  Future<bool> _waitWindow(int seq) async {
    final window = srv.ackWindow;
    final deadline = DateTime.now().add(srv.ackTimeout);
    while (!stopStream) {
      if (window == 0 || seq - lastAck <= window) return true;
      if (DateTime.now().isAfter(deadline)) break;
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    if (stopStream) return false;
    try {
      sendJson({
        'type': 'notification',
        'params': {'event_type': 'connection_closed', 'error_code': -1, 'close_reason': 'data timeout'}
      });
      await sock.flush();
    } catch (_) {}
    sock.destroy();
    return false;
  }

  List<Uint8List> _chunks() {
    final ts = srv.ts;
    final chunk = (srv.chunkSize ~/ 188).clamp(1, 1 << 20) * 188;
    return [
      for (var i = 0; i < ts.length; i += chunk)
        Uint8List.sublistView(ts, i, i + chunk > ts.length ? ts.length : i + chunk)
    ];
  }

  Future<void> _stream() async {
    try {
      final chunks = _chunks();
      for (var i = 1; i <= chunks.length; i++) {
        if (!await _waitWindow(i)) return;
        _sendMedia(i, chunks[i - 1], (3 * 90000 * (i - 1)) ~/ chunks.length, i == 1);
        if (i % 8 == 0) await Future<void>.delayed(Duration.zero);
      }
      if (!stopStream) {
        sendJson({
          'type': 'notification',
          'params': {'event_type': 'stream_status', 'status': 'finished'}
        });
      }
    } catch (_) {}
  }

  void _preview(Object? seq, Object? p) {
    String? resolution;
    if (p is Map && p['channels'] is List && p['resolutions'] is List) {
      final res = p['resolutions'] as List;
      if ((p['channels'] as List).isNotEmpty &&
          res.length == (p['channels'] as List).length &&
          (res.first == 'HD' || res.first == 'VGA')) {
        resolution = res.first as String;
      }
    }
    if (resolution == null) {
      _respond(seq, code: -52402);
      return;
    }
    if (sender != null && !_senderDone) {
      _respond(seq, code: -52417);
      return;
    }
    sessionId = '${srv.nextSessionId()}';
    _respond(seq, withSession: true, extra: {'resolutions': [resolution]});
    srv.previewRequests++;
    stopStream = false;
    _senderDone = false;
    sender = _previewLoop().whenComplete(() => _senderDone = true);
  }

  Future<void> _previewLoop() async {
    try {
      final chunks = _chunks();
      var i = 0;
      while (!stopStream) {
        final idx = i % chunks.length;
        i++;
        if (!await _waitWindow(i)) return;
        _sendMedia(i, chunks[idx], 3000 * (i - 1), idx == 0);
        await Future<void>.delayed(srv.previewInterval);
      }
    } catch (_) {}
  }
}
