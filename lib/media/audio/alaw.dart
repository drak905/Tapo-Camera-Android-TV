/// G.711 A-law decoding (P2: audio tap).
library;

import 'dart:typed_data';

/// One A-law code to a signed 16-bit sample: `code ^= 0x55; m = (code & 0xF)
/// << 4; seg = (code & 0x70) >> 4; seg == 0: m += 8; seg == 1: m += 0x108;
/// else m = (m + 0x108) << (seg - 1); value = (code & 0x80) ? m : -m`.
int alawDecode(int code) => throw UnimplementedError();

/// The 256-entry decode table.
Int16List alawTable() => throw UnimplementedError();

/// Decodes A-law bytes to little-endian PCM16 (2 bytes per input byte).
Uint8List alawToPcm16le(List<int> alaw) => throw UnimplementedError();
