// Demo mode: the TS demo stream reaches ExoPlayer through the RelayBridge
// (the native player only accepts bridge URLs, PlayerPolicy.isBridgeUrl).

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/relay_bridge.dart';
import 'package:tapo_tv/media/http_ts_source.dart';

void main() {
  late HttpServer server;
  final payload = Uint8List.fromList(List<int>.generate(188 * 4, (i) => i == 0 || i % 188 == 0 ? 0x47 : i & 0xff));
  final paths = <String>[];

  setUp(() async {
    paths.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      paths.add(req.uri.toString());
      req.response.headers.contentType = ContentType('video', 'mp2t');
      req.response.add(payload);
      await req.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  test('HttpTsSource yields the bytes of the URL', () async {
    final src = HttpTsSource(Uri.parse('http://127.0.0.1:${server.port}/live.ts?cam=demo-A'));
    final got = await src.openTs().fold<List<int>>([], (a, b) => a..addAll(b));
    expect(got, payload);
    expect(paths.single, '/live.ts?cam=demo-A');
  });

  test('HttpTsSource fails on a non-200 answer', () async {
    await server.close(force: true);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.statusCode = 404;
      await req.response.close();
    });
    final src = HttpTsSource(Uri.parse('http://127.0.0.1:${server.port}/live.ts'));
    await expectLater(src.openTs().drain<void>(), throwsA(isA<HttpException>()));
  });

  test('demo stream is served through the bridge URL with the key', () async {
    final bridge = RelayBridge.sources(
        (id, _) => HttpTsSource(Uri.parse('http://127.0.0.1:${server.port}/live.ts?cam=${Uri.encodeComponent(id)}')));
    await bridge.start();
    addTearDown(bridge.stop);
    final url = Uri.parse(bridge.urlFor('demo-A'));
    expect(url.host, '127.0.0.1');
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final res = await (await client.getUrl(url)).close().timeout(const Duration(seconds: 5));
    expect(res.statusCode, 200);
    final got = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    expect(got, payload);
    expect(paths.single, '/live.ts?cam=demo-A');
  });
}
