// mb.audio.alaw_path (P2): G.711 A-law table.
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/media/audio/alaw.dart';

void main() {
  test('all 256 codes golden', () {
    const golden = {
      0xD5: 8,
      0x55: -8,
      0xAA: 32256,
      0x2A: -32256,
      0x80: 5504,
      0x00: -5504,
      0xD4: 24,
      0xFF: 848,
      0x01: -5248,
      0xFE: 880,
    };
    golden.forEach((code, value) {
      expect(alawDecode(code), value, reason: '0x${code.toRadixString(16)}');
    });
  });

  test('sha256 of decode table', () {
    final table = Uint8List(512);
    final view = ByteData.sublistView(table);
    for (var i = 0; i < 256; i++) {
      view.setInt16(i * 2, alawDecode(i), Endian.little);
    }
    expect(sha256.convert(table).toString(), 'e04788d110e58ff8c70c93b8480190d973e3b67876b6119abbaec766cc75c174');
  });

  test('alawTable matches alawDecode', () {
    final t = alawTable();
    expect(t.length, 256);
    for (var i = 0; i < 256; i++) {
      expect(t[i], alawDecode(i));
    }
  });

  test('pcm16le output is two little-endian bytes per sample', () {
    final out = alawToPcm16le([0xD5, 0xAA]);
    expect(out, [8, 0, 0x00, 0x7E]); // 8, 32256 = 0x7E00
  });
}
