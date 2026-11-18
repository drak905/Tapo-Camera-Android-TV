/// Relay slot request (CIPC `/v2/relay/request`, cloudType 2).
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../client_parts.dart';
import '../media_deps.dart';
import '../media_errors.dart';

/// `streamType` of the slot request.
const int kRelayPreview = 0;
const int kRelayPlayback = 1;
const int kRelayDownload = 3;

const int _errDeviceOffline = -1007;
const int _errTokenInvalid = -1102;
const int _errIllegalRequest = 3;

const Map<int, String> _fatalMessages = {
  _errDeviceOffline: 'Camera is offline (the TP-Link cloud relay cannot reach it).',
  -1103: 'This camera is not linked to the signed-in TP-Link ID.',
  -52407: 'stream limit reached: the camera refused another viewer.',
  -52212: "The camera's cloud relay data limit is reached.",
  -100001: 'Too many relay requests; try again in a minute.',
  -20675: 'The TP-Link ID signed in elsewhere; sign in again.',
  _errIllegalRequest: 'The TP-Link relay rejected the request (illegal_request).',
};

/// The [RelayException] for a relay / CIPC error code. [detail] is a server
/// reason (never a token).
RelayException relayErrorFor(int code, {String detail = '', String what = 'relay'}) {
  final fatal = _fatalMessages[code];
  if (fatal != null) return RelayException(fatal, code: code, fatal: true);
  final suffix = detail.isEmpty ? '' : ': $detail';
  return RelayException('TP-Link cloud $what error $code$suffix', code: code);
}

/// One relay slot. `token` and `elbCookie` are secrets: excluded from
/// [toString]. relayToken is single use.
class RelaySlot {
  const RelaySlot({
    required this.deviceId,
    required this.relayHost,
    required this.relayPort,
    required this.relayPath,
    required this.relayIp,
    required this.trackId,
    required this.resolution,
    required this.token,
    this.elbCookie = '',
  });

  final String deviceId;
  final String relayHost;
  final int relayPort;

  /// `/relayservice?...` without `retryTime`.
  final String relayPath;
  final String relayIp;
  final String trackId;
  final String resolution;
  final String token;
  final String elbCookie;

  /// Parses `relayUrl`, `relayToken` (or `sessionToken`), `relayIp`,
  /// `elbCookie`. Throws `RelayException` without address or token.
  factory RelaySlot.fromResult(
    Map<String, dynamic> result, {
    required String deviceId,
    required String trackId,
    required String resolution,
  }) {
    final url = '${result['relayUrl'] ?? ''}'.trim();
    final tokenValue = result['relayToken'] ?? result['sessionToken'];
    if (url.isEmpty || tokenValue is! String || tokenValue.isEmpty) {
      throw const RelayException('The TP-Link cloud returned no relay address.');
    }
    final Uri uri;
    try {
      uri = Uri.parse(url.contains('//') ? url : 'https://$url');
    } on FormatException {
      throw const RelayException('The TP-Link cloud returned an invalid relay address.');
    }
    if (uri.host.isEmpty) {
      throw const RelayException('The TP-Link cloud returned an invalid relay address.');
    }
    var path = uri.path.isEmpty ? '/relayservice' : uri.path;
    if (uri.hasQuery) path = '$path?${uri.query}';
    final cookie = result['elbCookie'];
    return RelaySlot(
      deviceId: deviceId,
      relayHost: uri.host,
      relayPort: uri.hasPort ? uri.port : 443,
      relayPath: path,
      relayIp: '${result['relayIp'] ?? ''}'.trim(),
      trackId: trackId,
      resolution: resolution,
      token: tokenValue,
      elbCookie: cookie is String ? cookie : '',
    );
  }

  @override
  String toString() => 'RelaySlot(device: $deviceId, node: $relayHost:$relayPort)';
}

const String _sigChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

String _uuid4(Random rng) {
  final b = List<int>.generate(16, (_) => rng.nextInt(256));
  b[6] = (b[6] & 0x0F) | 0x40;
  b[8] = (b[8] & 0x3F) | 0x80;
  String h(int from, int to) => b.sublist(from, to).map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  return '${h(0, 4)}-${h(4, 6)}-${h(6, 8)}-${h(8, 10)}-${h(10, 16)}';
}

class RelaySlotClient {
  RelaySlotClient(this.auth);
  final CloudRelayAuth auth;

  /// `POST <cipc>/v2/relay/request`. Authorization = raw token before ';'
  /// (not signed). Headers: Content-Type `application/json; charset=UTF-8`,
  /// Accept `*/*`, User-Agent `Tapo_APP/<model>/<ver>_Android/Android 14`,
  /// X-Request-Signature (10 random alnum), X-Client-Id, X-Source `tapo-app`,
  /// X-Brand `TPLINK`, X-Ca-Type `cloud-self`, Connection `close`.
  ///
  /// Body (compact JSON, this key order). Preview: deviceId,
  /// dataTimeoutCount 0, cloudType, deviceType, playerId, rootCaVer '1',
  /// preConnection 0, resolution, streamType 0, customParams '{}', trackId.
  /// Playback/download: ..., rootCaVer, streamType, channelId '0',
  /// customParams '{}', trackId.
  ///
  /// -1102 or HTTP 401: one `auth.relogin()` and one retry. Error codes
  /// -1007, -1103, -52407, -52212, -100001, -20675 and 3 throw a fatal
  /// `RelayException`; other non-zero codes a non-fatal one.
  Future<RelaySlot> requestSlot(
    String deviceId, {
    String deviceType = 'SMART.IPCAMERA',
    String? model,
    String resolution = 'VGA',
    int cloudType = 2,
    int streamType = kRelayPreview,
  }) async {
    if (deviceId.isEmpty) throw ArgumentError.value(deviceId, 'deviceId');
    if (streamType == kRelayPreview && resolution != 'HD' && resolution != 'VGA') {
      throw ArgumentError.value(resolution, 'resolution', "must be 'HD' or 'VGA'");
    }
    final rng = Random.secure();
    final trackId = _uuid4(rng);
    final body = <String, Object?>{
      'deviceId': deviceId,
      'dataTimeoutCount': 0,
      'cloudType': cloudType,
      'deviceType': deviceType,
      'playerId': auth.terminalUuid,
      'rootCaVer': '1',
    };
    var slotResolution = resolution;
    if (streamType == kRelayPreview) {
      body
        ..['preConnection'] = 0
        ..['resolution'] = resolution
        ..['streamType'] = 0
        ..['customParams'] = '{}';
    } else {
      body
        ..['streamType'] = streamType
        ..['channelId'] = '0'
        ..['customParams'] = '{}';
      slotResolution = '';
    }
    body['trackId'] = trackId;
    final bytes = Uint8List.fromList(utf8.encode(compactJson(body)));

    final base = await auth.cipcUrl;
    final basePath = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
    final url = base.replace(path: '$basePath/v2/relay/request');

    for (var attempt = 0; attempt < 2; attempt++) {
      final token = await auth.token;
      if (token == null || token.isEmpty) {
        throw const RelayException('Not signed in to a TP-Link ID.', fatal: true);
      }
      final headers = <String, String>{
        'Authorization': token.split(';').first,
        'Content-Type': 'application/json; charset=UTF-8',
        'Accept': '*/*',
        'User-Agent': 'Tapo_APP/${model ?? auth.clientModel}/${auth.appVersion}_Android/Android 14',
        'X-Request-Signature': String.fromCharCodes(
            [for (var i = 0; i < 10; i++) _sigChars.codeUnitAt(rng.nextInt(_sigChars.length))]),
        'X-Client-Id': auth.terminalUuid,
        'X-Source': 'tapo-app',
        'X-Brand': 'TPLINK',
        'X-Ca-Type': 'cloud-self',
        'Connection': 'close',
      };
      final reply = await auth.postCipc(url, headers, bytes);
      final json = reply.json;
      final rawCode = json['errorCode'];
      final int? code = rawCode == null ? null : int.tryParse('$rawCode');
      if (reply.httpStatus == 401 || code == _errTokenInvalid) {
        if (attempt == 0) {
          await auth.relogin();
          continue;
        }
        throw RelayException('The TP-Link cloud session expired; sign in again.', code: _errTokenInvalid, fatal: true);
      }
      var effective = code;
      if (effective == null) {
        if (reply.httpStatus >= 400) throw relayErrorFor(reply.httpStatus, what: 'relay request HTTP');
        effective = 0;
      }
      if (effective != 0) {
        final msg = '${json['msg'] ?? ''}';
        throw relayErrorFor(effective, detail: msg.length > 120 ? msg.substring(0, 120) : msg, what: 'relay request');
      }
      final result = json['result'];
      return RelaySlot.fromResult(
        result is Map<String, dynamic> ? result : <String, dynamic>{},
        deviceId: deviceId,
        trackId: trackId,
        resolution: slotResolution,
      );
    }
    throw const RelayException('The TP-Link cloud session expired; sign in again.', code: _errTokenInvalid, fatal: true);
  }

  /// 2 unless the device-list entry says `isSupportIoTCloud` false (then 1).
  static int cloudTypeFor(Map<String, dynamic>? raw) {
    if (raw == null) return 2;
    for (final key in const ['isSupportIoTCloud', 'is_support_iot_cloud']) {
      if (raw[key] == false) return 1;
    }
    return 2;
  }
}
