// Self-signed EC P-256 certificate generated at test time (no key material is
// committed). Hand-built DER, signed with ECDSA-SHA256 via pointycastle.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'fx_crypto.dart';

class TestCert {
  TestCert(this.certDer, this.keyPkcs8Der);
  final Uint8List certDer;
  final Uint8List keyPkcs8Der;

  String get certPem => _pem('CERTIFICATE', certDer);
  String get keyPem => _pem('PRIVATE KEY', keyPkcs8Der);

  /// Lower-case hex SHA-256 of the DER certificate (the "fingerprint").
  String get fingerprint => toHex(sha256Raw(certDer));

  /// Server-side context presenting this certificate.
  SecurityContext serverContext() => SecurityContext()
    ..useCertificateChainBytes(utf8.encode(certPem))
    ..usePrivateKeyBytes(utf8.encode(keyPem));

  /// Client-side context that trusts only this certificate (hostname checked).
  SecurityContext clientContext() => SecurityContext(withTrustedRoots: false)
    ..setTrustedCertificatesBytes(utf8.encode(certPem));
}

String _pem(String label, Uint8List der) {
  final b = base64.encode(der);
  final lines = [
    for (var i = 0; i < b.length; i += 64) b.substring(i, min(i + 64, b.length))
  ];
  return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
}

// ---- DER helpers -----------------------------------------------------------
Uint8List _len(int n) {
  if (n < 128) return Uint8List.fromList([n]);
  final bytes = <int>[];
  var v = n;
  while (v > 0) {
    bytes.insert(0, v & 0xFF);
    v >>= 8;
  }
  return Uint8List.fromList([0x80 | bytes.length, ...bytes]);
}

Uint8List _tlv(int tag, List<int> body) =>
    Uint8List.fromList([tag, ..._len(body.length), ...body]);

Uint8List _seq(List<List<int>> parts) =>
    _tlv(0x30, [for (final p in parts) ...p]);

Uint8List _int(BigInt v) {
  var bytes = <int>[];
  var x = v;
  if (x == BigInt.zero) bytes = [0];
  while (x > BigInt.zero) {
    bytes.insert(0, (x & BigInt.from(0xFF)).toInt());
    x >>= 8;
  }
  if (bytes.first & 0x80 != 0) bytes.insert(0, 0);
  return _tlv(0x02, bytes);
}

Uint8List _oid(List<int> arcs) {
  final body = <int>[arcs[0] * 40 + arcs[1]];
  for (final a in arcs.skip(2)) {
    final tmp = <int>[a & 0x7F];
    var v = a >> 7;
    while (v > 0) {
      tmp.insert(0, 0x80 | (v & 0x7F));
      v >>= 7;
    }
    body.addAll(tmp);
  }
  return _tlv(0x06, body);
}

Uint8List _utf8(String s) => _tlv(0x0C, utf8.encode(s));
Uint8List _utcTime(DateTime t) {
  String p(int v) => v.toString().padLeft(2, '0');
  final u = t.toUtc();
  return _tlv(0x17,
      ascii.encode('${p(u.year % 100)}${p(u.month)}${p(u.day)}${p(u.hour)}${p(u.minute)}${p(u.second)}Z'));
}

BigInt _randBig(BigInt max) {
  final r = Random.secure();
  var v = BigInt.zero;
  for (var i = 0; i < 40; i++) {
    v = (v << 8) | BigInt.from(r.nextInt(256));
  }
  return (v % (max - BigInt.one)) + BigInt.one;
}

final _oidEcPublicKey = _oid([1, 2, 840, 10045, 2, 1]);
final _oidP256 = _oid([1, 2, 840, 10045, 3, 1, 7]);
final _oidEcdsaSha256 = _oid([1, 2, 840, 10045, 4, 3, 2]);

/// Generates a fresh self-signed certificate. [sanDns] / [sanIps] go into the
/// subjectAltName so a client that trusts the certificate can verify hostnames.
TestCert generateTestCert({
  String commonName = 'C210',
  List<String> sanDns = const [],
  List<String> sanIps = const [],
  bool isCa = false,
}) {
  final params = ECCurve_secp256r1();
  final d = _randBig(params.n);
  final q = (params.G * d)!;
  final pub = Uint8List.fromList([
    0x04,
    ..._fixed32(q.x!.toBigInteger()!),
    ..._fixed32(q.y!.toBigInteger()!),
  ]);

  final name = _seq([
    _tlv(0x31, _seq([_oid([2, 5, 4, 3]), _utf8(commonName)])),
    _tlv(0x31, _seq([_oid([2, 5, 4, 10]), _utf8('TP-Link (mock)')])),
  ]);
  final spki = _seq([
    _seq([_oidEcPublicKey, _oidP256]),
    _tlv(0x03, [0, ...pub]),
  ]);
  final now = DateTime.now().toUtc();
  final extensions = <Uint8List>[];
  if (sanDns.isNotEmpty || sanIps.isNotEmpty) {
    final names = <int>[
      for (final s in sanDns) ..._tlv(0x82, ascii.encode(s)),
      for (final ip in sanIps) ..._tlv(0x87, InternetAddress(ip).rawAddress),
    ];
    extensions.add(_seq([
      _oid([2, 5, 29, 17]),
      _tlv(0x04, _tlv(0x30, names)),
    ]));
  }
  if (isCa) {
    extensions.add(_seq([
      _oid([2, 5, 29, 19]),
      _tlv(0x01, [0xFF]),
      _tlv(0x04, _seq([_tlv(0x01, [0xFF])])),
    ]));
  }
  final tbs = _seq([
    _tlv(0xA0, _int(BigInt.two)),
    _int(_randBig(BigInt.one << 63)),
    _seq([_oidEcdsaSha256]),
    name,
    _seq([
      _utcTime(now.subtract(const Duration(days: 1))),
      _utcTime(now.add(const Duration(days: 3650))),
    ]),
    name,
    spki,
    if (extensions.isNotEmpty) _tlv(0xA3, _seq(extensions)),
  ]);

  final rnd = FortunaRandom()..seed(KeyParameter(randomBytes(32)));
  final signer = ECDSASigner(SHA256Digest())
    ..init(
        true,
        ParametersWithRandom(
            PrivateKeyParameter<ECPrivateKey>(ECPrivateKey(d, params)), rnd));
  final sig = signer.generateSignature(tbs) as ECSignature;
  final sigDer = _seq([_int(sig.r), _int(sig.s)]);
  final cert = _seq([
    tbs,
    _seq([_oidEcdsaSha256]),
    _tlv(0x03, [0, ...sigDer]),
  ]);

  final ecPriv = _seq([
    _int(BigInt.one),
    _tlv(0x04, _fixed32(d)),
    _tlv(0xA1, _tlv(0x03, [0, ...pub])),
  ]);
  final pkcs8 = _seq([
    _int(BigInt.zero),
    _seq([_oidEcPublicKey, _oidP256]),
    _tlv(0x04, ecPriv),
  ]);
  return TestCert(cert, pkcs8);
}

Uint8List _fixed32(BigInt v) {
  final out = Uint8List(32);
  var x = v;
  for (var i = 31; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xFF)).toInt();
    x >>= 8;
  }
  return out;
}
