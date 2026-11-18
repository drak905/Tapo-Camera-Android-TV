// Mock TP-Link cloud relay node (CIPC tunnel) on 127.0.0.1:<ephemeral>, TLS with
// a self-signed certificate valid for localhost / 127.0.0.1. Port of
// tests/fixtures/mock_relay.py of the Windows app.
//
// MockCloud hands out slots from [MockRelay.issueSlot] (relayUrl =
// https://localhost:<port>/relayservice?..., relayIp = 127.0.0.1). Tests inject
// [clientSecurityContext] (trusts only this certificate, hostname checked).
//
// Per tunnel the mock checks what the real relay checks: request line
// "POST <relayPath>&retryTime=0 HTTP/1.1" and the headers in EXACT order
// ([expectedHeaderOrder]; Cookie only when the slot had an elbCookie) with the
// X-token of an issued slot. Answers:
//  - missing / misordered / wrong header -> 400 {"errorCode":3,"closeReason":"illegal_request"}
//  - unknown X-token                     -> 403 {"errorCode":-1,...}
//  - cloudType != requiredCloudType, or mode "offline"
//                                        -> 500 {"errorCode":-1007,"closeReason":"device offline"}
//  - redirects > 0                       -> 304 + RequestUrlResult (new token); the client
//                                           reconnects with X-Redirect-Times + 1
//  - mode "drop"                         -> connection closed without an answer
//  - otherwise 200 and the mock plays the camera side: the first client part must be the
//    preview request (no inner POST /stream, no digest); it answers with a session_id and
//    loops the sample MPEG-TS (X-If-Encrypt: 0). Mode "encrypted": parts carry
//    X-If-Encrypt: 1 + X-Nonce + X-Data-Hmac and are HKDF-encrypted with
//    [encryptedKeys] (the key schedule is unknown on real relays; tests read the keys here).
// streamType 1 (SD playback, type=sdvod) / 3 (download, type=download) slots expect a
// first "get playback" / "get download" request instead of the preview.
// Heartbeats, acks and stop requests are recorded.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'fx_crypto.dart';
import 'fx_io.dart';
import 'mock_media8800.dart' show loadSampleTs;
import 'tls_cert.dart';

const String relayHost = 'localhost';
const String relayClientDelimiter = '----client-stream-boundary--';
const String relayDeviceDelimiter = '----device-stream-boundary--';
const String relayContentLengthSentinel = '9223372036854775807';
final Uint8List relayHeartbeatBody =
    Uint8List.fromList(utf8.encode('{"type": "notification", "params": {"event_type": "heartbeat"}}'));

/// Tunnel request header names in the order the app sends them.
const List<String> expectedHeaderOrder = [
  'User-Agent', 'Keep-Relay', 'Accept', 'Content-Type', 'Host', 'Content-Length', 'X-token',
  'X-Client-Model', 'X-Client-UUID', 'X-Track-Id', 'X-Redirect-Times', 'X-Pull-Mode', 'Cookie',
  'X-Version', 'X-Arrive-Latency',
];

enum RelayMode { ok, offline, drop, encrypted }

class RelaySlot {
  RelaySlot(this.deviceId, this.resolution, this.cloudType, this.trackId, this.redirectTimes,
      this.elbCookie, this.streamType);
  final String deviceId;
  final String resolution;
  final int cloudType;
  final String trackId;
  final int redirectTimes;
  final String elbCookie;
  final int streamType;
}

class RelayTunnelEntry {
  RelayTunnelEntry(this.line, this.headers);
  final String line;

  /// Header (name, value) pairs in the order received.
  final List<(String, String)> headers;

  /// "200", "304", "400 Bad Request", "403 Forbidden", "500", "dropped".
  String? status;
}

class RelayPart {
  RelayPart(this.headers, this.raw, this.body);
  final Map<String, String> headers; // lower-case names
  final Uint8List raw;
  final Map<String, dynamic>? body;
}

class MockRelay {
  MockRelay({
    this.partInterval = const Duration(milliseconds: 5),
    this.chunkSize = 188 * 32,
    Uint8List? ts,
    // ignore: prefer_initializing_formals
  }) : _ts = ts;

  RelayMode mode = RelayMode.ok;

  /// Next N tunnel requests answer 304.
  int redirects = 0;
  int requiredCloudType = 2;

  /// ELB cookie put into new slots (and required as Cookie header).
  String elbCookie = '';
  Duration partInterval;
  int chunkSize;

  /// playback: true -> `stream_status finished` after the clip; false keeps streaming.
  bool playbackFinishes = true;

  /// Verbs ("playback" / "download") answered with error -52402.
  final Set<String> vodRefuse = {};
  final Uint8List? _ts;

  // ---- inspection -----------------------------------------------------------
  final Map<String, RelaySlot> slots = {};
  final List<RelayTunnelEntry> tunnels = [];
  final List<RelayPart> clientParts = [];

  /// (time, raw body) per heartbeat part.
  final List<(DateTime, Uint8List)> heartbeats = [];
  final List<String?> acks = [];
  final List<Map<String, dynamic>> previews = [];
  final List<Map<String, dynamic>> vodRequests = [];
  int stops = 0;
  int openTunnels = 0;
  int mediaPartsSent = 0;
  int _sessionCounter = 0;

  SecureServerSocket? _server;
  TestCert? _cert;
  final Set<_Tunnel> _tunnels = {};

  Uint8List get ts => _ts ?? loadSampleTs();

  Future<MockRelay> start() async {
    _cert = generateTestCert(
        commonName: 'Mock TP-Link Relay', sanDns: [relayHost], sanIps: ['127.0.0.1'], isCa: true);
    _server = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, _cert!.serverContext());
    _server!.listen((s) {
      s.setOption(SocketOption.tcpNoDelay, true);
      final t = _Tunnel(this, s);
      _tunnels.add(t);
      t.run().whenComplete(() => _tunnels.remove(t));
    }, onError: (Object _) {});
    return this;
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
    dropAll();
  }

  int get port => _server!.port;
  String get certPem => _cert!.certPem;

  /// Client TLS context that trusts only the mock relay certificate (hostname checked).
  SecurityContext clientSecurityContext() => _cert!.clientContext();

  /// Closes every open tunnel (simulates a relay / network drop).
  void dropAll() {
    for (final t in _tunnels.toList()) {
      t.stopMedia = true;
      t.sock.destroy();
    }
  }

  /// Fixed keys of "encrypted" mode (clients cannot learn them from the protocol).
  ({String nonce, String salt, String passwordT, Uint8List aesKey, Uint8List hmacKey}) get encryptedKeys {
    const nonce = '00112233445566778899aabbccddeeff';
    const salt = 'ffeeddccbbaa99887766554433221100';
    final pwd = sha256Upper('relay-test-secret');
    final k = mediaHkdfKeys(nonce, pwd, salt);
    return (nonce: nonce, salt: salt, passwordT: pwd, aesKey: k.aesKey, hmacKey: k.hmacKey);
  }

  // ---- slots (used by MockCloud) -------------------------------------------
  Map<String, dynamic> _newSlot(String deviceId, String resolution, int cloudType, String trackId,
      {int redirectTimes = 0, int streamType = 0}) {
    final token = randomHex(16);
    final String path;
    if (streamType == 1) {
      path = '/relayservice?deviceid=$deviceId&type=sdvod&playerid=${randomHex(16)}';
    } else if (streamType == 3) {
      path = '/relayservice?deviceid=$deviceId&type=download&bidirectionid=${randomHex(16)}';
    } else {
      path = '/relayservice?deviceid=$deviceId&type=video&resolution=$resolution';
    }
    final result = <String, dynamic>{
      'relayUrl': 'https://$relayHost:$port$path',
      'relayIp': '127.0.0.1',
      'relayToken': token,
    };
    if (elbCookie.isNotEmpty) result['elbCookie'] = elbCookie;
    slots[token] =
        RelaySlot(deviceId, resolution, cloudType, trackId, redirectTimes, elbCookie, streamType);
    return result;
  }

  /// RequestUrlResult for a new slot (called by MockCloud's /v2/relay/request).
  Map<String, dynamic> issueSlot(String deviceId, String resolution, int cloudType, String trackId,
          {int streamType = 0}) =>
      _newSlot(deviceId, resolution, cloudType, trackId, streamType: streamType);
}

class _Tunnel {
  _Tunnel(this.relay, this.sock) : reader = ByteReader(sock);
  final MockRelay relay;
  final Socket sock;
  final ByteReader reader;
  bool stopMedia = false;
  String? sessionId;
  RelaySlot? slot;
  Future<void>? sender;

  void _write(List<int> data) {
    try {
      sock.add(data);
    } catch (_) {
      stopMedia = true;
    }
  }

  void sendPart(Map<String, String> headers, List<int> body) {
    final head = StringBuffer('$relayDeviceDelimiter\r\n');
    headers.forEach((k, v) => head.write('$k: $v\r\n'));
    head.write('Content-Length: ${body.length}\r\n\r\n');
    _write([...latin1.encode(head.toString()), ...body, 13, 10]);
  }

  void sendJson(Map<String, dynamic> obj) => sendPart({
        'Content-Type': 'application/json',
        'X-Session-Id': ?sessionId,
      }, utf8.encode(jsonEncode(obj)));

  void answer(String status, Map<String, dynamic>? body, [List<String> headers = const []]) {
    final data = body == null ? <int>[] : utf8.encode(jsonEncode(body));
    final lines = ['HTTP/1.1 $status', ...headers];
    if (body != null) lines.addAll(['Content-Type: application/json', 'Content-Length: ${data.length}']);
    _write([...latin1.encode('${lines.join('\r\n')}\r\n\r\n'), ...data]);
  }

  (String, Map<String, dynamic>)? _checkHead(String line, List<(String, String)> headers) {
    const illegal = ('400 Bad Request', {'errorCode': 3, 'closeReason': 'illegal_request'});
    final parts = line.split(' ');
    if (parts.length != 3 || parts[0] != 'POST' || parts[2] != 'HTTP/1.1') return illegal;
    final target = Uri.parse(parts[1]);
    if (target.path != '/relayservice' ||
        target.queryParameters['retryTime'] != '0' ||
        !target.query.endsWith('&retryTime=0')) {
      return illegal;
    }
    final values = {for (final h in headers) h.$1: h.$2};
    final token = values['X-token'] ?? '';
    final s = relay.slots[token];
    final expected = [
      for (final h in expectedHeaderOrder)
        if (h != 'Cookie' || (s != null && s.elbCookie.isNotEmpty)) h
    ];
    final got = headers.map((h) => h.$1).toList();
    if (got.length != expected.length || !_listEq(got, expected)) return illegal;
    final ua = values['User-Agent']!;
    if (!ua.startsWith('Client=TP-Link_Tapo_Android Android ') || !ua.endsWith('/1.3')) return illegal;
    const fixed = {
      'Keep-Relay': '3600',
      'Accept': '*/*',
      'Host': relayHost,
      'Content-Type': 'multipart/mixed;boundary=--client-stream-boundary--',
      'Content-Length': relayContentLengthSentinel,
      'X-Pull-Mode': '2',
      'X-Version': '2.0',
    };
    for (final e in fixed.entries) {
      if (values[e.key] != e.value) return illegal;
    }
    if ((values['X-Client-UUID'] ?? '').isEmpty ||
        (values['X-Client-Model'] ?? '').isEmpty ||
        int.tryParse(values['X-Arrive-Latency']!) == null) {
      return illegal;
    }
    if (s == null) return ('403 Forbidden', {'errorCode': -1, 'closeReason': 'invalid token'});
    if (values['X-Track-Id'] != s.trackId ||
        values['X-Redirect-Times'] != '${s.redirectTimes}' ||
        target.queryParameters['deviceid'] != s.deviceId) {
      return illegal;
    }
    if (s.elbCookie.isNotEmpty && values['Cookie'] != s.elbCookie) return illegal;
    slot = s;
    return null;
  }

  bool _listEq(List<String> a, List<String> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> run() async {
    try {
      final line = await reader.readLine();
      if (line == null) return;
      final headers = <(String, String)>[];
      while (true) {
        final ln = await reader.readLine();
        if (ln == null) return;
        if (ln.isEmpty) break;
        final i = ln.indexOf(':');
        headers.add((ln.substring(0, i).trim(), ln.substring(i + 1).trim()));
      }
      final entry = RelayTunnelEntry(line, headers);
      relay.tunnels.add(entry);
      if (relay.mode == RelayMode.drop) {
        entry.status = 'dropped';
        return;
      }
      final problem = _checkHead(line, headers);
      if (problem != null) {
        entry.status = problem.$1;
        answer(problem.$1, problem.$2);
        return;
      }
      final s = slot!;
      if (relay.mode == RelayMode.offline || s.cloudType != relay.requiredCloudType) {
        entry.status = '500';
        answer('500 Internal Server Error', {'errorCode': -1007, 'closeReason': 'device offline'});
        return;
      }
      if (relay.redirects > 0) {
        relay.redirects--;
        final nu = relay._newSlot(s.deviceId, s.resolution, s.cloudType, s.trackId,
            redirectTimes: s.redirectTimes + 1, streamType: s.streamType);
        entry.status = '304';
        answer('304 Not Modified', nu);
        return;
      }
      entry.status = '200';
      answer('200 OK', null, [
        'X-Client-Id: ${randomHex(8)}',
        'Content-Type: multipart/mixed;boundary=--device-stream-boundary--',
      ]);
      relay.openTunnels++;
      try {
        await _deviceLoop();
      } finally {
        stopMedia = true;
        relay.openTunnels--;
        try {
          await sender;
        } catch (_) {}
      }
    } catch (_) {
      // socket error
    } finally {
      try {
        await sock.flush();
      } catch (_) {}
      sock.destroy();
    }
  }

  Future<RelayPart?> _nextPart() async {
    while (true) {
      final ln = await reader.readLine();
      if (ln == null) return null;
      if (ln.trim() == relayClientDelimiter) break;
    }
    final h = await reader.readHeaders();
    if (h == null) return null;
    final n = int.tryParse(h['content-length'] ?? '');
    if (n == null) return null;
    final body = await reader.readExact(n);
    if (body == null) return null;
    Map<String, dynamic>? msg;
    try {
      msg = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
    } catch (_) {}
    return RelayPart(h, body, msg);
  }

  Future<void> _deviceLoop() async {
    var first = true;
    while (true) {
      final part = await _nextPart();
      if (part == null) return;
      relay.clientParts.add(part);
      final msg = part.body;
      if (msg == null) continue;
      final params = msg['params'] is Map ? (msg['params'] as Map).cast<String, dynamic>() : <String, dynamic>{};
      if (msg['type'] == 'notification') {
        final event = params['event_type'];
        if (event == 'heartbeat') {
          relay.heartbeats.add((DateTime.now(), part.raw));
        } else if (event == 'stream_sequence') {
          relay.acks.add(part.headers['x-data-received']);
        }
        continue;
      }
      if (msg['type'] != 'request') continue;
      final st = slot?.streamType ?? 0;
      if (first) {
        first = false;
        final verb = {0: 'preview', 1: 'playback', 3: 'download'}[st];
        if (params['method'] != 'get' || !params.containsKey(verb)) {
          sendJson({'type': 'response', 'seq': msg['seq'], 'result': {'error_code': -40106}});
          continue;
        }
      }
      if (params['method'] == 'get' && st == 0 && params['preview'] is Map) {
        _startPreview(msg['seq'], (params['preview'] as Map).cast<String, dynamic>());
      } else if (params['method'] == 'get' && (st == 1 || st == 3)) {
        final verb = st == 1 ? 'playback' : 'download';
        if (params[verb] is Map) _startVod(msg['seq'], verb, (params[verb] as Map).cast<String, dynamic>());
      } else if (params['method'] == 'do' && params.containsKey('stop')) {
        relay.stops++;
        stopMedia = true;
      }
    }
  }

  List<Uint8List> _chunks() {
    final ts = relay.ts;
    final c = (relay.chunkSize ~/ 188).clamp(1, 1 << 20) * 188;
    return [
      for (var i = 0; i < ts.length; i += c)
        Uint8List.sublistView(ts, i, i + c > ts.length ? ts.length : i + c)
    ];
  }

  void _sendMedia(int i, Uint8List data, int pts, bool key) {
    final headers = <String, String>{'Content-Type': 'video/mp2t'};
    List<int> body = data;
    if (relay.mode == RelayMode.encrypted) {
      final k = relay.encryptedKeys;
      final e = mediaHkdfEncrypt(k.aesKey, k.hmacKey, data);
      body = e.data;
      headers['X-If-Encrypt'] = '1';
      headers.addAll(e.headers);
    } else {
      headers['X-If-Encrypt'] = '0';
    }
    headers.addAll({
      'X-Session-Id': sessionId ?? '',
      'X-Data-Sequence': '$i',
      'X-Data-PTS': '$pts',
      'X-If-IFrame': key ? '1' : '0',
    });
    sendPart(headers, body);
    relay.mediaPartsSent++;
  }

  void _startPreview(Object? seq, Map<String, dynamic> p) {
    final res = p['resolutions'] is List ? p['resolutions'] as List : const [];
    final resolution = res.isNotEmpty && (res.first == 'HD' || res.first == 'VGA') ? res.first as String : null;
    if (resolution == null || p['channels'] is! List) {
      sendJson({'type': 'response', 'seq': seq, 'result': {'error_code': -52402}});
      return;
    }
    relay.previews.add({
      'resolution': resolution,
      'channels': p['channels'],
      'slot_resolution': slot?.resolution,
    });
    sessionId = '${++relay._sessionCounter}';
    sendJson({
      'type': 'response',
      'seq': seq,
      'params': {'session_id': sessionId},
      'result': {'error_code': 0, 'resolutions': [resolution]},
    });
    stopMedia = false;
    sender = _previewLoop();
  }

  Future<void> _previewLoop() async {
    try {
      final chunks = _chunks();
      var i = 0;
      while (!stopMedia) {
        final idx = i % chunks.length;
        i++;
        _sendMedia(i, chunks[idx], 3000 * (i - 1), idx == 0);
        await Future<void>.delayed(relay.partInterval);
      }
    } catch (_) {}
  }

  void _startVod(Object? seq, String verb, Map<String, dynamic> p) {
    relay.vodRequests.add({'verb': verb, 'params': Map<String, dynamic>.from(p)});
    final sRaw = p['start_time'];
    final st = sRaw is String ? int.tryParse(sRaw) : null;
    final et = int.tryParse('${p['end_time'] ?? sRaw}');
    if (st == null || st <= 0 || et == null || et < st || relay.vodRefuse.contains(verb)) {
      sendJson({'type': 'response', 'seq': seq, 'result': {'error_code': -52402}});
      return;
    }
    sessionId = '${++relay._sessionCounter}';
    sendJson({
      'type': 'response',
      'seq': seq,
      'params': {'session_id': sessionId},
      'result': {'error_code': 0, if (verb == 'playback') 'speed': p['scale'] ?? '1/1'},
    });
    stopMedia = false;
    sender = _vodLoop(verb);
  }

  Future<void> _vodLoop(String verb) async {
    try {
      final chunks = _chunks();
      var i = 0;
      do {
        for (final c in chunks) {
          if (stopMedia) return;
          i++;
          _sendMedia(i, c, (3 * 90000 * (i - 1)) ~/ chunks.length, i == 1);
          if (i % 8 == 0) await Future<void>.delayed(Duration.zero);
        }
        // playbackFinishes = false: keep looping like a relay that never closes (capped)
      } while (verb == 'playback' && !relay.playbackFinishes && i < chunks.length * 20);
      if (!stopMedia && (verb == 'download' || relay.playbackFinishes)) {
        sendJson({
          'type': 'notification',
          'params': {'event_type': 'stream_status', 'status': 'finished'}
        });
      }
    } catch (_) {}
  }
}
