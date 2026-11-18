// TDP v2 discovery (UDP 20002/20004, RSA-OAEP + AES encrypt_info).
// Spec: hc.discovery.tdp_packet / tdp_reply / tdp_encrypt_info / targets.

import 'dart:typed_data';

import 'package:pointycastle/export.dart' show RSAPrivateKey, RSAPublicKey;

/// Flags of a broadcast request (0x10 | 0x01).
const tdpFlagsBroadcast = 0x11;

/// Flags of a unicast request.
const tdpFlagsUnicast = 0x21;

/// Seed written into the CRC slot (bytes 12..15) while computing the CRC.
const tdpCrcSeed = 0x5A6B7C8D;

/// 16-byte big-endian header + [payloadJson]: u8 version 2, u8 0, u16 opcode 1,
/// u16 payload length, u8 flags, u8 ret 0, u32 serial, u32 CRC32.
/// Throws `ArgumentError` when [serial] is not in 0 until 2^28.
Uint8List buildTdpProbe({
  required String payloadJson,
  required int serial,
  int flags = tdpFlagsBroadcast,
}) =>
    throw UnimplementedError();

/// IEEE CRC32 of the whole [packet] with bytes 12..15 replaced by [tdpCrcSeed]
/// (whatever they contain).
int tdpCrc32(Uint8List packet) => throw UnimplementedError();

/// Compact `{"params":{"rsa_key":"<PEM>"}}`.
String tdpProbePayload(String publicKeyPem) => throw UnimplementedError();

/// RSA-2048 key pair, generated once per process (off the UI isolate).
class TdpKeyPair {
  const TdpKeyPair(this.publicKey, this.privateKey, this.publicKeyPem);
  final RSAPublicKey publicKey;
  final RSAPrivateKey privateKey;

  /// SubjectPublicKeyInfo PEM with 64-char lines and a trailing LF.
  final String publicKeyPem;
}

Future<TdpKeyPair> generateTdpKeyPair() => throw UnimplementedError();

/// Decrypts `encrypt_info {sym_schm, key, data}`: RSA-OAEP(SHA-1, MGF1-SHA1)
/// of `key` gives key_iv (>= 32 B: AES key = [0:16], IV = [16:32]); `data` is
/// AES-128-CBC/PKCS7 UTF-8 JSON. Returns `{}` on any failure.
Map<String, dynamic> decryptEncryptInfo(Map<String, dynamic> encryptInfo, TdpKeyPair keys) =>
    throw UnimplementedError();

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
}) =>
    throw UnimplementedError();

/// A local IPv4 interface.
class TdpInterface {
  const TdpInterface(this.address, this.prefixLength);
  final String address;
  final int prefixLength;
}

/// `255.255.255.255` plus the directed broadcast of every non-loopback,
/// non-link-local interface with prefix < 31, each on ports 20002 and 20004.
List<(String host, int port)> tdpTargets(List<TdpInterface> interfaces) =>
    throw UnimplementedError();