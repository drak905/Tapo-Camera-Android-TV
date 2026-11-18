// mb.arch.bridge_contract, mb.security.bridge: loopback bridge over MediaSource.
//
// Spec decision: wrong key or bad path answers 404 (the baseline behaviour),
// not 403.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/relay_bridge.dart';
import 'package:tapo_tv/media/media_errors.dart';
import 'package:tapo_tv/media/media_source.dart';

class _Source implements MediaSource {
  _Source(this.build);
  final Stream<Uint8List> Function() build;
  int opened = 0;
  @override
  Stream<Uint8List> openTs() {
    opened++;
    return build();
  }
}

Uint8List _ts(int n) => Uint8List.fromList([0x47, 0x40, 0x00, 0x10, for (var i = 0; i < 184; i++) (i + n) & 0xff]);

Future<({int status, ContentType? type, String? cache, List<int> body})> _get(String url) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close();
    final body = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    return (
      status: res.statusCode,
      type: res.headers.contentType,
      cache: res.headers.value(HttpHeaders.cacheControlHeader),
      body: body,
    );
  } finally {
    client.close(force: true);
  }
}

void main() {
  late RelayBridge bridge;
  late Map<String, _Source> sources;
  final resolutions = <String?>[];

  setUp(() async {
    sources = {};
    resolutions.clear();
    bridge = RelayBridge.sources((id, resolution) {
      resolutions.add(resolution);
      return sources[id];
    });
    await bridge.start();
  });

  tearDown(() => bridge.stop());

  test('server bound to loopback only', () {
    expect(bridge.boundAddress, InternetAddress.loopbackIPv4);
    expect(bridge.urlFor('CAM1'), startsWith('http://127.0.0.1:'));
  });

  test('url carries a 24 char per-launch key', () {
    final k = Uri.parse(bridge.urlFor('CAM1')).queryParameters['k']!;
    expect(k, matches(RegExp(r'^[a-z0-9]{24}$')));
    final other = Uri.parse(bridge.urlFor('CAM1')).queryParameters['k'];
    expect(other, k, reason: 'stable within one launch');
  });

  test('rejects wrong key and bad path with 404', () async {
    sources['CAM1'] = _Source(() => Stream.value(_ts(1)));
    final good = Uri.parse(bridge.urlFor('CAM1'));
    final base = 'http://127.0.0.1:${good.port}';
    expect((await _get('$base/camera/CAM1.ts?k=wrongkey')).status, 404);
    expect((await _get('$base/camera/CAM1.ts')).status, 404);
    expect((await _get('$base/camera/CAM1.ts?k=')).status, 404);
    expect((await _get('$base/other/CAM1.ts?k=${good.queryParameters['k']}')).status, 404);
    expect((await _get('$base/camera/CAM1.mp4?k=${good.queryParameters['k']}')).status, 404);
    expect(sources['CAM1']!.opened, 0, reason: 'a rejected request never opens a camera session');
  });

  test('unknown camera answers 404', () async {
    expect((await _get(bridge.urlFor('NOPE'))).status, 404);
  });

  test('streams TS bytes of a fake MediaSource unchanged', () async {
    sources['CAM1'] = _Source(() => Stream.fromIterable([_ts(1), _ts(2), _ts(3)]));
    final r = await _get(bridge.urlFor('CAM1'));
    expect(r.status, 200);
    expect(r.type?.mimeType, 'video/mp2t');
    expect(r.cache, 'no-store');
    expect(r.body, [..._ts(1), ..._ts(2), ..._ts(3)]);
  });

  test('requested resolution reaches the source resolver', () async {
    sources['CAM1'] = _Source(() => Stream.value(_ts(1)));
    await _get(bridge.urlFor('CAM1', resolution: 'HD'));
    await _get(bridge.urlFor('CAM1'));
    expect(resolutions, ['HD', null]);
  });

  test('502 and lastErrors when source yields no bytes', () async {
    sources['CAM1'] = _Source(() => const Stream.empty());
    final r = await _get(bridge.urlFor('CAM1'));
    expect(r.status, 502);
    expect(bridge.lastErrors['CAM1'], isNotEmpty);
  });

  test('502 carries the typed source error into lastErrors', () async {
    sources['CAM1'] = _Source(() => Stream.error(const StreamLimitException('stream limit reached')));
    final r = await _get(bridge.urlFor('CAM1'));
    expect(r.status, 502);
    expect(bridge.lastErrors['CAM1'], contains('stream limit reached'));
  });

  test('lastErrors never contain the bridge key', () async {
    final url = bridge.urlFor('CAM1');
    final key = Uri.parse(url).queryParameters['k']!;
    sources['CAM1'] = _Source(() => Stream.error(Exception('GET $url failed')));
    await _get(url);
    expect(bridge.lastErrors['CAM1'], isNotNull);
    expect(bridge.lastErrors['CAM1'], isNot(contains(key)));
  });

  test('a good request clears the last error', () async {
    var fail = true;
    sources['CAM1'] = _Source(() => fail ? const Stream.empty() : Stream.value(_ts(1)));
    await _get(bridge.urlFor('CAM1'));
    expect(bridge.lastErrors.containsKey('CAM1'), isTrue);
    fail = false;
    await _get(bridge.urlFor('CAM1'));
    expect(bridge.lastErrors.containsKey('CAM1'), isFalse);
  });

  test('closing the player connection cancels the source subscription', () async {
    final cancelled = Completer<void>();
    late StreamController<Uint8List> controller;
    controller = StreamController<Uint8List>(onCancel: () => cancelled.complete());
    sources['CAM1'] = _Source(() => controller.stream);
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse(bridge.urlFor('CAM1')));
    final future = req.close();
    controller.add(_ts(1));
    final res = await future;
    final sub = res.listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();
    client.close(force: true);
    await cancelled.future.timeout(const Duration(seconds: 3));
  });

  test('stop closes the server', () async {
    final url = bridge.urlFor('CAM1');
    await bridge.stop();
    expect(() => _get(url), throwsA(isA<SocketException>()));
  });
}
