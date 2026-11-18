// Seam between the cloud clients (TapoCloud, IotThingsClient,
// CloudPassthrough) and dart:io, so tests can use an in-memory fake.

import 'dart:typed_data';

/// One HTTPS request to a TP-Link cloud host.
class CloudRequest {
  const CloudRequest({
    required this.method,
    required this.uri,
    this.headers = const {},
    this.body,
    this.timeout = const Duration(seconds: 15),
  });
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Uint8List? body;
  final Duration timeout;
}

/// Raw reply: HTTP status and body bytes (capped at 16 MiB by the real one).
class CloudResponse {
  const CloudResponse(this.status, this.body);
  final int status;
  final Uint8List body;
}

/// Sends [CloudRequest]s. The real implementation wraps `HttpClient` with the
/// TLS context from `TapoCloud.buildContext`; it never disables verification.
abstract class CloudTransport {
  Future<CloudResponse> send(CloudRequest request);
  void close();
}