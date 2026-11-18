import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../media/media_errors.dart';
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
  InternetAddress? get boundAddress => _server?.address;

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

  /// Camera id from `/camera/{id}.ts?k={key}`, or null (wrong key / path).
  String? _deviceIdOf(HttpRequest request) {
    final segments = request.uri.pathSegments;
    if (request.method != 'GET' ||
        request.uri.queryParameters['k'] != _key ||
        segments.length != 2 ||
        segments[0] != 'camera' ||
        !segments[1].endsWith('.ts') ||
        segments[1].length <= 3) {
      return null;
    }
    return segments[1].substring(0, segments[1].length - 3);
  }

  String _redact(Object error) => redactSecrets(error.toString(), [_key]);

  Future<void> _handleSource(
    HttpRequest request,
    MediaSource? Function(String deviceId, String? resolution) resolve,
  ) async {
    final response = request.response;
    final deviceId = _deviceIdOf(request);
    final source = deviceId == null ? null : resolve(deviceId, request.uri.queryParameters['r']);
    if (deviceId == null || source == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    // Answer only after the first TS bytes, so a camera failure becomes an
    // HTTP error with a readable reason instead of an empty stream.
    final video = StreamIterator(source.openTs());
    try {
      if (!await video.moveNext()) throw const MediaException('Camera sent no video');
    } catch (e) {
      lastErrors[deviceId] = _redact(e);
      await video.cancel();
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }
    lastErrors.remove(deviceId);
    response.headers.contentType = ContentType('video', 'mp2t');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    // Body runs until the connection closes (no chunking), so the raw socket
    // can be watched: a player that disconnects ends the camera session at
    // once instead of at the next write.
    response.headers.chunkedTransferEncoding = false;
    response.persistentConnection = false;
    final Socket socket;
    try {
      socket = await response.detachSocket();
    } catch (e) {
      await video.cancel();
      return;
    }
    var playerGone = false;
    void onGone() {
      if (playerGone) return;
      playerGone = true;
      unawaited(video.cancel());
    }

    final watch = socket.listen((_) {}, onError: (Object _) => onGone(), onDone: onGone, cancelOnError: true);
    try {
      socket.add(video.current);
      while (!playerGone && await video.moveNext()) {
        socket.add(video.current);
        await socket.flush();
      }
    } catch (e) {
      if (!playerGone) lastErrors[deviceId] = _redact(e);
    } finally {
      await video.cancel();
      await watch.cancel();
      try {
        await socket.close();
      } catch (_) {}
      socket.destroy();
    }
  }
  Future<void> _handle(HttpRequest request) async {    final response = request.response;
    final resolveSource = _resolveSource;
    if (resolveSource != null) {
      await _handleSource(request, resolveSource);
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
