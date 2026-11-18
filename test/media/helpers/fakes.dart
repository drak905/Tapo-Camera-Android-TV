// Test doubles shared by the player-lane tests: in-memory transport, scripted
// camera (local :8800 and relay tunnel), cloud auth, byte helpers.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:tapo_tv/media/media_deps.dart';
import 'package:tapo_tv/media/media_transport.dart';

/// `192.168.1.x` only: no real addresses in fixtures.
const kCameraHost = '192.168.1.50';

Uint8List bytesOf(String latin1Text) => Uint8List.fromList(latin1.encode(latin1Text));

String hexOf(List<int> b) => b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

Uint8List fromHex(String hex) =>
    Uint8List.fromList([for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);

/// 188-byte plain TS payload used as a "video" part body: sync byte, then 0..183.
Uint8List tsPacket([int fill = 0]) =>
    Uint8List.fromList([0x47, 0x40, 0x00, 0x10, for (var i = 0; i < 184; i++) (i + fill) & 0xff]);

/// A device part: `----device-stream-boundary--` + headers + body.
Uint8List devicePart(
  List<int> body, {
  String contentType = 'video/mp2t',
  List<(String, String)> headers = const [],
}) {
  final head = StringBuffer('----device-stream-boundary--\r\n');
  for (final (k, v) in headers) {
    head.write('$k: $v\r\n');
  }
  head
    ..write('Content-Type: $contentType\r\n')
    ..write('Content-Length: ${body.length}\r\n\r\n');
  return Uint8List.fromList([...latin1.encode(head.toString()), ...body, 13, 10]);
}

Uint8List jsonPart(Map<String, Object?> message, {List<(String, String)> headers = const []}) =>
    devicePart(utf8.encode(jsonEncode(message)), contentType: 'application/json', headers: headers);

/// One client part as the camera sees it.
class ClientPart {
  ClientPart(this.headers, this.body);
  final List<(String, String)> headers;
  final Uint8List body;
  String? header(String name) {
    for (final (k, v) in headers) {
      if (k.toLowerCase() == name.toLowerCase()) return v;
    }
    return null;
  }

  Map<String, dynamic>? get json {
    if (!(header('Content-Type') ?? '').contains('json')) return null;
    final v = jsonDecode(utf8.decode(body));
    return v is Map<String, dynamic> ? v : null;
  }
}

class FakeTransport implements MediaTransport {
  FakeTransport({this.clock});

  final _input = StreamController<Uint8List>();
  final List<Uint8List> writes = [];
  final List<(String, Duration)> events = [];
  final Duration Function()? clock;
  void Function(Uint8List data)? onWrite;
  bool closed = false;
  int closeCount = 0;

  Duration get _now => clock?.call() ?? Duration.zero;

  @override
  Stream<Uint8List> get input => _input.stream;

  @override
  void add(List<int> data) {
    final bytes = Uint8List.fromList(data);
    writes.add(bytes);
    events.add(('write', _now));
    onWrite?.call(bytes);
  }

  /// All bytes written so far.
  Uint8List get written => Uint8List.fromList([for (final w in writes) ...w]);

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    closeCount++;
    if (closed) return;
    closed = true;
    events.add(('close', _now));
    if (!_input.isClosed) await _input.close();
  }

  void push(List<int> data) {
    if (!_input.isClosed) _input.add(Uint8List.fromList(data));
  }

  /// Peer closes the connection.
  void end() {
    if (!_input.isClosed) _input.close();
  }
}

class ConnectCall {
  ConnectCall(this.host, this.port, this.tls, this.serverName);
  final String host;
  final int port;
  final bool tls;
  final String? serverName;
}

class FakeConnector {
  FakeConnector({this.clock, this.onConnect});
  final Duration Function()? clock;
  final void Function(FakeTransport transport, int index)? onConnect;
  final List<FakeTransport> transports = [];
  final List<ConnectCall> calls = [];

  Future<MediaTransport> call(String host, int port, {bool tls = false, String? serverName, Duration? timeout}) async {
    final t = FakeTransport(clock: clock);
    calls.add(ConnectCall(host, port, tls, serverName));
    transports.add(t);
    onConnect?.call(t, transports.length - 1);
    return t;
  }

  TransportConnector get connect => call;
}

enum CameraMode { local, relay }

/// Scripted camera on one [FakeTransport]. Local mode answers `POST /stream`
/// with Digest (401 then 200 + Key-Exchange); relay mode answers the tunnel
/// head with 200. Both parse client parts and answer get/do requests.
class FakeCamera {
  FakeCamera(
    this.t, {
    this.mode = CameraMode.local,
    this.requireAuth = true,
    this.keyExchange,
    this.errorCode = 0,
    this.sessionId = '7',
    this.respond = true,
    this.http401Always = false,
    this.tunnelHead,
  }) {
    t.onWrite = _onWrite;
  }

  final FakeTransport t;
  final CameraMode mode;
  final bool requireAuth;
  final String? keyExchange;
  final int errorCode;
  final String? sessionId;
  final bool respond;
  final bool http401Always;

  /// Overrides the 200 answer of the relay tunnel (e.g. a 304 or 400 response).
  final String? tunnelHead;

  final List<String> heads = [];
  final List<ClientPart> parts = [];
  final List<Map<String, dynamic>> requests = [];
  final _buf = BytesBuilder();
  bool _headDone = false;

  /// Requests with `params.method == method` and the given key under params.
  Iterable<Map<String, dynamic>> requestsOf(String method, String key) =>
      requests.where((r) => (r['params'] as Map?)?['method'] == method && (r['params'] as Map).containsKey(key));

  void _onWrite(Uint8List data) {
    _buf.add(data);
    _drain();
  }

  void _drain() {
    var all = _buf.takeBytes();
    var progress = true;
    while (progress) {
      progress = false;
      if (!_headDone) {
        final end = _indexOf(all, [13, 10, 13, 10], 0);
        if (end < 0) break;
        final head = latin1.decode(all.sublist(0, end));
        all = Uint8List.fromList(all.sublist(end + 4));
        heads.add(head);
        _answerHead(head);
        progress = true;
        continue;
      }
      final headEnd = _indexOf(all, [13, 10, 13, 10], 0);
      if (headEnd < 0) break;
      final headerText = latin1.decode(all.sublist(0, headEnd));
      final lines = headerText.split('\r\n').where((l) => l.isNotEmpty).toList();
      if (lines.isEmpty || !lines.first.startsWith('--')) {
        all = Uint8List.fromList(all.sublist(headEnd + 4));
        progress = true;
        continue;
      }
      final headers = <(String, String)>[];
      var length = 0;
      for (final l in lines.skip(1)) {
        final i = l.indexOf(':');
        final k = l.substring(0, i), v = l.substring(i + 1).trim();
        headers.add((k, v));
        if (k.toLowerCase() == 'content-length') length = int.parse(v);
      }
      final bodyStart = headEnd + 4;
      if (all.length < bodyStart + length + 2) break;
      final body = Uint8List.fromList(all.sublist(bodyStart, bodyStart + length));
      all = Uint8List.fromList(all.sublist(bodyStart + length + 2));
      final part = ClientPart(headers, body);
      parts.add(part);
      final j = part.json;
      if (j != null && j['type'] == 'request') {
        requests.add(j);
        _answerRequest(j);
      }
      progress = true;
    }
    _buf.add(all);
  }

  void _answerHead(String head) {
    if (mode == CameraMode.relay) {
      t.push(bytesOf(tunnelHead ?? 'HTTP/1.1 200 OK\r\n\r\n'));
      _headDone = tunnelHead == null || tunnelHead!.startsWith('HTTP/1.1 200');
      return;
    }
    final hasAuth = head.toLowerCase().contains('\r\nauthorization:');
    if ((requireAuth && !hasAuth) || http401Always) {
      t.push(bytesOf('HTTP/1.1 401 Unauthorized\r\n'
          'WWW-Authenticate: Digest realm="TP-LINK IP-CAM", qop="auth", nonce="8c5d1f22", opaque="6494321", algorithm=MD5\r\n'
          'Content-Length: 0\r\n\r\n'));
      return;
    }
    final ke = keyExchange == null ? '' : 'Key-Exchange: $keyExchange\r\n';
    t.push(bytesOf('HTTP/1.1 200 OK\r\nConnection: keep-alive\r\n$ke\r\n'));
    _headDone = true;
  }

  void _answerRequest(Map<String, dynamic> r) {
    if (!respond) return;
    final params = r['params'] as Map<String, dynamic>? ?? {};
    final method = params['method'];
    if (method == 'get' && (params.containsKey('preview') || params.containsKey('playback'))) {
      t.push(jsonPart({
        'type': 'response',
        'seq': r['seq'],
        'params': {'session_id': ?sessionId},
        'result': {'error_code': errorCode, 'speed': '1/1'},
      }));
    }
  }

  /// Pushes a TS video part; [sequence] sets `X-Data-Sequence`.
  void video(List<int> body, {int? sequence, List<(String, String)> headers = const []}) =>
      t.push(devicePart(body, headers: [if (sequence != null) ('X-Data-Sequence', '$sequence'), ...headers]));

  void audio(List<int> body) => t.push(devicePart(body, contentType: 'audio/mp2t'));

  void notify(Map<String, Object?> params) => t.push(jsonPart({'type': 'notification', 'params': params}));
}

int _indexOf(List<int> data, List<int> pattern, int from) {
  for (var i = from; i <= data.length - pattern.length; i++) {
    var ok = true;
    for (var j = 0; j < pattern.length; j++) {
      if (data[i + j] != pattern[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

class FakeLocalAuth implements LocalMediaAuth {
  FakeLocalAuth({this.digestSecret = 'cloudpass', this.username = 'admin'});
  @override
  final String digestSecret;
  @override
  final String username;
}

/// Cloud auth fake. [replies] are consumed in order by `postCipc`; the last
/// one repeats.
class FakeCloudAuth implements CloudRelayAuth {
  FakeCloudAuth({List<CipcResponse>? replies, this.tokenValue = 'ACCOUNTTOKEN;extra'})
      : replies = replies ?? [relayOk()];

  final List<CipcResponse> replies;
  final String? tokenValue;
  final List<({Uri url, Map<String, String> headers, Map<String, dynamic> body})> posts = [];
  int reloginCount = 0;

  static CipcResponse relayOk({String host = 'relay.example.com', String token = 'RELAYTOKEN1', String? cookie}) =>
      CipcResponse(200, {
        'errorCode': 0,
        'result': {
          'relayUrl': 'https://$host/relayservice?deviceid=DEV&type=video',
          'relayToken': token,
          'relayIp': '10.0.0.9',
          'elbCookie': ?cookie,
        },
      });

  static CipcResponse error(int code) => CipcResponse(200, {'errorCode': code, 'msg': 'x'});

  @override
  Future<String?> get token async => tokenValue;
  @override
  Future<Uri> get cipcUrl async => Uri.parse('https://cipc.example.com');
  @override
  String get terminalUuid => '0123456789abcdef0123456789abcdef';
  @override
  String get clientModel => 'Windows';
  @override
  String get appVersion => '3.22.806';

  @override
  Future<CipcResponse> postCipc(Uri url, Map<String, String> headers, Uint8List body) async {
    posts.add((url: url, headers: headers, body: jsonDecode(utf8.decode(body)) as Map<String, dynamic>));
    final i = posts.length - 1;
    return replies[i < replies.length ? i : replies.length - 1];
  }

  @override
  Future<void> relogin() async => reloginCount++;
}

/// Collects a stream into a list and exposes a done flag / error.
class Collector<T> {
  Collector(Stream<T> stream) {
    sub = stream.listen(items.add, onError: (Object e) => errors.add(e), onDone: () => done = true);
  }
  late final StreamSubscription<T> sub;
  final List<T> items = [];
  final List<Object> errors = [];
  bool done = false;
}

/// Lets queued microtasks and zero-delay timers run.
Future<void> settle([int rounds = 20]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
