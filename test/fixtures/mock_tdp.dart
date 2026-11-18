// Mock TDP v2 responder (Tapo camera LAN discovery) on UDP 127.0.0.1:<port>.
// Port of tests/fixtures/mock_tdp.py of the Windows app.
//
// Answers every valid probe like a Tapo camera: 16-byte big-endian header
// (version 2, opcode 1, reply flag 0x02, request serial, CRC32 seeded with
// 0x5A6B7C8D) + JSON {"error_code":0,"result":{...}}. Probes with a bad CRC or
// wrong version are ignored and counted in [badProbes].
//
// With encrypt = true (default) the reply carries encrypt_info: a random 32-byte
// key||iv encrypted with RSA-OAEP-SHA1 to the probe's rsa_key, and the JSON
// {"device_id","http_port",...} encrypted with AES-128-CBC/PKCS7. Like real C200
// firmware 1.5.7 the top-level device_id is MD5(deviceId) in UPPER case, also next
// to encrypt_info; topLevelId = false omits it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'fx_crypto.dart';

const int tdpCrcSeed = 0x5A6B7C8D;

final List<int> _crcTable = () {
  final t = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

int crc32(List<int> data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// CRC of a packet with bytes 12..15 replaced by the seed.
int tdpCrc(Uint8List packet) {
  final b = Uint8List.fromList(packet);
  ByteData.sublistView(b).setUint32(12, tdpCrcSeed, Endian.big);
  return crc32(b);
}

/// Header + payload with a valid TDP checksum.
Uint8List buildTdpPacket(List<int> payload, int serial,
    {required int flags, int opcode = 1, int version = 2, int ret = 0}) {
  final pkt = Uint8List(16 + payload.length);
  final bd = ByteData.sublistView(pkt);
  bd.setUint8(0, version);
  bd.setUint8(1, 0);
  bd.setUint16(2, opcode, Endian.big);
  bd.setUint16(4, payload.length, Endian.big);
  bd.setUint8(6, flags);
  bd.setUint8(7, ret);
  bd.setUint32(8, serial, Endian.big);
  bd.setUint32(12, tdpCrcSeed, Endian.big);
  pkt.setRange(16, pkt.length, payload);
  bd.setUint32(12, tdpCrc(pkt), Endian.big);
  return pkt;
}

class TdpDevice {
  TdpDevice({
    this.ip = '127.0.0.1',
    this.mac = '',
    required this.deviceId,
    this.deviceModel = 'C210',
    this.deviceType = 'SMART.IPCAMERA',
    this.httpPort = 443,
    this.encrypt = true,
    this.topLevelId = true,
    this.extra = const {},
  });

  /// Reported ip (default loopback).
  final String ip;

  /// Any MAC format.
  final String mac;

  /// Full cloud deviceId (40 hex).
  final String deviceId;
  final String deviceModel;
  final String deviceType;
  final int httpPort;
  final bool encrypt;
  final bool topLevelId;

  /// Merged into `result` (e.g. {"tpap": {"pake":[1]}, "encrypt_type": ["3"]}).
  final Map<String, dynamic> extra;
}

Uint8List buildTdpReply(TdpDevice d, int serial, String? rsaKeyPem) {
  final result = <String, dynamic>{
    'ip': d.ip,
    'mac': d.mac,
    'device_type': d.deviceType,
    'device_model': d.deviceModel,
    'device_name': d.deviceModel,
    'factory_default': false,
    'hardware_version': '2.0',
    'firmware_version': '1.3.11 Build 231121 Rel.41203n',
    'owner': '0' * 32,
    'is_support_iot_cloud': true,
    'mgt_encrypt_schm': {'is_support_https': true},
  };
  final encrypted = d.encrypt && rsaKeyPem != null;
  if (encrypted) {
    final pub = rsaPublicKeyFromPem(rsaKeyPem);
    final keyIv = randomBytes(32);
    final encKey = rsaOaepSha1Encrypt(pub, keyIv);
    final inner = utf8.encode(jsonEncode({
      'device_id': d.deviceId,
      'http_port': d.httpPort,
      'connect_ssid': '',
      'connect_type': 'wireless',
      'owner': '0' * 32,
    }));
    final data = aesCbcEncrypt(keyIv.sublist(0, 16), keyIv.sublist(16), inner);
    result['encrypt_info'] = {'sym_schm': 'AES', 'key': b64e(encKey), 'data': b64e(data)};
  }
  if (d.topLevelId || !encrypted) {
    result['device_id'] = md5Upper(d.deviceId);
  }
  result.addAll(d.extra);
  return buildTdpPacket(utf8.encode(jsonEncode({'error_code': 0, 'result': result})), serial, flags: 0x02);
}

class TdpRequest {
  TdpRequest(this.serial, this.rsaKey, this.flags, this.address, this.port);
  final int serial;
  final String? rsaKey;
  final int flags;
  final InternetAddress address;
  final int port;
}

class MockTdp {
  MockTdp({
    List<TdpDevice>? devices,
    this.port = 0,
    this.host = '127.0.0.1',
    this.concat = false,
    this.garbage = false,
  }) : devices = [...?devices];

  final List<TdpDevice> devices;
  int port;
  final String host;

  /// Pack all device replies into ONE datagram (allowed by the spec).
  bool concat;

  /// Send a junk datagram before the real replies.
  bool garbage;

  /// Every valid probe.
  final List<TdpRequest> requests = [];

  /// Rejected datagrams (bad length, version, opcode or CRC).
  int badProbes = 0;

  RawDatagramSocket? _sock;

  Future<MockTdp> start() async {
    _sock = await RawDatagramSocket.bind(InternetAddress(host), port);
    port = _sock!.port;
    _sock!.listen((e) {
      if (e != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = _sock?.receive()) != null) {
        try {
          unawaited(_answer(d!).catchError((Object _) => badProbes++));
        } catch (_) {
          badProbes++;
        }
      }
    });
    return this;
  }

  Future<void> stop() async {
    _sock?.close();
    _sock = null;
  }

  Future<void> _sendTo(List<int> data, InternetAddress addr, int port) async {
    for (var i = 0; i < 200; i++) {
      final s = _sock;
      if (s == null) return;
      if (s.send(data, addr, port) > 0) return;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<void> _answer(Datagram dg) async {
    final data = dg.data;
    if (data.length < 16) {
      badProbes++;
      return;
    }
    final bd = ByteData.sublistView(data);
    final version = bd.getUint8(0);
    final opcode = bd.getUint16(2, Endian.big);
    final length = bd.getUint16(4, Endian.big);
    final flags = bd.getUint8(6);
    final serial = bd.getUint32(8, Endian.big);
    final checksum = bd.getUint32(12, Endian.big);
    if (version != 2 || opcode != 1 || data.length < 16 + length) {
      badProbes++;
      return;
    }
    if (tdpCrc(Uint8List.sublistView(data, 0, 16 + length)) != checksum) {
      badProbes++;
      return;
    }
    final json = jsonDecode(utf8.decode(data.sublist(16, 16 + length))) as Map;
    final params = json['params'] is Map ? json['params'] as Map : const {};
    final rsa = params['rsa_key'] as String?;
    requests.add(TdpRequest(serial, rsa, flags, dg.address, dg.port));
    if (garbage) {
      await _sendTo(Uint8List.fromList([2, 0, ...utf8.encode('garbage-not-a-tdp-packet')]), dg.address, dg.port);
    }
    final replies = [for (final d in devices) buildTdpReply(d, serial, rsa)];
    if (concat && replies.isNotEmpty) {
      await _sendTo(concatBytes(replies), dg.address, dg.port);
    } else {
      for (final r in replies) {
        await _sendTo(r, dg.address, dg.port);
      }
    }
  }
}
