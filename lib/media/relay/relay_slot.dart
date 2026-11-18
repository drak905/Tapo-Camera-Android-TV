/// Relay slot request (CIPC `/v2/relay/request`, cloudType 2).
library;

import '../media_deps.dart';

/// `streamType` of the slot request.
const int kRelayPreview = 0;
const int kRelayPlayback = 1;
const int kRelayDownload = 3;

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
  }) =>
      throw UnimplementedError();
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
  }) =>
      throw UnimplementedError();

  /// 2 unless the device-list entry says `isSupportIoTCloud` false (then 1).
  static int cloudTypeFor(Map<String, dynamic>? raw) => throw UnimplementedError();
}
