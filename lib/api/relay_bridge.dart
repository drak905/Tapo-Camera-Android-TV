import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../media/media_source.dart';
import 'tapo_cloud.dart';

/// Serves each camera's cloud relay as a plain MPEG-TS HTTP stream on the
/// loopback interface so the native player (ExoPlayer) can decode it.
///
/// Loopback is shared by every app on the device, so every URL carries a
/// random per-launch key and requests without it are rejected.
class RelayBridge {
  RelayBridge(this._resolve) : _resolveSource = null;

  /// Source-based bridge: [resolve] returns the [MediaSource] (local :8800,
  /// relay, VOD) for a camera id and the requested resolution (`r=HD|VGA` in
  /// the URL, null when absent). Contract: bound to 127.0.0.1 only; every URL
  /// needs the per-launch key `k` (wrong key, bad path or unknown camera: 404);
  /// the response is `video/mp2t`, `Cache-Control: no-store`, answered only
  /// after the first TS bytes (no bytes: 502 and `lastErrors[id]` with secrets
  /// redacted); only what `openTs` emits is forwarded.
  RelayBridge.sources(MediaSource? Function(String deviceId, String? resolution) resolve)
      : _resolve = ((_) => null),
        _resolveSource = resolve;

  /// Returns the cloud client, base URL and device for a camera id.
  final (TapoCloud, String, Map<String, dynamic>)? Function(String deviceId) _resolve;
  final MediaSource? Function(String deviceId, String? resolution)? _resolveSource;

  /// Address the server is bound to (127.0.0.1), null before [start].
  InternetAddress? get boundAddress => throw UnimplementedError();

  HttpServer? _server;

  /// Last relay failure per device id, shown when the player reports an error.
  final Map<String, String> lastErrors = {};
  final String _key = List.generate(24, (_) => Random.secure().nextInt(36).toRadixString(36)).join();

  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle, onError: (_) {});
    _server = server;
  }

  /// URL for [deviceId]; [resolution] (`HD` or `VGA`) is added as `r=` for
  /// source-based bridges.
  String urlFor(String deviceId, {String? resolution}) {
    final port = _server?.port ?? 0;
    return 'http://127.0.0.1:$port/camera/${Uri.encodeComponent(deviceId)}.ts'
        '?k=$_key&n=${DateTime.now().microsecondsSinceEpoch}'
        '${resolution == null ? '' : '&r=$resolution'}';
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    if (_resolveSource != null) {
      // Source-based handling is the player lane's GREEN phase.
      response.statusCode = HttpStatus.notImplemented;
      await response.close();
      return;
    }
    final segments = request.uri.pathSegments;
    if (request.uri.queryParameters['k'] != _key ||
        segments.length != 2 ||
        segments[0] != 'camera' ||
        !segments[1].endsWith('.ts')) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final deviceId = segments[1].substring(0, segments[1].length - 3);
    final target = _resolve(deviceId);
    if (target == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final (client, baseUrl, device) = target;
    // Wait for the first video bytes before answering, so a relay failure
    // becomes an HTTP error with a readable reason instead of an empty file.
    final video = StreamIterator(client.openVideoStream(baseUrl, device));
    try {
      if (!await video.moveNext()) throw TapoException('Camera sent no video');
    } catch (e) {
      lastErrors[deviceId] = e.toString();
      await video.cancel();
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }
    lastErrors.remove(deviceId);
    response.bufferOutput = false;
    response.headers.contentType = ContentType('video', 'mp2t');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    Stream<List<int>> rest() async* {
      yield video.current;
      while (await video.moveNext()) {
        yield video.current;
      }
    }

    try {
      await response.addStream(rest());
    } catch (e) {
      // Relay or player went away. The player view restarts the stream
      // while it is still on screen.
      lastErrors[deviceId] = e.toString();
    } finally {
      await video.cancel();
    }
    try {
      await response.close();
    } catch (_) {}
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }
}
