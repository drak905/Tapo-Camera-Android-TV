// Cloud passthrough (services-sync) used for remote and shared cameras.
// Spec: hc.passthrough.request, hc.passthrough.response_errors.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'camera_dtos.dart';
import 'cloud_transport.dart';
import 'iot_things.dart';
import 'tapo_cloud.dart' show TapoException, buildIotHeaders;
import 'tapo_errors.dart';

/// Returns a fresh token after the old one was refused. Called single-flight:
/// concurrent callers share one refresh and skip it when the token already changed.
typedef TokenRefresher = Future<String> Function(String staleToken);

const _offlineCode = -20571;
const _timeoutCode = -20002;
const _notBoundCode = -20580;
const _tokenCodes = {-20651, -20652, -20675};
const _passthroughTimeout = Duration(seconds: 30);

const msgCameraOffline = 'Camera is offline';
const msgNoResponse = 'Camera did not respond';
const msgCloudBusy = 'The TP-Link cloud is busy (too many requests); try again in a moment.';
const msgSessionExpired = 'The TP-Link cloud session expired; sign in again.';
const msgNotBound = 'This camera is not linked to the signed-in TP-Link ID.';

class _TokenRejected implements Exception {
  const _TokenRejected();
}

int _code(Object? value) {
  if (value is bool) return 0;
  if (value is int) return value;
  return int.tryParse('${value ?? ''}'.trim()) ?? 0;
}

int _cloudCode(Object? body) {
  if (body is! Map) return 0;
  for (final key in const ['code', 'errorCode', 'error_code']) {
    final c = _code(body[key]);
    if (c != 0) return c;
  }
  return 0;
}

TapoException _cloudError(int code, int status) {
  if (code == _offlineCode) return TapoException(msgCameraOffline, code: code);
  if (code == _timeoutCode || code == 12202 || status == 408) {
    return TapoException(msgNoResponse, code: code == 0 ? status : code);
  }
  if (status == 429) return TapoException(msgCloudBusy, code: status);
  if (code == _notBoundCode) return TapoException(msgNotBound, code: code);
  final value = code != 0 ? code : status;
  return TapoException('TP-Link cloud error $value for this camera', code: value);
}

String _quoteSegment(String name) => Uri.encodeComponent(name)
    .replaceAll('!', '%21')
    .replaceAll('*', '%2A')
    .replaceAll("'", '%27')
    .replaceAll('(', '%28')
    .replaceAll(')', '%29');

class CloudPassthrough {
  CloudPassthrough({
    required CloudTransport transport,
    required String token,
    required String terminalUuid,
    required TokenRefresher refresher,
    String locale = 'en_US',
    bool accountApiIsHttps = true,
  })  : _transport = transport,
        _token = token,
        _terminalUuid = terminalUuid,
        _refresher = refresher,
        _locale = locale,
        _accountApiIsHttps = accountApiIsHttps;

  final CloudTransport _transport;
  final String _terminalUuid;
  final TokenRefresher _refresher;
  final String _locale;
  final bool _accountApiIsHttps;
  String _token;
  Future<void>? _refreshing;

  /// Current token (after refreshes).
  String get token => _token;

  @override
  String toString() => 'CloudPassthrough()';

  Uri _servicesSyncUri(IotThing thing) {
    final base = thing.appServerUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final parsed = Uri.tryParse(base);
    if (parsed == null ||
        (parsed.scheme != 'http' && parsed.scheme != 'https') ||
        parsed.host.isEmpty ||
        base.contains('?') ||
        base.contains('#')) {
      throw TapoProtocolError('The TP-Link cloud returned no usable address for this camera.');
    }
    if (_accountApiIsHttps && parsed.scheme != 'https') {
      throw TapoProtocolError('The TP-Link cloud returned an insecure address for this camera.');
    }
    if (thing.thingName.isEmpty) throw TapoProtocolError('The camera has no thing name.');
    return Uri.parse('$base/v1/things/${_quoteSegment(thing.thingName)}/services-sync');
  }

  /// POST `{thing url}/v1/things/{thingName as ONE quoted segment}/services-sync`
  /// with IoT headers and body `{serviceId:'passthrough', inputParams:{requestData:
  /// a multipleRequest}}`. Returns normalised items (per-item errors kept).
  /// An empty batch sends nothing. A thing URL with query/fragment, a
  /// non-http(s) URL, or http while the account API is https throws
  /// `TapoProtocolError`. 30 s timeout. HTTP 401 or code -20651/-20652/-20675
  /// refreshes once and retries once, then `TapoException('session expired')`.
  Future<List<ControlItem>> send(IotThing thing, List<Map<String, dynamic>> requests) async {
    final uri = _servicesSyncUri(thing);
    if (requests.isEmpty) return const [];
    final body = Uint8List.fromList(utf8.encode(jsonEncode({
      'serviceId': 'passthrough',
      'inputParams': {
        'requestData': buildMultipleRequest(requests),
      },
    })));
    for (var attempt = 1; attempt <= 2; attempt++) {
      final used = _token;
      try {
        return await _call(uri, body);
      } on _TokenRejected {
        if (attempt == 2) break;
        await _refresh(used);
      }
    }
    throw TapoException(msgSessionExpired, code: -20651);
  }

  Future<void> _refresh(String used) {
    if (_token != used) return Future<void>.value(); // someone already refreshed
    return _refreshing ??= () async {
      try {
        _token = await _refresher(used);
      } finally {
        _refreshing = null;
      }
    }();
  }

  Future<List<ControlItem>> _call(Uri uri, Uint8List body) async {
    final CloudResponse response;
    try {
      response = await _transport.send(CloudRequest(
        method: 'POST',
        uri: uri,
        headers: buildIotHeaders(
          token: _token,
          terminalUuid: _terminalUuid,
          locale: _locale,
          post: true,
        ),
        body: body,
        timeout: _passthroughTimeout,
      ));
    } on CloudTransportError catch (e) {
      throw TapoException(e.message);
    }
    Object? reply;
    try {
      reply = response.body.isEmpty ? null : jsonDecode(utf8.decode(response.body));
    } on FormatException {
      reply = null;
    }
    final code = _cloudCode(reply);
    if (response.status == 401 || _tokenCodes.contains(code)) throw const _TokenRejected();
    if (response.status >= 400 || code != 0) throw _cloudError(code, response.status);
    if (reply is! Map) {
      throw TapoProtocolError('The TP-Link cloud sent an unreadable passthrough answer.');
    }
    var output = reply['outputParams'];
    if (output == null && reply['result'] is Map) output = (reply['result'] as Map)['outputParams'];
    if (output is! Map) {
      throw TapoProtocolError('The TP-Link cloud passthrough answer has no outputParams.');
    }
    final data = output['responseData'] ?? output;
    if (data is! Map) {
      throw TapoProtocolError('The TP-Link cloud passthrough answer has no responseData.');
    }
    final inner = _code(data['error_code']);
    if (inner != 0) {
      if (inner == _offlineCode || inner == _timeoutCode) throw _cloudError(inner, response.status);
      throw TapoDeviceError('The camera answered error $inner', code: inner, method: 'multipleRequest');
    }
    final result = data['result'];
    final responses = result is Map ? result['responses'] : null;
    if (responses is! List) {
      throw TapoProtocolError("The camera's passthrough answer has no responses list.");
    }
    return [for (final item in responses) ControlItem.normalize(item)];
  }
}
