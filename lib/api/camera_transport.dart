// Local HTTPS transport to a camera: headers, TOFU certificate pin,
// reconnect-once, one request at a time. Spec: hc.local.headers_tls.

import 'dart:typed_data';

/// Reply to one local request.
class ChannelResponse {
  const ChannelResponse(this.status, this.body, [this.headers = const {}]);
  final int status;
  final Uint8List body;
  final Map<String, String> headers;
}

/// What the control client needs from a transport (so tests can script one).
abstract class CameraChannel {
  /// POSTs [body] to [path] (`/` or `/stok=<stok>/ds`). Extra [headers] are
  /// merged over the standard camera headers.
  Future<ChannelResponse> post(
    String path,
    List<int> body, {
    Map<String, String> headers = const {},
  });
  void close();
}

/// Stores `sha256(DER)` of a camera leaf certificate per `host:port`.
abstract class PinStore {
  String? read(String hostPort);
  Future<void> write(String hostPort, String sha256Hex);
}

/// One physical connection (kept alive). The real one wraps `HttpClient` with
/// `badCertificateCallback` that only records the certificate.
abstract class CameraLink {
  /// DER bytes of the leaf certificate presented on connect.
  Uint8List get peerCertificateDer;

  /// Sends one request. Reset/EOF throws `SocketException`; a timeout throws
  /// `TimeoutException`.
  Future<ChannelResponse> send(
    String path,
    List<int> body,
    Map<String, String> headers, {
    required Duration timeout,
  });
  void close();
}

typedef CameraLinkFactory = Future<CameraLink> Function(String host, int port);

/// Real [CameraChannel]: pins on first contact (TOFU), raises
/// `CertificateMismatch` when the certificate changes, resends once after a
/// stale socket, never retries timeouts (10 s), serialises requests.
class CameraTransport implements CameraChannel {
  CameraTransport({
    required this.host,
    this.port = 443,
    required this.pins,
    required this.linkFactory,
    this.timeout = const Duration(seconds: 10),
  });

  final String host;
  final int port;
  final PinStore pins;
  final CameraLinkFactory linkFactory;
  final Duration timeout;

  @override
  Future<ChannelResponse> post(
    String path,
    List<int> body, {
    Map<String, String> headers = const {},
  }) =>
      throw UnimplementedError();

  @override
  void close() => throw UnimplementedError();
}