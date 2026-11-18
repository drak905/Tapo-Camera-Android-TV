// TPAP (SPAKE2+ P-256, RFC 9383) login and the AES-128-CCM /ds channel.
// Spec: hc.local.tpap_*, hc.local.lat_mode. At most 2 pake_share attempts per
// login; never loop credential variants. No secret in logs/toString.

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import 'local_crypto.dart' show md5Upper, sha256Upper;
import 'tapo_errors.dart';
import 'tpap_crypt.dart';

export 'tpap_crypt.dart';

const _contextTag = 'PAKE V1';
const _maxAttempts = 2;
const _reloginRetryDelay = Duration(seconds: 2);
const _defaultIterations = 10000;
const _encryption = 'aes_128_ccm';
const _cipherSuite = 1;
const _lockCodes = {-40404, -40408};
const _badUsername = -40209;
const _needsV3 = -40413;

/// `md5hex('admin')`, or `SHA256U('admin')` when TDP `user_hash_type == 1`.
String tpapCameraUsername({int userHashType = 0, String user = 'admin'}) =>
    userHashType == 1 ? sha256Upper(user) : md5Upper(user).toLowerCase();

/// Passcode candidate: `'md5'` -> md5 hex lower of the password, `'sha256'` ->
/// SHA256U, `'lat'` -> SHA256U of the LAT.
String tpapCredential(String variant, String secret) {
  switch (variant) {
    case 'md5':
      return md5Upper(secret).toLowerCase();
    case 'sha256':
    case 'lat':
      return sha256Upper(secret);
  }
  throw ArgumentError.value(variant, 'variant', 'unknown credential variant');
}

/// Builds the `params` of `pake_register`.
Map<String, dynamic> buildPakeRegister({required String username, required Uint8List userRandom}) => {
      'sub_method': 'pake_register',
      'username': username,
      'user_random': base64.encode(userRandom),
      'cipher_suites': [_cipherSuite],
      'encryption': [_encryption],
      'passcode_type': 'userpw',
    };

final _b64Strict = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');

Uint8List _b64Field(Map<String, dynamic> res, String name) {
  final value = res[name];
  if (value is! String || value.isEmpty) throw TapoProtocolError('TPAP reply has no $name');
  if (value.length % 4 != 0 || !_b64Strict.hasMatch(value)) {
    throw TapoProtocolError('TPAP reply field $name is not base64');
  }
  try {
    return Uint8List.fromList(base64.decode(value));
  } on FormatException {
    throw TapoProtocolError('TPAP reply field $name is not base64');
  }
}

int? _intField(Map<String, dynamic> res, String name, [int? fallback]) {
  if (!res.containsKey(name)) return fallback;
  final v = res[name];
  if (v == null) return fallback;
  if (v is int) return v;
  if (v is String) {
    final p = int.tryParse(v);
    if (p != null) return p;
  }
  throw TapoProtocolError('TPAP reply field $name is not an integer');
}

/// Parsed `pake_register` reply (`result`).
class TpapRegisterReply {
  const TpapRegisterReply({
    required this.devRandom,
    required this.devSalt,
    required this.devShare,
    required this.iterations,
    required this.encryption,
    this.extraCrypt,
  });
  final Uint8List devRandom;
  final Uint8List devSalt;
  final Uint8List devShare;
  final int iterations;
  final String encryption;
  final Object? extraCrypt;

  /// Throws `TapoProtocolError` for bad base64, iterations outside
  /// 1..10_000_000 or cipher_suites != 1. Defaults: iterations 10000,
  /// encryption `aes_128_ccm`.
  factory TpapRegisterReply.parse(Map<String, dynamic> result) {
    final suite = _intField(result, 'cipher_suites', _cipherSuite);
    if (suite != _cipherSuite) {
      throw TapoProtocolError('The camera chose an unsupported TPAP cipher suite');
    }
    final iterations = _intField(result, 'iterations', _defaultIterations)!;
    if (iterations <= 0 || iterations > 10000000) {
      throw TapoProtocolError('TPAP iteration count out of range');
    }
    final enc = result['encryption'] ?? _encryption;
    if (enc is! String) throw TapoProtocolError('TPAP reply has a bad encryption field');
    return TpapRegisterReply(
      devRandom: _b64Field(result, 'dev_random'),
      devSalt: _b64Field(result, 'dev_salt'),
      devShare: _b64Field(result, 'dev_share'),
      iterations: iterations,
      encryption: enc,
      extraCrypt: result['extra_crypt'],
    );
  }
}

// ----------------------------------------------------------------- P-256 --

final _curve = ECCurve_secp256r1();
final BigInt _p = BigInt.parse(
    'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
    radix: 16);
final BigInt _a = _p - BigInt.from(3);
final BigInt _b = BigInt.parse(
    '5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b',
    radix: 16);
final BigInt _n = _curve.n;

Uint8List _unhex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16),
    ]);

BigInt _bigFrom(List<int> bytes) =>
    bytes.fold(BigInt.zero, (acc, v) => (acc << 8) | BigInt.from(v));

Uint8List _bigTo(BigInt v, int len) {
  final out = Uint8List(len);
  var x = v;
  final mask = BigInt.from(0xff);
  for (var i = len - 1; i >= 0; i--) {
    out[i] = (x & mask).toInt();
    x >>= 8;
  }
  return out;
}

/// SPAKE2+ constants M and N, compressed SEC1.
final Uint8List tpapPointM =
    _unhex('02886e2f97ace46e55ba9dd7242579f2993b64e16ef3dcab95afd497333d8fa12f');
final Uint8List tpapPointN =
    _unhex('03d8bbd6c639c62937b04d997f38c3770719c629d7014d49a24b4f98baa1292b49');

ECPoint _point(Uint8List sec1) {
  final BigInt x, y;
  if (sec1.length == 65 && sec1[0] == 4) {
    x = _bigFrom(sec1.sublist(1, 33));
    y = _bigFrom(sec1.sublist(33));
  } else if (sec1.length == 33 && (sec1[0] == 2 || sec1[0] == 3)) {
    x = _bigFrom(sec1.sublist(1));
    if (x >= _p) throw TapoProtocolError('Point x coordinate out of range');
    final rhs = (x * x * x + _a * x + _b) % _p;
    var root = rhs.modPow((_p + BigInt.one) >> 2, _p);
    if ((root * root) % _p != rhs) throw TapoProtocolError('No P-256 point with this x');
    if ((root.isOdd ? 1 : 0) != (sec1[0] & 1)) root = _p - root;
    y = root;
  } else {
    throw TapoProtocolError('Bad point encoding');
  }
  if (x >= _p || y >= _p || (y * y - (x * x * x + _a * x + _b)) % _p != BigInt.zero) {
    throw TapoProtocolError('Point is not on P-256');
  }
  return _curve.curve.createPoint(x, y);
}

/// Decodes a SEC1 point (compressed or uncompressed) and returns the
/// uncompressed encoding (65 B). Throws `TapoProtocolError` when invalid or
/// off the curve.
Uint8List tpapDecodePoint(Uint8List sec1) => _point(sec1).getEncoded(false);

/// Compresses an uncompressed SEC1 point (33 B).
Uint8List tpapCompressPoint(Uint8List uncompressed) => _point(uncompressed).getEncoded(true);

// ------------------------------------------------------------------ KDFs --

Uint8List _hkdf(List<int> ikm, List<int>? salt, List<int> info, int length) {
  final prk = Hmac(sha256, salt == null || salt.isEmpty ? List.filled(32, 0) : salt).convert(ikm).bytes;
  final out = <int>[];
  var t = <int>[];
  for (var i = 1; out.length < length; i++) {
    t = Hmac(sha256, prk).convert([...t, ...info, i]).bytes;
    out.addAll(t);
  }
  return Uint8List.fromList(out.sublist(0, length));
}

/// `SHA256('PAKE V1' || userRandom || devRandom)`.
Uint8List tpapContext(Uint8List userRandom, Uint8List devRandom) =>
    Uint8List.fromList(sha256.convert([...utf8.encode(_contextTag), ...userRandom, ...devRandom]).bytes);

/// `PBKDF2-HMAC-SHA256(passcode UTF-8, salt, iterations, 80 B)`, raw bytes.
Uint8List tpapPbkdf2(String passcode, Uint8List salt, int iterations) {
  if (iterations <= 0) throw ArgumentError.value(iterations, 'iterations');
  final kdf = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, iterations, 80));
  return kdf.process(Uint8List.fromList(utf8.encode(passcode)));
}

/// `(w0, w1)` = `(int(dk[0:40]) mod n, int(dk[40:80]) mod n)`. Run in an isolate on TV.
(BigInt, BigInt) tpapDeriveW0W1(String passcode, Uint8List salt, int iterations) {
  final dk = tpapPbkdf2(passcode, salt, iterations);
  return (_bigFrom(dk.sublist(0, 40)) % _n, _bigFrom(dk.sublist(40, 80)) % _n);
}

// ------------------------------------------------------------ SPAKE2+ ----

/// Keys and shares of one SPAKE2+ run (prover side).
class Spake2pKeys {
  const Spake2pKeys({
    required this.shareP,
    required this.z,
    required this.v,
    required this.kMain,
    required this.kConfirmP,
    required this.kConfirmV,
    required this.confirmP,
    required this.confirmV,
    required this.kShared,
  });
  final Uint8List shareP, z, v, kMain, kConfirmP, kConfirmV, confirmP, confirmV, kShared;

  @override
  String toString() => 'Spake2pKeys(<hidden>)';
}

Uint8List _lenPrefixed(List<List<int>> parts) {
  final out = BytesBuilder();
  for (final part in parts) {
    final len = ByteData(8)..setUint64(0, part.length, Endian.little);
    out
      ..add(len.buffer.asUint8List())
      ..add(part);
  }
  return out.toBytes();
}

BigInt _randomScalar() {
  final rnd = Random.secure();
  while (true) {
    final candidate = _bigFrom(List.generate(32, (_) => rnd.nextInt(256))) % _n;
    if (candidate != BigInt.zero) return candidate;
  }
}

/// Prover side of SPAKE2+-P256-SHA256-HKDF-SHA256-HMAC-SHA256.
/// [x] is the private scalar (random in [1,n-1] when null). [shareV] must be
/// on the curve, else `TapoProtocolError`. Transcript: u64-LE length-prefixed
/// context, idProver, idVerifier, M, N, shareP, shareV, Z, V, then
/// u64-LE 32 || w0 (32 B big-endian).
Spake2pKeys spake2pProve({
  required BigInt w0,
  required BigInt w1,
  required Uint8List context,
  required Uint8List shareV,
  BigInt? x,
  Uint8List? idProver,
  Uint8List? idVerifier,
}) {
  final scalar = (x ?? _randomScalar()) % _n;
  if (scalar == BigInt.zero) throw ArgumentError('x must be non-zero');
  final m = _point(tpapPointM);
  final nPoint = _point(tpapPointN);
  final w0n = w0 % _n;
  final w1n = w1 % _n;
  final shareP = ((_curve.G * scalar)! + (m * w0n)!)!.getEncoded(false);
  final y = _point(shareV);
  final base = (y - (nPoint * w0n)!);
  if (base == null || base.isInfinity) throw TapoProtocolError('Peer share cancels out');
  final z = (base * scalar);
  final v = (base * w1n);
  if (z == null || v == null || z.isInfinity || v.isInfinity) {
    throw TapoProtocolError('Degenerate SPAKE2+ result');
  }
  final shareVEnc = y.getEncoded(false);
  final tt = _lenPrefixed([
    context,
    idProver ?? const [],
    idVerifier ?? const [],
    m.getEncoded(false),
    nPoint.getEncoded(false),
    shareP,
    shareVEnc,
    z.getEncoded(false),
    v.getEncoded(false),
    _bigTo(w0n, 32),
  ]);
  final kMain = Uint8List.fromList(sha256.convert(tt).bytes);
  final conf = _hkdf(kMain, null, utf8.encode('ConfirmationKeys'), 64);
  final kcP = Uint8List.sublistView(conf, 0, 32);
  final kcV = Uint8List.sublistView(conf, 32);
  return Spake2pKeys(
    shareP: shareP,
    z: z.getEncoded(false),
    v: v.getEncoded(false),
    kMain: kMain,
    kConfirmP: Uint8List.fromList(kcP),
    kConfirmV: Uint8List.fromList(kcV),
    confirmP: Uint8List.fromList(Hmac(sha256, kcP).convert(shareVEnc).bytes),
    confirmV: Uint8List.fromList(Hmac(sha256, kcV).convert(shareP).bytes),
    kShared: _hkdf(kMain, null, utf8.encode('SharedKey'), 32),
  );
}

// -------------------------------------------------------------- Channel ---

/// AES-128-CCM session channel (tag 16 B, no AAD).
class TpapCipher {
  /// Only `aes_128_ccm` is supported; anything else throws `TapoProtocolError`.
  TpapCipher(Uint8List sharedKey, {String encryption = _encryption}) {
    if (encryption != _encryption) {
      throw TapoProtocolError('Unsupported TPAP session encryption');
    }
    _key = _hkdf(sharedKey, utf8.encode('tp-kdf-salt-aes128-key'),
            utf8.encode('tp-kdf-info-aes128-key'), 32)
        .sublist(0, 16);
    _nonce = _hkdf(sharedKey, utf8.encode('tp-kdf-salt-aes128-iv'),
            utf8.encode('tp-kdf-info-aes128-iv'), 32)
        .sublist(0, 12);
  }

  late final Uint8List _key;
  late final Uint8List _nonce;

  /// First 16 bytes of HKDF(K_shared, 'tp-kdf-salt-aes128-key', 'tp-kdf-info-aes128-key', 32).
  Uint8List get aesKey => Uint8List.fromList(_key);

  /// First 12 bytes of HKDF(K_shared, 'tp-kdf-salt-aes128-iv', 'tp-kdf-info-aes128-iv', 32).
  Uint8List get nonceBase => Uint8List.fromList(_nonce);

  /// `nonceBase[0:8] || u32_be(seq)`.
  Uint8List nonceFor(int seq) {
    final out = Uint8List(12)..setRange(0, 8, _nonce);
    ByteData.sublistView(out).setUint32(8, seq & 0xFFFFFFFF);
    return out;
  }

  CCMBlockCipher _ccm(bool encrypt, int seq) => CCMBlockCipher(AESEngine())
    ..init(encrypt, AEADParameters(KeyParameter(_key), 128, nonceFor(seq), Uint8List(0)));

  /// `u32_be(seq) || ciphertext || tag`.
  Uint8List seal(Uint8List plain, int seq) {
    final ct = _ccm(true, seq).process(plain);
    final out = Uint8List(4 + ct.length);
    ByteData.sublistView(out).setUint32(0, seq & 0xFFFFFFFF);
    out.setRange(4, out.length, ct);
    return out;
  }

  /// Parses a reply body (own seq in the first 4 bytes). Throws
  /// `TapoSessionInvalid` when it is too short or fails authentication.
  (int, Uint8List) open(Uint8List body) {
    if (body.length < 4 + 16) throw TapoSessionInvalid('TPAP reply is too short');
    final seq = ByteData.sublistView(body).getUint32(0);
    try {
      return (seq, _ccm(false, seq).process(Uint8List.sublistView(body, 4)));
    } catch (_) {
      throw TapoSessionInvalid('TPAP reply failed authentication');
    }
  }

  /// True when [body] is a plaintext JSON refusal (`{` ... with error_code).
  /// Codes -40401, -40418, -40420, -40421, -2402 mean session invalid.
  static int? plaintextRefusalCode(Uint8List body) {
    if (body.isEmpty || body[0] != 0x7B) return null;
    try {
      final doc = jsonDecode(utf8.decode(body));
      if (doc is Map) {
        final code = doc['error_code'];
        if (code is int) return code;
        if (code is String) return int.tryParse(code);
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  @override
  String toString() => 'TpapCipher(aes_128_ccm)';
}

/// An established TPAP session.
class TpapSession {
  const TpapSession({
    required this.stok,
    required this.startSeq,
    required this.cipher,
    required this.variant,
    this.expiresIn,
  });
  final String stok;
  final int startSeq;
  final TpapCipher cipher;
  final String variant;
  final int? expiresIn;

  /// Never prints stok or keys.
  @override
  String toString() => 'TpapSession(variant: $variant, expiresIn: $expiresIn)';
}

/// Posts `{"method":"login","params":<params>}` and returns the decoded reply.
typedef TpapPostLogin = Future<Map<String, dynamic>> Function(Map<String, dynamic> params);

/// `pake_register` says the camera wants the v3 secure login instead.
class TpapNotSupported extends TapoError {
  TpapNotSupported() : super('camera needs the v3 secure login, not TPAP');
}

/// The camera refused a TPAP step with a code that is not a credential failure.
class TpapRejected extends TapoError {
  TpapRejected(this.code, this.stage) : super('TPAP $stage rejected (error $code)');
  final int? code;
  final String stage;
}

class _Register {
  _Register(this.userRandom, this.reply);
  final Uint8List userRandom;
  final TpapRegisterReply reply;
}

Uint8List _secureBytes(int n) {
  final rnd = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => rnd.nextInt(256)));
}

(BigInt, BigInt) _deriveInIsolate((String, Uint8List, int) args) =>
    tpapDeriveW0W1(args.$1, args.$2, args.$3);

/// Bounded TPAP login for one camera (spec: hc.local.tpap_share_login).
class TpapAuthenticator {
  /// [maxAttempts] is fixed at 2 (MAX_ATTEMPTS). [rng] returns n random bytes.
  /// [sleep] is used for the 2 s retry of a known-good variant.
  TpapAuthenticator({
    required TpapPostLogin postLogin,
    String password = '',
    String? localToken,
    Map<String, dynamic>? tpapHints,
    Uint8List Function(int n)? rng,
    Future<void> Function(Duration d)? sleep,
  })  : _post = postLogin,
        _password = password,
        _localToken = (localToken == null || localToken.isEmpty) ? null : localToken,
        _rng = rng ?? _secureBytes,
        _sleep = sleep ?? ((d) => Future<void>.delayed(d)) {
    final hashType = tpapHints?['user_hash_type'];
    _usernames = [tpapCameraUsername(userHashType: hashType == 1 ? 1 : 0)];
    if (!_usernames.contains('admin')) _usernames.add('admin');
  }

  final TpapPostLogin _post;
  final String _password;
  final String? _localToken;
  final Uint8List Function(int n) _rng;
  final Future<void> Function(Duration d) _sleep;
  late List<String> _usernames;
  String? _goodVariant;

  /// `'lat'`, `'md5'`, `'sha256'` of the last success, else null.
  String? get goodVariant => _goodVariant;

  @override
  String toString() => 'TpapAuthenticator(goodVariant: $_goodVariant)';

  int _code(Object? reply) {
    if (reply is! Map) throw TapoProtocolError('TPAP login reply is not a JSON object');
    final code = reply['error_code'] ?? 0;
    if (code is int) return code;
    if (code is String) {
      final p = int.tryParse(code);
      if (p != null) return p;
    }
    throw TapoProtocolError('TPAP login reply has a non-integer error_code');
  }

  Map<String, dynamic> _result(Map<String, dynamic> reply) {
    final r = reply['result'];
    return r is Map<String, dynamic> ? r : <String, dynamic>{};
  }

  void _raiseIfLocked(int code, Map<String, dynamic> reply) {
    if (!_lockCodes.contains(code)) return;
    final data = _result(reply)['data'];
    final left = data is Map ? data['sec_left'] : null;
    throw TapoLockedError(
      'The camera is blocking logins after too many failures (error $code)',
      secLeft: left is int ? left : null,
    );
  }

  Future<_Register> _register() async {
    while (true) {
      final userRandom = _rng(32);
      final reply = await _post(buildPakeRegister(username: _usernames.first, userRandom: userRandom));
      final code = _code(reply);
      _raiseIfLocked(code, reply);
      if (code == _badUsername && _usernames.length > 1) {
        _usernames.removeAt(0); // remembered for later logins too
        continue;
      }
      if (code == _badUsername) throw TapoAuthError('The camera rejected the TPAP user name');
      if (code == _needsV3) throw TpapNotSupported();
      if (code != 0) throw TpapRejected(code, 'pake_register');
      return _Register(userRandom, TpapRegisterReply.parse(_result(reply)));
    }
  }

  String _passcode(String variant) =>
      variant == 'lat' ? tpapCredential('lat', _localToken!) : tpapCredential(variant, _password);

  /// One password attempt: the session on success, else the camera's error code.
  Future<(TpapSession?, int)> _share(_Register reg, String variant) async {
    final r = reg.reply;
    final passcode = applyExtraCrypt(_passcode(variant), r.extraCrypt);
    final (w0, w1) = r.iterations >= 3000
        ? await Isolate.run(() => _deriveInIsolate((passcode, r.devSalt, r.iterations)))
        : tpapDeriveW0W1(passcode, r.devSalt, r.iterations);
    final keys = spake2pProve(
      w0: w0,
      w1: w1,
      context: tpapContext(reg.userRandom, r.devRandom),
      shareV: r.devShare,
    );
    final cipher = TpapCipher(keys.kShared, encryption: r.encryption);
    final reply = await _post({
      'sub_method': 'pake_share',
      'user_share': base64.encode(keys.shareP),
      'user_confirm': base64.encode(keys.confirmP),
    });
    final code = _code(reply);
    _raiseIfLocked(code, reply);
    if (code != 0) return (null, code);
    final res = _result(reply);
    final devConfirm = _b64Field(res, 'dev_confirm');
    if (!_constantTimeEquals(devConfirm, keys.confirmV)) {
      throw TapoAuthError('The camera could not prove it knows the password (TPAP dev_confirm mismatch)');
    }
    final stok = res['stok'];
    if (stok is! String || stok.isEmpty) throw TapoProtocolError('TPAP login reply has no stok');
    final startSeq = _intField(res, 'start_seq');
    if (startSeq == null) throw TapoProtocolError('TPAP login reply has no start_seq');
    return (
      TpapSession(
        stok: stok,
        startSeq: startSeq,
        cipher: cipher,
        variant: variant,
        expiresIn: _intField(res, 'expired'),
      ),
      0,
    );
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    var diff = a.length ^ b.length;
    for (var i = 0; i < a.length && i < b.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  List<String> _order(Object? extraCrypt) => [
        if (_localToken != null) 'lat',
        if (_password.isNotEmpty) ...(extraCrypt != null ? ['sha256', 'md5'] : ['md5', 'sha256']),
      ];

  /// Throws `TapoAuthError` (wrong secrets, dev_confirm mismatch, after at most
  /// 2 shares), `TapoLockedError` (-40404/-40408), `TpapNotSupported`
  /// (register answered -40413 with encrypt_type ['3']) or `TapoProtocolError`.
  Future<TpapSession> login() async {
    if (_password.isEmpty && _localToken == null) {
      throw TapoAuthError('No password for the TPAP login (sign in with the TP-Link ID)');
    }
    var known = _goodVariant;
    if (known == 'lat' && _localToken == null) known = null;
    if (known != null && known != 'lat' && _password.isEmpty) known = null;
    int? lastCode;
    final tried = <String>[];
    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      if (attempt > 0 && known != null) await _sleep(_reloginRetryDelay);
      if (known == null && _order(null).where((v) => !tried.contains(v)).isEmpty) break;
      final reg = await _register();
      String? variant = known;
      variant ??= _order(reg.reply.extraCrypt).where((v) => !tried.contains(v)).firstOrNull;
      if (variant == null) break;
      tried.add(variant);
      final (session, code) = await _share(reg, variant);
      if (session != null) {
        _goodVariant = variant;
        return session;
      }
      lastCode = code;
    }
    _goodVariant = null;
    if (_localToken != null) {
      throw TapoAuthError(
          'The camera rejected the local access token and the TP-Link ID password (TPAP, error $lastCode)');
    }
    throw TapoAuthError('The camera rejected the TP-Link ID password (TPAP, error $lastCode)');
  }
}
