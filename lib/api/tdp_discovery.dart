// TDP v2 discovery (UDP 20002/20004, RSA-OAEP + AES encrypt_info).
// Spec: hc.discovery.tdp_packet / tdp_reply / tdp_encrypt_info / targets.

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

import 'lan_matcher.dart';

/// Flags of a broadcast request (0x10 | 0x01).
const tdpFlagsBroadcast = 0x11;

/// Flags of a unicast request.
const tdpFlagsUnicast = 0x21;

/// Seed written into the CRC slot (bytes 12..15) while computing the CRC.
const tdpCrcSeed = 0x5A6B7C8D;

const _headerSize = 16;
const _tdpVersion = 2;

final List<int> _crcTable = () {
  final table = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}();

/// 16-byte big-endian header + [payloadJson]: u8 version 2, u8 0, u16 opcode 1,
/// u16 payload length, u8 flags, u8 ret 0, u32 serial, u32 CRC32.
/// Throws `ArgumentError` when [serial] is not in 0 until 2^28.
Uint8List buildTdpProbe({
  required String payloadJson,
  required int serial,
  int flags = tdpFlagsBroadcast,
}) {
  if (serial < 0 || serial >= (1 << 28)) {
    throw ArgumentError.value(serial, 'serial', 'must be in 0 until 2^28');
  }
  final payload = utf8.encode(payloadJson);
  final packet = Uint8List(_headerSize + payload.length);
  final data = ByteData.sublistView(packet)
    ..setUint8(0, _tdpVersion)
    ..setUint8(1, 0)
    ..setUint16(2, 1)
    ..setUint16(4, payload.length)
    ..setUint8(6, flags)
    ..setUint8(7, 0)
    ..setUint32(8, serial)
    ..setUint32(12, tdpCrcSeed);
  packet.setRange(_headerSize, packet.length, payload);
  data.setUint32(12, tdpCrc32(packet));
  return packet;
}

/// IEEE CRC32 of the whole [packet] with bytes 12..15 replaced by [tdpCrcSeed]
/// (whatever they contain).
int tdpCrc32(Uint8List packet) {
  var crc = 0xFFFFFFFF;
  for (var i = 0; i < packet.length; i++) {
    final b = (i >= 12 && i < 16) ? ((tdpCrcSeed >> (8 * (15 - i))) & 0xFF) : packet[i];
    crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// Compact `{"params":{"rsa_key":"<PEM>"}}`.
String tdpProbePayload(String publicKeyPem) =>
    jsonEncode({'params': {'rsa_key': publicKeyPem}});

/// RSA-2048 key pair, generated once per process (off the UI isolate).
class TdpKeyPair {
  const TdpKeyPair(this.publicKey, this.privateKey, this.publicKeyPem);
  final RSAPublicKey publicKey;
  final RSAPrivateKey privateKey;

  /// SubjectPublicKeyInfo PEM with 64-char lines and a trailing LF.
  final String publicKeyPem;
}

Future<TdpKeyPair>? _keyPair;

Future<TdpKeyPair> generateTdpKeyPair() => Isolate.run(_generate);

/// The process-wide key pair (generated on first use).
Future<TdpKeyPair> sharedTdpKeyPair() => _keyPair ??= generateTdpKeyPair();

TdpKeyPair _generate() {
  final seeder = Random.secure();
  final fortuna = FortunaRandom()
    ..seed(KeyParameter(Uint8List.fromList(List.generate(32, (_) => seeder.nextInt(256)))));
  final generator = RSAKeyGenerator()
    ..init(ParametersWithRandom(
      RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64),
      fortuna,
    ));
  final pair = generator.generateKeyPair();
  final pub = pair.publicKey as RSAPublicKey;
  final priv = pair.privateKey as RSAPrivateKey;
  return TdpKeyPair(pub, priv, _spkiPem(pub));
}

Uint8List _derLen(int n) {
  if (n < 0x80) return Uint8List.fromList([n]);
  final bytes = <int>[];
  var v = n;
  while (v > 0) {
    bytes.insert(0, v & 0xFF);
    v >>= 8;
  }
  return Uint8List.fromList([0x80 | bytes.length, ...bytes]);
}

Uint8List _der(int tag, List<int> content) =>
    Uint8List.fromList([tag, ..._derLen(content.length), ...content]);

Uint8List _derInteger(BigInt v) {
  var hex = v.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  final bytes = <int>[for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
  if (bytes.first & 0x80 != 0) bytes.insert(0, 0);
  return _der(0x02, bytes);
}

String _spkiPem(RSAPublicKey key) {
  final rsaKey = _der(0x30, [..._derInteger(key.modulus!), ..._derInteger(key.publicExponent!)]);
  final algorithm = _der(0x30, [
    ..._der(0x06, [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]),
    0x05,
    0x00,
  ]);
  final spki = _der(0x30, [...algorithm, ..._der(0x03, [0x00, ...rsaKey])]);
  final b64 = base64.encode(spki);
  final lines = [for (var i = 0; i < b64.length; i += 64) b64.substring(i, min(i + 64, b64.length))];
  return '-----BEGIN PUBLIC KEY-----\n${lines.join('\n')}\n-----END PUBLIC KEY-----\n';
}

/// Decrypts `encrypt_info {sym_schm, key, data}`: RSA-OAEP(SHA-1, MGF1-SHA1)
/// of `key` gives key_iv (>= 32 B: AES key = [0:16], IV = [16:32]); `data` is
/// AES-128-CBC/PKCS7 UTF-8 JSON. Returns `{}` on any failure.
Map<String, dynamic> decryptEncryptInfo(Map<String, dynamic> encryptInfo, TdpKeyPair keys) {
  final key = encryptInfo['key'], data = encryptInfo['data'];
  if (key is! String || key.isEmpty || data is! String || data.isEmpty) return {};
  try {
    final oaep = OAEPEncoding.withSHA1(RSAEngine())
      ..init(false, PrivateKeyParameter<RSAPrivateKey>(keys.privateKey));
    final keyIv = oaep.process(base64.decode(key));
    if (keyIv.length < 32) return {};
    final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
      ..init(
        false,
        PaddedBlockCipherParameters(
          ParametersWithIV(KeyParameter(Uint8List.sublistView(keyIv, 0, 16)), Uint8List.sublistView(keyIv, 16, 32)),
          null,
        ),
      );
    final plain = jsonDecode(utf8.decode(cipher.process(Uint8List.fromList(base64.decode(data)))));
    return plain is Map<String, dynamic> ? plain : {};
  } catch (_) {
    return {};
  }
}

/// A camera answer.
class TdpDevice {
  const TdpDevice({
    required this.ip,
    required this.mac,
    required this.md5,
    this.httpPort,
    this.deviceType = '',
    this.deviceModel = '',
    this.encryptTypes = const [],
    this.tpap,
    this.raw = const {},
  });
  final String ip;

  /// Normalised `AA-BB-CC-DD-EE-FF`.
  final String mac;

  /// md5(decrypted device_id), else lower-cased top-level 32-hex device_id, else ''.
  final String md5;

  /// null for 0/invalid (default 443).
  final int? httpPort;
  final String deviceType;
  final String deviceModel;
  final List<String> encryptTypes;

  /// `{pake:[..], user_hash_type?, port?}` hint, or null.
  final Map<String, dynamic>? tpap;
  final Map<String, dynamic> raw;

  /// The LAN view used by `matchLan`.
  LanDevice toLanDevice() => LanDevice(ip: ip, mac: mac, md5: md5, httpPort: httpPort, raw: raw);
}

final _md5Hex = RegExp(r'^[0-9a-f]{32}$');

String? _validIpv4(Object? value) {
  if (value is! String) return null;
  final parts = value.trim().split('.');
  if (parts.length != 4) return null;
  final out = <int>[];
  for (final p in parts) {
    if (p.isEmpty || p.length > 3 || !RegExp(r'^\d+$').hasMatch(p)) return null;
    final n = int.parse(p);
    if (n > 255) return null;
    out.add(n);
  }
  return out.join('.');
}

/// Parses one UDP datagram that may hold several concatenated packets.
/// Stops on length 0/truncation/CRC mismatch; skips version != 2, ret not in
/// {0,1} and serial != [serial]; ignores error_code != 0 or missing result;
/// `ip` from `result.ip` (valid IPv4) else [senderIp]; dedupes by MAC (first
/// wins). Never throws on hostile data.
List<TdpDevice> parseTdpDatagram(
  Uint8List datagram, {
  required int serial,
  required String senderIp,
  TdpKeyPair? keys,
}) {
  final found = <String, TdpDevice>{};
  try {
    final view = ByteData.sublistView(datagram);
    var offset = 0;
    while (datagram.length - offset >= _headerSize) {
      final version = view.getUint8(offset);
      final length = view.getUint16(offset + 4);
      final ret = view.getUint8(offset + 7);
      final packetSerial = view.getUint32(offset + 8);
      final checksum = view.getUint32(offset + 12);
      final end = offset + _headerSize + length;
      if (length == 0 || end > datagram.length) break;
      final packet = Uint8List.sublistView(datagram, offset, end);
      final start = offset;
      offset = end;
      if (tdpCrc32(packet) != checksum) break;
      if (version != _tdpVersion || (ret != 0 && ret != 1) || packetSerial != serial) continue;
      try {
        final device = _deviceFromPayload(
          Uint8List.sublistView(datagram, start + _headerSize, end),
          senderIp,
          keys,
        );
        if (device != null) {
          final key = device.mac.isNotEmpty ? device.mac : device.ip;
          found.putIfAbsent(key, () => device);
        }
      } catch (_) {
        continue;
      }
    }
  } catch (_) {
    // hostile datagram: return what was parsed
  }
  return found.values.toList();
}

TdpDevice? _deviceFromPayload(Uint8List payload, String senderIp, TdpKeyPair? keys) {
  final doc = jsonDecode(utf8.decode(payload));
  if (doc is! Map) return null;
  final errorCode = doc['error_code'] ?? 0;
  if (errorCode != 0) return null;
  final result = doc['result'];
  if (result is! Map) return null;
  final ip = _validIpv4(result['ip']) ?? _validIpv4(senderIp);
  if (ip == null) return null;

  final info = result['encrypt_info'];
  final secret = (keys != null && info is Map<String, dynamic>)
      ? decryptEncryptInfo(info, keys)
      : <String, dynamic>{};
  final topLevel = '${result['device_id'] ?? ''}'.trim().toLowerCase();
  final secretId = secret['device_id'];
  final String md5;
  if (secretId != null && '$secretId'.isNotEmpty) {
    md5 = crypto.md5.convert(utf8.encode('$secretId')).toString();
  } else if (_md5Hex.hasMatch(topLevel)) {
    md5 = topLevel;
  } else {
    md5 = '';
  }
  final rawPort = secret['http_port'];
  final port = rawPort is int ? rawPort : int.tryParse('${rawPort ?? 0}') ?? 0;
  final rawMac = '${result['mac'] ?? ''}';
  final encrypt = result['encrypt_type'];
  final tpap = result['tpap'];
  final raw = <String, dynamic>{
    for (final e in result.entries)
      if (e.key != 'encrypt_info') '${e.key}': e.value,
    ...secret,
  };
  return TdpDevice(
    ip: ip,
    mac: normaliseMac(rawMac).isNotEmpty ? normaliseMac(rawMac) : rawMac.toUpperCase(),
    md5: md5,
    httpPort: (port > 0 && port < 65536) ? port : null,
    deviceType: '${result['device_type'] ?? ''}',
    deviceModel: '${result['device_model'] ?? ''}',
    encryptTypes: encrypt is List
        ? [for (final e in encrypt) '$e']
        : (encrypt == null ? const [] : ['$encrypt']),
    tpap: tpap is Map ? Map<String, dynamic>.from(tpap) : null,
    raw: raw,
  );
}

/// A local IPv4 interface.
class TdpInterface {
  const TdpInterface(this.address, this.prefixLength);
  final String address;
  final int prefixLength;
}

/// `255.255.255.255` plus the directed broadcast of every non-loopback,
/// non-link-local interface with prefix < 31, each on ports 20002 and 20004.
List<(String host, int port)> tdpTargets(List<TdpInterface> interfaces) {
  final hosts = <String>['255.255.255.255'];
  for (final iface in interfaces) {
    final addr = _validIpv4(iface.address);
    if (addr == null || iface.prefixLength < 0 || iface.prefixLength >= 31) continue;
    final o = addr.split('.').map(int.parse).toList();
    if (o[0] == 127 || (o[0] == 169 && o[1] == 254)) continue;
    final value = (o[0] << 24) | (o[1] << 16) | (o[2] << 8) | o[3];
    final hostMask = iface.prefixLength == 0 ? 0xFFFFFFFF : (0xFFFFFFFF >> iface.prefixLength);
    final b = (value | hostMask) & 0xFFFFFFFF;
    final text = '${(b >> 24) & 255}.${(b >> 16) & 255}.${(b >> 8) & 255}.${b & 255}';
    if (!hosts.contains(text)) hosts.add(text);
  }
  return [
    for (final h in hosts) ...[(h, 20002), (h, 20004)],
  ];
}
