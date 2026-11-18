/// Interfaces the media layer needs from the api lane (login session, cloud
/// token, CIPC URL). Tests use fakes; `lib/api/` implements them.
library;

import 'dart:typed_data';

/// Credentials for the local :8800 media port of one camera.
abstract class LocalMediaAuth {
  /// Plain secret for the Digest login: the local access token (LAT) when
  /// known, else the cloud password. Empty means "use the default media
  /// password". The Digest code transforms it (MD5/SHA-256 upper hex).
  String get digestSecret;

  /// Digest username, `admin` unless the camera says otherwise.
  String get username;
}

/// Result of a signed POST to the CIPC relay API.
class CipcResponse {
  const CipcResponse(this.httpStatus, this.json);
  final int httpStatus;
  final Map<String, dynamic> json;
}

/// Cloud session facts the relay needs (implemented over `tapo_cloud.dart`).
abstract class CloudRelayAuth {
  /// Raw account token (the part before ';').
  Future<String?> get token;

  /// `https://<cipc host>` from getAppServiceUrl (service id cipc.api.cloud),
  /// or the aps1 fallback.
  Future<Uri> get cipcUrl;

  /// Terminal uuid, used as playerId, X-Client-Id and X-Client-UUID.
  String get terminalUuid;

  /// Header `X-Client-Model` (Windows app: `Windows`).
  String get clientModel;

  /// App version in the user agents, e.g. `3.22.806`.
  String get appVersion;

  /// POSTs [body] (compact JSON, UTF-8) with [headers] to [url].
  Future<CipcResponse> postCipc(Uri url, Map<String, String> headers, Uint8List body);

  /// One silent re-login (for -1102 / HTTP 401); throws when it fails.
  Future<void> relogin();
}
