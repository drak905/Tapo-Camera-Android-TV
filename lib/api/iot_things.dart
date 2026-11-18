// IoT thing list: role, status, appServerUrlV2, localAccessToken (LAT).
// Spec: hc.cloud.iot_things, hc.cloud.online_state.

import 'dart:convert';

import 'cloud_transport.dart';
import 'tapo_cloud.dart' show TapoException, buildIotHeaders;

/// One entry of `GET {iot}/v2/things`.
class IotThing {
  const IotThing({
    required this.thingName,
    required this.deviceId,
    required this.status,
    required this.role,
    this.shareType = '',
    this.appServerUrl = '',
    this.deviceType = '',
    this.model = '',
    this.localAccessToken,
  });

  final String thingName;
  final String deviceId;

  /// Integer status; `1` means online (bools are rejected by the parser).
  final int status;

  /// `0` owner, anything else shared with this account.
  final int role;
  final String shareType;

  /// `appServerUrlV2` else `appServerUrl`, trailing `/` stripped.
  final String appServerUrl;
  final String deviceType;
  final String model;

  /// Non-empty cloud-issued LAT enables LAT mode; null when absent/empty.
  final String? localAccessToken;

  bool get online => status == 1;
  bool get isShared => role != 0;

  /// Must never print [localAccessToken].
  @override
  String toString() =>
      'IotThing(thingName: $thingName, status: $status, role: $role, hasLat: ${localAccessToken != null})';
}

/// The IoT token was refused (HTTP 401 or code -20651/-20652/-20675).
/// Callers re-login once and retry.
class IotTokenExpired implements Exception {
  const IotTokenExpired([this.code]);
  final int? code;
}

/// Reads the thing list (page size 100) through a [CloudTransport].
class IotThingsClient {
  IotThingsClient({
    required this.transport,
    required this.iotBaseUrl,
    required this.token,
    required this.terminalUuid,
    this.locale = 'en_US',
  });

  final CloudTransport transport;
  final String iotBaseUrl;
  final String token;
  final String terminalUuid;
  final String locale;

  /// Fetches all pages (stops when a page is empty, seen >= total, or there is
  /// no total and the page has < 100 items). The map has BOTH `thingName` and
  /// `deviceId` as keys. Malformed entries are skipped. Throws
  /// [IotTokenExpired] on token errors.
  Future<Map<String, IotThing>> fetchAll() async {
    final things = <String, IotThing>{};
    var seen = 0;
    for (var page = 0; page < 500; page++) {
      final body = await _getPage(page);
      final raw = body['data'];
      final items = raw is List ? raw : const [];
      for (final item in items) {
        if (item is! Map) continue;
        final thing = _parse(item);
        if (thing == null) continue;
        things[thing.thingName] = thing;
        if (thing.deviceId.isNotEmpty) things[thing.deviceId] = thing;
      }
      seen += items.length;
      if (items.isEmpty) break;
      final total = body['total'];
      if (total is int) {
        if (seen >= total) break;
      } else if (items.length < 100) {
        break;
      }
    }
    return things;
  }

  static const _tokenCodes = {-20651, -20652, -20675};

  Future<Map<String, dynamic>> _getPage(int page) async {
    final base = Uri.parse(iotBaseUrl.replaceAll(RegExp(r'/+$'), ''));
    final uri = base.replace(
      path: '${base.path}/v2/things',
      queryParameters: {
        'page': '$page',
        'pageSize': '100',
        'deviceTypes': 'SMART.IPCAMERA,SMART.TAPODOORBELL,SMART.TAPOHUB',
        'includePcDevice': 'false',
        'includeKasaShareDevices': 'true',
        'includeMatterDevice': 'false',
        'includeExternalVendorDeviceInfo': 'true',
      },
    );
    final response = await transport.send(CloudRequest(
      method: 'GET',
      uri: uri,
      headers: buildIotHeaders(token: token, terminalUuid: terminalUuid, locale: locale),
    ));
    Object? decoded;
    try {
      decoded = response.body.isEmpty ? <String, dynamic>{} : jsonDecode(utf8.decode(response.body));
    } on FormatException {
      decoded = null;
    }
    final map = decoded is Map<String, dynamic> ? decoded : null;
    final rawCode = map?['code'];
    final code = rawCode is int ? rawCode : int.tryParse('${rawCode ?? 0}') ?? 0;
    if (response.status == 401) {
      throw IotTokenExpired(_tokenCodes.contains(code) ? code : -20651);
    }
    if (map == null) {
      throw TapoException('Unexpected answer from the Tapo IoT cloud (HTTP ${response.status})');
    }
    if (_tokenCodes.contains(code)) throw IotTokenExpired(code);
    if (response.status >= 400 || code != 0) {
      throw TapoException('Tapo IoT cloud error ${code != 0 ? code : response.status}',
          code: code != 0 ? code : response.status);
    }
    return map;
  }

  static IotThing? _parse(Map item) {
    final nameRaw = item['thingName'] ?? item['deviceId'];
    if (nameRaw is! String || nameRaw.isEmpty) return null;
    final idRaw = item['deviceId'];
    final status = item['status'];
    final role = item['role'];
    final url = item['appServerUrlV2'] ?? item['appServerUrl'];
    final lat = item['localAccessToken'];
    final share = item['shareType'];
    return IotThing(
      thingName: nameRaw,
      deviceId: idRaw is String && idRaw.isNotEmpty ? idRaw : nameRaw,
      status: status is int ? status : -1,
      role: role is int ? role : 0,
      shareType: share is String ? share : '',
      appServerUrl: url is String ? url.replaceAll(RegExp(r'/+$'), '') : '',
      deviceType: '${item['deviceType'] ?? ''}',
      model: '${item['model'] ?? ''}',
      localAccessToken: lat is String && lat.isNotEmpty ? lat : null,
    );
  }
}