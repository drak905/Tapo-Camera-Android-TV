// TPAP (SPAKE2+ P-256, RFC 9383) login and the AES-128-CCM /ds channel.
// Spec: hc.local.tpap_*, hc.local.lat_mode. At most 2 pake_share attempts per
// login; never loop credential variants. No secret in logs/toString.

import 'dart:typed_data';

import 'tapo_errors.dart';

export 'tpap_crypt.dart';

/// `md5hex('admin')`, or `SHA256U('admin')` when TDP `user_hash_type == 1`.
String tpapCameraUsername({int userHashType = 0, String user = 'admin'}) =>
    throw UnimplementedError();

/// Passcode candidate: `'md5'` -> md5 hex lower of the password, `'sha256'` ->
/// SHA256U, `'lat'` -> SHA256U of the LAT.
String tpapCredential(String variant, String secret) => throw UnimplementedError();

/// Builds the `params` of `pake_register`.
Map<String, dynamic> buildPakeRegister({required String username, required Uint8List userRandom}) =>
    throw UnimplementedError();

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
  factory TpapRegisterReply.parse(Map<String, dynamic> result) => throw UnimplementedError();
}

/// SPAKE2+ constants M and N, compressed SEC1.
final Uint8List tpapPointM = throw UnimplementedError();
final Uint8List tpapPointN = throw UnimplementedError();

/// `SHA256('PAKE V1' || userRandom || devRandom)`.
Uint8List tpapContext(Uint8List userRandom, Uint8List devRandom) => throw UnimplementedError();

/// `PBKDF2-HMAC-SHA256(passcode UTF-8, salt, iterations, 80 B)`, raw bytes.
Uint8List tpapPbkdf2(String passcode, Uint8List salt, int iterations) =>
    throw UnimplementedError();

/// `(w0, w1)` = `(int(dk[0:40]) mod n, int(dk[40:80]) mod n)`. Run in an isolate on TV.
(BigInt, BigInt) tpapDeriveW0W1(String passcode, Uint8List salt, int iterations) =>
    throw UnimplementedError();

/// Decodes a SEC1 point (compressed or uncompressed) and returns the
/// uncompressed encoding (65 B). Throws `TapoProtocolError` when invalid or
/// off the curve.
Uint8List tpapDecodePoint(Uint8List sec1) => throw UnimplementedError();

/// Compresses an uncompressed SEC1 point (33 B).
Uint8List tpapCompressPoint(Uint8List uncompressed) => throw UnimplementedError();

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
}) =>
    throw UnimplementedError();

/// AES-128-CCM session channel (tag 16 B, no AAD).
class TpapCipher {
  /// Only `aes_128_ccm` is supported; anything else throws `TapoProtocolError`.
  TpapCipher(Uint8List sharedKey, {String encryption = 'aes_128_ccm'});

  /// First 16 bytes of HKDF(K_shared, 'tp-kdf-salt-aes128-key', 'tp-kdf-info-aes128-key', 32).
  Uint8List get aesKey => throw UnimplementedError();

  /// First 12 bytes of HKDF(K_shared, 'tp-kdf-salt-aes128-iv', 'tp-kdf-info-aes128-iv', 32).
  Uint8List get nonceBase => throw UnimplementedError();

  /// `nonceBase[0:8] || u32_be(seq)`.
  Uint8List nonceFor(int seq) => throw UnimplementedError();

  /// `u32_be(seq) || ciphertext || tag`.
  Uint8List seal(Uint8List plain, int seq) => throw UnimplementedError();

  /// Parses a reply body (own seq in the first 4 bytes). Throws
  /// `TapoSessionInvalid` when it is too short or fails authentication.
  (int, Uint8List) open(Uint8List body) => throw UnimplementedError();

  /// True when [body] is a plaintext JSON refusal (`{` ... with error_code).
  /// Codes -40401, -40418, -40420, -40421, -2402 mean session invalid.
  static int? plaintextRefusalCode(Uint8List body) => throw UnimplementedError();
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
  String toString() => throw UnimplementedError();
}

/// Posts `{"method":"login","params":<params>}` and returns the decoded reply.
typedef TpapPostLogin = Future<Map<String, dynamic>> Function(Map<String, dynamic> params);

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
  });

  /// `'lat'`, `'md5'`, `'sha256'` of the last success, else null.
  String? get goodVariant => throw UnimplementedError();

  /// Throws `TapoAuthError` (wrong secrets, dev_confirm mismatch, after at most
  /// 2 shares), `TapoLockedError` (-40404/-40408), `TpapNotSupported`
  /// (register answered -40413 with encrypt_type ['3']) or `TapoProtocolError`.
  Future<TpapSession> login() => throw UnimplementedError();
}

/// `pake_register` says the camera wants the v3 secure login instead.
class TpapNotSupported extends TapoError {
  TpapNotSupported() : super('camera needs the v3 secure login, not TPAP');
}
