// Minimal MPEG-TS writer for tests: PAT, PMT, PES packets.
import 'dart:typed_data';

int _crc32mpeg(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b << 24;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x80000000) != 0 ? ((crc << 1) ^ 0x04C11DB7) : (crc << 1);
      crc &= 0xFFFFFFFF;
    }
  }
  return crc;
}

List<int> _section(int tableId, int idExt, List<int> body) {
  final len = 5 + body.length + 4;
  final head = [tableId, 0xB0 | (len >> 8), len & 0xFF, idExt >> 8, idExt & 0xFF, 0xC1, 0x00, 0x00, ...body];
  final crc = _crc32mpeg(head);
  return [...head, crc >> 24, (crc >> 16) & 0xFF, (crc >> 8) & 0xFF, crc & 0xFF];
}

Uint8List _packet(int pid, List<int> payload, {bool start = false, int cc = 0}) {
  assert(payload.length <= 184);
  final out = Uint8List(188)..fillRange(0, 188, 0xFF);
  out[0] = 0x47;
  out[1] = (start ? 0x40 : 0) | (pid >> 8);
  out[2] = pid & 0xFF;
  out[3] = 0x10 | (cc & 0xF);
  out.setRange(4, 4 + payload.length, payload);
  return out;
}

Uint8List patPacket({int pmtPid = 0x100}) =>
    _packet(0, [0, ..._section(0, 1, [0, 1, 0xE0 | (pmtPid >> 8), pmtPid & 0xFF])], start: true);

/// PMT with H.264 video on [videoPid] and one audio stream of [audioType] on [audioPid].
Uint8List pmtPacket({int pmtPid = 0x100, int videoPid = 0x101, int audioPid = 0x102, required int audioType}) {
  final body = [
    0xE0 | (videoPid >> 8), videoPid & 0xFF, 0xF0, 0x00, // PCR pid, program info length 0
    0x1B, 0xE0 | (videoPid >> 8), videoPid & 0xFF, 0xF0, 0x00,
    audioType, 0xE0 | (audioPid >> 8), audioPid & 0xFF, 0xF0, 0x00,
  ];
  return _packet(pmtPid, [0, ..._section(2, 1, body)], start: true);
}

/// One audio PES (stream id 0xC0) with a PTS, split over as many packets as needed.
List<Uint8List> pesPackets(int pid, List<int> payload, {int pts = 90000, int streamId = 0xC0}) {
  final pts5 = [
    0x21 | (((pts >> 30) & 0x7) << 1),
    (pts >> 22) & 0xFF,
    (((pts >> 15) & 0x7F) << 1) | 1,
    (pts >> 7) & 0xFF,
    ((pts & 0x7F) << 1) | 1,
  ];
  final pes = [0, 0, 1, streamId, ((payload.length + 8) >> 8) & 0xFF, (payload.length + 8) & 0xFF, 0x80, 0x80, 5, ...pts5, ...payload];
  final out = <Uint8List>[];
  for (var i = 0, cc = 0; i < pes.length; i += 184, cc++) {
    final end = i + 184 < pes.length ? i + 184 : pes.length;
    final chunk = pes.sublist(i, end);
    if (chunk.length < 184) {
      // adaptation field stuffing so the packet carries exactly the payload
      final stuff = 184 - chunk.length;
      final af = stuff == 1 ? [0] : [stuff - 1, 0x00, ...List.filled(stuff - 2, 0xFF)];
      final p = Uint8List(188)..[0] = 0x47;
      p[1] = (i == 0 ? 0x40 : 0) | (pid >> 8);
      p[2] = pid & 0xFF;
      p[3] = 0x30 | (cc & 0xF);
      p.setRange(4, 4 + af.length, af);
      p.setRange(4 + af.length, 188, chunk);
      out.add(p);
    } else {
      out.add(_packet(pid, chunk, start: i == 0, cc: cc));
    }
  }
  return out;
}

Uint8List concat(Iterable<List<int>> chunks) => Uint8List.fromList([for (final c in chunks) ...c]);
