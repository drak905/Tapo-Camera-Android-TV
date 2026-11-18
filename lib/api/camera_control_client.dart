// Local login state machine (TPAP / secure v3 / legacy MD5) with the auth
// circuit breaker. Spec: hc.local.login_flow, hc.local.breaker, hc.local.lat_mode.

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../media/media_deps.dart';
import 'camera_dtos.dart';
import 'camera_transport.dart';
import 'local_crypto.dart';
import 'tapo_errors.dart';
import 'tpap.dart';

const _sessionExpired = -40401;
const _protocolFormatError = -40210;
const _invalidNonce = -40413;
const _tpapRequired = -40211;
const _lockCodes = {-40404, -40408};
const _tpapSessionErrors = {-40401, -40418, -40420, -40421, -2402};

/// Secrets of one camera. Never printed.
class LocalSecrets {
  const LocalSecrets({this.password = '', this.lat});
  final String password;

  /// Cloud-issued local access token (LAT mode), or null.
  final String? lat;

  @override
  String toString() => 'LocalSecrets(<hidden>)';
}

/// :8800 media credentials from the camera's local secrets: the LAT when one
/// is known, else the cloud password (Windows vod/session.py `_secret`,
/// [spec:lat.media.digest]). User `admin`.
class LocalSecretsMediaAuth implements LocalMediaAuth {
  const LocalSecretsMediaAuth(this.secrets);
  final LocalSecrets secrets;

  @override
  String get digestSecret {
    final lat = secrets.lat;
    return (lat != null && lat.isNotEmpty) ? lat : secrets.password;
  }

  @override
  String get username => 'admin';

  @override
  String toString() => 'LocalSecretsMediaAuth(<hidden>)';
}

/// TDP hint for the first login step.
enum LocalProtocolHint { probe, tpap }

class _Session {
  _Session({
    required this.stok,
    required this.secure,
    this.keys,
    this.cnonce = '',
    this.seq = 0,
    this.tpap,
    this.expiresAt,
    this.secret = '',
  });
  final String stok;
  final bool secure;
  final V3SessionKeys? keys;
  final String cnonce;
  int seq;
  final TpapSession? tpap;
  final DateTime? expiresAt;
  final String secret;

  @override
  String toString() => '_Session(secure: $secure)';
}

class _SessionInvalid implements Exception {
  _SessionInvalid(this.error);
  final TapoError error;
}

int _asInt(Object? value, String what) {
  if (value is int) return value;
  if (value is String) {
    final p = int.tryParse(value);
    if (p != null) return p;
  }
  throw TapoProtocolError('Camera reply $what is not an integer');
}

int _errorCode(Map<String, dynamic> obj) =>
    obj.containsKey('error_code') ? _asInt(obj['error_code'], 'error_code') : 0;

Map<String, dynamic> _resultOf(Map<String, dynamic> obj) {
  final r = obj['result'];
  return r is Map ? Map<String, dynamic>.from(r) : <String, dynamic>{};
}

Map<String, dynamic> _parseJson(List<int> body) {
  try {
    final obj = jsonDecode(utf8.decode(body));
    if (obj is Map) return Map<String, dynamic>.from(obj);
  } on FormatException {
    throw TapoProtocolError('Camera reply is not JSON');
  }
  throw TapoProtocolError('Camera reply is not a JSON object');
}

class CameraControlClient {
  /// [clock] drives the 120 s breaker. [cnonce] overrides the random cnonce.
  /// [rng]/[sleep] feed the TPAP authenticator.
  CameraControlClient({
    required CameraChannel channel,
    required LocalSecrets secrets,
    LocalProtocolHint hint = LocalProtocolHint.probe,
    int userHashType = 0,
    DateTime Function()? clock,
    String Function()? cnonce,
    Random? rng,
    Future<void> Function(Duration d)? sleep,
  })  : _channel = channel,
        _secrets = secrets,
        _userHashType = userHashType,
        _clock = clock ?? DateTime.now,
        _cnonce = cnonce ?? generateCnonce,
        _rng = rng,
        _sleep = sleep,
        _useTpap = hint == LocalProtocolHint.tpap;

  final CameraChannel _channel;
  final LocalSecrets _secrets;
  final int _userHashType;
  final DateTime Function() _clock;
  final String Function() _cnonce;
  final Random? _rng;
  final Future<void> Function(Duration d)? _sleep;

  bool _useTpap;
  bool _tpapConfirmed = false;
  TpapAuthenticator? _tpapAuth;
  _Session? _session;
  TapoAuthError? _authError;
  DateTime? _blockedUntil;
  Future<void> _tail = Future<void>.value();

  /// Breaker length after an auth failure.
  static const authBackoff = Duration(seconds: 120);

  String get _lat => _secrets.lat ?? '';

  /// `login` steps: v3 step 1 -> (-40211 TPAP | -40413 v3 | else legacy).
  /// Throws `TapoAuthError`, `TapoLockedError` (-40404/-40408, not breakered),
  /// `TapoProtocolError`. While the breaker is armed it fails fast with the
  /// same error and sends nothing.
  Future<void> login() => _serialized(_loginGuarded);

  /// Serialises login and every seq/tag/POST critical section.
  Future<T> _serialized<T>(Future<T> Function() action) {
    final done = Completer<T>();
    final previous = _tail;
    _tail = done.future.then<void>((_) {}, onError: (Object _) {});
    previous.then((_) async {
      try {
        done.complete(await action());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  Future<void> _loginGuarded() async {
    final blocked = _blockedUntil;
    final error = _authError;
    if (blocked != null && error != null && _clock().isBefore(blocked)) {
      throw TapoAuthError(error.message);
    }
    try {
      await _loginImpl();
    } on TapoLockedError {
      rethrow;
    } on TapoAuthError catch (e) {
      _authError = e;
      _blockedUntil = _clock().add(authBackoff);
      rethrow;
    }
    _authError = null;
    _blockedUntil = null;
  }

  /// Time until a new login is allowed after an auth failure, else null.
  Duration? get authRetryAfter {
    final blocked = _blockedUntil;
    if (blocked == null || _authError == null) return null;
    final left = blocked.difference(_clock());
    return left.isNegative || left == Duration.zero ? null : left;
  }

  /// Clears the breaker (user re-entered the password or the LAT changed).
  void resetAuthBackoff() {
    _authError = null;
    _blockedUntil = null;
  }

  /// Session valid (a login succeeded and has not been invalidated).
  bool get loggedIn => _session != null;

  /// `'tpap'`, `'secure'` or `'legacy'` for the current session, else null.
  String? get protocol {
    final s = _session;
    if (s == null) return null;
    if (s.tpap != null) return 'tpap';
    return s.secure ? 'secure' : 'legacy';
  }

  /// True when a cloud-issued local access token was given.
  bool get usesLocalToken => _lat.isNotEmpty;

  /// Credentials for this camera's :8800 media port (same secrets as the
  /// control login: LAT first, then the cloud password).
  LocalMediaAuth get mediaAuth => LocalSecretsMediaAuth(_secrets);

  // ------------------------------------------------------------------ login

  Future<void> _loginImpl() async {
    _session = null;
    if (_useTpap) {
      try {
        _session = await _tpapLogin();
        return;
      } on TpapNotSupported {
        if (_tpapConfirmed) rethrow;
        _useTpap = false;
      }
    }
    final cnonce = _cnonce();
    final resp = await _postLogin({'cnonce': cnonce, 'encrypt_type': '3', 'username': 'admin'});
    final code = _errorCode(resp);
    _raiseIfLocked(code, resp);
    if (code == _tpapRequired) {
      _useTpap = true;
      _tpapConfirmed = true;
      _session = await _tpapLogin();
      return;
    }
    final data = _resultOf(resp)['data'];
    if (code == _invalidNonce &&
        data is Map &&
        data['nonce'] is String &&
        data['device_confirm'] is String) {
      _session = await _secureLogin(cnonce, data['nonce'] as String, data['device_confirm'] as String);
    } else {
      _session = await _legacyLogin();
    }
  }

  Future<_Session> _tpapLogin() async {
    final auth = _tpapAuth ??= TpapAuthenticator(
      postLogin: _postLogin,
      password: _secrets.password,
      localToken: _secrets.lat,
      tpapHints: {'user_hash_type': _userHashType},
      rng: _rng == null ? null : (n) => Uint8List.fromList(List.generate(n, (_) => _rng.nextInt(256))),
      sleep: _sleep,
    );
    final t = await auth.login();
    final expires = t.expiresIn;
    return _Session(
      stok: t.stok,
      secure: true,
      seq: t.startSeq,
      tpap: t,
      expiresAt: (expires != null && expires > 0) ? _clock().add(Duration(seconds: expires)) : null,
    );
  }

  String? _secretFor(String cnonce, String nonce, String deviceConfirm) {
    for (final secret in [if (_lat.isNotEmpty) _lat, _secrets.password]) {
      if (secret.isEmpty) continue;
      final expected = v3ExpectedDeviceConfirm(secret: secret, cnonce: cnonce, nonce: nonce);
      if (verifyDeviceConfirm(expected, deviceConfirm)) return secret;
    }
    return null;
  }

  Future<_Session> _secureLogin(String cnonce, String nonce, String deviceConfirm) async {
    final secret = _secretFor(cnonce, nonce, deviceConfirm);
    if (secret == null) {
      throw TapoAuthError(_lat.isNotEmpty
          ? 'The camera did not confirm the password: neither the local access token nor the TP-Link ID password matches'
          : 'The camera did not confirm the password: wrong password, or the camera uses a cloud-synced local access token');
    }
    final firstHash = v3FirstHash(secret: secret, cnonce: cnonce, nonce: nonce);
    final keys = deriveV3SessionKeys(cnonce: cnonce, nonce: nonce, firstHash: firstHash);
    final resp = await _postLogin({
      'cnonce': cnonce,
      'encrypt_type': '3',
      'username': 'admin',
      'digest_passwd': v3DigestPasswd(secret: secret, cnonce: cnonce, nonce: nonce),
    });
    final code = _errorCode(resp);
    _raiseIfLocked(code, resp);
    if (code != 0) throw TapoAuthError('Secure login rejected by the camera (error $code)');
    final res = _resultOf(resp);
    return _Session(
      stok: _stok(res),
      secure: true,
      keys: keys,
      cnonce: cnonce,
      seq: _asInt(res['start_seq'], 'start_seq'),
      secret: secret,
    );
  }

  Future<_Session> _legacyLogin() async {
    final resp = await _postLogin({
      'hashed': true,
      'password': md5Upper(_secrets.password),
      'username': 'admin',
    });
    final code = _errorCode(resp);
    _raiseIfLocked(code, resp);
    if (code != 0) throw TapoAuthError('Login rejected by the camera (error $code)');
    return _Session(stok: _stok(_resultOf(resp)), secure: false);
  }

  static String _stok(Map<String, dynamic> res) {
    final stok = res['stok'];
    if (stok is! String || stok.isEmpty) throw TapoProtocolError('Login reply has no stok');
    return stok;
  }

  static void _raiseIfLocked(int code, Map<String, dynamic> resp) {
    if (!_lockCodes.contains(code)) return;
    final data = _resultOf(resp)['data'];
    final left = data is Map ? data['sec_left'] : null;
    throw TapoLockedError(
      'The camera is blocking logins after too many failures (error $code)',
      secLeft: left is int ? left : null,
    );
  }

  Future<Map<String, dynamic>> _postLogin(Map<String, dynamic> params) async {
    final response = await _channel.post(
      '/',
      utf8.encode(jsonEncode({'method': 'login', 'params': params})),
    );
    if (response.status == 401) throw TapoAuthError('Login rejected (HTTP 401)');
    if (response.status != 200) {
      throw TapoProtocolError('Login answered with HTTP ${response.status}');
    }
    return _parseJson(response.body);
  }

  // --------------------------------------------------------------- requests

  /// Sends a batch through the session. Logs in first when there is no
  /// session (re-login once and retry once on
  /// session-invalid; a second failure raises). Seq is burned on every attempt.
  Future<List<ControlItem>> send(List<Map<String, dynamic>> requests) =>
      _serialized(() => _sendLocked(requests));

  Future<List<ControlItem>> _sendLocked(List<Map<String, dynamic>> requests) async {
    for (var attempt = 1;; attempt++) {
      final s = _session;
      if (s != null && s.expiresAt != null && !_clock().isBefore(s.expiresAt!)) _session = null;
      if (_session == null) await _loginGuarded();
      try {
        return await _sendBatch(requests);
      } on _SessionInvalid catch (invalid) {
        _session = null;
        if (attempt >= 2) throw invalid.error;
      }
    }
  }

  Future<List<ControlItem>> _sendBatch(List<Map<String, dynamic>> requests) async {
    final reply = await _postDs(buildMultipleRequest(requests));
    final code = _errorCode(reply);
    if (code == _sessionExpired) {
      throw _SessionInvalid(TapoSessionInvalid('The camera session expired'));
    }
    final items = parseMultipleResponse(reply);
    for (final item in items) {
      if (item.errorCode == _sessionExpired) {
        throw _SessionInvalid(TapoSessionInvalid('The camera session expired'));
      }
    }
    return items;
  }

  Future<Map<String, dynamic>> _postDs(Map<String, dynamic> inner) async {
    final sess = _session!;
    final path = '/stok=${sess.stok}/ds';
    if (sess.tpap != null) return _postTpap(sess, path, inner);
    final innerJson = jsonEncode(inner);
    if (!sess.secure) {
      return _checked(await _channel.post(path, utf8.encode(innerJson)));
    }
    final seq = sess.seq;
    sess.seq += 1; // consumed whether or not the request succeeds
    final outerBody = wrapSecurePassthrough(v3Encrypt(sess.keys!, innerJson));
    final tag = v3ComputeTag(
      password: sess.secret.isEmpty ? _secrets.password : sess.secret,
      cnonce: sess.cnonce,
      outerBody: outerBody,
      seq: seq,
    );
    final outer = _checked(await _channel.post(
      path,
      utf8.encode(outerBody),
      headers: {'seq': '$seq', 'tapo_tag': tag},
    ));
    final code = _errorCode(outer);
    if (code == _sessionExpired) {
      throw _SessionInvalid(TapoSessionInvalid('The camera session expired'));
    }
    if (code == _protocolFormatError) {
      throw _SessionInvalid(TapoDeviceError('securePassthrough rejected', code: code, method: 'securePassthrough'));
    }
    if (code != 0) {
      throw TapoDeviceError('securePassthrough rejected', code: code, method: 'securePassthrough');
    }
    final encrypted = _resultOf(outer)['response'];
    if (encrypted is! String) {
      throw TapoProtocolError('securePassthrough reply has no encrypted payload');
    }
    try {
      return _parseJson(utf8.encode(v3Decrypt(sess.keys!, encrypted)));
    } on TapoProtocolError catch (e) {
      throw _SessionInvalid(e);
    }
  }

  Future<Map<String, dynamic>> _postTpap(_Session sess, String path, Map<String, dynamic> inner) async {
    final tpap = sess.tpap!;
    final seq = sess.seq;
    sess.seq += 1; // every attempt burns a seq
    final body = tpap.cipher.seal(Uint8List.fromList(utf8.encode(jsonEncode(inner))), seq);
    final response = await _channel.post(path, body, headers: {
      'Content-Type': 'application/octet-stream',
      'Accept': 'application/octet-stream',
    });
    if (response.status == 401) throw _SessionInvalid(TapoSessionInvalid('The camera session expired'));
    if (response.status != 200) {
      throw _SessionInvalid(TapoProtocolError('The camera answered with HTTP ${response.status}'));
    }
    final refusal = TpapCipher.plaintextRefusalCode(response.body);
    if (refusal != null) {
      if (_tpapSessionErrors.contains(refusal)) {
        throw _SessionInvalid(TapoSessionInvalid('The camera session expired'));
      }
      _session = null;
      throw TapoDeviceError('The camera refused the request', code: refusal, method: 'multipleRequest');
    }
    try {
      final (_, plain) = tpap.cipher.open(response.body);
      return _parseJson(plain);
    } on TapoError {
      throw _SessionInvalid(TapoProtocolError('TPAP reply could not be decrypted'));
    }
  }

  Map<String, dynamic> _checked(ChannelResponse response) {
    if (response.status == 401) throw _SessionInvalid(TapoSessionInvalid('The camera session expired'));
    if (response.status != 200) {
      throw TapoProtocolError('The camera answered with HTTP ${response.status}');
    }
    return _parseJson(response.body);
  }

  void close() {
    _session = null;
    _channel.close();
  }
}
