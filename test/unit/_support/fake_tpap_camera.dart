// In-test TPAP camera: the SPAKE2+ VERIFIER side, written independently of
// lib/api/tpap.dart (package:crypto + pointycastle only). It answers
// pake_register / pake_share like a real camera and counts every attempt, so
// the tests can prove the "at most 2 attempts" safety rule.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import 'helpers.dart';

final _params = ECCurve_secp256r1();
final _n = _params.n;

ECPoint _pt(String compressedHex) => _params.curve.decodePoint(unhex(compressedHex))!;

final _m = _pt('02886e2f97ace46e55ba9dd7242579f2993b64e16ef3dcab95afd497333d8fa12f');
final _nPoint = _pt('03d8bbd6c639c62937b04d997f38c3770719c629d7014d49a24b4f98baa1292b49');

BigInt _toBig(List<int> b) => b.fold(BigInt.zero, (a, v) => (a << 8) | BigInt.from(v));

Uint8List _toBytes(BigInt v, int len) {
  final out = Uint8List(len);
  var x = v;
  for (var i = len - 1; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x >>= 8;
  }
  return out;
}

Uint8List _pbkdf2(String pass, Uint8List salt, int iters, int len) {
  final mac = Hmac(sha256, utf8.encode(pass));
  final out = BytesBuilder();
  for (var block = 1; out.length < len; block++) {
    final idx = ByteData(4)..setUint32(0, block);
    var u = mac.convert([...salt, ...idx.buffer.asUint8List()]).bytes;
    final t = List<int>.from(u);
    for (var i = 1; i < iters; i++) {
      u = mac.convert(u).bytes;
      for (var j = 0; j < t.length; j++) {
        t[j] ^= u[j];
      }
    }
    out.add(t);
  }
  return Uint8List.sublistView(out.toBytes(), 0, len);
}

Uint8List _hkdf(List<int> ikm, List<int> info, int len) {
  final prk = Hmac(sha256, List.filled(32, 0)).convert(ikm).bytes;
  final out = <int>[];
  var t = <int>[];
  for (var i = 1; out.length < len; i++) {
    t = Hmac(sha256, prk).convert([...t, ...info, i]).bytes;
    out.addAll(t);
  }
  return Uint8List.fromList(out.sublist(0, len));
}

Uint8List _lenLe(List<int> part) {
  final b = ByteData(8)..setUint64(0, part.length, Endian.little);
  return Uint8List.fromList([...b.buffer.asUint8List(), ...part]);
}

/// Session data the fake camera hands out on success.
class FakeTpapOutcome {
  FakeTpapOutcome(this.stok, this.startSeq, this.kShared);
  final String stok;
  final int startSeq;
  final Uint8List kShared;
}

class FakeTpapCamera {
  FakeTpapCamera({
    required this.expectedPasscode,
    this.extraCrypt,
    this.acceptedUsernames,
    this.iterations = 1000,
  });

  /// The passcode the camera expects AFTER extra_crypt shaping.
  final String expectedPasscode;
  final Object? extraCrypt;

  /// null = any user name; else only these are accepted (others -> -40209).
  final Set<String>? acceptedUsernames;
  final int iterations;

  bool locked = false;
  bool badDevConfirm = false;
  bool needsV3 = false;

  /// The next N pake_share calls are refused even with the right passcode.
  int refuseNextShares = 0;

  int registerCount = 0;
  int shareCount = 0;
  final List<String> usernames = [];
  FakeTpapOutcome? lastOutcome;

  final _rnd = Random(99);
  Uint8List _bytes(int n) => Uint8List.fromList(List.generate(n, (_) => _rnd.nextInt(256)));

  // Per-register state.
  Uint8List? _userRandom, _devRandom;
  BigInt? _y, _w0, _w1;
  Uint8List? _shareV;

  Map<String, dynamic> _locked() => {
        'error_code': -40404,
        'result': {'data': {'sec_left': 300}},
      };

  /// Plug into `TpapAuthenticator(postLogin: camera.postLogin)`.
  Future<Map<String, dynamic>> postLogin(Map<String, dynamic> params) async {
    if (locked) return _locked();
    switch (params['sub_method']) {
      case 'pake_register':
        return _register(params);
      case 'pake_share':
        return _share(params);
    }
    return {'error_code': -40101};
  }

  Map<String, dynamic> _register(Map<String, dynamic> params) {
    registerCount++;
    final username = '${params['username']}';
    usernames.add(username);
    if (needsV3) {
      return {
        'error_code': -40413,
        'result': {'data': {'encrypt_type': ['3']}},
      };
    }
    if (acceptedUsernames != null && !acceptedUsernames!.contains(username)) {
      return {'error_code': -40209};
    }
    _userRandom = Uint8List.fromList(base64.decode(params['user_random'] as String));
    _devRandom = _bytes(32);
    final salt = _bytes(16);
    final dk = _pbkdf2(expectedPasscode, salt, iterations, 80);
    _w0 = _toBig(dk.sublist(0, 40)) % _n;
    _w1 = _toBig(dk.sublist(40, 80)) % _n;
    _y = (_toBig(_bytes(32)) % (_n - BigInt.one)) + BigInt.one;
    final shareV = ((_params.G * _y!)! + (_nPoint * _w0!)!)!;
    _shareV = shareV.getEncoded(false);
    return {
      'error_code': 0,
      'result': {
        'dev_random': base64.encode(_devRandom!),
        'dev_salt': base64.encode(salt),
        'dev_share': base64.encode(_shareV!),
        'iterations': iterations,
        'cipher_suites': 1,
        'encryption': 'aes_128_ccm',
        'extra_crypt': ?extraCrypt,
      },
    };
  }

  Map<String, dynamic> _share(Map<String, dynamic> params) {
    shareCount++;
    final shareP = Uint8List.fromList(base64.decode(params['user_share'] as String));
    final userConfirm = base64.decode(params['user_confirm'] as String);
    final x = _params.curve.decodePoint(shareP)!;
    final w0 = _w0!;
    final z = ((x - (_m * w0)!)! * _y!)!;
    final v = ((_params.G * _w1!)! * _y!)!;
    final context = Uint8List.fromList(
      sha256.convert([...utf8.encode('PAKE V1'), ..._userRandom!, ..._devRandom!]).bytes,
    );
    final tt = BytesBuilder()
      ..add(_lenLe(context))
      ..add(_lenLe(const []))
      ..add(_lenLe(const []))
      ..add(_lenLe(_m.getEncoded(false)))
      ..add(_lenLe(_nPoint.getEncoded(false)))
      ..add(_lenLe(shareP))
      ..add(_lenLe(_shareV!))
      ..add(_lenLe(z.getEncoded(false)))
      ..add(_lenLe(v.getEncoded(false)))
      ..add(_lenLe(_toBytes(w0, 32)));
    final kMain = Uint8List.fromList(sha256.convert(tt.toBytes()).bytes);
    final conf = _hkdf(kMain, utf8.encode('ConfirmationKeys'), 64);
    final confirmP = Hmac(sha256, conf.sublist(0, 32)).convert(_shareV!).bytes;
    final confirmV = Hmac(sha256, conf.sublist(32)).convert(shareP).bytes;
    final kShared = _hkdf(kMain, utf8.encode('SharedKey'), 32);

    if (refuseNextShares > 0) {
      refuseNextShares--;
      return {'error_code': -40401};
    }
    final same = confirmP.length == userConfirm.length &&
        List.generate(confirmP.length, (i) => confirmP[i] == userConfirm[i]).every((b) => b);
    if (!same) return {'error_code': -40401};
    lastOutcome = FakeTpapOutcome('stok-fake-$shareCount', 100, kShared);
    return {
      'error_code': 0,
      'result': {
        'dev_confirm': base64.encode(badDevConfirm ? List.filled(32, 1) : confirmV),
        'stok': lastOutcome!.stok,
        'start_seq': 100,
        'expired': 600,
      },
    };
  }
}
