// Self-test of test/fixtures/mock_tdp.dart with raw UDP datagrams.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

import '../fixtures/fx_crypto.dart';
import '../fixtures/mock_tdp.dart';

late AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> keys;
late String publicPem;

String spkiPem(RSAPublicKey k) {
  final rsaKey = ASN1Sequence(elements: [ASN1Integer(k.modulus), ASN1Integer(k.exponent)]);
  final algo = ASN1Sequence(elements: [
    ASN1ObjectIdentifier.fromIdentifierString('1.2.840.113549.1.1.1'),
    ASN1Null(),
  ]);
  final bits = ASN1BitString(stringValues: rsaKey.encode());
  final der = ASN1Sequence(elements: [algo, bits]).encode();
  final b = base64.encode(der);
  final lines = [for (var i = 0; i < b.length; i += 64) b.substring(i, i + 64 > b.length ? b.length : i + 64)];
  return '-----BEGIN PUBLIC KEY-----\n${lines.join('\n')}\n-----END PUBLIC KEY-----\n';
}

/// Probe packet per spec hc.discovery.tdp_packet.
Uint8List probe(int serial, String rsaKey, {int flags = 0x11}) => buildTdpPacket(
    utf8.encode(compactJson({
      'params': {'rsa_key': rsaKey}
    })),
    serial,
    flags: flags);

Future<List<Uint8List>> exchange(MockTdp tdp, Uint8List packet,
    {Duration wait = const Duration(milliseconds: 400)}) async {
  final sock = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final got = <Uint8List>[];
  sock.listen((e) {
    if (e == RawSocketEvent.read) {
      Datagram? d;
      while ((d = sock.receive()) != null) {
        got.add(d!.data);
      }
    }
  });
  sock.send(packet, InternetAddress.loopbackIPv4, tdp.port);
  await Future<void>.delayed(wait);
  sock.close();
  return got;
}

/// Splits concatenated replies; verifies the CRC of each.
List<Map<String, dynamic>> parseReplies(Uint8List data, int serial) {
  final out = <Map<String, dynamic>>[];
  var off = 0;
  while (data.length - off >= 16) {
    final bd = ByteData.sublistView(data, off);
    final len = bd.getUint16(4, Endian.big);
    if (len == 0 || data.length - off < 16 + len) break;
    final pkt = Uint8List.sublistView(data, off, off + 16 + len);
    expect(tdpCrc(pkt), bd.getUint32(12, Endian.big), reason: 'CRC');
    expect(bd.getUint8(0), 2);
    expect(bd.getUint8(6) & 0x02, 0x02);
    expect(bd.getUint32(8, Endian.big), serial);
    out.add(jsonDecode(utf8.decode(pkt.sublist(16))) as Map<String, dynamic>);
    off += 16 + len;
  }
  return out;
}

Map<String, dynamic> decryptInfo(Map<String, dynamic> result) {
  final ei = result['encrypt_info'] as Map<String, dynamic>;
  final dec = OAEPEncoding.withSHA1(RSAEngine())..init(false, PrivateKeyParameter<RSAPrivateKey>(keys.privateKey));
  final keyIv = dec.process(b64d(ei['key'] as String));
  final plain = aesCbcDecrypt(keyIv.sublist(0, 16), keyIv.sublist(16, 32), b64d(ei['data'] as String));
  return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
}

const id1 = '802200000000000000000000000000000000ABCD';
const id2 = '80220000000000000000000000000000000000FF';

void main() {
  setUpAll(() {
    final gen = RSAKeyGenerator()
      ..init(ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64),
          FortunaRandom()..seed(KeyParameter(randomBytes(32)))));
    final pair = gen.generateKeyPair();
    keys = AsymmetricKeyPair(pair.publicKey, pair.privateKey);
    publicPem = spkiPem(keys.publicKey);
  });

  test('golden: probe packet bytes and CRC (hc.discovery.tdp_packet)', () {
    final p = probe(0x01234567, 'TEST');
    expect(toHex(p),
        '02000001001d1100012345671acf25777b22706172616d73223a7b227273615f6b6579223a2254455354227d7d');
    expect(tdpCrc(p), 0x1acf2577);
    expect(md5Hex(id1), 'e4247a931858b38594790fc6606441aa');
  });

  test('RSA-OAEP encrypt_info round-trips; top-level id is MD5 upper', () async {
    final tdp = await MockTdp(devices: [
      TdpDevice(ip: '10.0.0.5', mac: 'A0-B1-C2-00-00-01', deviceId: id1, httpPort: 8443),
    ]).start();
    addTearDown(tdp.stop);
    final replies = await exchange(tdp, probe(0x0ABCDEF, publicPem));
    expect(replies.length, 1);
    final r = parseReplies(replies.single, 0x0ABCDEF).single;
    expect(r['error_code'], 0);
    final result = r['result'] as Map<String, dynamic>;
    expect(result['ip'], '10.0.0.5');
    expect(result['device_id'], md5Upper(id1));
    final info = decryptInfo(result);
    expect(info['device_id'], id1);
    expect(info['http_port'], 8443);
    expect(tdp.requests.single.serial, 0x0ABCDEF);
    expect(tdp.requests.single.flags, 0x11);
    expect(tdp.requests.single.rsaKey, publicPem);
  });

  test('two devices: separate datagrams, or one concatenated datagram', () async {
    final tdp = await MockTdp(devices: [
      TdpDevice(deviceId: id1, mac: 'AA:BB:CC:00:00:01'),
      TdpDevice(deviceId: id2, mac: 'AA:BB:CC:00:00:02'),
    ]).start();
    addTearDown(tdp.stop);
    var replies = await exchange(tdp, probe(7, publicPem));
    expect(replies.length, 2);
    tdp.concat = true;
    replies = await exchange(tdp, probe(8, publicPem));
    expect(replies.length, 1);
    final all = parseReplies(replies.single, 8);
    expect(all.length, 2);
    expect(decryptInfo(all[1]['result'] as Map<String, dynamic>)['device_id'], id2);
  });

  test('garbage option, no-encrypt and topLevelId=false variants, extras', () async {
    final tdp = await MockTdp(garbage: true, devices: [
      TdpDevice(deviceId: id1, encrypt: false, extra: {
        'encrypt_type': ['3'],
        'tpap': {'pake': [1]}
      }),
      TdpDevice(deviceId: id2, topLevelId: false),
    ]).start();
    addTearDown(tdp.stop);
    final replies = await exchange(tdp, probe(9, publicPem));
    expect(replies.length, 3);
    expect(replies.first.length, lessThan(40)); // junk first
    final a = parseReplies(replies[1], 9).single['result'] as Map<String, dynamic>;
    expect(a.containsKey('encrypt_info'), isFalse);
    expect(a['device_id'], md5Upper(id1));
    expect(a['tpap'], {'pake': [1]});
    final b = parseReplies(replies[2], 9).single['result'] as Map<String, dynamic>;
    expect(b.containsKey('device_id'), isFalse);
    expect(decryptInfo(b)['device_id'], id2);
  });

  test('bad CRC, wrong version and short datagrams are ignored and counted', () async {
    final tdp = await MockTdp(devices: [TdpDevice(deviceId: id1)]).start();
    addTearDown(tdp.stop);
    final badCrc = probe(1, publicPem)..[13] ^= 0xFF;
    expect(await exchange(tdp, badCrc, wait: const Duration(milliseconds: 150)), isEmpty);
    expect(await exchange(tdp, Uint8List(5), wait: const Duration(milliseconds: 150)), isEmpty);
    final v3 = buildTdpPacket(utf8.encode('{"params":{}}'), 2, flags: 0x11, version: 3);
    expect(await exchange(tdp, v3, wait: const Duration(milliseconds: 150)), isEmpty);
    expect(tdp.badProbes, 3);
    expect(tdp.requests, isEmpty);
    expect((await exchange(tdp, probe(3, publicPem))).length, 1);
  });
}
