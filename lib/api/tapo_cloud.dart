// Dart port of upstream `tapo_cloud_probe.py` + the relay part of
// `tapo_cloud_app.py` (https://github.com/filirnd/topo), brought in line with
// the Windows client (`core/cloud/client.py`, app 3.22.806).
//
// It talks only to the Tapo cloud: account login with MFA, device list,
// service discovery, camera control through the IoT gateway, and the CIPC
// video relay. The API is private and undocumented; it may change.
// Secrets (password, token) stay in memory and never appear in messages.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'cloud_transport.dart';
import 'lan_matcher.dart' show normaliseMac;
import 'tapo_signing.dart';

const appName = 'TP-Link_Tapo_Android';
const appVersion = '3.22.806';
const productName = 'Topo TV';
const loginUrl = 'https://n-wap.i.tplinkcloud.com';
const defaultCipcUrl = 'https://cipc.api.cloud';

/// Service id of the IoT app server (thing list with local access tokens).
const iotServiceId = 'nbu.iot-app-server.app-v2';
const cipcServiceId = 'cipc.api.cloud';

const _platformName = 'Android 14';
const _jsonType = 'application/json;charset=UTF-8';
const _requestDeviceTypes = ['SMART.IPCAMERA', 'SMART.TAPODOORBELL', 'SMART.TAPOHUB'];
const _cameraDeviceTypes = {'SMART.IPCAMERA', 'SMART.TAPODOORBELL'};
const _tokenErrors = {-20651, -20652, -20675};

const _deviceErrorMessages = {
  -64303: 'Motor busy, wait for the movement to finish',
  -64304: 'Maximum pan/tilt limit reached',
  -64324: 'Privacy mode is on',
  -64336: 'Movement blocked by a privacy zone',
};

const _authMessages = {
  -20004: 'Sign-in failed. Check your email and password.',
  -20200: 'That email address is not valid.',
  -20202: 'That user name is not valid.',
  -20600: 'No TP-Link ID exists for this email.',
  -20601: 'Incorrect email or password.',
  -20602: 'This TP-Link ID is not activated yet. Open the activation email first.',
  -20607: 'Sign-in failed. Check your email and password.',
  -20615: 'Incorrect email or password.',
  -20661: 'Too many failed attempts. The account is locked.',
  -20676: 'Verification failed. Check the code and try again.',
  -20681: 'Sign-in failed. Try again later.',
  -20697: 'Sign-in failed. Try again later.',
  -20708: 'Sign-in failed. Try again later.',
};

const _mfaSendPaths = {
  1: '/api/v2/account/getPushVC4TerminalMFA',
  2: '/api/v2/account/getEmailVC4TerminalMFA',
  4: '/api/v2/account/getSmsVC4TerminalMFA',
};

class TapoException implements Exception {
  TapoException(this.message, {this.code, this.details = const {}});
  final String message;
  final int? code;

  /// Cloud `result` map of the failed call (never shown to the user).
  final Map<String, dynamic> details;

  /// True when the cloud session token is no longer accepted.
  bool get isAuthError => _tokenErrors.contains(code);

  @override
  String toString() => message;
}

String randomUuid() => randomUuidV4();

int errorCode(Object? value) {
  if (value is! Map) return 0;
  for (final key in const ['error_code', 'errorCode']) {
    if (value.containsKey(key)) {
      final v = value[key];
      if (v is int) return v;
      return int.tryParse('$v') ?? 1;
    }
  }
  return 0;
}

Map<String, dynamic> resultOf(Map<String, dynamic> response) {
  final value = response['result'];
  return value is Map<String, dynamic> ? value : <String, dynamic>{};
}

int _intCode(Object? value) {
  if (value is int) return value;
  return int.tryParse('${value ?? ''}'.trim()) ?? 0;
}

TapoException _errorFor(int code, String msg, Map<String, dynamic> result) {
  final known = _authMessages[code];
  if (known != null) {
    var text = known;
    final locked = result['lockedMinutes'];
    final remain = result['remainAttempts'];
    if (code == -20661 && locked != null && '$locked' != '0') {
      text = 'Too many failed attempts. The account is locked for $locked minutes.';
    } else if ((code == -20601 || code == -20615) && remain is int) {
      text += ' $remain attempts left.';
    }
    return TapoException(text, code: code, details: result);
  }
  if (code == -23003) {
    return TapoException('This app version is too old for the TP-Link cloud.',
        code: code, details: result);
  }
  return TapoException('TP-Link cloud error $code${msg.isNotEmpty ? ': $msg' : ''}',
      code: code, details: result);
}

String _normaliseLocale(String raw) {
  final base = raw.split('.').first.split('@').first.replaceAll('-', '_');
  return base.contains('_') && base.length <= 8 ? base : 'en_US';
}

/// Approximation of Python's `str.isprintable` for alias decoding.
bool _isPrintable(String text) {
  if (text.isEmpty) return false;
  for (final c in text.runes) {
    if (c < 0x20 || (c >= 0x7F && c <= 0xA0) || c == 0xAD || c == 0xFFFD) return false;
    if (c == 0x1680 || (c >= 0x2000 && c <= 0x200F) || (c >= 0x2028 && c <= 0x202F)) return false;
    if ((c >= 0x205F && c <= 0x206F) || c == 0x3000 || c == 0xFEFF) return false;
    if (c >= 0xD800 && c <= 0xDFFF) return false;
  }
  return true;
}

final _base64Strict = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');

/// Result of [TapoCloud.login]: either a token or a pending MFA challenge.
class LoginResult {
  LoginResult(this.baseUrl, this.result);
  final String baseUrl;
  final Map<String, dynamic> result;

  String? get token {
    final t = result['token'];
    return t is String ? t : null;
  }

  String? get mfaProcessId => result['MFAProcessId']?.toString();
  List<int> get mfaTypes {
    final raw = result['supportedMFATypes'];
    if (raw is List && raw.isNotEmpty) {
      return raw.map((e) => int.tryParse('$e') ?? 2).toList();
    }
    return const [2];
  }
}

class RelayInfo {
  RelayInfo({
    required this.host,
    required this.port,
    required this.path,
    required this.token,
    required this.playerId,
    this.elbCookie,
  });
  final String host;
  final int port;
  final String path;
  final String token;
  final String playerId;
  final String? elbCookie;
}

class TapoCloud {
  TapoCloud({required this.terminalUuid, required SecurityContext context, String? locale})
      : _context = context,
        _transport = HttpCloudTransport(context),
        locale = _normaliseLocale(locale ?? Platform.localeName);

  TapoCloud._(this.terminalUuid, this._transport, this.locale) : _context = null;

  /// Test/DI constructor: every request goes through [transport] instead of
  /// `HttpClient`. [locale] is `xx_YY` (default `en_US`). Spec: hc.cloud.*.
  factory TapoCloud.withTransport({
    required String terminalUuid,
    required CloudTransport transport,
    String locale = 'en_US',
  }) =>
      TapoCloud._(terminalUuid, transport, _normaliseLocale(locale));

  /// TP-Link serves a CA chain that ships with the Tapo app but not with all
  /// trust stores. Keep the system roots and add those two public roots; TLS
  /// and hostname verification stay enabled.
  static SecurityContext buildContext(List<int> tpLinkRootsPem) {
    return SecurityContext(withTrustedRoots: true)
      ..setTrustedCertificatesBytes(tpLinkRootsPem);
  }

  final String terminalUuid;
  final String locale;
  final SecurityContext? _context;
  final CloudTransport _transport;

  /// Session token. Never printed.
  String token = '';

  String? _email;
  String? _password;
  String? _region;
  String _cipcUrl = defaultCipcUrl;
  String _servicesSyncVersion = 'v1';
  final Map<String, String> _serviceCache = {};

  @override
  String toString() => 'TapoCloud(signedIn: ${token.isNotEmpty})';

  /// Keeps the account secrets in memory so an expired token can be renewed
  /// silently (captchaLogin once on -20651, one full login on -20652/-20675).
  /// Never persisted here; never logged. Spec: hc.cloud.token_refresh.
  void rememberCredentials({
    required String username,
    required String password,
    required String baseUrl,
  }) {
    _email = username;
    _password = password;
    _region = baseUrl.replaceAll(RegExp(r'/+$'), '');
  }

  void close() => _transport.close();

  // ---------------------------------------------------------------- HTTP --

  static Uint8List _body(Map<String, dynamic> payload) =>
      Uint8List.fromList(utf8.encode(jsonEncode(payload)));

  Future<(int, Map<String, dynamic>)> _postRaw(
    Uri uri,
    Uint8List body,
    Map<String, String> headers,
  ) async {
    final CloudResponse response;
    try {
      response = await _transport.send(CloudRequest(
        method: 'POST',
        uri: uri,
        headers: headers,
        body: body,
      ));
    } on CloudTransportError catch (e) {
      throw TapoException(e.message);
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.body));
    } on FormatException {
      decoded = null;
    }
    if (decoded is! Map<String, dynamic>) {
      if (response.status >= 400) {
        throw TapoException('Cloud rejected the request (HTTP ${response.status})',
            code: response.status);
      }
      throw TapoException('Unexpected answer from the Tapo cloud');
    }
    return (response.status, decoded);
  }

  Map<String, String> _commonQuery({required bool withToken}) => {
        'appName': appName,
        'appVer': appVersion,
        'netType': 'wifi',
        'termID': terminalUuid,
        'ospf': _platformName,
        'brand': 'TPLINK',
        'locale': locale,
        if (withToken && token.isNotEmpty) 'token': token,
      };

  /// Signed POST of the account API; returns the `result` map or throws.
  Future<Map<String, dynamic>> _call(
    String baseUrl,
    String endpoint,
    Map<String, dynamic> payload, {
    bool withToken = false,
  }) async {
    final base = Uri.tryParse(baseUrl.replaceAll(RegExp(r'/+$'), ''));
    if (base == null || (base.scheme != 'https' && base.scheme != 'http') || base.host.isEmpty) {
      throw TapoException('Invalid cloud URL');
    }
    final body = _body(payload);
    final uri = base.replace(
      path: '${base.path}$endpoint',
      queryParameters: _commonQuery(withToken: withToken),
    );
    final signed = signCloudRequest(body: body, url: uri);
    final (status, env) = await _postRaw(uri, body, {
      'Content-Type': _jsonType,
      'Accept': 'application/json',
      'Content-MD5': signed.contentMd5,
      'X-Authorization': signed.xAuthorization,
      'User-Agent': 'okhttp/3.12.13',
    });
    final result = resultOf(env);
    var code = _intCode(env['errorCode']);
    if (code == 0) code = _intCode(result['errorCode']);
    if (code != 0) {
      throw _errorFor(code, '${env['msg'] ?? result['errorMsg'] ?? ''}', result);
    }
    if (status >= 400) throw TapoException('TP-Link cloud HTTP error $status', code: status);
    return result;
  }

  /// Signed call with the session token; renews an expired token once.
  Future<Map<String, dynamic>> _signedCall(
    String baseUrl,
    String endpoint,
    Map<String, dynamic> payload,
  ) async {
    var relogged = false;
    while (true) {
      try {
        return await _call(baseUrl, endpoint, payload, withToken: true);
      } on TapoException catch (e) {
        if (relogged || !_tokenErrors.contains(e.code)) rethrow;
        relogged = true;
        await _relogin(captcha: e.code == -20651);
      }
    }
  }

  /// Silent re-login with the stored credentials [spec hc.cloud.token_refresh].
  Future<void> _relogin({required bool captcha}) async {
    final email = _email, password = _password, region = _region;
    if (email == null || password == null || region == null) {
      throw TapoException('Session expired, sign in again', code: -20651);
    }
    token = '';
    _serviceCache.clear();
    final result = await _call(
      region,
      captcha ? '/api/v2/account/captchaLogin' : '/api/v2/account/login',
      _loginPayload(email, password),
    );
    final fresh = result['token'];
    if (fresh is! String || fresh.isEmpty) {
      throw TapoException('The TP-Link cloud returned no session token');
    }
    token = fresh;
  }

  // ------------------------------------------------------------ Services --

  /// Signed `getAppServiceUrl` call for [serviceIds]. Values that are not
  /// non-empty strings are dropped and a trailing `/` is stripped. The result
  /// is cached per session and cleared on re-login. Spec: hc.cloud.service_urls.
  Future<Map<String, String>> serviceUrls(String baseUrl, List<String> serviceIds) async {
    final ids = serviceIds.where((s) => s.isNotEmpty).toList();
    if (ids.isEmpty) return {};
    final missing = ids.where((s) => !_serviceCache.containsKey(s)).toList();
    if (missing.isNotEmpty) {
      final result = await _signedCall(
        baseUrl,
        '/api/v2/common/getAppServiceUrl',
        {'serviceIds': missing},
      );
      final urls = result['serviceUrls'];
      if (urls is Map) {
        urls.forEach((k, v) {
          if (v is String && v.isNotEmpty) {
            _serviceCache['$k'] = v.replaceAll(RegExp(r'/+$'), '');
          }
        });
      }
    }
    return {
      for (final id in ids)
        if (_serviceCache.containsKey(id)) id: _serviceCache[id]!,
    };
  }

  /// URL of `nbu.iot-app-server.app-v2`. Throws [TapoException] when the
  /// scheme is not http(s) or the URL is plain http while the account API is
  /// https. Spec: hc.cloud.service_urls.
  Future<String> discoverIotServer(String baseUrl) async {
    final url = (await serviceUrls(baseUrl, [iotServiceId]))[iotServiceId] ?? '';
    final parsed = Uri.tryParse(url);
    if (parsed == null ||
        (parsed.scheme != 'http' && parsed.scheme != 'https') ||
        parsed.host.isEmpty) {
      _serviceCache.remove(iotServiceId);
      throw TapoException('The TP-Link cloud returned no IoT server address');
    }
    if (baseUrl.startsWith('https://') && parsed.scheme != 'https') {
      _serviceCache.remove(iotServiceId);
      throw TapoException('The TP-Link cloud returned an insecure IoT server address');
    }
    return url;
  }

  /// URL of `cipc.api.cloud`, used by the player lane's relay request together
  /// with [token] and [postCipc].
  Future<String> discoverCipcUrl(String baseUrl) async {
    final url = (await serviceUrls(baseUrl, [cipcServiceId]))[cipcServiceId];
    if (url == null) throw TapoException('$cipcServiceId endpoint missing from cloud response');
    return url;
  }

  /// IoT headers (Authorization `ut|<token>`, app-cid, x-*; no HMAC headers).
  /// Spec: hc.cloud.iot_headers.
  Map<String, String> iotHeaders({bool post = false}) => {
        'Authorization': 'ut|$token',
        'app-cid': 'app:$appName:$terminalUuid',
        'x-app-name': appName,
        'x-app-version': appVersion,
        'x-term-id': terminalUuid,
        'x-ospf': _platformName,
        'x-net-type': 'wifi',
        'x-strict': '0',
        'x-locale': locale,
        'User-Agent': '$appName/$appVersion(cloud-only;AndroidTV)',
        'Accept': 'application/json',
        if (post) 'Content-Type': _jsonType,
      };

  /// Plain alias or Base64 alias (only when len%4==0, len>=4, strict base64 of
  /// printable UTF-8 that re-encodes identically). Spec: hc.cloud.alias_decode.
  static String decodeAlias(String alias) {
    if (alias.isEmpty || alias.length % 4 != 0 || !_base64Strict.hasMatch(alias)) return alias;
    try {
      final raw = base64.decode(alias);
      final text = utf8.decode(raw);
      if (!_isPrintable(text) || base64.encode(raw) != alias) return alias;
      return text;
    } on FormatException {
      return alias;
    }
  }

  /// Display alias of a device-list entry: decoded alias, else deviceName, else model.
  static String aliasOf(Map<String, dynamic> device) {
    final decoded = decodeAlias('${device['alias'] ?? ''}');
    if (decoded.isNotEmpty) return decoded;
    final name = '${device['deviceName'] ?? ''}';
    return name.isNotEmpty ? name : '${device['deviceModel'] ?? ''}';
  }

  Future<void> _ensureCipc(String baseUrl) async {
    _cipcUrl = await discoverCipcUrl(baseUrl);
  }

  Future<Map<String, dynamic>> postCipc(
    String endpoint,
    Map<String, dynamic> payload,
    String playerId,
  ) async {
    final body = _body(payload);
    final uri = Uri.parse(_cipcUrl.replaceAll(RegExp(r'/+$'), '') + endpoint);
    try {
      final (_, decoded) = await _postRaw(uri, body, {
        // CIPC expects the raw cloud token (no `ut|` prefix).
        'Authorization': token,
        'Content-Type': 'application/json; charset=UTF-8',
        'User-Agent': 'Tapo_APP/Linux/${appVersion}_Android/Android 14',
        'X-Client-Id': playerId,
        'X-Source': 'tapo-app',
        'X-Brand': 'TPLINK',
        'X-Ca-Type': 'cloud-self',
        'X-Request-Signature': randomUuid().replaceAll('-', '').substring(0, 10),
      });
      return decoded;
    } on TapoException {
      _serviceCache.remove(cipcServiceId);
      rethrow;
    }
  }

  // --------------------------------------------------------------- Login --

  Map<String, dynamic> _loginPayload(String username, String password) => {
        'appType': appName,
        'appVersion': appVersion,
        'cloudUserName': username,
        'cloudPassword': password,
        'platform': _platformName,
        'refreshTokenNeeded': false,
        'terminalUUID': terminalUuid,
        'terminalName': '$productName - Android TV',
        'terminalMeta': '1',
      };

  /// Signs in: `getAccountStatusAndUrl` finds the regional URL, then `login`
  /// (one `-20212` region redirect is followed). A pending MFA challenge is
  /// returned as a [LoginResult] without token. Spec: hc.cloud.login_region.
  Future<LoginResult> login(String username, String password) async {
    final status = await _call(loginUrl, '/api/v2/account/getAccountStatusAndUrl', {
      'appType': appName,
      'cloudUserName': username,
    });
    var region = '${status['appServerUrlV2'] ?? ''}'.replaceAll(RegExp(r'/+$'), '');
    if (region.isEmpty) region = loginUrl;
    Map<String, dynamic> result;
    try {
      try {
        result = await _call(region, '/api/v2/account/login', _loginPayload(username, password));
      } on TapoException catch (e) {
        final redirect = '${e.details['appServerUrlV2'] ?? ''}'.replaceAll(RegExp(r'/+$'), '');
        if (e.code != -20212 || redirect.isEmpty || redirect == region) rethrow;
        region = redirect;
        result = await _call(region, '/api/v2/account/login', _loginPayload(username, password));
      }
    } on TapoException catch (e) {
      if (e.code == -20677) {
        // MFA challenge: the caller continues with requestMfa/verifyMfa.
        _email = username;
        _password = password;
        _region = region;
        return LoginResult(region, Map<String, dynamic>.of(e.details));
      }
      rethrow;
    }
    final fresh = result['token'];
    if (fresh is! String || fresh.isEmpty) {
      throw TapoException('The TP-Link cloud returned no session token');
    }
    token = fresh;
    rememberCredentials(username: username, password: password, baseUrl: region);
    return LoginResult(region, result);
  }

  /// [mfaType] 1 = push to the Tapo phone app, 2 = email code, 4 = SMS,
  /// 3 = authenticator app (nothing to send).
  Future<void> requestMfa(String baseUrl, String username, String password, int mfaType) async {
    if (mfaType == 3) return;
    final endpoint = _mfaSendPaths[mfaType] ?? _mfaSendPaths[2]!;
    await _call(baseUrl, endpoint, {
      'appType': appName,
      'cloudUserName': username,
      'cloudPassword': password,
      'terminalUUID': terminalUuid,
      if (mfaType == 2 || mfaType == 4) 'locale': locale,
    });
  }

  Future<Map<String, dynamic>> verifyMfa(
    String baseUrl,
    String username,
    String code,
    String processId,
    int mfaType,
  ) async {
    final result = await _call(baseUrl, '/api/v2/account/checkMFACodeAndLogin', {
      'appType': appName,
      'cloudUserName': username,
      'code': code.trim(),
      'MFAProcessId': processId,
      'MFAType': mfaType,
      'terminalBindEnabled': true,
    });
    final fresh = result['token'];
    if (fresh is String && fresh.isNotEmpty) {
      token = fresh;
      _region = baseUrl.replaceAll(RegExp(r'/+$'), '');
      _email = username;
    }
    return result;
  }

  // ------------------------------------------------------------- Devices --

  /// Camera-like devices of the account (hubs and id-less entries dropped,
  /// duplicates ignored, MAC normalised). Renews an expired token once.
  Future<List<Map<String, dynamic>>> listCameras(String baseUrl) async {
    final devices = <String, Map<String, dynamic>>{};
    var index = 0;
    for (var pages = 0; pages < 500; pages++) {
      final page = await _signedCall(baseUrl, '/api/v2/common/getDeviceListByPage', {
        'deviceTypeList': _requestDeviceTypes,
        'index': index,
        'limit': 20,
      });
      final raw = page['deviceList'];
      final items = raw is List ? raw : const [];
      for (final item in items) {
        if (item is! Map<String, dynamic>) continue;
        final id = item['deviceId'];
        if (id is! String || id.isEmpty || !_cameraDeviceTypes.contains(item['deviceType'])) {
          continue;
        }
        final mac = '${item['deviceMac'] ?? ''}';
        devices.putIfAbsent(id, () {
          final copy = Map<String, dynamic>.of(item);
          final normal = normaliseMac(mac);
          copy['deviceMac'] = normal.isNotEmpty ? normal : mac.toUpperCase();
          return copy;
        });
      }
      index += 20;
      if (items.isEmpty || index >= _intCode(page['totalNum'])) break;
    }
    return devices.values.toList();
  }

  /// Send camera control methods through Tapo's IoT cloud gateway.
  Future<List<dynamic>> servicesSync(
    String baseUrl,
    String deviceId,
    List<Map<String, dynamic>> requests,
  ) async {
    final iotAppServer = await discoverIotServer(baseUrl);
    final body = _body({
      'inputParams': {
        'requestData': {
          'method': 'multipleRequest',
          'params': {'requests': requests},
        },
      },
      'serviceId': 'passthrough',
    });
    Uri url(String version) => Uri.parse(
        '${iotAppServer.replaceAll(RegExp(r'/+$'), '')}/$version/things/'
        '${Uri.encodeComponent(deviceId)}/services-sync');
    var (status, decoded) = await _postRaw(url(_servicesSyncVersion), body, iotHeaders(post: true));
    if ({404, 405, 501}.contains(status) && _servicesSyncVersion == 'v2') {
      // Older regional gateways only expose v1.
      _servicesSyncVersion = 'v1';
      (status, decoded) = await _postRaw(url('v1'), body, iotHeaders(post: true));
    }
    if (status >= 400) {
      final msg = decoded['message'] ?? decoded['msg'];
      throw TapoException('Camera control rejected (HTTP $status)${msg != null ? ': $msg' : ''}');
    }
    final output = decoded['outputParams'];
    final data = output is Map ? output['responseData'] : null;
    if (data is! Map) throw TapoException('Camera did not answer');
    final code = errorCode(data);
    if (code != 0) {
      throw TapoException(_deviceErrorMessages[code] ?? 'Camera control rejected (code $code)', code: code);
    }
    final responses = (data['result'] is Map) ? data['result']['responses'] : null;
    if (responses is! List) throw TapoException('Camera returned no answer');
    return responses;
  }

  Map<String, dynamic> _firstResponse(List<dynamic> responses, String method) {
    if (responses.isEmpty || responses.first is! Map) {
      throw TapoException('Incomplete $method response');
    }
    final response = Map<String, dynamic>.from(responses.first as Map);
    final code = errorCode(response);
    if (code != 0) {
      throw TapoException(_deviceErrorMessages[code] ?? '$method rejected by camera (code $code)', code: code);
    }
    return response;
  }

  Future<bool> getPrivacyMode(String baseUrl, String deviceId) async {
    final responses = await servicesSync(baseUrl, deviceId, [
      {
        'method': 'getLensMaskConfig',
        'params': {
          'lens_mask': {
            'name': ['lens_mask_info'],
          },
        },
      },
    ]);
    final result = _firstResponse(responses, 'getLensMaskConfig')['result'];
    final lensMask = result is Map ? result['lens_mask'] : null;
    final info = lensMask is Map ? lensMask['lens_mask_info'] : null;
    final enabled = info is Map ? info['enabled'] : null;
    if (enabled != 'on' && enabled != 'off') {
      throw TapoException('Privacy state missing from camera answer');
    }
    return enabled == 'on';
  }

  Future<bool> setPrivacyMode(String baseUrl, String deviceId, bool enabled) async {
    final responses = await servicesSync(baseUrl, deviceId, [
      {
        'method': 'setLensMaskConfig',
        'params': {
          'lens_mask': {
            'lens_mask_info': {'enabled': enabled ? 'on' : 'off'},
          },
        },
      },
    ]);
    _firstResponse(responses, 'setLensMaskConfig');
    // The camera applies the change asynchronously; poll for the new state.
    Object? lastError;
    for (final delay in const [0, 400, 800, 1200, 1600]) {
      if (delay > 0) await Future<void>.delayed(Duration(milliseconds: delay));
      try {
        if (await getPrivacyMode(baseUrl, deviceId) == enabled) return enabled;
        lastError = null;
      } catch (e) {
        lastError = e;
      }
    }
    if (lastError != null) throw lastError;
    throw TapoException('Privacy mode did not change, try again');
  }

  Future<bool> ptzSupported(String baseUrl, String deviceId) async {
    final responses = await servicesSync(baseUrl, deviceId, [
      {
        'method': 'getAppComponentList',
        'params': {
          'app_component': {
            'name': ['app_component_list'],
          },
        },
      },
    ]);
    final result = _firstResponse(responses, 'getAppComponentList')['result'];
    final list = (result is Map && result['app_component'] is Map)
        ? result['app_component']['app_component_list']
        : null;
    return list is List && list.any((item) => item is Map && item['name'] == 'ptz');
  }

  /// Relative pan/tilt step; x>0 pans right, y>0 tilts up.
  Future<void> moveMotor(String baseUrl, String deviceId, int x, int y) async {
    if (x.abs() > 200 || y.abs() > 200) {
      throw TapoException('Movement must be between -200 and 200');
    }
    final responses = await servicesSync(baseUrl, deviceId, [
      {
        'method': 'motorMove',
        'params': {
          'motor': {
            'move': {'x_coord': '$x', 'y_coord': '$y'},
          },
        },
      },
    ]);
    _firstResponse(responses, 'motorMove');
  }

  // --------------------------------------------------------------- Relay --

  Future<RelayInfo> requestRelay(String baseUrl, Map<String, dynamic> device) async {
    final deviceId = '${device['deviceId'] ?? ''}';
    if (deviceId.isEmpty) throw TapoException('Camera has no deviceId');
    await _ensureCipc(baseUrl);
    final playerId = randomUuid();
    final response = await postCipc('/v2/relay/request', {
      'deviceId': deviceId,
      'dataTimeoutCount': 0,
      'cloudType': 2,
      'deviceType': device['deviceType'] ?? 'SMART.IPCAMERA',
      'playerId': playerId,
      'rootCaVer': '1',
      'streamType': 0,
      'preConnection': 0,
      'resolution': 'HD',
    }, playerId);
    final info = resultOf(response);
    final code = errorCode(response);
    if (code != 0) {
      throw TapoException(
        code == -40401 || code == -40406
            ? 'Camera is offline'
            : 'Cloud relay rejected the stream (code $code)',
        code: code,
      );
    }
    final relayUrl = '${info['relayUrl'] ?? ''}';
    final relayToken = '${info['relayToken'] ?? info['sessionToken'] ?? ''}';
    if (relayUrl.isEmpty || relayToken.isEmpty) {
      throw TapoException('Incomplete relay answer from the cloud');
    }
    // The relay query is an opaque signed string: keep it byte-for-byte.
    final full = relayUrl.contains('://') ? relayUrl : 'https://$relayUrl';
    final schemeEnd = full.indexOf('://') + 3;
    final pathStart = full.indexOf('/', schemeEnd);
    final authority = pathStart < 0 ? full.substring(schemeEnd) : full.substring(schemeEnd, pathStart);
    var pathAndQuery = pathStart < 0 ? '/' : full.substring(pathStart);
    pathAndQuery += pathAndQuery.contains('?') ? '&retryTime=0' : '?retryTime=0';
    final colon = authority.lastIndexOf(':');
    final host = colon > 0 ? authority.substring(0, colon) : authority;
    final port = colon > 0 ? int.tryParse(authority.substring(colon + 1)) ?? 443 : 443;
    return RelayInfo(
      host: host,
      port: port,
      path: pathAndQuery,
      token: relayToken,
      playerId: playerId,
      elbCookie: info['elbCookie']?.toString(),
    );
  }

  /// Opens the relay and yields the raw MPEG-TS video bytes.
  Stream<Uint8List> openVideoStream(String baseUrl, Map<String, dynamic> device) async* {
    final relay = await requestRelay(baseUrl, device);
    final headers = <String, String>{
      'Host': relay.host,
      'User-Agent': 'Client=$appName Android $appVersion/1.3',
      'Keep-Relay': '3600',
      'Accept': '*/*',
      'Content-Type': 'multipart/mixed;boundary=--client-stream-boundary--',
      'Content-Length': '9223372036854775807',
      'X-token': relay.token,
      'X-Client-Model': '${device['deviceModel'] ?? 'C200'}',
      'X-Client-UUID': relay.playerId,
      'X-Redirect-Times': '0',
      // PullMode.DIRECT_FORWARDING of the official client.
      'X-Pull-Mode': '2',
      'X-Version': '2.0',
      'X-Arrive-Latency': '0',
      'Connection': 'Keep-alive',
      if (relay.elbCookie != null && relay.elbCookie!.isNotEmpty) 'Cookie': relay.elbCookie!,
    };
    final request = StringBuffer('POST ${relay.path} HTTP/1.1\r\n');
    headers.forEach((k, v) => request.write('$k: $v\r\n'));
    request.write('\r\n');

    final SecureSocket socket;
    try {
      socket = await SecureSocket.connect(
        relay.host,
        relay.port,
        context: _context ?? SecurityContext(withTrustedRoots: true),
        timeout: const Duration(seconds: 15),
      );
    } on SocketException catch (e) {
      throw TapoException('Could not reach the video relay: ${e.message}');
    }
    try {
      socket.add(ascii.encode(request.toString()));
      await socket.flush();
      yield* parseRelayResponse(socket);
    } finally {
      socket.destroy();
    }
  }
}

/// Parses the relay's HTTP response: a `multipart/mixed` body whose parts
/// (boundary `--device-stream-boundary--`) carry MPEG-TS video. Yields the
/// raw video bytes as they arrive.
Stream<Uint8List> parseRelayResponse(Stream<Uint8List> source) async* {
  final reader = _ByteReader(source);
  try {
    final status = await reader.readHttpHeaders();
    if (!status.startsWith('HTTP/1.1 200')) {
      throw TapoException('Video relay refused the connection');
    }
    while (true) {
      final line = await reader.readLine();
      // The wire boundary normally has four leading hyphens; match by
      // containment like the official client.
      if (line.isEmpty || !line.contains('--device-stream-boundary--')) continue;
      final partHeaders = <String, String>{};
      while (true) {
        final h = await reader.readLine();
        if (h.isEmpty) break;
        final sep = h.indexOf(':');
        if (sep > 0) {
          partHeaders[h.substring(0, sep).trim().toLowerCase()] = h.substring(sep + 1).trim();
        }
      }
      if (partHeaders['x-if-encrypt'] == '1') {
        throw TapoException('This camera sends encrypted video, which is not supported yet');
      }
      final length = int.tryParse(partHeaders['content-length'] ?? '0') ?? 0;
      if (length <= 0) continue;
      yield* reader.readExact(length);
    }
  } finally {
    await reader.cancel();
  }
}

/// Minimal buffered reader over a socket for HTTP/multipart framing.
class _ByteReader {
  _ByteReader(Stream<Uint8List> source) : _it = StreamIterator(source);

  static const _timeout = Duration(seconds: 20);
  final StreamIterator<Uint8List> _it;
  Uint8List _buf = Uint8List(0);
  int _pos = 0;

  int get _available => _buf.length - _pos;

  Future<void> _fill() async {
    final hasMore = await _it.moveNext().timeout(
          _timeout,
          onTimeout: () => throw TapoException('Camera stopped sending video'),
        );
    if (!hasMore) throw TapoException('Video relay closed the connection');
    final chunk = _it.current;
    if (_available == 0) {
      _buf = chunk;
    } else {
      final merged = Uint8List(_available + chunk.length)
        ..setRange(0, _available, _buf, _pos)
        ..setRange(_available, _available + chunk.length, chunk);
      _buf = merged;
    }
    _pos = 0;
  }

  int _indexOfCrlf(int from) {
    for (var i = from; i < _buf.length - 1; i++) {
      if (_buf[i] == 13 && _buf[i + 1] == 10) return i;
    }
    return -1;
  }

  Future<String> readLine() async {
    var scanFrom = _pos;
    while (true) {
      final idx = _indexOfCrlf(scanFrom);
      if (idx >= 0) {
        final line = latin1.decode(Uint8List.sublistView(_buf, _pos, idx));
        _pos = idx + 2;
        return line;
      }
      if (_available > 65536) throw TapoException('Malformed video relay data');
      final consumed = _pos;
      final scanned = max(_buf.length - 1, _pos);
      await _fill();
      scanFrom = max(0, scanned - consumed);
    }
  }

  /// Reads the HTTP response head and returns its status line.
  Future<String> readHttpHeaders() async {
    final status = await readLine();
    while ((await readLine()).isNotEmpty) {}
    return status;
  }

  Stream<Uint8List> readExact(int length) async* {
    var remaining = length;
    while (remaining > 0) {
      if (_available == 0) await _fill();
      final take = min(remaining, _available);
      yield Uint8List.sublistView(_buf, _pos, _pos + take);
      _pos += take;
      remaining -= take;
    }
  }

  Future<void> cancel() => _it.cancel();
}
