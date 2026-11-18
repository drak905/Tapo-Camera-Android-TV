// Wires the REAL cloud clients (TapoCloud, IotThingsClient, CloudPassthrough,
// relay auth) to MockCloud over loopback HTTP.
//
// The production CloudTransport (HttpClient + TP-Link roots) is not written
// yet, and MockCloud speaks plain HTTP, so the rig brings its own
// [LoopbackCloudTransport]: it forwards every request to the mock and rewrites
// the hard-coded bootstrap host (n-wap-gw.tplinkcloud.com) to the mock.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/camera_router.dart';
import 'package:tapo_tv/api/cloud_passthrough.dart';
import 'package:tapo_tv/api/cloud_transport.dart';
import 'package:tapo_tv/api/iot_things.dart';
import 'package:tapo_tv/api/tapo_cloud.dart';
import 'package:tapo_tv/media/media_deps.dart';

import '../../fixtures/mock_camera.dart';
import '../../fixtures/mock_cloud.dart';
import '../../fixtures/mock_relay.dart';

const String testEmail = 'user@example.com';
const String testPassword = 'correct-horse-battery';
const String testTerminal = 'A1B2C3D4E5F60718293A4B5C6D7E8F90';

/// Real HTTP to the mock; requests for any non-loopback host go to [mockBase].
class LoopbackCloudTransport implements CloudTransport {
  LoopbackCloudTransport(this.mockBase);
  final Uri mockBase;
  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  final List<CloudRequest> sent = [];

  Uri _rewrite(Uri uri) {
    final host = uri.host;
    if (host == '127.0.0.1' || host == 'localhost') return uri;
    return Uri(
      scheme: mockBase.scheme,
      host: mockBase.host,
      port: mockBase.port,
      path: uri.path,
      query: uri.hasQuery && uri.query.isNotEmpty ? uri.query : null,
    );
  }

  @override
  Future<CloudResponse> send(CloudRequest request) async {
    sent.add(request);
    final target = _rewrite(request.uri);
    final req = await _http.openUrl(request.method, target).timeout(request.timeout);
    request.headers.forEach((k, v) {
      if (k.toLowerCase() == 'host') return;
      req.headers.set(k, v, preserveHeaderCase: true);
    });
    final body = request.body;
    if (body != null) {
      req.contentLength = body.length;
      req.add(body);
    }
    final res = await req.close().timeout(request.timeout);
    final bytes = await res.fold<BytesBuilder>(BytesBuilder(copy: false), (b, d) => b..add(d));
    return CloudResponse(res.statusCode, bytes.takeBytes());
  }

  @override
  void close() => _http.close(force: true);
}

/// A started MockCloud with a real TapoCloud in front of it.
class CloudRig {
  CloudRig._(this.mock, this.transport, this.cloud);
  final MockCloud mock;
  final LoopbackCloudTransport transport;
  final TapoCloud cloud;

  /// Base URL of the account API after login (regional URL of the mock).
  String baseUrl = '';

  /// The IoT app server (v2/things base) from getAppServiceUrl.
  String iotUrl = '';

  static Future<CloudRig> start({
    List<Map<String, dynamic>>? devices,
    bool mfa = false,
    bool regionRedirect = true,
    Map<String, String>? localTokens,
    MockRelay? relay,
  }) async {
    final mock = MockCloud(
      accounts: {testEmail: testPassword},
      devices: devices ?? [makeCloudDevice(1)],
      mfa: mfa,
      regionRedirect: regionRedirect,
      localTokens: localTokens,
    );
    mock.relay = relay;
    await mock.start();
    final transport = LoopbackCloudTransport(Uri.parse(mock.baseUrl));
    final cloud = TapoCloud.withTransport(terminalUuid: testTerminal, transport: transport);
    final rig = CloudRig._(mock, transport, cloud);
    addTearDown(() async {
      transport.close();
      await mock.stop();
    });
    return rig;
  }

  /// Plain login without MFA; stores the token on the client like the app.
  Future<LoginResult> signIn({String password = testPassword}) async {
    final login = await cloud.login(testEmail, password);
    final token = login.token;
    if (token == null || token.isEmpty) {
      throw StateError('login returned no token: ${login.result}');
    }
    cloud.token = token;
    baseUrl = login.baseUrl;
    cloud.rememberCredentials(username: testEmail, password: password, baseUrl: baseUrl);
    return login;
  }

  /// IoT things client bound to the current token.
  Future<IotThingsClient> iotClient() async {
    iotUrl = await cloud.discoverIotServer(baseUrl);
    return IotThingsClient(
      transport: transport,
      iotBaseUrl: iotUrl,
      token: cloud.token,
      terminalUuid: testTerminal,
    );
  }

  /// Passthrough that renews the token with a full login when it expires.
  CloudPassthrough passthrough() => CloudPassthrough(
        transport: transport,
        token: cloud.token,
        terminalUuid: testTerminal,
        accountApiIsHttps: false,
        refresher: (stale) async {
          refreshes++;
          final login = await cloud.login(testEmail, testPassword);
          cloud.token = login.token!;
          return cloud.token;
        },
      );

  int refreshes = 0;

  /// Registers [camera] behind passthrough for [deviceId].
  void attach(String deviceId, MockCamera camera) => mock.registerCamera(deviceId, camera);

  /// A [TapoCamera] shaped like the app would derive it.
  static TapoCamera tapoCamera(
    IotThing thing, {
    required CameraRoute route,
    String? lanIp,
  }) =>
      TapoCamera(
        id: thing.deviceId,
        name: 'Camera',
        model: thing.model,
        role: thing.isShared ? CameraRole.shared : CameraRole.owner,
        online: thing.online,
        route: route,
        lanIp: lanIp,
      );
}

/// CloudRelayAuth over a signed-in [CloudRig]: real token, real cipc discovery,
/// real HTTP POST to MockCloud's /cipc/v2/relay/request.
class RigRelayAuth implements CloudRelayAuth {
  RigRelayAuth(this.rig);
  final CloudRig rig;
  int relogins = 0;
  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  final List<Map<String, String>> postedHeaders = [];

  @override
  Future<String?> get token async => rig.cloud.token;

  @override
  Future<Uri> get cipcUrl async => Uri.parse(await rig.cloud.discoverCipcUrl(rig.baseUrl));

  @override
  String get terminalUuid => testTerminal;

  @override
  String get clientModel => 'AndroidTV';

  @override
  String get appVersion => appVersionForTests;

  @override
  Future<CipcResponse> postCipc(Uri url, Map<String, String> headers, Uint8List body) async {
    postedHeaders.add(Map.of(headers));
    final req = await _http.postUrl(url);
    headers.forEach((k, v) => req.headers.set(k, v, preserveHeaderCase: true));
    req.contentLength = body.length;
    req.add(body);
    final res = await req.close().timeout(const Duration(seconds: 10));
    final raw = await res.fold<BytesBuilder>(BytesBuilder(copy: false), (b, d) => b..add(d));
    Map<String, dynamic> json;
    try {
      final v = jsonDecode(utf8.decode(raw.takeBytes()));
      json = v is Map<String, dynamic> ? v : <String, dynamic>{};
    } catch (_) {
      json = <String, dynamic>{};
    }
    return CipcResponse(res.statusCode, json);
  }

  @override
  Future<void> relogin() async {
    relogins++;
    await rig.signIn();
  }
}

const String appVersionForTests = '3.21.114';
