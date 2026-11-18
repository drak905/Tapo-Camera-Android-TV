// Seam between the cloud clients (TapoCloud, IotThingsClient,
// CloudPassthrough) and dart:io, so tests can use an in-memory fake.

import 'dart:async';
import 'dart:io';
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
/// Largest accepted cloud reply.
const maxCloudResponseBytes = 16 * 1024 * 1024;

/// Cloud failed before an HTTP answer arrived (DNS, TLS, timeout...). The
/// message never contains the request.
class CloudTransportError implements Exception {
  const CloudTransportError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// [CloudTransport] over `dart:io`. TLS verification is always on; [context]
/// adds the TP-Link cloud roots.
class HttpCloudTransport implements CloudTransport {
  HttpCloudTransport(SecurityContext context)
      : _http = HttpClient(context: context)
          ..connectionTimeout = const Duration(seconds: 15)
          ..idleTimeout = const Duration(seconds: 30);

  final HttpClient _http;

  @override
  Future<CloudResponse> send(CloudRequest request) async {
    try {
      return await _send(request).timeout(request.timeout);
    } on TimeoutException {
      throw const CloudTransportError('The Tapo cloud did not answer in time');
    } on SocketException catch (e) {
      throw CloudTransportError('Network error: ${e.osError?.message ?? e.message}');
    } on HandshakeException catch (e) {
      throw CloudTransportError('Secure connection failed: ${e.message}');
    } on TlsException catch (e) {
      throw CloudTransportError('Secure connection failed: ${e.message}');
    } on HttpException catch (e) {
      throw CloudTransportError('Network error: ${e.message}');
    }
  }

  Future<CloudResponse> _send(CloudRequest request) async {
    final req = await _http.openUrl(request.method, request.uri);
    request.headers.forEach((k, v) => req.headers.set(k, v, preserveHeaderCase: true));
    final body = request.body;
    if (body != null) {
      req.contentLength = body.length;
      req.add(body);
    }
    final response = await req.close();
    final out = BytesBuilder(copy: false);
    await for (final chunk in response) {
      out.add(chunk);
      if (out.length > maxCloudResponseBytes) {
        throw const CloudTransportError('The Tapo cloud answer is too large');
      }
    }
    return CloudResponse(response.statusCode, out.takeBytes());
  }

  @override
  void close() => _http.close(force: true);
}