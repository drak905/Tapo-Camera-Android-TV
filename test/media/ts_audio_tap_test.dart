// mb.audio.exo_support (PMT 0x90 detected as A-law), mb.audio.alaw_path (tap, P2)
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/media/audio/ts_audio_tap.dart';

import 'helpers/ts_builder.dart';

Uint8List _stream({required int audioType, required List<int> audio}) => concat([
      patPacket(),
      pmtPacket(audioType: audioType),
      ...pesPackets(0x102, audio),
      ...pesPackets(0x102, audio, pts: 90000 + 1800),
    ]);

void main() {
  test('PMT with stream_type 0x90 is detected as alaw', () {
    expect(TsAudioTap.probeCodec(_stream(audioType: 0x90, audio: [1, 2, 3])), TsAudioCodec.alaw);
  });

  test('PMT with stream_type 0x0F is detected as aac', () {
    expect(TsAudioTap.probeCodec(_stream(audioType: 0x0F, audio: [1, 2, 3])), TsAudioCodec.aac);
  });

  test('stream without PMT has no codec', () {
    expect(TsAudioTap.probeCodec(patPacket()), isNull);
  });

  test('extracts pcm_alaw pes payloads from sample ts', () {
    final alaw = List<int>.generate(160, (i) => i); // 20 ms at 8 kHz, 1 byte per sample
    final tap = TsAudioTap();
    final out = tap.add(_stream(audioType: 0x90, audio: alaw));
    expect(tap.codec, TsAudioCodec.alaw);
    // The first PES is complete once the second one starts; the second flushes with more data.
    expect(out.isNotEmpty, isTrue);
    expect(out.first, alaw);
  });

  test('packets split across chunks are reassembled', () {
    final alaw = List<int>.generate(300, (i) => (i * 7) & 0xFF);
    final bytes = _stream(audioType: 0x90, audio: alaw);
    final tap = TsAudioTap();
    final out = <Uint8List>[];
    for (var i = 0; i < bytes.length; i += 61) {
      out.addAll(tap.add(bytes.sublist(i, i + 61 > bytes.length ? bytes.length : i + 61)));
    }
    expect(out.first, alaw);
  });

  test('aac stream ignored', () {
    final tap = TsAudioTap();
    final out = tap.add(_stream(audioType: 0x0F, audio: List<int>.filled(100, 9)));
    expect(tap.codec, TsAudioCodec.aac);
    expect(out, isEmpty);
  });
}
