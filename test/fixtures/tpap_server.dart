// Camera side of the TPAP local login (SPAKE2+ verifier, RFC 9383, P-256) and
// the AES-128-CCM /ds channel. Used by MockCamera(protocol: tpap).
//
// Flow on HTTPS :443 (same as the Windows mock):
//  POST /  login {cnonce, encrypt_type:"3"...}              -> -40211
//  POST /  login {sub_method:pake_register, username, user_random, ...}
//       -> dev_salt, dev_random, dev_share, iterations, cipher_suites, encryption[, extra_crypt]
//  POST /  login {sub_method:pake_share, user_share, user_confirm}
//       -> dev_confirm, stok, start_seq, expired      (wrong passcode -> -40401)
//  POST /stok=<stok>/ds  binary  u32_be(seq) || CCM(ct) || tag16 -> same layout
import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'fx_crypto.dart';
import 'mock_camera.dart';

// ---------------------------------------------------------------- P-256
final ECDomainParameters _curve = ECCurve_secp256r1();
final BigInt _p = BigInt.parse(
    'FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF',
    radix: 16);
final BigInt _a = _p - BigInt.from(3);
final BigInt _b = BigInt.parse(
    '5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B',
    radix: 16);

/// The group order n of P-256.
BigInt get p256Order => _curve.n;

ECPoint get p256G => _curve.G;

ECPoint p256Add(ECPoint a, ECPoint b) => (a + b)!;
ECPoint p256Mul(ECPoint a, BigInt k) => (a * k)!;

BigInt _bigFromBytes(List<int> b) {
  var v = BigInt.zero;
  for (final x in b) {
    v = (v << 8) | BigInt.from(x);
  }
  return v;
}

Uint8List bigToBytes(BigInt v, int len) {
  final out = Uint8List(len);
  var x = v;
  for (var i = len - 1; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xFF)).toInt();
    x >>= 8;
  }
  return out;
}

/// SEC1 decode (uncompressed or compressed) with an on-curve check.
ECPoint p256Decode(List<int> b) {
  BigInt x, y;
  if (b.length == 65 && b[0] == 4) {
    x = _bigFromBytes(b.sublist(1, 33));
    y = _bigFromBytes(b.sublist(33));
  } else if (b.length == 33 && (b[0] == 2 || b[0] == 3)) {
    x = _bigFromBytes(b.sublist(1));
    final rhs = (x.pow(3) + _a * x + _b) % _p;
    y = rhs.modPow((_p + BigInt.one) >> 2, _p);
    if ((y.isOdd ? 1 : 0) != (b[0] & 1)) y = _p - y;
  } else {
    throw const FormatException('bad point encoding');
  }
  if (x >= _p || y >= _p || (y * y - (x.pow(3) + _a * x + _b)) % _p != BigInt.zero) {
    throw const FormatException('point not on P-256');
  }
  return _curve.curve.createPoint(x, y);
}

Uint8List p256Encode(ECPoint p) => Uint8List.fromList([
      4,
      ...bigToBytes(p.x!.toBigInteger()!, 32),
      ...bigToBytes(p.y!.toBigInteger()!, 32),
    ]);

final ECPoint spakeM = p256Decode(fromHex(
    '02886e2f97ace46e55ba9dd7242579f2993b64e16ef3dcab95afd497333d8fa12f'));
final ECPoint spakeN = p256Decode(fromHex(
    '03d8bbd6c639c62937b04d997f38c3770719c629d7014d49a24b4f98baa1292b49'));

Uint8List _u64le(int n) {
  final b = ByteData(8)..setUint64(0, n, Endian.little);
  return b.buffer.asUint8List();
}

Uint8List _lenpre(List<List<int>> parts) =>
    concatBytes([for (final p in parts) ...[_u64le(p.length), p]]);

/// w0 / w1 from PBKDF2-HMAC-SHA256(passcode, salt, iterations, 80 bytes).
({BigInt w0, BigInt w1}) tpapW0W1(String passcode, List<int> salt, int iterations) {
  final kd = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(Uint8List.fromList(salt), iterations, 80));
  final dk = kd.process(utf8Bytes(passcode));
  return (
    w0: _bigFromBytes(dk.sublist(0, 40)) % _curve.n,
    w1: _bigFromBytes(dk.sublist(40)) % _curve.n,
  );
}

// ---------------------------------------------------------------- credentials
const String _c64 = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

/// Drepper SHA-crypt "$5$" (default 5000 rounds); salt <= 16 chars from [prefix].
String sha256Crypt(String key, String prefix) {
  var rest = prefix.startsWith(r'$5$') ? prefix.substring(3) : prefix;
  var rounds = 5000;
  var custom = false;
  if (rest.startsWith('rounds=') && rest.contains(r'$')) {
    final i = rest.indexOf(r'$');
    final r = int.parse(rest.substring(7, i));
    rest = rest.substring(i + 1);
    rounds = r < 1000 ? 1000 : (r > 999999999 ? 999999999 : r);
    custom = true;
  }
  var salt = rest.split(r'$').first;
  if (salt.length > 16) salt = salt.substring(0, 16);
  final k = utf8.encode(key);
  final s = utf8.encode(salt);
  final b = sha256Raw([...k, ...s, ...k]);
  final ctx = BytesBuilder()..add(k)..add(s);
  var n = k.length;
  while (n > 32) {
    ctx.add(b);
    n -= 32;
  }
  ctx.add(b.sublist(0, n));
  n = k.length;
  while (n > 0) {
    ctx.add((n & 1) != 0 ? b : k);
    n >>= 1;
  }
  final a = sha256Raw(ctx.toBytes());
  Uint8List rep(List<int> unit, int times) {
    final bb = BytesBuilder();
    for (var i = 0; i < times; i++) {
      bb.add(unit);
    }
    return bb.toBytes();
  }

  final dp = sha256Raw(rep(k, k.length));
  final p = rep(dp, k.length ~/ 32 + 1).sublist(0, k.length);
  final ds = sha256Raw(rep(s, 16 + a[0]));
  final sb = rep(ds, s.length ~/ 32 + 1).sublist(0, s.length);
  var c = Uint8List.fromList(a);
  for (var i = 0; i < rounds; i++) {
    final h = BytesBuilder()..add((i & 1) != 0 ? p : c);
    if (i % 3 != 0) h.add(sb);
    if (i % 7 != 0) h.add(p);
    h.add((i & 1) != 0 ? c : p);
    c = sha256Raw(h.toBytes());
  }
  String b64(int v, int cnt) {
    final sbuf = StringBuffer();
    var x = v;
    for (var i = 0; i < cnt; i++) {
      sbuf.write(_c64[x & 63]);
      x >>= 6;
    }
    return sbuf.toString();
  }

  const order = [
    [0, 10, 20], [21, 1, 11], [12, 22, 2], [3, 13, 23], [24, 4, 14],
    [15, 25, 5], [6, 16, 26], [27, 7, 17], [18, 28, 8], [9, 19, 29],
  ];
  final enc = StringBuffer();
  for (final t in order) {
    enc.write(b64((c[t[0]] << 16) | (c[t[1]] << 8) | c[t[2]], 4));
  }
  enc.write(b64((c[31] << 8) | c[30], 3));
  return '\$5\$${custom ? 'rounds=$rounds\$' : ''}$salt\$$enc';
}

// ---------------------------------------------------------------- endpoint
class _Pending {
  _Pending(this.userRandom, this.devRandom, this.w0, this.w1, this.y, this.shareV);
  final Uint8List userRandom;
  final Uint8List devRandom;
  final BigInt w0;
  final BigInt w1;
  final BigInt y;
  final Uint8List shareV;
}

class TpapSession {
  TpapSession(this.stok, this.key, this.nonce, this.nextSeq);
  final String stok;
  final Uint8List key;
  final Uint8List nonce;
  int nextSeq;

  Uint8List nonceFor(int seq) {
    final n = Uint8List(12)..setRange(0, 8, nonce);
    ByteData.sublistView(n).setUint32(8, seq & 0xFFFFFFFF, Endian.big);
    return n;
  }
}

/// A binary or JSON answer for /ds.
class TpapDsReply {
  TpapDsReply(this.contentType, this.body);
  final String contentType;
  final Uint8List body;
}

class TpapEndpoint {
  TpapEndpoint(this.cam)
      : prefix = '\$5\$${List<String>.generate(16, (_) => _c64[2 + randomBytes(1)[0] % 62]).join()}\$';

  final MockCamera cam;
  final String prefix;
  _Pending? _pending;
  final Map<String, TpapSession> sessions = {};

  void expire() => sessions.clear();

  String passcode() {
    switch (cam.tpapCredential) {
      case TpapCredential.lat:
        return sha256Upper(cam.localToken);
      case TpapCredential.sha256Extra:
        return sha256Crypt(sha256Upper(cam.cloudPassword), prefix);
      case TpapCredential.md5:
        return md5Hex(cam.cloudPassword);
    }
  }

  String expectedUsername() => cam.tpapUsername == 'admin' ? 'admin' : md5Hex('admin');

  Map<String, dynamic>? _locked() {
    final left = cam.lockRemainingSeconds();
    if (left > 0) {
      return {
        'error_code': -40404,
        'result': {
          'data': {'code': -40404, 'sec_left': left.floor() + 1}
        }
      };
    }
    return null;
  }

  Map<String, dynamic> handleLogin(Object? params) {
    cam.loginAttempts++;
    if (params is! Map) return {'error_code': -40210};
    final sub = params['sub_method'];
    if (sub == 'pake_register') return _register(params);
    if (sub == 'pake_share') return _share(params);
    if (sub == null &&
        (params.containsKey('encrypt_type') ||
            params.containsKey('password') ||
            params.containsKey('cnonce'))) {
      cam.v3ProbeCount++;
      return {'error_code': -40211}; // what TPAP-only firmware answers to v3 / legacy
    }
    return {'error_code': -40209};
  }

  Map<String, dynamic> _register(Map params) {
    cam.tpapRegisterCount++;
    final locked = _locked();
    if (locked != null) return locked;
    if (params['username'] != expectedUsername()) return {'error_code': -40209};
    final suites = params['cipher_suites'];
    final enc = params['encryption'] ?? ['aes_128_ccm'];
    if (params['passcode_type'] != 'userpw' ||
        suites is! List ||
        !suites.contains(1) ||
        enc is! List ||
        !enc.contains('aes_128_ccm')) {
      return {'error_code': -40209};
    }
    Uint8List userRandom;
    try {
      final ur = params['user_random'];
      if (ur is! String) throw const FormatException('x');
      userRandom = b64d(ur);
    } on FormatException {
      return {'error_code': -40209};
    }
    if (userRandom.length < 16 || userRandom.length > 64) return {'error_code': -40209};
    final salt = randomBytes(16);
    final devRandom = randomBytes(32);
    final iterations = cam.tpapIterations;
    final w = tpapW0W1(passcode(), salt, iterations);
    final y = _bigFromBytes(randomBytes(48)) % (_curve.n - BigInt.one) + BigInt.one;
    final shareV = p256Encode(p256Add(p256Mul(p256G, y), p256Mul(spakeN, w.w0)));
    _pending = _Pending(userRandom, devRandom, w.w0, w.w1, y, shareV);
    final result = <String, dynamic>{
      'dev_salt': b64e(salt),
      'dev_random': b64e(devRandom),
      'dev_share': b64e(shareV),
      'cipher_suites': 1,
      'iterations': iterations,
      'encryption': 'aes_128_ccm',
    };
    if (cam.tpapCredential == TpapCredential.sha256Extra) {
      result['extra_crypt'] = {
        'type': 'password_shadow',
        'params': {'passwd_id': 5, 'passwd_prefix': prefix}
      };
    }
    return {'error_code': 0, 'result': result};
  }

  Map<String, dynamic> _share(Map params) {
    cam.tpapShareAttempts++;
    final locked = _locked();
    if (locked != null) return locked;
    final pend = _pending;
    _pending = null;
    if (pend == null) return {'error_code': -40401};
    Uint8List userConfirm;
    ECPoint xpt;
    try {
      final us = params['user_share'];
      final uc = params['user_confirm'];
      if (us is! String || uc is! String) throw const FormatException('x');
      userConfirm = b64d(uc);
      xpt = p256Decode(b64d(us));
    } on FormatException {
      return {'error_code': -40209};
    }
    final shareP = p256Encode(xpt);
    final h = p256Add(xpt, -p256Mul(spakeM, pend.w0));
    final z = p256Mul(h, pend.y);
    final v = p256Mul(p256G, (pend.y * pend.w1) % _curve.n);
    if (z.isInfinity || v.isInfinity) {
      return {'error_code': -40401};
    }
    final context = sha256Raw([...utf8.encode('PAKE V1'), ...pend.userRandom, ...pend.devRandom]);
    final tt = _lenpre([
      context,
      const <int>[],
      const <int>[],
      p256Encode(spakeM),
      p256Encode(spakeN),
      shareP,
      pend.shareV,
      p256Encode(z),
      p256Encode(v),
      bigToBytes(pend.w0, 32),
    ]);
    final kMain = sha256Raw(tt);
    final conf = hkdfSha256(kMain, null, utf8.encode('ConfirmationKeys'), 64);
    final kcA = conf.sublist(0, 32);
    final kcB = conf.sublist(32);
    final shared = hkdfSha256(kMain, null, utf8.encode('SharedKey'), 32);
    if (!constTimeEq(userConfirm, hmacSha256(kcA, pend.shareV))) {
      cam.registerFailure();
      return {'error_code': -40401};
    }
    if (cam.tpapRefuseShares > 0) {
      cam.tpapRefuseShares--; // C200 quirk: correct share right after a session ended is refused once
      return {'error_code': -40401};
    }
    var devConfirm = hmacSha256(kcB, shareP);
    if (cam.tpapBadDevConfirm) {
      devConfirm = Uint8List.fromList(devConfirm.map((x) => x ^ 0x5A).toList());
    }
    final key = hkdfSha256(shared, utf8.encode('tp-kdf-salt-aes128-key'),
            utf8.encode('tp-kdf-info-aes128-key'), 32)
        .sublist(0, 16);
    final nonce = hkdfSha256(shared, utf8.encode('tp-kdf-salt-aes128-iv'),
            utf8.encode('tp-kdf-info-aes128-iv'), 32)
        .sublist(0, 12);
    final stok = randomHex(16);
    final startSeq = cam.fixedStartSeq ?? (randomBytes(2).buffer.asByteData().getUint16(0) % 9000 + 100);
    sessions[stok] = TpapSession(stok, key, nonce, startSeq);
    cam.loginCount++;
    cam.resetFailures();
    return {
      'error_code': 0,
      'result': {
        'dev_confirm': b64e(devConfirm),
        'stok': stok,
        'start_seq': startSeq,
        'expired': cam.tpapSessionExpired,
      }
    };
  }

  TpapDsReply _refuse(String stok, int code) {
    sessions.remove(stok);
    return TpapDsReply('application/json; charset=UTF-8',
        utf8Bytes(compactJson({'error_code': code})));
  }

  TpapDsReply handleDs(String stok, Uint8List raw) {
    final sess = sessions[stok];
    if (sess == null) return _refuse(stok, -40401);
    if (cam.expiryFires()) return _refuse(stok, -40401);
    if (raw.length < 4 + 16) return _refuse(stok, -40401);
    final seq = ByteData.sublistView(raw).getUint32(0, Endian.big);
    cam.tpapDsSeqs.add(seq);
    if (seq < sess.nextSeq) return _refuse(stok, -40401);
    final plain = ccmOpen(sess.key, sess.nonceFor(seq), raw.sublist(4));
    if (plain == null) return _refuse(stok, -40401);
    sess.nextSeq = seq + 1;
    Object? inner;
    try {
      inner = jsonDecode(utf8.decode(plain));
    } on FormatException {
      return _refuse(stok, -40209);
    }
    if (inner is! Map || inner['method'] != 'multipleRequest') {
      return _refuse(stok, -40209);
    }
    final reply = cam.handleInner(inner);
    final sealed = ccmSeal(sess.key, sess.nonceFor(seq), utf8Bytes(compactJson(reply)));
    final head = ByteData(4)..setUint32(0, seq, Endian.big);
    return TpapDsReply('application/octet-stream',
        concatBytes([head.buffer.asUint8List(), sealed]));
  }
}
