import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'media_source.dart';

/// Plain MPEG-TS over HTTP (demo/test mode only, e.g. ffmpeg on the host
/// reached through `adb reverse tcp:8099`). Served to ExoPlayer through the
/// RelayBridge so the native player keeps accepting bridge URLs only.
class HttpTsSource implements MediaSource {
  HttpTsSource(this.url, {this.connectTimeout = const Duration(seconds: 5)});

  final Uri url;
  final Duration connectTimeout;

  @override
  Stream<Uint8List> openTs() {
    final client = HttpClient()..connectionTimeout = connectTimeout;
    StreamSubscription<List<int>>? sub;
    late final StreamController<Uint8List> out;
    out = StreamController<Uint8List>(
      onListen: () async {
        try {
          final res = await (await client.getUrl(url)).close().timeout(connectTimeout);
          if (res.statusCode != HttpStatus.ok) {
            await res.drain<void>();
            throw HttpException('demo stream answered HTTP ${res.statusCode}', uri: url);
          }
          sub = res.listen(
            (chunk) => out.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk)),
            onError: (Object e, StackTrace s) => out.addError(e, s),
            onDone: () {
              client.close(force: true);
              out.close();
            },
            cancelOnError: true,
          );
          out.onPause = () => sub?.pause();
          out.onResume = () => sub?.resume();
        } catch (e, s) {
          client.close(force: true);
          if (!out.isClosed) {
            out.addError(e, s);
            await out.close();
          }
        }
      },
      onCancel: () async {
        await sub?.cancel();
        client.close(force: true);
      },
    );
    return out.stream;
  }
}
