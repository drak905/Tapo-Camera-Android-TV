// Wires the REAL local-control classes (CameraTransport, CameraControlClient,
// LocalControl) to MockCamera over loopback TLS.
//
// The production CameraLink (TLS socket with certificate pinning on first use)
// is not written yet; [TlsCameraLink] is the minimal HTTP/1.1 keep-alive client
// the tests need. It accepts the mock's self-signed certificate and exposes its
// DER so CameraTransport can pin it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tapo_tv/api/camera_control_client.dart';
import 'package:tapo_tv/api/camera_transport.dart';

import '../../fixtures/mock_camera.dart';

class MemoryPins implements PinStore {
  final Map<String, String> pins = {};

  @override
  String? read(String hostPort) => pins[hostPort];

  @override
  Future<void> write(String hostPort, String sha256Hex) async => pins[hostPort] = sha256Hex;
}

/// One keep-alive HTTPS connection to a camera (mock).
class TlsCameraLink implements CameraLink {
  TlsCameraLink._(this._socket, this._host, this._port, this.peerCertificateDer) {
    _it = StreamIterator<Uint8List>(_socket);
  }

  final SecureSocket _socket;
  final String _host;
  final int _port;
  late final StreamIterator<Uint8List> _it;
  Uint8List _buf = Uint8List(0);

  @override
  final Uint8List peerCertificateDer;

  static Future<CameraLink> connect(String host, int port) async {
    final socket = await SecureSocket.connect(
      host,
      port,
      onBadCertificate: (_) => true,
      timeout: const Duration(milliseconds: 1200),
    );
    final der = socket.peerCertificate?.der;
    if (der == null) {
      socket.destroy();
      throw StateError('camera sent no certificate');
    }
    return TlsCameraLink._(socket, host, port, Uint8List.fromList(der));
  }

  Future<void> _fill() async {
    if (!await _it.moveNext()) throw const SocketException('connection closed by camera');
    final chunk = _it.current;
    _buf = Uint8List.fromList([..._buf, ...chunk]);
  }

  int _headEnd() {
    for (var i = 0; i + 3 < _buf.length; i++) {
      if (_buf[i] == 13 && _buf[i + 1] == 10 && _buf[i + 2] == 13 && _buf[i + 3] == 10) return i;
    }
    return -1;
  }

  Future<ChannelResponse> _read() async {
    var end = _headEnd();
    while (end < 0) {
      await _fill();
      end = _headEnd();
    }
    final head = latin1.decode(_buf.sublist(0, end)).split('\r\n');
    final status = int.parse(head.first.split(' ')[1]);
    final headers = <String, String>{};
    for (final line in head.skip(1)) {
      final i = line.indexOf(':');
      if (i > 0) headers[line.substring(0, i).trim().toLowerCase()] = line.substring(i + 1).trim();
    }
    final length = int.tryParse(headers['content-length'] ?? '') ?? 0;
    while (_buf.length < end + 4 + length) {
      await _fill();
    }
    final body = Uint8List.fromList(_buf.sublist(end + 4, end + 4 + length));
    _buf = Uint8List.fromList(_buf.sublist(end + 4 + length));
    return ChannelResponse(status, body, headers);
  }

  @override
  Future<ChannelResponse> send(
    String path,
    List<int> body,
    Map<String, String> headers, {
    required Duration timeout,
  }) async {
    final head = StringBuffer('POST $path HTTP/1.1\r\nHost: $_host:$_port\r\n');
    final names = headers.keys.map((k) => k.toLowerCase()).toSet();
    if (!names.contains('content-type')) head.write('Content-Type: application/json\r\n');
    headers.forEach((k, v) => head.write('$k: $v\r\n'));
    head.write('Content-Length: ${body.length}\r\nConnection: keep-alive\r\n\r\n');
    _socket.add(latin1.encode(head.toString()));
    _socket.add(body);
    await _socket.flush();
    return _read().timeout(timeout);
  }

  @override
  void close() => _socket.destroy();
}

/// CameraTransport (TOFU pinning, one link) to [cam].
CameraTransport transportFor(MockCamera cam, {MemoryPins? pins, int? port}) => CameraTransport(
      host: cam.host,
      port: port ?? cam.port,
      pins: pins ?? MemoryPins(),
      linkFactory: TlsCameraLink.connect,
      timeout: const Duration(seconds: 10),
    );

/// A real control client against [cam]. Backoff sleeps are skipped.
CameraControlClient controlClientFor(
  MockCamera cam, {
  String password = '',
  String? lat,
  LocalProtocolHint hint = LocalProtocolHint.probe,
  int userHashType = 0,
  MemoryPins? pins,
  int? port,
}) =>
    CameraControlClient(
      channel: transportFor(cam, pins: pins, port: port),
      secrets: LocalSecrets(password: password, lat: lat),
      hint: hint,
      userHashType: userHashType,
      sleep: (_) async {},
    );
