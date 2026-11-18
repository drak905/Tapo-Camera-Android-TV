// IoT thing list: role, status, appServerUrlV2, localAccessToken (LAT).
// Spec: hc.cloud.iot_things, hc.cloud.online_state.

import 'cloud_transport.dart';

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
  String toString() => throw UnimplementedError();
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
  Future<Map<String, IotThing>> fetchAll() => throw UnimplementedError();
}