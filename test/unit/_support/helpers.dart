// Shared helpers for the api-lane tests. Independent of the code under test:
// everything here uses package:crypto / pointycastle directly.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';
import 'package:tapo_tv/api/cloud_transport.dart';

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List unhex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16),
    ]);

String sha256UpperRef(String s) => sha256.convert(utf8.encode(s)).toString().toUpperCase();
String md5UpperRef(String s) => md5.convert(utf8.encode(s)).toString().toUpperCase();
String md5LowerRef(String s) => md5.convert(utf8.encode(s)).toString();
List<int> sha256Digest(List<int> data) => sha256.convert(data).bytes;

/// IEEE CRC32 (zlib).
int crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// AES-128-CBC with PKCS7.
Uint8List aesCbc(bool encrypt, Uint8List key, Uint8List iv, Uint8List data) {
  final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
    ..init(encrypt, PaddedBlockCipherParameters(ParametersWithIV(KeyParameter(key), iv), null));
  return cipher.process(data);
}

/// A TDP reply/probe packet: 16-byte header + compact JSON, CRC with the
/// 0x5A6B7C8D seed in slot 12..15.
Uint8List tdpPacket(
  Object payload, {
  required int serial,
  int version = 2,
  int ret = 0,
  int flags = 0x11,
  bool badCrc = false,
}) {
  final body = utf8.encode(payload is String ? payload : jsonEncode(payload));
  final head = ByteData(16)
    ..setUint8(0, version)
    ..setUint8(1, 0)
    ..setUint16(2, 1)
    ..setUint16(4, body.length)
    ..setUint8(6, flags)
    ..setUint8(7, ret)
    ..setUint32(8, serial)
    ..setUint32(12, 0x5A6B7C8D);
  final bytes = Uint8List.fromList([...head.buffer.asUint8List(), ...body]);
  var crc = crc32(bytes);
  if (badCrc) crc ^= 0xFFFF;
  ByteData.sublistView(bytes).setUint32(12, crc);
  return bytes;
}

/// One recorded cloud request.
class SeenRequest {
  SeenRequest(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String body;

  Map<String, dynamic> get json => jsonDecode(body) as Map<String, dynamic>;
  String get path => uri.path;
}

CloudResponse jsonReply(Object body, {int status = 200}) =>
    CloudResponse(status, Uint8List.fromList(utf8.encode(jsonEncode(body))));

CloudResponse textReply(String text, {int status = 200}) =>
    CloudResponse(status, Uint8List.fromList(utf8.encode(text)));

/// In-memory [CloudTransport]; [handler] answers every request.
class FakeCloudTransport implements CloudTransport {
  FakeCloudTransport(this.handler);

  CloudResponse Function(SeenRequest request) handler;
  final List<SeenRequest> requests = [];

  @override
  Future<CloudResponse> send(CloudRequest request) async {
    final seen = SeenRequest(
      request.method,
      request.uri,
      Map.of(request.headers),
      request.body == null ? '' : utf8.decode(request.body!),
    );
    requests.add(seen);
    return handler(seen);
  }

  @override
  void close() {}
}
