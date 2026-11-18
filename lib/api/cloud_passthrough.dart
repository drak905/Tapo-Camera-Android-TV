// Cloud passthrough (services-sync) used for remote and shared cameras.
// Spec: hc.passthrough.request, hc.passthrough.response_errors.

import 'camera_dtos.dart';
import 'cloud_transport.dart';
import 'iot_things.dart';

/// Returns a fresh token after the old one was refused. Called single-flight:
/// concurrent callers share one refresh and skip it when the token already changed.
typedef TokenRefresher = Future<String> Function(String staleToken);

class CloudPassthrough {
  CloudPassthrough({
    required CloudTransport transport,
    required String token,
    required String terminalUuid,
    required TokenRefresher refresher,
    String locale = 'en_US',
    bool accountApiIsHttps = true,
  });

  /// Current token (after refreshes).
  String get token => throw UnimplementedError();

  /// POST `{thing url}/v1/things/{thingName as ONE quoted segment}/services-sync`
  /// with IoT headers and body `{serviceId:'passthrough', inputParams:{requestData:
  /// a multipleRequest}}`. Returns normalised items (per-item errors kept).
  /// An empty batch sends nothing. A thing URL with query/fragment, a
  /// non-http(s) URL, or http while the account API is https throws
  /// `TapoProtocolError`. 30 s timeout. HTTP 401 or code -20651/-20652/-20675
  /// refreshes once and retries once, then `TapoException('session expired')`.
  Future<List<ControlItem>> send(IotThing thing, List<Map<String, dynamic>> requests) =>
      throw UnimplementedError();
}