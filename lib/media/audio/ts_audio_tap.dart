/// Finds the audio elementary stream in camera MPEG-TS (P2).
library;

import 'dart:typed_data';

enum TsAudioCodec {
  /// PMT stream_type 0x90 (G.711 A-law, 8 kHz mono); ExoPlayer drops it.
  alaw,

  /// PMT stream_type 0x0F (AAC ADTS); ExoPlayer plays it, no tap needed.
  aac,
}

/// Walks 188-byte TS packets, parses PAT/PMT, reassembles PES payloads of the
/// A-law PID. AAC and unknown audio are ignored by the tap.
class TsAudioTap {
  TsAudioTap();

  /// Codec found in the PMT, null until a PMT was seen.
  TsAudioCodec? get codec => throw UnimplementedError();

  /// Feeds TS bytes (any chunking, packets may straddle chunks) and returns
  /// the A-law payload bytes completed by them (PES header stripped, one
  /// byte per sample). Empty when there is no A-law audio.
  List<Uint8List> add(List<int> chunk) => throw UnimplementedError();

  /// Detects the audio codec in [ts] (PAT then PMT), or null.
  static TsAudioCodec? probeCodec(List<int> ts) => throw UnimplementedError();
}
