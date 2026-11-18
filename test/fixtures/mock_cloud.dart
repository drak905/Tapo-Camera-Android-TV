// Mock TP-Link cloud (V2 REST account + device-list API, IoT app server, CIPC
// relay-request API) on 127.0.0.1:<ephemeral>. Port of
// tests/fixtures/mock_cloud.py of the Windows app.
//
// Every signed request is VERIFIED like the real server: Content-MD5 must be
// base64(MD5(body or "{}")) and X-Authorization must carry Timestamp=9999999999,
// the production AccessKey and a valid HMAC-SHA1 over
// "content_md5\n9999999999\nnonce\npath" (spec hc.cloud.signing). Unsigned or badly
// signed requests get HTTP 401 {"errorCode": -1}.
//
// Routes (REGION_PREFIX "/eu" emulates the regional appServerUrlV2):
//  POST /api/v2/account/getAccountStatusAndUrl
//  POST [/eu]/api/v2/account/login and .../captchaLogin (refresh); regionRedirect
//       answers -20212 + the regional URL at the bootstrap host
//  POST /eu/api/v2/account/get{Email,Sms,Push}VC4TerminalMFA, checkMFACodeAndLogin
//       (mfa = true: login answers -20677 until the terminal is bound)
//  POST /eu/api/v2/common/getDeviceListByPage   (?token= required, else -20651)
//  POST /eu/api/v2/common/getAppServiceUrl      (signed, ?token=) -> iot + cipc urls
//  GET  /iot/v2/things?page=&pageSize=&deviceTypes=  (NOT signed; IoT headers,
//       Authorization "ut|<token>"; things carry role/status/localAccessToken)
//  POST /eu/v1/things/<id>/services-sync        (NOT signed; passthrough to a
//       registered MockCamera.execute)
//  POST /cipc/v2/relay/request                  (NOT signed; slot from [relay])
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import 'fx_crypto.dart';
import 'mock_camera.dart';
import 'mock_relay.dart';

const String cloudAccessKey = '4d11b6b9d5ea4d19a829adbb9714b057';
const String cloudSecretKey = '6ed7d97f3e73467f8a5bab90b577ba4c';
const String regionPrefix = '/eu';
const String iotPrefix = '/iot';
const String iotServiceId = 'nbu.iot-app-server.app-v2';
const String cipcPrefix = '/cipc';
const String cipcServiceId = 'cipc.api.cloud';
const String appType = 'TP-Link_Tapo_Android';

/// A DeviceInfoResult-shaped map with deterministic ids.
Map<String, dynamic> makeCloudDevice(int index, {Map<String, dynamic> overrides = const {}}) => {
      'deviceType': 'SMART.IPCAMERA',
      'role': 0,
      'status': 1,
      'deviceName': 'C210',
      'deviceModel': 'C210',
      'deviceId': '8022${index.toRadixString(16).toUpperCase().padLeft(36, '0')}',
      'deviceMac': 'A0B1C2${index.toRadixString(16).toUpperCase().padLeft(6, '0')}',
      'alias': 'Camera $index',
      'deviceHwVer': '2.0',
      'fwVer': '1.3.11 Build 231121 Rel.41203n',
      'fwId': '0' * 32,
      'hwId': '0' * 32,
      'oemId': '0' * 32,
      'isSameRegion': true,
      'appServerUrl': '',
      'appServerUrlV2': '',
      ...overrides,
    };

/// One request seen by the cloud.
class CloudCall {
  CloudCall(this.method, this.path, this.query, this.body, this.headers, this.signatureOk);
  final String method;
  final String path;
  final Map<String, String> query;
  final Object? body;
  final Map<String, String> headers; // lower-case names
  final bool? signatureOk;
}

class MockCloud {
  MockCloud({
    Map<String, String>? accounts,
    List<Map<String, dynamic>>? devices,
    this.mfa = false,
    this.regionRedirect = false,
    List<int>? mfaTypes,
    this.mfaCode = '123456',
    this.nickname = 'Tester',
    Map<String, String>? localTokens,
  })  : accounts = {...?accounts},
        devices = [...?devices],
        mfaTypes = mfaTypes ?? [1, 2, 3],
        localTokens = {...?localTokens};

  /// {email: password}
  final Map<String, String> accounts;
  final List<Map<String, dynamic>> devices;
  bool mfa;
  List<int> mfaTypes;
  String mfaCode;
  bool regionRedirect;
  String nickname;

  /// Emails answering -20661 (locked).
  final Set<String> locked = {};

  /// deviceId -> LAT (absent -> null in the thing list).
  final Map<String, String> localTokens;
  int thingsMaxPageSize = 100;

  /// Relay node serving /v2/relay/request slots.
  MockRelay? relay;

  /// deviceId -> errorCode answered by /v2/relay/request.
  final Map<String, int> relayErrors = {};
  final Set<int> relayRefuseStreamTypes = {};

  /// deviceId -> camera serving services-sync.
  final Map<String, MockCamera> cameras = {};

  /// thing -> (HTTP status, code); status 200 answers {"errorCode": code}.
  final Map<String, (int, int)> passthroughErrors = {};

  /// "responseData" | "direct" (outputParams is the responseData itself).
  String passthroughShape = 'responseData';
  final List<({String thing, List<dynamic> requests})> passthroughLog = [];

  /// null -> [cipcUrl]; "" -> not listed.
  String? cipcServiceUrl;
  final List<CloudCall> requestLog = [];
  final List<(int, String)> sentCodes = [];
  final Set<String> boundTerminals = {};

  final Map<String, String> _tokens = {}; // token -> email
  final Map<String, String> _mfaProcesses = {};
  HttpServer? _server;

  Future<MockCloud> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_onRequest, onError: (Object _) {});
    return this;
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    await s?.close(force: true);
  }

  int get port => _server!.port;

  /// Bootstrap URL (the app's account API base).
  String get baseUrl => 'http://127.0.0.1:$port';

  /// The appServerUrlV2 the mock hands out.
  String get regionalUrl => baseUrl + regionPrefix;
  String get iotUrl => baseUrl + iotPrefix;
  String get cipcUrl => baseUrl + cipcPrefix;

  /// Invalidates every issued token (next device call answers -20651).
  void expireTokens() => _tokens.clear();
  List<String> get validTokens => _tokens.keys.toList();

  List<CloudCall> calls(String endpointSuffix) =>
      requestLog.where((r) => r.path.endsWith(endpointSuffix)).toList();

  // ---------------------------------------------------------------- HTTP
  Future<void> _onRequest(HttpRequest req) async {
    try {
      final builder = await req.fold<BytesBuilder>(BytesBuilder(copy: false), (b, d) => b..add(d));
      final body = builder.takeBytes();
      final headers = <String, String>{};
      req.headers.forEach((k, v) => headers[k.toLowerCase()] = v.join(','));
      final path = req.uri.path;
      final query = {for (final e in req.uri.queryParameters.entries) e.key: e.value};
      (int, Map<String, dynamic>) r;
      if (req.method == 'POST') {
        final sync = RegExp('^${RegExp.escape(regionPrefix)}/v1/things/([^/]+)/services-sync\$').firstMatch(path);
        if (sync != null) {
          r = _servicesSync(Uri.decodeComponent(sync.group(1)!), body, headers);
        } else if (path.startsWith('$cipcPrefix/')) {
          r = _cipc(path.substring(cipcPrefix.length), body, headers);
        } else {
          r = _handle(path, query, body, headers);
        }
      } else if (req.method == 'GET' && path.startsWith('$iotPrefix/')) {
        r = _iotGet(path.substring(iotPrefix.length), query, headers);
      } else {
        r = (405, {'errorCode': -1, 'msg': 'method not allowed'});
      }
      final data = utf8.encode(jsonEncode(r.$2));
      req.response.statusCode = r.$1;
      req.response.headers.set('content-type', 'application/json;charset=UTF-8');
      req.response.contentLength = data.length;
      req.response.add(data);
      await req.response.close();
    } catch (_) {
      try {
        req.response.statusCode = 500;
        await req.response.close();
      } catch (_) {}
    }
  }

  static final RegExp _authRe = RegExp(
      r'^Timestamp=([^,]+), Nonce=([^,]+), AccessKey=([^,]+), Signature=([0-9a-f]+)$');

  static bool verifySignature(String path, List<int> body, Map<String, String> headers) {
    final expectedMd5 = base64.encode(c.md5.convert(body.isEmpty ? utf8.encode('{}') : body).bytes);
    if (headers['content-md5'] != expectedMd5) return false;
    final m = _authRe.firstMatch(headers['x-authorization'] ?? '');
    if (m == null || m.group(1) != '9999999999' || m.group(3) != cloudAccessKey) return false;
    final msg = '$expectedMd5\n${m.group(1)}\n${m.group(2)}\n$path';
    final sig = c.Hmac(c.sha1, utf8.encode(cloudSecretKey)).convert(utf8.encode(msg)).toString();
    return constTimeEqStr(sig, m.group(4)!);
  }

  Map<String, dynamic> _ok(Map<String, dynamic> result) =>
      {'errorCode': 0, 'msg': 'Success', 'result': result};

  (int, Map<String, dynamic>) _handle(
      String path, Map<String, String> q, Uint8List body, Map<String, String> headers) {
    final ok = verifySignature(path, body, headers);
    Object? parsed;
    try {
      parsed = body.isEmpty ? <String, dynamic>{} : jsonDecode(utf8.decode(body));
    } catch (_) {
      parsed = null;
    }
    requestLog.add(CloudCall('POST', path, q, parsed, headers, ok));
    if (!ok) return (401, {'errorCode': -1, 'msg': 'signature verification failed'});
    if (parsed is! Map) return (400, {'errorCode': -20104, 'msg': 'bad json'});
    final params = parsed.cast<String, dynamic>();
    if (q['appName'] != appType || (q['termID'] ?? '').isEmpty) {
      return (200, {'errorCode': -20104, 'msg': 'APP_PARAMETER_NOT_FOUND'});
    }
    final regional = path.startsWith('$regionPrefix/');
    final route = regional ? path.substring(regionPrefix.length) : path;
    if (route == '/api/v2/account/getAccountStatusAndUrl') return (200, _statusAndUrl(params));
    if (route == '/api/v2/account/login' || route == '/api/v2/account/captchaLogin') {
      if (!regional && regionRedirect) {
        return (
          200,
          _ok({
            'errorCode': '-20212',
            'errorMsg': 'wrong region',
            'appServerUrlV2': regionalUrl,
            'appServerUrl': '$regionalUrl/v1',
          })
        );
      }
      return (200, _login(params));
    }
    if (!regional) return (404, {'errorCode': -1, 'msg': 'not found on bootstrap host'});
    if (route == '/api/v2/account/getEmailVC4TerminalMFA' ||
        route == '/api/v2/account/getSmsVC4TerminalMFA' ||
        route == '/api/v2/account/getPushVC4TerminalMFA') {
      return (200, _sendCode(route, params));
    }
    if (route == '/api/v2/account/checkMFACodeAndLogin') return (200, _checkMfa(params, q));
    if (route == '/api/v2/common/getDeviceListByPage') return (200, _devicePage(q, params));
    if (route == '/api/v2/common/getAppServiceUrl') return (200, _serviceUrls(q, params));
    return (404, {'errorCode': -1, 'msg': 'not found'});
  }

  Map<String, dynamic> _statusAndUrl(Map<String, dynamic> p) {
    if (p['appType'] != appType || (p['cloudUserName'] ?? '') == '') {
      return {'errorCode': -20104, 'msg': 'APP_PARAMETER_NOT_FOUND'};
    }
    if (!accounts.containsKey(p['cloudUserName'])) {
      return {'errorCode': -20600, 'msg': 'Account not found'};
    }
    final url = regionRedirect ? baseUrl : regionalUrl;
    return _ok({
      'appServerUrl': '$url/v1',
      'appServerUrlV2': url,
      'accountApiUrl': baseUrl,
      'status': 1,
      'deletePending': 0,
      'lockedMinutes': '0',
      'serviceRegion': 'eu-west-1',
    });
  }

  Map<String, dynamic> _loginResult(String email) {
    final token = randomHex(16);
    _tokens[token] = email;
    return {
      'errorCode': '0',
      'token': token,
      'accountId': '12345678',
      'nickname': nickname,
      'email': email,
      'regionCode': 'EU',
      'registerType': 'email',
      'appServerUrlV2': regionalUrl,
    };
  }

  Map<String, dynamic> _login(Map<String, dynamic> p) {
    final email = p['cloudUserName'];
    final password = p['cloudPassword'];
    const required = ['appType', 'appVersion', 'cloudUserName', 'cloudPassword', 'terminalUUID', 'platform'];
    if (required.any((k) => (p[k] ?? '') == '') || p['appType'] != appType) {
      return {'errorCode': -20104, 'msg': 'APP_PARAMETER_NOT_FOUND'};
    }
    if (locked.contains(email)) {
      return _ok({'errorCode': '-20661', 'errorMsg': 'account locked', 'lockedMinutes': 30});
    }
    if (!accounts.containsKey(email)) {
      return _ok({'errorCode': '-20600', 'errorMsg': 'account not found'});
    }
    if (accounts[email] != password) {
      return _ok({
        'errorCode': '-20601',
        'errorMsg': 'credential mismatch',
        'failedAttempts': 1,
        'remainAttempts': 4,
      });
    }
    if (mfa && !boundTerminals.contains(p['terminalUUID'])) {
      final pid = randomHex(8);
      _mfaProcesses[pid] = email as String;
      return _ok({
        'errorCode': '-20677',
        'errorMsg': 'MFA required',
        'MFAProcessId': pid,
        'supportedMFATypes': [...mfaTypes],
        'mfaEmail': 'u***@example.com',
      });
    }
    return _ok(_loginResult(email as String));
  }

  Map<String, dynamic> _sendCode(String route, Map<String, dynamic> p) {
    final email = p['cloudUserName'];
    if (!accounts.containsKey(email) ||
        accounts[email] != p['cloudPassword'] ||
        (p['terminalUUID'] ?? '') == '') {
      return {'errorCode': -20601, 'msg': 'credential mismatch'};
    }
    final type = route.contains('Email') ? 2 : (route.contains('Sms') ? 4 : 1);
    sentCodes.add((type, email as String));
    return _ok({});
  }

  Map<String, dynamic> _checkMfa(Map<String, dynamic> p, Map<String, String> q) {
    final pid = p['MFAProcessId'];
    final email = _mfaProcesses[pid ?? ''];
    if (email == null || email != p['cloudUserName'] || p['appType'] != appType) {
      return _ok({'errorCode': '-20676', 'errorMsg': 'MFA process not found'});
    }
    if (!mfaTypes.contains(p['MFAType']) || '${p['code']}' != mfaCode) {
      return _ok({'errorCode': '-20676', 'errorMsg': 'verification code incorrect'});
    }
    _mfaProcesses.remove(pid);
    if (p['terminalBindEnabled'] == true && (q['termID'] ?? '').isNotEmpty) {
      boundTerminals.add(q['termID']!);
    }
    return _ok(_loginResult(email));
  }

  Map<String, dynamic> _devicePage(Map<String, String> q, Map<String, dynamic> p) {
    if (!_tokens.containsKey(q['token'] ?? '')) {
      return {'errorCode': -20651, 'msg': 'Token expired'};
    }
    final index = (p['index'] as num?)?.toInt() ?? 0;
    var limit = (p['limit'] as num?)?.toInt() ?? 20;
    if (limit > 50) limit = 50;
    final types = p['deviceTypeList'];
    final all = devices.where((d) => types is! List || types.isEmpty || types.contains(d['deviceType'])).toList();
    final page = limit > 0 && index < all.length
        ? all.sublist(index, index + limit > all.length ? all.length : index + limit)
        : <Map<String, dynamic>>[];
    return _ok({'currentIndex': index, 'totalNum': all.length, 'deviceList': page});
  }

  Map<String, dynamic> _serviceUrls(Map<String, String> q, Map<String, dynamic> p) {
    if (!_tokens.containsKey(q['token'] ?? '')) {
      return {'errorCode': -20651, 'msg': 'Token expired'};
    }
    final ids = p['serviceIds'];
    if (ids is! List || ids.isEmpty) return {'errorCode': -20104, 'msg': 'serviceIds missing'};
    final urls = <String, String>{if (ids.contains(iotServiceId)) iotServiceId: iotUrl};
    final cipc = cipcServiceUrl ?? cipcUrl;
    if (ids.contains(cipcServiceId) && cipc.isNotEmpty) urls[cipcServiceId] = cipc;
    return _ok({'regionCode': 'EU', 'serviceUrls': urls});
  }

  // ---------------------------------------------------------------- CIPC
  static final RegExp _sigRe = RegExp(r'^[A-Za-z0-9]{10}$');

  bool _jsonStringObject(Object? v) {
    if (v is! String) return false;
    try {
      return jsonDecode(v) is Map;
    } catch (_) {
      return false;
    }
  }

  (int, Map<String, dynamic>) _cipc(String path, Uint8List body, Map<String, String> h) {
    Object? params;
    try {
      params = body.isEmpty ? null : jsonDecode(utf8.decode(body));
    } catch (_) {
      params = null;
    }
    requestLog.add(CloudCall('POST', cipcPrefix + path, {}, params, h, null));
    final email = _tokens[h['authorization'] ?? ''];
    if (path != '/v2/relay/request') return (404, {'errorCode': -1, 'msg': 'not found'});
    final ua = h['user-agent'] ?? '';
    if (!_sigRe.hasMatch(h['x-request-signature'] ?? '') ||
        (h['x-client-id'] ?? '').isEmpty ||
        h['x-source'] != 'tapo-app' ||
        h['x-brand'] != 'TPLINK' ||
        h['x-ca-type'] != 'cloud-self' ||
        !ua.startsWith('Tapo_APP/') ||
        !ua.contains('_Android/Android ') ||
        !(h['content-type'] ?? '').startsWith('application/json')) {
      return (400, {'errorCode': -1, 'msg': 'bad headers'});
    }
    if (email == null) return (401, {'errorCode': -1102, 'msg': 'token invalid'});
    if (params is! Map) return (400, {'errorCode': -1, 'msg': 'bad json'});
    final known = devices.map((d) => d['deviceId']).toSet();
    final st = params['streamType'];
    final common = known.contains(params['deviceId']) &&
        (params['cloudType'] == 1 || params['cloudType'] == 2) &&
        (params['deviceType'] ?? '') != '' &&
        params['playerId'] == h['x-client-id'] &&
        params['rootCaVer'] == '1' &&
        (params['trackId'] ?? '') != '' &&
        params['dataTimeoutCount'] == 0;
    bool valid;
    if (st == 0) {
      valid = common &&
          params['preConnection'] == 0 &&
          (params['resolution'] == 'HD' || params['resolution'] == 'VGA') &&
          params['customParams'] == '{}';
    } else if (st == 1 || st == 3) {
      valid = common &&
          !params.containsKey('resolution') &&
          !params.containsKey('preConnection') &&
          params['channelId'] == '0' &&
          _jsonStringObject(params['customParams']) &&
          (st != 3 || params['subType'] == 'cover');
    } else {
      valid = false;
    }
    if (!valid) return (200, {'errorCode': -1, 'msg': 'bad relay request params'});
    if (relayRefuseStreamTypes.contains(st)) {
      return (200, {'errorCode': -1, 'msg': 'streamType $st not supported'});
    }
    final code = relayErrors[params['deviceId']];
    if (code != null && code != 0) return (200, {'errorCode': code, 'msg': 'relay request refused'});
    if (relay == null) return (200, {'errorCode': -1014, 'msg': 'no relay node'});
    final result = relay!.issueSlot(params['deviceId'] as String,
        st == 0 ? params['resolution'] as String : '', params['cloudType'] as int, params['trackId'] as String,
        streamType: st as int);
    return (200, {'errorCode': 0, 'msg': 'Success', 'result': result});
  }

  // ---------------------------------------------------------------- IoT
  (int, Map<String, dynamic>)? _iotAuth(Map<String, String> h) {
    final term = h['x-term-id'] ?? '';
    if (term.isEmpty ||
        h['x-app-name'] != appType ||
        h['x-strict'] != '0' ||
        h['app-cid'] != 'app:$appType:$term' ||
        (h['x-app-version'] ?? '').isEmpty) {
      return (400, {'code': -20104, 'message': 'missing app headers'});
    }
    final auth = h['authorization'] ?? '';
    final email = auth.startsWith('ut|') ? _tokens[auth.substring(3)] : null;
    if (email == null) return (401, {'code': -20651, 'message': 'Token expired', 'data': null});
    return null;
  }

  (int, Map<String, dynamic>) _iotGet(String path, Map<String, String> q, Map<String, String> h) {
    requestLog.add(CloudCall('GET', iotPrefix + path, q, null, h, null));
    if (path != '/v2/things') return (404, {'code': -1, 'message': 'not found'});
    final bad = _iotAuth(h);
    if (bad != null) return bad;
    final page = int.tryParse(q['page'] ?? '0');
    var size = int.tryParse(q['pageSize'] ?? '20');
    if (page == null || size == null) return (400, {'code': -20104, 'message': 'bad paging'});
    if (size > thingsMaxPageSize) size = thingsMaxPageSize;
    final types = (q['deviceTypes'] ?? '').split(',').where((s) => s.isNotEmpty).toList();
    final things = [
      for (final d in devices)
        if (types.isEmpty || types.contains(d['deviceType'])) _thing(d)
    ];
    final chunk = size > 0 && page >= 0 && page * size < things.length
        ? things.sublist(page * size, ((page + 1) * size).clamp(0, things.length))
        : <Map<String, dynamic>>[];
    return (200, {'data': chunk, 'page': page, 'pageSize': size, 'total': things.length});
  }

  Map<String, dynamic> _thing(Map<String, dynamic> d) {
    final role = (d['role'] as num?)?.toInt() ?? 0;
    return {
      'thingName': d['deviceId'],
      'localAccessToken': localTokens[d['deviceId']],
      'appServerUrl': regionalUrl,
      'appServerUrlV2': regionalUrl,
      'ownerAccountId': '12345678',
      'role': role,
      'deviceType': d['deviceType'],
      'shareType': d['shareType'] ?? (role != 0 ? 'deviceShare' : null),
      'model': d['deviceModel'],
      'mac': d['deviceMac'],
      'fwVer': d['fwVer'],
      'hwVer': d['deviceHwVer'],
      'region': 'eu-west-1',
      'status': d['status'] ?? 1,
    };
  }

  // ---------------------------------------------------------------- services-sync
  /// Routes passthrough requests for [deviceId] to [camera].
  void registerCamera(String deviceId, MockCamera camera) => cameras[deviceId] = camera;

  (int, Map<String, dynamic>) _servicesSync(String thing, Uint8List body, Map<String, String> h) {
    Object? params;
    try {
      params = body.isEmpty ? null : jsonDecode(utf8.decode(body));
    } catch (_) {
      params = null;
    }
    requestLog.add(CloudCall('POST', '$regionPrefix/v1/things/$thing/services-sync', {}, params, h, null));
    final bad = _iotAuth(h);
    if (bad != null) return bad;
    if (!(h['content-type'] ?? '').startsWith('application/json')) {
      return (400, {'code': 11000, 'message': 'bad content type'});
    }
    Object? request;
    if (params is Map && params['inputParams'] is Map) {
      request = (params['inputParams'] as Map)['requestData'];
    }
    final reqs = request is Map && request['params'] is Map ? (request['params'] as Map)['requests'] : null;
    if (params is! Map ||
        params['serviceId'] != 'passthrough' ||
        request is! Map ||
        request['method'] != 'multipleRequest' ||
        reqs is! List) {
      return (400, {'code': 11000, 'message': 'bad passthrough body'});
    }
    passthroughLog.add((thing: thing, requests: reqs));
    final injected = passthroughErrors[thing];
    if (injected != null) {
      if (injected.$1 == 200) return (200, {'errorCode': injected.$2, 'msg': 'passthrough refused'});
      return (injected.$1, {'code': injected.$2, 'message': 'passthrough refused'});
    }
    final device = devices.where((d) => d['deviceId'] == thing).firstOrNull;
    if (device == null) return (404, {'code': -20580, 'message': 'device not bound to this account'});
    if ((device['status'] ?? 1) != 1) return (400, {'code': -20571, 'message': 'device is offline'});
    final camera = cameras[thing];
    if (camera == null) return (500, {'code': -20002, 'message': 'device did not answer in time'});
    final responses = <Map<String, dynamic>>[];
    for (final item in reqs) {
      final method = item is Map ? item['method'] : null;
      final (code, result) = camera.execute(method, item is Map ? item['params'] : null);
      responses.add({'method': method, 'result': result, 'error_code': code});
    }
    final responseData = {
      'error_code': 0,
      'result': {'responses': responses}
    };
    return (
      200,
      {
        'outputParams': passthroughShape == 'direct' ? responseData : {'responseData': responseData},
        'requestId': randomHex(8),
      }
    );
  }
}
