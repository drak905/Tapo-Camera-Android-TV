// dart:io implementations of the seams the api and media lanes define:
// cloud HTTPS transport, LAN camera link (TOFU certificate), TDP discovery
// sockets, secure key/value backend and the TLS pin store.
//
// Nothing here is used by widget tests (they inject fakes); AppState builds
// these only when `useBackend` is on.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/camera_transport.dart';
import '../api/cloud_transport.dart';
import '../api/lan_matcher.dart';
import '../api/tdp_discovery.dart';
import 'secure_store.dart';

/// Production [CloudTransport]: HTTPS with the TP-Link roots from
/// `TapoCloud.buildContext`; certificate and hostname checks stay on.
class HttpCloudTransport implements CloudTransport {
  HttpCloudTransport(SecurityContext context)
      : _http = HttpClient(context: context)
          ..connectionTimeout = const Duration(seconds: 15)
          ..idleTimeout = const Duration(seconds: 30);

  final HttpClient _http;
  static const _maxBody = 16 * 1024 * 1024;

  @override
  Future<CloudResponse> send(CloudRequest request) async {
    final req = await _http.openUrl(request.method, request.uri).timeout(request.timeout);
    request.headers.forEach(req.headers.set);
    final body = request.body;
    if (body != null) {
      req.headers.contentLength = body.length;
      req.add(body);
    }
    final res = await req.close().timeout(request.timeout);
    final out = BytesBuilder(copy: false);
    await for (final chunk in res.timeout(request.timeout)) {
      out.add(chunk);
      if (out.length > _maxBody) throw const HttpException('Response too large');
    }
    return CloudResponse(res.statusCode, out.takeBytes());
  }

  @override
  void close() => _http.close(force: true);
}

/// flutter_secure_storage (Android Keystore) as [SecureBackend].
class FlutterSecureBackend implements SecureBackend {
  FlutterSecureBackend([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();
}

/// Certificate pins (a SHA-256 of a public certificate, not a secret) kept in
/// shared_preferences under `tls_pin:<host:port>`.
class PrefsPinStore implements PinStore {
  PrefsPinStore(this._prefs);
  final SharedPreferences _prefs;
  static const _prefix = 'tls_pin:';

  @override
  String? read(String hostPort) => _prefs.getString('$_prefix$hostPort');

  @override
  Future<void> write(String hostPort, String sha256Hex) async {
    await _prefs.setString('$_prefix$hostPort', sha256Hex);
  }

  /// Forgets every pin (sign out).
  Future<void> clear() async {
    for (final key in _prefs.getKeys().where((k) => k.startsWith(_prefix)).toList()) {
      await _prefs.remove(key);
    }
  }
}

/// One keep-alive TLS connection to a camera. The certificate is self-signed,
/// so verification is replaced by the caller's TOFU pin check against
/// [peerCertificateDer]; nothing is sent before that check.
class IoCameraLink implements CameraLink {
  IoCameraLink._(this._socket, this._der, this.host) {
    _sub = _socket.listen(
      (data) {
        _buffer.add(data);
        _wake?.complete();
      },
      onError: (Object e) {
        _error = e;
        _wake?.complete();
      },
      onDone: () {
        _closed = true;
        _wake?.complete();
      },
    );
  }

  static Future<IoCameraLink> connect(String host, int port) async {
    Uint8List? der;
    final socket = await SecureSocket.connect(
      host,
      port,
      timeout: const Duration(seconds: 5),
      onBadCertificate: (cert) {
        der = cert.der;
        return true;
      },
    );
    der ??= socket.peerCertificate?.der;
    if (der == null) {
      socket.destroy();
      throw const HandshakeException('The camera sent no certificate');
    }
    return IoCameraLink._(socket, der!, host);
  }

  final SecureSocket _socket;
  final Uint8List _der;
  final String host;
  late final StreamSubscription<Uint8List> _sub;
  final _buffer = BytesBuilder();
  Completer<void>? _wake;
  Object? _error;
  bool _closed = false;

  @override
  Uint8List get peerCertificateDer => _der;

  Future<void> _waitData(Duration timeout) async {
    _wake = Completer<void>();
    try {
      await _wake!.future.timeout(timeout);
    } finally {
      _wake = null;
    }
  }

  @override
  Future<ChannelResponse> send(
    String path,
    List<int> body,
    Map<String, String> headers, {
    required Duration timeout,
  }) async {
    final head = StringBuffer('POST $path HTTP/1.1\r\nHost: $host\r\nContent-Length: ${body.length}\r\n');
    headers.forEach((k, v) => head.write('$k: $v\r\n'));
    head.write('\r\n');
    _buffer.clear();
    _socket.add(latin1.encode(head.toString()));
    _socket.add(body);
    await _socket.flush();

    final deadline = DateTime.now().add(timeout);
    Duration left() {
      final d = deadline.difference(DateTime.now());
      if (d <= Duration.zero) throw TimeoutException('Camera did not answer', timeout);
      return d;
    }

    Uint8List snapshot() => _buffer.toBytes();
    int headerEnd(Uint8List b) {
      for (var i = 0; i + 3 < b.length; i++) {
        if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) return i;
      }
      return -1;
    }

    var bytes = snapshot();
    var end = headerEnd(bytes);
    while (end < 0) {
      if (_error != null) throw SocketException('Connection error');
      if (_closed) throw const SocketException('Connection closed by the camera');
      await _waitData(left());
      bytes = snapshot();
      end = headerEnd(bytes);
    }
    final headText = latin1.decode(bytes.sublist(0, end));
    final lines = headText.split('\r\n');
    final status = int.tryParse(lines.first.split(' ').elementAtOrNull(1) ?? '') ?? 0;
    final responseHeaders = <String, String>{};
    for (final line in lines.skip(1)) {
      final i = line.indexOf(':');
      if (i > 0) responseHeaders[line.substring(0, i).trim().toLowerCase()] = line.substring(i + 1).trim();
    }
    final length = int.tryParse(responseHeaders['content-length'] ?? '');
    final bodyStart = end + 4;
    if (length == null) {
      // No length: read until the camera closes the connection.
      while (!_closed) {
        if (_error != null) break;
        await _waitData(left());
      }
      final all = snapshot();
      _socket.destroy();
      return ChannelResponse(status, Uint8List.fromList(all.sublist(min(bodyStart, all.length))), responseHeaders);
    }
    while (_buffer.length < bodyStart + length) {
      if (_error != null) throw SocketException('Connection error');
      if (_closed) throw const SocketException('Connection closed by the camera');
      await _waitData(left());
    }
    final all = snapshot();
    return ChannelResponse(status, Uint8List.fromList(all.sublist(bodyStart, bodyStart + length)), responseHeaders);
  }

  @override
  void close() {
    unawaited(_sub.cancel());
    _socket.destroy();
  }
}

Future<CameraLink> connectCameraLink(String host, int port) => IoCameraLink.connect(host, port);

TdpKeyPair? _tdpKeys;

/// Broadcasts one TDP probe and collects the answers for [window].
Future<List<LanDevice>> discoverLanDevices({Duration window = const Duration(seconds: 2)}) async {
  final keys = _tdpKeys ??= await generateTdpKeyPair();
  final serial = Random.secure().nextInt(1 << 28);
  final payload = tdpProbePayload(keys.publicKeyPem);
  final packet = buildTdpProbe(payloadJson: payload, serial: serial);

  RawDatagramSocket socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 20004, reuseAddress: true);
  } catch (_) {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  }
  socket.broadcastEnabled = true;

  final interfaces = <TdpInterface>[];
  try {
    for (final nic in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in nic.addresses) {
        // dart:io does not report the prefix length; a /24 is the home default.
        interfaces.add(TdpInterface(a.address, 24));
      }
    }
  } catch (_) {}

  final found = <String, TdpDevice>{};
  final sub = socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    Datagram? d;
    while ((d = socket.receive()) != null) {
      for (final device in parseTdpDatagram(d!.data, serial: serial, senderIp: d.address.address, keys: keys)) {
        found.putIfAbsent(device.mac, () => device);
      }
    }
  });
  for (final (host, port) in tdpTargets(interfaces)) {
    try {
      socket.send(packet, InternetAddress(host), port);
    } catch (_) {}
  }
  await Future<void>.delayed(window);
  await sub.cancel();
  socket.close();
  return [
    for (final d in found.values)
      LanDevice(ip: d.ip, mac: d.mac, md5: d.md5, httpPort: d.httpPort, raw: d.raw),
  ];
}
