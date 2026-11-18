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

  static const int _packetSize = 188;

  final List<int> _pending = [];
  int? _pmtPid;
  int? _alawPid;
  TsAudioCodec? _codec;
  final List<int> _pes = [];
  bool _inPes = false;

  /// Codec found in the PMT, null until a PMT was seen.
  TsAudioCodec? get codec => _codec;

  /// Feeds TS bytes (any chunking, packets may straddle chunks) and returns
  /// the A-law payload bytes completed by them (PES header stripped, one
  /// byte per sample). Empty when there is no A-law audio.
  List<Uint8List> add(List<int> chunk) {
    _pending.addAll(chunk);
    final out = <Uint8List>[];
    var pos = 0;
    while (true) {
      while (pos < _pending.length && _pending[pos] != 0x47) {
        pos++;
      }
      if (_pending.length - pos < _packetSize) break;
      _packet(_pending, pos, out);
      pos += _packetSize;
    }
    _pending.removeRange(0, pos);
    return out;
  }

  void _packet(List<int> d, int o, List<Uint8List> out) {
    final pid = ((d[o + 1] & 0x1F) << 8) | d[o + 2];
    final start = (d[o + 1] & 0x40) != 0;
    final afc = (d[o + 3] >> 4) & 0x3;
    if ((afc & 0x1) == 0) return;
    var p = o + 4;
    if ((afc & 0x2) != 0) p += 1 + d[o + 4];
    final end = o + _packetSize;
    if (p >= end) return;
    if (pid == 0) {
      if (start) _pat(d, p, end);
    } else if (pid == _pmtPid) {
      if (start) _pmt(d, p, end);
    } else if (pid == _alawPid) {
      if (start) {
        _flush(out);
        _inPes = true;
      }
      if (_inPes) _pes.addAll(d.sublist(p, end));
    }
  }

  void _pat(List<int> d, int p, int end) {
    p += 1 + d[p]; // pointer field
    if (p + 8 > end || d[p] != 0) return;
    final len = ((d[p + 1] & 0x0F) << 8) | d[p + 2];
    final stop = (p + 3 + len - 4).clamp(0, end);
    for (var i = p + 8; i + 4 <= stop; i += 4) {
      final program = (d[i] << 8) | d[i + 1];
      if (program != 0) {
        _pmtPid = ((d[i + 2] & 0x1F) << 8) | d[i + 3];
        return;
      }
    }
  }

  void _pmt(List<int> d, int p, int end) {
    p += 1 + d[p];
    if (p + 12 > end || d[p] != 2) return;
    final len = ((d[p + 1] & 0x0F) << 8) | d[p + 2];
    final infoLen = ((d[p + 10] & 0x0F) << 8) | d[p + 11];
    final stop = (p + 3 + len - 4).clamp(0, end);
    var i = p + 12 + infoLen;
    TsAudioCodec? found;
    int? alawPid;
    while (i + 5 <= stop) {
      final type = d[i];
      final pid = ((d[i + 1] & 0x1F) << 8) | d[i + 2];
      final esInfo = ((d[i + 3] & 0x0F) << 8) | d[i + 4];
      if (type == 0x90) {
        found = TsAudioCodec.alaw;
        alawPid = pid;
      } else if (type == 0x0F && found == null) {
        found = TsAudioCodec.aac;
      }
      i += 5 + esInfo;
    }
    if (found != null) {
      _codec = found;
      _alawPid = alawPid;
    }
  }

  void _flush(List<Uint8List> out) {
    if (_inPes && _pes.length >= 9 && _pes[0] == 0 && _pes[1] == 0 && _pes[2] == 1) {
      final payloadStart = 9 + _pes[8];
      if (payloadStart < _pes.length) {
        out.add(Uint8List.fromList(_pes.sublist(payloadStart)));
      }
    }
    _pes.clear();
    _inPes = false;
  }

  /// Detects the audio codec in [ts] (PAT then PMT), or null.
  static TsAudioCodec? probeCodec(List<int> ts) {
    final tap = TsAudioTap();
    tap.add(ts);
    return tap.codec;
  }
}
