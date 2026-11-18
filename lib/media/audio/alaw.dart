/// G.711 A-law decoding (P2: audio tap).
library;

import 'dart:typed_data';

/// One A-law code to a signed 16-bit sample: `code ^= 0x55; m = (code & 0xF)
/// << 4; seg = (code & 0x70) >> 4; seg == 0: m += 8; seg == 1: m += 0x108;
/// else m = (m + 0x108) << (seg - 1); value = (code & 0x80) ? m : -m`.
int alawDecode(int code) {
  final c = (code & 0xFF) ^ 0x55;
  var m = (c & 0x0F) << 4;
  final seg = (c & 0x70) >> 4;
  if (seg == 0) {
    m += 8;
  } else if (seg == 1) {
    m += 0x108;
  } else {
    m = (m + 0x108) << (seg - 1);
  }
  return (c & 0x80) != 0 ? m : -m;
}

final Int16List _table = Int16List.fromList([for (var i = 0; i < 256; i++) alawDecode(i)]);

/// The 256-entry decode table.
Int16List alawTable() => Int16List.fromList(_table);

/// Decodes A-law bytes to little-endian PCM16 (2 bytes per input byte).
Uint8List alawToPcm16le(List<int> alaw) {
  final out = Uint8List(alaw.length * 2);
  final view = ByteData.sublistView(out);
  for (var i = 0; i < alaw.length; i++) {
    view.setInt16(i * 2, _table[alaw[i] & 0xFF], Endian.little);
  }
  return out;
}
