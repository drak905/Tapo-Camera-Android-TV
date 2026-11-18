// Wire-level mock of a Tapo camera's HTTPS :443 control API (server side), on
// loopback with an ephemeral port and a self-signed certificate generated at
// test time. Port of tests/fixtures/mock_tapo_server/{https_server,camera}.py.
//
// Protocols (CameraProtocol):
//  secure  v3 login: POST / {cnonce, encrypt_type:"3", username} -> -40413 +
//          nonce + device_confirm; then {digest_passwd} -> stok + start_seq;
//          POST /stok=<stok>/ds with headers seq + tapo_tag and a
//          securePassthrough body (AES-128-CBC with lsk / ivb).
//  legacy  POST / {"method":"login","params":{"hashed":true,"password":MD5U,
//          "username":"admin"}} -> stok; plain JSON on /stok=<stok>/ds.
//  tpap    SPAKE2+ login + AES-128-CCM /ds (see tpap_server.dart). The v3 and
//          legacy probes answer -40211.
//
// Camera-side error behaviour (HTTP 200 unless noted):
//  unknown/expired stok, bad/missing tapo_tag, replayed seq      -> -40401
//  undecodable securePassthrough / non-JSON body                  -> -40210
//  wrong digest_passwd / legacy password                          -> -40401
//  locked                                                         -> -40404 {sec_left}
//  legacy camera answering a v3 step 1                            -> -40210
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'camera_state.dart';
import 'fx_crypto.dart';
import 'tls_cert.dart';
import 'tpap_server.dart';

enum CameraProtocol { secure, legacy, tpap }

/// Passcode the TPAP camera expects ("lat" = the cloud-issued local access token).
enum TpapCredential { md5, sha256Extra, lat }

/// Error of real C510W firmware for searchVideoWithUTC without player_id.
const int clipSearchFormError = -71103;

class LoggedCall {
  LoggedCall(this.method, this.params);
  final Object? method;
  final Object? params;
}

class _SecureSession {
  _SecureSession(this.stok, this.password, this.cnonce, this.nonce, this.lsk,
      this.ivb, this.nextSeq, this.tagPrefix);
  final String stok;
  final String password;
  final String cnonce;
  final String nonce;
  final Uint8List lsk;
  final Uint8List ivb;
  int nextSeq;
  final String tagPrefix;
}

class MockCamera {
  MockCamera({
    this.protocol = CameraProtocol.secure,
    this.cloudPassword = 'cloudpass',
    this.tpapCredential = TpapCredential.md5,
    this.localToken = '',
    String model = 'C210',
    String alias = 'Mock Camera',
    String deviceId = '80231A1F3B9E2C4D5E6F708192A3B4C5D6E7F801',
    String mac = 'AA-BB-CC-DD-EE-FF',
    bool dualLens = false,
    List<Recording>? recordings,
    this.host = '127.0.0.1',
    this.httpsPort = 0,
    this.fixedNonce,
    this.fixedStartSeq,
    this.maxFailedLogins = 0,
    this.lockoutSeconds = 1800,
    this.clipSearchRequiresPlayerId = false,
    this.tpapIterations = 1000,
    this.tpapUsername = 'md5',
    this.tpapBadDevConfirm = false,
    this.tpapRefuseShares = 0,
    this.tpapSessionExpired = 3600,
  }) : state = DeviceShadow(
          model: model,
          alias: alias,
          deviceId: deviceId,
          mac: mac,
          recordings: recordings,
          components: defaultComponents(dualLens: dualLens),
        ) {
    if (tpapCredential == TpapCredential.lat && localToken.isEmpty) {
      throw ArgumentError('tpapCredential lat needs a localToken');
    }
  }

  final CameraProtocol protocol;
  final String cloudPassword;
  final TpapCredential tpapCredential;

  /// LAT mode: the camera's admin secret is this string (may change while running).
  String localToken;
  final String host;
  final int httpsPort;

  /// Fixed v3 nonce / start_seq make the login deterministic (golden vectors).
  String? fixedNonce;
  int? fixedStartSeq;

  /// Automatic lockout after N bad logins (0 = off) for [lockoutSeconds].
  int maxFailedLogins;
  double lockoutSeconds;

  /// true: searchVideoWithUTC without player_id answers -71103 (C510W).
  bool clipSearchRequiresPlayerId;

  // TPAP knobs
  int tpapIterations;
  String tpapUsername; // "md5" = md5_hex("admin") like the app, "admin" = literal
  bool tpapBadDevConfirm;
  int tpapRefuseShares; // refuse the next N correct pake_share with -40401
  int tpapSessionExpired;

  /// Mutable device state (privacy, PTZ, recordings, ...).
  final DeviceShadow state;

  // ---- counters / logs ------------------------------------------------------
  /// Every POST / login request that reached the camera (incl. probes). Assert "no loops" on it.
  int loginAttempts = 0;

  /// Successful logins.
  int loginCount = 0;
  int v3ProbeCount = 0;
  int tpapRegisterCount = 0;
  int tpapShareAttempts = 0;
  final List<int> tpapDsSeqs = [];

  /// Number of /ds requests served so far (also counts refused ones).
  int dsRequestCount = 0;

  /// Commands run through [execute] (HTTPS and the cloud passthrough).
  final List<LoggedCall> requestLog = [];

  /// Whole decrypted inner bodies received over HTTPS.
  final List<Object?> rawRequestLog = [];

  // ---- internals ------------------------------------------------------------
  HttpServer? _server;
  TestCert? _cert;
  TpapEndpoint? tpap;
  final Map<String, String> _pending = {}; // cnonce -> nonce
  final Map<String, _SecureSession> _sessions = {};
  final Set<String> _legacyStoks = {};
  int _tokenExpiryEvery = 0;
  final Map<String, List<int>> _errors = {};
  final List<int> _httpStatus = [];
  DateTime _lockedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  int _failures = 0;

  // ---- lifecycle ------------------------------------------------------------
  Future<MockCamera> start() async {
    if (_server != null) return this;
    if (protocol == CameraProtocol.tpap) tpap = TpapEndpoint(this);
    _cert = generateTestCert(commonName: state.model);
    _server = await HttpServer.bindSecure(
        InternetAddress(host), httpsPort, _cert!.serverContext());
    _server!.listen(_onRequest, onError: (Object _) {});
    return this;
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    await s?.close(force: true);
  }

  int get port => _server!.port;

  /// Lower-case hex SHA-256 of the DER certificate.
  String get certFingerprint => _cert?.fingerprint ?? '';
  String get certPem => _cert?.certPem ?? '';

  /// New self-signed certificate for new TLS handshakes; returns its fingerprint.
  Future<String> rotateCertificate() async {
    // dart:io cannot swap the context of a bound server, so rebind on the same port.
    final p = port;
    await _server!.close(force: true);
    _cert = generateTestCert(commonName: state.model);
    _server = await HttpServer.bindSecure(
        InternetAddress(host), p, _cert!.serverContext());
    _server!.listen(_onRequest, onError: (Object _) {});
    return _cert!.fingerprint;
  }

  /// Password the camera's v3 login and :8800 digest expect: the LAT in LAT mode.
  String get deviceSecret =>
      tpapCredential == TpapCredential.lat ? localToken : cloudPassword;

  bool get secure => protocol != CameraProtocol.legacy;

  // ---- injections -----------------------------------------------------------
  /// Drops every session (next /ds answers -40401).
  void expireSessions() {
    _sessions.clear();
    _legacyStoks.clear();
    tpap?.expire();
  }

  /// Every Nth /ds request expires the session (0 = off).
  void injectTokenExpiry(int everyN) {
    _tokenExpiryEvery = everyN < 0 ? 0 : everyN;
    dsRequestCount = 0;
  }

  /// The next [times] calls of [method] answer [code] as the item error_code.
  void injectError(String method, int code, {int times = 1}) {
    _errors.putIfAbsent(method, () => []).addAll(List.filled(times, code));
  }

  /// The next [times] POSTs answer this HTTP status with {"error_code":-1}.
  void injectHttpStatus(int status, {int times = 1}) {
    _httpStatus.addAll(List.filled(times, status));
  }

  void lockLogin(Duration d) => _lockedUntil = DateTime.now().add(d);

  // ---- hooks used by the TPAP endpoint -------------------------------------
  double lockRemainingSeconds() {
    final ms = _lockedUntil.difference(DateTime.now()).inMilliseconds;
    return ms > 0 ? ms / 1000.0 : 0.0;
  }

  void registerFailure() {
    _failures++;
    if (maxFailedLogins > 0 && _failures >= maxFailedLogins) {
      _lockedUntil = DateTime.now().add(Duration(milliseconds: (lockoutSeconds * 1000).round()));
      _failures = 0;
    }
  }

  void resetFailures() => _failures = 0;

  bool expiryFires() {
    dsRequestCount++;
    return _tokenExpiryEvery > 0 && dsRequestCount % _tokenExpiryEvery == 0;
  }

  // ---- command execution (HTTPS /ds and the cloud services-sync passthrough) -
  (int, Map<String, dynamic>) execute(Object? method, Object? params) {
    requestLog.add(LoggedCall(method, params));
    final q = method is String ? _errors[method] : null;
    if (q != null && q.isNotEmpty) return (q.removeAt(0), <String, dynamic>{});
    if (clipSearchRequiresPlayerId && method == 'searchVideoWithUTC') {
      final inner = params is Map && params['playback'] is Map
          ? (params['playback'] as Map)['search_video_with_utc']
          : null;
      if (inner is Map && !inner.containsKey('player_id')) {
        return (clipSearchFormError, <String, dynamic>{});
      }
    }
    final r = dispatchCommand(state, method, params);
    if (r.$1 == 0 && method == 'rebootDevice') expireSessions();
    return r;
  }

  /// Handles a decrypted inner request (single command or multipleRequest).
  Map<String, dynamic> handleInner(Object? inner) {
    rawRequestLog.add(inner);
    if (inner is! Map) return {'error_code': -40210};
    final method = inner['method'];
    final params = inner['params'];
    if (method == 'multipleRequest') {
      final reqs = params is Map ? params['requests'] : null;
      if (reqs is! List) return {'error_code': -40210};
      final responses = <Map<String, dynamic>>[];
      for (final r in reqs) {
        final m = r is Map ? r['method'] : null;
        final p = r is Map ? r['params'] : null;
        final (code, result) = execute(m, p);
        responses.add({'method': m, 'result': result, 'error_code': code});
      }
      return {
        'error_code': 0,
        'result': {'responses': responses}
      };
    }
    final (code, result) = execute(method, params);
    return {'error_code': code, 'method': method, 'result': result};
  }

  // ---- HTTP -----------------------------------------------------------------
  static final RegExp _dsRe = RegExp(r'^/stok=([^/]+)/ds/?$');
  static final RegExp _cnonceRe = RegExp(r'^[0-9A-F]{16}$');

  Future<void> _send(HttpResponse res, int status, Object payload,
      [String ctype = 'application/json; charset=UTF-8']) async {
    final data = payload is Uint8List ? payload : utf8Bytes(compactJson(payload));
    res.statusCode = status;
    res.headers.set(HttpHeaders.contentTypeHeader, ctype);
    res.headers.set(HttpHeaders.serverHeader, 'lighttpd');
    res.contentLength = data.length;
    res.add(data);
    await res.close();
  }

  Future<void> _onRequest(HttpRequest req) async {
    try {
      await _handle(req);
    } catch (_) {
      try {
        req.response.statusCode = 500;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    if (req.method != 'POST') {
      await _send(res, 404, {'error_code': -40106});
      return;
    }
    final builder = await req.fold<BytesBuilder>(BytesBuilder(copy: false), (b, d) => b..add(d));
    final raw = builder.takeBytes();
    if (_httpStatus.isNotEmpty) {
      await _send(res, _httpStatus.removeAt(0), {'error_code': -1});
      return;
    }
    final path = req.uri.path;
    final m = _dsRe.firstMatch(path);
    if (tpap != null && m != null) {
      final r = tpap!.handleDs(m.group(1)!, raw);
      await _send(res, 200, r.body, r.contentType);
      return;
    }
    String body;
    try {
      body = utf8.decode(raw);
    } on FormatException {
      await _send(res, 200, {'error_code': -40210});
      return;
    }
    if (path == '/' || path.isEmpty) {
      Object? j;
      try {
        j = jsonDecode(body);
      } on FormatException {
        await _send(res, 200, {'error_code': -40210});
        return;
      }
      if (j is! Map || j['method'] != 'login') {
        await _send(res, 200, {'error_code': -40401});
        return;
      }
      await _send(res, 200, handleLogin(j['params']));
      return;
    }
    if (m == null) {
      await _send(res, 404, {'error_code': -40106});
      return;
    }
    await _send(res, 200, handleDs(m.group(1)!, body, req.headers));
  }

  // ---- login ----------------------------------------------------------------
  Map<String, dynamic> handleLogin(Object? params) {
    if (tpap != null) return tpap!.handleLogin(params);
    loginAttempts++;
    if (params is! Map) return {'error_code': -40210};
    final left = lockRemainingSeconds();
    if (left > 0) {
      return {
        'error_code': -40404,
        'result': {
          'data': {'code': -40404, 'sec_left': left.floor() + 1}
        }
      };
    }
    if ((params['username'] ?? 'admin') != 'admin') return _failed();
    return protocol == CameraProtocol.secure ? _secureLogin(params) : _legacyLogin(params);
  }

  Map<String, dynamic> _failed() {
    registerFailure();
    return {
      'error_code': -40401,
      'result': {
        'data': {'code': -40401}
      }
    };
  }

  Map<String, dynamic> _challenge(String cnonce) {
    final nonce = fixedNonce ?? randomHex(8, upper: true);
    _pending[cnonce] = nonce;
    return {
      'error_code': -40413,
      'result': {
        'data': {
          'code': -40401,
          'encrypt_type': ['3'],
          'key': b64e(randomBytes(18)).replaceAll('+', '-').replaceAll('/', '_'),
          'nonce': nonce,
          'device_confirm': deviceConfirm(deviceSecret, cnonce, nonce),
        }
      }
    };
  }

  Map<String, dynamic> _secureLogin(Map params) {
    final cnonce = params['cnonce'];
    if (params['encrypt_type'] != '3' || cnonce is! String) {
      // legacy-style login sent to a secure camera: advertise encryption, no nonce
      return {
        'error_code': -40413,
        'result': {
          'data': {
            'code': -40401,
            'encrypt_type': ['3'],
            'key': b64e(randomBytes(18)),
          }
        }
      };
    }
    if (!_cnonceRe.hasMatch(cnonce)) return {'error_code': -40210};
    final dp = params['digest_passwd'];
    if (dp == null) return _challenge(cnonce);
    final nonce = _pending.remove(cnonce);
    if (nonce == null) return _challenge(cnonce); // unknown / consumed nonce
    final pwd = deviceSecret;
    if (dp is! String || !constTimeEqStr(dp, digestPasswd(pwd, cnonce, nonce))) {
      return _failed();
    }
    final keys = sessionKeys(pwd, cnonce, nonce);
    final stok = randomHex(16);
    final startSeq = fixedStartSeq ?? (randomBytes(2).buffer.asByteData().getUint16(0) % 9000 + 100);
    _sessions[stok] = _SecureSession(
        stok, pwd, cnonce, nonce, keys.lsk, keys.ivb, startSeq, tagPrefix(pwd, cnonce));
    loginCount++;
    resetFailures();
    return {
      'error_code': 0,
      'result': {'stok': stok, 'user_group': 'root', 'start_seq': startSeq}
    };
  }

  Map<String, dynamic> _legacyLogin(Map params) {
    if (!params.containsKey('password')) return {'error_code': -40210};
    final pw = params['password'];
    final expected = params['hashed'] == true ? md5Upper(cloudPassword) : cloudPassword;
    if (pw is! String || !constTimeEqStr(pw, expected)) return _failed();
    final stok = randomHex(16);
    _legacyStoks.add(stok);
    loginCount++;
    resetFailures();
    return {
      'error_code': 0,
      'result': {'stok': stok, 'user_group': 'root'}
    };
  }

  // ---- data -----------------------------------------------------------------
  Map<String, dynamic> handleDs(String stok, String body, HttpHeaders headers) {
    if (secure) {
      final sess = _sessions[stok];
      if (sess == null) return {'error_code': -40401};
      if (expiryFires()) {
        _sessions.remove(stok);
        return {'error_code': -40401};
      }
      final seq = int.tryParse(headers.value('seq') ?? '');
      final tag = headers.value('tapo_tag');
      if (seq == null || tag == null) return {'error_code': -40401};
      final expected = sha256Upper(sess.tagPrefix + body + seq.toString());
      if (!constTimeEqStr(tag.trim().toUpperCase(), expected)) {
        return {'error_code': -40401};
      }
      if (seq < sess.nextSeq) return {'error_code': -40401};
      sess.nextSeq = seq + 1;
      Object? inner;
      try {
        final outer = jsonDecode(body) as Map;
        if (outer['method'] != 'securePassthrough') return {'error_code': -40210};
        inner = jsonDecode(b64Decrypt(sess.lsk, sess.ivb, (outer['params'] as Map)['request'] as String));
      } catch (_) {
        return {'error_code': -40210};
      }
      final reply = handleInner(inner);
      return {
        'error_code': 0,
        'result': {'response': b64Encrypt(sess.lsk, sess.ivb, compactJson(reply))}
      };
    }
    if (!_legacyStoks.contains(stok)) return {'error_code': -40401};
    if (expiryFires()) {
      _legacyStoks.remove(stok);
      return {'error_code': -40401};
    }
    Object? inner;
    try {
      inner = jsonDecode(body);
    } on FormatException {
      return {'error_code': -40210};
    }
    return handleInner(inner);
  }
}
