// mb.local.multipart_framing, mb.tvbaseline.gaps (json parts never video).
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/media/media_errors.dart';
import 'package:tapo_tv/media/multipart_reader.dart';

import 'helpers/fakes.dart';

List<MultipartPart> _readChunked(List<int> data, int seed, {int maxChunk = 97}) {
  final reader = MultipartReader();
  final rng = Random(seed);
  final out = <MultipartPart>[];
  var i = 0;
  while (i < data.length) {
    final n = min(data.length - i, 1 + rng.nextInt(maxChunk));
    out.addAll(reader.add(data.sublist(i, i + n)));
    i += n;
  }
  return out;
}

void main() {
  test('arbitrary chunking yields the same parts', () {
    final payloads = [tsPacket(1), tsPacket(2), Uint8List.fromList(utf8.encode('{"type":"notification"}'))];
    final wire = <int>[
      ...devicePart(payloads[0], headers: [('X-Data-Sequence', '1')]),
      ...devicePart(payloads[1], headers: [('X-Data-Sequence', '2')]),
      ...devicePart(payloads[2], contentType: 'application/json'),
    ];
    for (final seed in [1, 2, 3, 99]) {
      final parts = _readChunked(wire, seed);
      expect(parts, hasLength(3), reason: 'seed $seed');
      expect(parts[0].body, payloads[0]);
      expect(parts[0].header('x-data-sequence'), '1');
      expect(parts[1].body, payloads[1]);
      expect(parts[2].contentType, 'application/json');
      expect(parts[2].isJson, isTrue);
      expect(parts[0].isVideo, isTrue);
    }
  });

  test('single byte chunks work', () {
    final wire = devicePart(tsPacket());
    final reader = MultipartReader();
    final out = <MultipartPart>[];
    for (final b in wire) {
      out.addAll(reader.add([b]));
    }
    expect(out, hasLength(1));
    expect(out.single.body, tsPacket());
  });

  test('missing content-length throws', () {
    final bad = bytesOf('----device-stream-boundary--\r\nContent-Type: video/mp2t\r\n\r\nabc\r\n');
    expect(() => MultipartReader().add(bad), throwsA(isA<MultipartFormatException>()));
  });

  test('negative content-length throws', () {
    final bad = bytesOf('----device-stream-boundary--\r\nContent-Type: video/mp2t\r\nContent-Length: -4\r\n\r\nabc\r\n');
    expect(() => MultipartReader().add(bad), throwsA(isA<MultipartFormatException>()));
  });

  test('part larger than 16 MiB throws', () {
    final bad = bytesOf(
        '----device-stream-boundary--\r\nContent-Type: video/mp2t\r\nContent-Length: ${16 * 1024 * 1024 + 1}\r\n\r\n');
    expect(() => MultipartReader().add(bad), throwsA(isA<MultipartFormatException>()));
  });

  test('junk and blank lines between parts are ignored', () {
    final wire = <int>[
      ...bytesOf('\r\njunk line\r\n\r\n'),
      ...devicePart(tsPacket(1)),
      ...bytesOf('\r\n\r\nnoise\r\n'),
      ...devicePart(tsPacket(2)),
      ...bytesOf('----device-stream-boundary----\r\n'),
    ];
    final parts = _readChunked(wire, 5);
    expect(parts.map((p) => p.body).toList(), [tsPacket(1), tsPacket(2)]);
  });

  test('header lookup is case-insensitive and names are kept', () {
    final p = MultipartReader().add(devicePart(tsPacket(), headers: [('X-If-Encrypt', '1')])).single;
    expect(p.header('x-if-encrypt'), '1');
    expect(p.headers.keys, contains('X-If-Encrypt'));
  });

  test('json parts are not emitted as video', () async {
    final wire = <int>[
      ...jsonPart({'type': 'response', 'seq': 1}),
      ...devicePart(tsPacket(1)),
      ...devicePart(utf8.encode('xx'), contentType: 'audio/mp2t'),
      ...devicePart(tsPacket(2)),
    ];
    final parts = MultipartReader().bind(Stream.value(wire));
    final video = await videoBytes(parts).toList();
    expect(video, [tsPacket(1), tsPacket(2)]);
  });
}
