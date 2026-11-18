// Production CloudRelayAuth (lib/media/media_deps.dart) over TapoCloud: raw
// token, CIPC URL from getAppServiceUrl (cipc.api.cloud), the unsigned CIPC
// POST through the CloudTransport, and one silent re-login.
// Spec: mb.relay.slot_request, hc.cloud.service_urls, hc.cloud.token_refresh.

import 'dart:convert';
import 'dart:typed_data';

import '../media/media_deps.dart';
import 'cloud_transport.dart';
import 'tapo_cloud.dart';

const String _appVersion = appVersion;

class TapoCloudRelayAuth implements CloudRelayAuth {
  /// [baseUrl] is read on every use (the regional account URL can change at a
  /// re-login). [relogin] defaults to `cloud.relogin()` (remembered account).
  TapoCloudRelayAuth({
    required this.cloud,
    required String Function() baseUrl,
    required this.transport,
    required this.terminalUuid,
    Future<void> Function()? relogin,
    this.clientModel = 'AndroidTV',
    this.appVersion = _appVersion,
    this.timeout = const Duration(seconds: 15),
  })  : _baseUrl = baseUrl,
        _relogin = relogin;

  final TapoCloud cloud;
  final String Function() _baseUrl;
  final CloudTransport transport;
  final Future<void> Function()? _relogin;
  final Duration timeout;

  @override
  final String terminalUuid;

  @override
  final String clientModel;

  @override
  final String appVersion;

  @override
  Future<String?> get token async {
    final t = cloud.token.split(';').first;
    return t.isEmpty ? null : t;
  }

  /// cipc.api.cloud from getAppServiceUrl (cached by TapoCloud); the default
  /// CIPC host when the account API does not list it.
  @override
  Future<Uri> get cipcUrl async {
    try {
      return Uri.parse(await cloud.discoverCipcUrl(_baseUrl()));
    } on TapoException catch (e) {
      if (e.isAuthError) rethrow;
      return Uri.parse(defaultCipcUrl);
    }
  }

  @override
  Future<CipcResponse> postCipc(Uri url, Map<String, String> headers, Uint8List body) async {
    final response = await transport.send(
      CloudRequest(method: 'POST', uri: url, headers: headers, body: body, timeout: timeout),
    );
    Map<String, dynamic> json = const {};
    try {
      final decoded = jsonDecode(utf8.decode(response.body));
      if (decoded is Map) json = Map<String, dynamic>.from(decoded);
    } on FormatException {
      // not JSON: the slot client maps the HTTP status
    }
    return CipcResponse(response.status, json);
  }

  @override
  Future<void> relogin() => (_relogin ?? cloud.relogin)();

  @override
  String toString() => 'TapoCloudRelayAuth(<hidden>)';
}
