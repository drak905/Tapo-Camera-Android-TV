// Adapts the api lane (router, passthrough, IoT things, TDP discovery, VOD,
// alarm poller) and the player lane (media sources) to the UI seams
// `CameraActions` and `CameraViewModel`.
//
// Type names that exist in both the api and the ui layer are imported with
// prefixes: `api.CameraRoute`, `alarm.MotionEvent`, `vod.RecordingClip`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show md5;
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:shared_preferences/shared_preferences.dart';

import '../api/alarm_poller.dart' as alarm;
import '../api/camera_control_client.dart';
import '../api/camera_dtos.dart' as dto;
import '../api/camera_router.dart' as api;
import '../api/camera_transport.dart';
import '../api/cloud_passthrough.dart';
import '../api/cloud_transport.dart';
import '../api/iot_things.dart';
import '../api/lan_matcher.dart';
import '../api/tapo_cloud.dart';
import '../api/tapo_errors.dart';
import '../api/vod_client.dart' as vod;
import '../api/vod_session.dart' as vs;
import '../media/local8800/local_ts_source.dart';
import '../media/media_deps.dart';
import '../media/media_errors.dart';
import '../media/media_source.dart';
import '../media/media_transport.dart';
import '../media/relay/relay_ts_source.dart';
import '../media/remote_stream_gate.dart';
import '../media/stream_limiter.dart';
import 'camera_actions.dart';
import 'camera_names.dart';
import 'camera_view_model.dart';
import 'io_transports.dart';
import 'secure_store.dart';

// ------------------------------------------------------------ conversions --

dto.DayNightMode _toApiMode(DayNightMode mode) => switch (mode) {
      DayNightMode.auto => dto.DayNightMode.auto,
      DayNightMode.on => dto.DayNightMode.on,
      DayNightMode.off => dto.DayNightMode.off,
    };

DayNightMode _toUiMode(dto.DayNightMode mode) => switch (mode) {
      dto.DayNightMode.auto => DayNightMode.auto,
      dto.DayNightMode.on => DayNightMode.on,
      dto.DayNightMode.off => DayNightMode.off,
    };

CameraRoute _toUiRoute(api.CameraRoute route) => route == api.CameraRoute.local ? CameraRoute.local : CameraRoute.cloud;

/// Component names (getAppComponentList) that switch the optional controls on.
/// Best effort: the names come from the Tapo firmware and need a check on real
/// hardware (Tier 4); a wrong name only hides a control.
Set<CameraCapability> capabilitiesFromComponents(Iterable<String> components) {
  final names = components.map((c) => c.toLowerCase()).toSet();
  bool any(List<String> keys) => keys.any(names.contains);
  return {
    if (any(const ['nightvision', 'daynightmode', 'night_vision'])) CameraCapability.nightVision,
    if (any(const ['siren', 'msg_alarm', 'alarm', 'sound_alarm'])) CameraCapability.siren,
    if (any(const ['playback', 'sdcard', 'sd_card', 'record_playback'])) CameraCapability.sdCard,
  };
}

/// Turns any control-stack error into a [CameraActionException] with a
/// readable message. Never includes secrets (the api errors are redacted).
CameraActionException describeCameraError(Object error) {
  if (error is CameraActionException) return error;
  if (error is api.CameraRouteError) {
    return CameraActionException(switch (error.reason) {
      api.RouteFailure.networkOnly => 'This camera is not on this network. Sign in to your Tapo account to reach it.',
      api.RouteFailure.sharedCloudOnly => 'This camera is shared with you and needs the cloud connection.',
      api.RouteFailure.cameraOffline => 'The camera is offline.',
    });
  }
  if (error is TapoDeviceError) return CameraActionException('The camera refused the request (code ${error.code})', code: error.code);
  if (error is TapoException) return CameraActionException(error.message, code: error.code);
  if (error is TapoLockedError) return CameraActionException(error.message);
  if (error is TapoError) return CameraActionException(error.message);
  if (error is TimeoutException) return const CameraActionException('The camera did not answer');
  if (error is MediaException) return CameraActionException(error.message);
  return const CameraActionException('The camera did not answer');
}

// ------------------------------------------------------------ media auth --

class _LocalAuth implements LocalMediaAuth {
  _LocalAuth(this.digestSecret);
  @override
  final String digestSecret;
  @override
  String get username => 'admin';
}

/// Cloud session facts for the relay (token, CIPC URL, signed POST, re-login).
class _RelayAuth implements CloudRelayAuth {
  _RelayAuth({
    required this.cloud,
    required this.baseUrl,
    required this.transport,
    required this.terminalUuid,
    required this.relogin_,
  });

  final TapoCloud cloud;
  final String baseUrl;
  final CloudTransport transport;
  final Future<void> Function() relogin_;

  @override
  final String terminalUuid;

  @override
  Future<String?> get token async {
    final t = cloud.token;
    return t.isEmpty ? null : t.split(';').first;
  }

  @override
  Future<Uri> get cipcUrl async => Uri.parse(await cloud.discoverCipcUrl(baseUrl));

  @override
  String get clientModel => 'AndroidTV';

  @override
  String get appVersion => '3.22.806';

  @override
  Future<CipcResponse> postCipc(Uri url, Map<String, String> headers, Uint8List body) async {
    final response = await transport.send(CloudRequest(method: 'POST', uri: url, headers: headers, body: body));
    Map<String, dynamic> json = const {};
    try {
      final decoded = jsonDecode(utf8.decode(response.body));
      if (decoded is Map) json = Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return CipcResponse(response.status, json);
  }

  @override
  Future<void> relogin() => relogin_();
}

// ----------------------------------------------------------- remote gate --

/// A source that holds a [RemoteStreamGate] slot while it streams. When the
/// gate evicts it (too many remote streams) the stream ends with an error.
class _GatedSource implements MediaSource {
  _GatedSource(this._inner, this._gate, this._key, {required this.preempt});
  final MediaSource _inner;
  final RemoteStreamGate _gate;
  final String _key;
  final bool preempt;

  @override
  Stream<Uint8List> openTs() {
    late StreamController<Uint8List> out;
    StreamSubscription<Uint8List>? sub;
    var finished = false;

    void finish() {
      if (finished) return;
      finished = true;
      _gate.release(_key);
    }

    out = StreamController<Uint8List>(
      onListen: () {
        final admitted = _gate.acquire(_key, () {
          unawaited(sub?.cancel());
          if (!out.isClosed) {
            out.addError(const StreamLimitException('Too many remote streams. Raise the limit in Settings.'));
            unawaited(out.close());
          }
          finish();
        }, preempt: preempt);
        if (!admitted) {
          out.addError(const StreamLimitException('Too many remote streams. Raise the limit in Settings.'));
          unawaited(out.close());
          return;
        }
        sub = _inner.openTs().listen(
          out.add,
          onError: out.addError,
          onDone: () {
            finish();
            unawaited(out.close());
          },
        );
      },
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () async {
        finish();
        await sub?.cancel();
      },
    );
    return out.stream;
  }
}

// ---------------------------------------------------------------- backend --

/// What a status refresh reports to the UI.
class BackendStatus {
  const BackendStatus({required this.privacy, required this.dayNight, this.ptz});
  final bool privacy;
  final DayNightMode dayNight;
  final bool? ptz;
}

typedef DiscoverFn = Future<List<LanDevice>> Function();

/// Owns the control stack for one signed-in session: IoT things, LAN
/// discovery, per-camera routing, media sources, SD playback, motion polling
/// and the optional per-camera account.
class CameraBackend {
  CameraBackend({
    required this.cloud,
    required this.baseUrl,
    required this.terminalUuid,
    required this.transport,
    int maxRemoteStreams = kDefaultMaxRemoteStreams,
    this.secureStore,
    this.secureBackend,
    this.prefs,
    this.pins,
    DiscoverFn? discover,
    CameraLinkFactory? linkFactory,
    TransportConnector? connector,
    this.rememberPassword = _never,
  })  : _discover = discover ?? discoverLanDevices,
        _linkFactory = linkFactory ?? connectCameraLink,
        _connector = connector ?? connectSocketTransport,
        _gate = RemoteStreamGate(capacity: maxRemoteStreams) {
    passthrough = CloudPassthrough(
      transport: transport,
      token: cloud.token,
      terminalUuid: terminalUuid,
      refresher: _refreshToken,
    );
    router = api.CameraRouter(
      localFactory: _localControl,
      cloudFactory: _cloudControl,
      cloudSignedIn: () => cloud.token.isNotEmpty,
    );
    actions = LiveCameraActions(this);
    _localNames = _readLocalNames();
  }

  static bool _never() => false;

  final TapoCloud cloud;
  final String baseUrl;
  final String terminalUuid;
  final CloudTransport transport;
  final SecureStore? secureStore;
  final SecureBackend? secureBackend;
  final SharedPreferences? prefs;
  final PinStore? pins;

  /// Whether the user opted in to keep the cloud password on this TV.
  final bool Function() rememberPassword;

  final DiscoverFn _discover;
  final CameraLinkFactory _linkFactory;
  final TransportConnector _connector;
  final RemoteStreamGate _gate;
  final StreamLimiter _limiter = StreamLimiter();

  late final CloudPassthrough passthrough;
  late final api.CameraRouter router;
  late final LiveCameraActions actions;
  late final _RelayAuth _relayAuth = _RelayAuth(
    cloud: cloud,
    baseUrl: baseUrl,
    transport: transport,
    terminalUuid: terminalUuid,
    relogin_: _relogin,
  );

  final CameraNames names = CameraNames();
  final Map<String, api.TapoCamera> cameras = {};
  final Map<String, IotThing> things = {};
  final Map<String, LanMatch> lan = {};
  final Map<String, CameraControlClient> _localClients = {};
  final Map<String, Set<String>> _components = {};
  final Map<String, MediaSource> _vodSources = {};
  final Map<String, alarm.AlarmPoller> _pollers = {};
  final _motion = StreamController<MotionEvent>.broadcast();
  late Map<String, String> _localNames;
  String? _password;
  String? _username;
  bool _closed = false;

  Stream<MotionEvent> get motionEvents => _motion.stream;

  // ----------------------------------------------------------- session --

  Future<String> _refreshToken(String stale) async {
    if (cloud.token.isNotEmpty && cloud.token != stale) return cloud.token;
    await _relogin();
    return cloud.token;
  }

  /// One silent sign-in with the opt-in stored password.
  Future<void> _relogin() async {
    await _loadPassword();
    final user = _username, pass = _password;
    if (user == null || pass == null) throw TapoException('Your session expired. Sign in again.', code: -20651);
    final result = await cloud.login(user, pass);
    final token = result.result['token'];
    if (token == null || '$token'.isEmpty) throw TapoException('Your session expired. Sign in again.', code: -20651);
    cloud.token = '$token';
  }

  Future<void> _loadPassword() async {
    if (!rememberPassword() || _password != null) return;
    final stored = await secureStore?.loadPassword();
    if (stored != null) {
      _username = stored.$1;
      _password = stored.$2;
    }
  }

  // ------------------------------------------------------------- views --

  Map<String, String> _readLocalNames() {
    try {
      final raw = prefs?.getString('local_names');
      if (raw == null) return {};
      return {for (final e in (jsonDecode(raw) as Map).entries) '${e.key}': '${e.value}'};
    } catch (_) {
      return {};
    }
  }

  Future<void> setLocalName(String cameraId, String? name) async {
    if (name == null) {
      _localNames.remove(cameraId);
    } else {
      _localNames[cameraId] = name;
    }
    await prefs?.setString('local_names', jsonEncode(_localNames));
  }

  static String _alias(Map<String, dynamic> device) {
    final alias = '${device['alias'] ?? device['deviceName'] ?? device['deviceModel'] ?? 'Camera'}'.trim();
    return alias.isEmpty ? 'Camera' : alias;
  }

  /// Builds the view model of every device: thing role/status, LAN match,
  /// route. Capabilities start empty and are filled by [loadCapabilities].
  Future<Map<String, CameraViewModel>> loadViews(List<Map<String, dynamic>> devices) async {
    Map<String, IotThing> fetched = {};
    try {
      final iotBase = await cloud.discoverIotServer(baseUrl);
      fetched = await IotThingsClient(
        transport: transport,
        iotBaseUrl: iotBase,
        token: cloud.token,
        terminalUuid: terminalUuid,
      ).fetchAll();
    } on IotTokenExpired {
      throw TapoException('Your session expired. Sign in again.', code: -20651);
    } catch (_) {
      // The device list still gives role and status; control falls back to it.
    }
    List<LanDevice> found = const [];
    try {
      found = await _discover();
    } catch (_) {}
    final matches = matchLan([
      for (final d in devices)
        CloudDeviceRef(deviceId: '${d['deviceId'] ?? ''}', mac: '${d['deviceMac'] ?? d['mac'] ?? ''}'),
    ], found);

    things
      ..clear()
      ..addAll(fetched);
    lan
      ..clear()
      ..addAll(matches);
    final views = <String, CameraViewModel>{};
    for (final d in devices) {
      final id = '${d['deviceId'] ?? ''}';
      final thing = things[id];
      final match = lan[id];
      final role = api.roleFromRecords(thingRole: thing?.role, deviceListRole: int.tryParse('${d['role'] ?? ''}'));
      final online = api.cameraOnline(
        thingStatus: thing?.status,
        deviceListStatus: int.tryParse('${d['status'] ?? ''}'),
        lanFound: match?.lanFound ?? false,
      );
      final route = api.routeFor(isManual: false, role: role, lanFound: match?.lanFound ?? false, host: match?.host);
      final camera = api.TapoCamera(
        id: id,
        name: _alias(d),
        model: '${d['deviceModel'] ?? ''}',
        role: role,
        online: online,
        route: route,
        lanIp: match?.lanFound == true ? match!.host : null,
      );
      cameras[id] = camera;
      final lat = thing?.localAccessToken;
      if (lat != null) unawaited(secureStore?.saveLat(id, lat) ?? Future<void>.value());
      views[id] = _view(camera, d, _components[id]);
    }
    return views;
  }

  CameraViewModel _view(api.TapoCamera camera, Map<String, dynamic> device, Set<String>? components) {
    final local = _localNames[camera.id];
    final alias = _alias(device);
    return CameraViewModel(
      id: camera.id,
      displayName: local ?? names.display(camera.id, alias),
      model: camera.model,
      isShared: camera.isShared,
      online: camera.online,
      route: _toUiRoute(camera.route),
      capabilities: components == null ? const {} : capabilitiesFromComponents(components),
      localName: local,
    );
  }

  /// Reads the component list of every online camera (one request each, a few
  /// at a time) and reports a refreshed view model per camera.
  Future<void> loadCapabilities(
    List<Map<String, dynamic>> devices,
    void Function(String id, CameraViewModel view) onView,
  ) async {
    final queue = [for (final d in devices) if (cameras[_id(d)]?.online ?? false) d];
    Future<void> worker() async {
      while (queue.isNotEmpty && !_closed) {
        final d = queue.removeAt(0);
        final id = _id(d);
        try {
          final components = await _loadComponents(id);
          final camera = cameras[id];
          if (camera != null && !_closed) onView(id, _view(camera, d, components));
        } catch (_) {}
      }
    }

    await Future.wait([for (var i = 0; i < 3; i++) worker()]);
  }

  static String _id(Map<String, dynamic> d) => '${d['deviceId'] ?? ''}';

  Future<Set<String>> _loadComponents(String id) async {
    final cached = _components[id];
    if (cached != null) return cached;
    final responses = await cloud.servicesSync(baseUrl, id, [dto.buildGetAppComponentList()]).timeout(const Duration(seconds: 12));
    final first = responses.isNotEmpty && responses.first is Map ? Map<String, dynamic>.from(responses.first as Map) : const <String, dynamic>{};
    final result = first['result'];
    final list = result is Map && result['app_component'] is Map ? result['app_component']['app_component_list'] : null;
    final out = <String>{
      if (list is List)
        for (final item in list)
          if (item is Map && item['name'] != null) '${item['name']}',
    };
    _components[id] = out;
    return out;
  }

  // ----------------------------------------------------------- control --

  api.CameraControl _localControl(api.TapoCamera camera, String? lat) {
    final host = camera.lanIp;
    if (host == null) throw const api.CameraRouteError(api.RouteFailure.networkOnly);
    final match = lan[camera.id];
    final client = CameraControlClient(
      channel: CameraTransport(
        host: host,
        port: match?.httpsPort ?? 443,
        pins: pins ?? _MemoryPins(),
        linkFactory: _linkFactory,
      ),
      secrets: LocalSecrets(password: _password ?? '', lat: lat),
      hint: match?.controlProtocol == 'tpap' ? LocalProtocolHint.tpap : LocalProtocolHint.probe,
    );
    _localClients[camera.id] = client;
    return api.LocalControl(client);
  }

  api.CameraControl _cloudControl(api.TapoCamera camera) {
    final thing = things[camera.id];
    if (thing == null) throw const api.CameraRouteError(api.RouteFailure.cameraOffline);
    return api.CloudControl(passthrough: passthrough, thing: thing);
  }

  Future<api.CameraControl> control(String id) async {
    final camera = cameras[id];
    if (camera == null) throw const CameraActionException('Unknown camera');
    await _loadPassword();
    final lat = things[id]?.localAccessToken ?? await secureStore?.loadLat(id);
    return router.controlFor(camera, lat: lat);
  }

  /// Runs [fn] on the camera's control and maps errors for the UI.
  Future<T> run<T>(String id, Future<T> Function(api.CameraControl control) fn) async {
    try {
      return await fn(await control(id));
    } catch (e) {
      throw describeCameraError(e);
    }
  }

  Future<BackendStatus> readStatus(String id) async {
    final status = await run(id, (c) => c.readStatus());
    bool? ptz;
    try {
      ptz = (await _loadComponents(id)).contains('ptz');
    } catch (_) {}
    return BackendStatus(privacy: status.privacy, dayNight: _toUiMode(status.nightVision), ptz: ptz);
  }

  Future<bool> setPrivacy(String id, bool on) async {
    await run(id, (c) => c.setPrivacy(on));
    return on;
  }

  Future<void> move(String id, int x, int y) => run(id, (c) => c.ptzMove(x, y));

  void setMaxRemoteStreams(int value) {
    try {
      _gate.setCapacity(value);
    } catch (_) {}
  }

  // ------------------------------------------------------------- media --

  /// Camera in the current view (never evicted from the remote gate).
  void reserveViewed(Iterable<String> ids) => _gate.reserve(ids);

  /// Source for the loopback bridge: `vod:<id>` is an SD playback, anything
  /// else a live preview (`HD` main stream, else `VGA`).
  MediaSource? sourceFor(String id, String? resolution) {
    final vodSource = _vodSources[id];
    if (vodSource != null) return vodSource;
    final camera = cameras[id];
    if (camera == null || !camera.online) return null;
    final res = resolution == 'HD' ? 'HD' : 'VGA';
    final host = camera.lanIp;
    if (camera.route == api.CameraRoute.local && host != null && !camera.isShared) {
      return LocalTsSource(
        host: host,
        auth: _LocalAuth(things[id]?.localAccessToken ?? _password ?? ''),
        connector: _connector,
        resolution: res,
        limiter: _limiter,
        limiterKey: host,
      );
    }
    return _GatedSource(
      RelayTsSource(deviceId: id, auth: _relayAuth, connector: _connector, resolution: res, limiter: _limiter),
      _gate,
      id,
      preempt: true,
    );
  }

  // ------------------------------------------------------------ motion --

  /// Polls getLastAlarmInfo for every online camera (5 s local, 30 s cloud).
  void startMotion(List<String> Function() cameraIds) {
    for (final id in cameraIds()) {
      final camera = cameras[id];
      if (camera == null || !camera.online || _pollers.containsKey(id)) continue;
      final poller = alarm.AlarmPoller(
        cameraId: id,
        cloudRouted: camera.route == api.CameraRoute.cloud,
        readAlarm: () async {
          final info = await run(id, (c) => c.lastAlarm());
          return {
            'system': {
              'last_alarm_info': {'last_alarm_time': info.time, 'last_alarm_type': info.type},
            },
          };
        },
        onEvent: (e) {
          if (!_motion.isClosed) _motion.add(MotionEvent(cameraId: e.cameraId, active: e.active, time: e.timestamp));
        },
      );
      _pollers[id] = poller..start();
    }
  }

  // ------------------------------------------------------------ vod --

  vod.VodControl _vodControl(String id) {
    final camera = cameras[id];
    if (camera == null) throw const CameraActionException('Unknown camera');
    return _VodControlAdapter(this, camera);
  }

  Future<List<RecordingClip>> listClips(String id, DateTime fromUtc, DateTime toUtc) async {
    final client = vod.VodClient(control: _vodControl(id), terminalUuid: terminalUuid);
    final out = <RecordingClip>[];
    var day = DateTime(fromUtc.toLocal().year, fromUtc.toLocal().month, fromUtc.toLocal().day);
    final last = toUtc.toLocal();
    try {
      while (!day.isAfter(last)) {
        for (final c in await client.recordingsForDay(day)) {
          final start = DateTime.fromMillisecondsSinceEpoch(c.start * 1000, isUtc: true);
          final end = DateTime.fromMillisecondsSinceEpoch(c.end * 1000, isUtc: true);
          if (end.isAfter(fromUtc) && start.isBefore(toUtc)) {
            out.add(RecordingClip(start: start, end: end, eventType: c.eventType == 0 ? 1 : c.eventType));
          }
        }
        day = DateTime(day.year, day.month, day.day + 1);
      }
    } catch (e) {
      throw describeCameraError(e);
    }
    return out;
  }

  Future<PlaybackControl> openPlayback(String id, DateTime startUtc, DateTime endUtc) async {
    final camera = cameras[id];
    if (camera == null) throw const CameraActionException('Unknown camera');
    final choice = vod.chooseVodTransport(camera, relayAvailable: cloud.token.isNotEmpty);
    if (choice.failure != null) {
      throw CameraActionException(switch (choice.failure!) {
        vod.VodFailReason.notOnThisNetwork => 'The recordings are only reachable from the camera network or with your Tapo account.',
        vod.VodFailReason.cameraOffline => 'The camera is offline.',
        vod.VodFailReason.sharedCameraCloudOnly => 'Recordings of a shared camera need the cloud connection.',
      });
    }
    final start = startUtc.millisecondsSinceEpoch ~/ 1000;
    final end = endUtc.millisecondsSinceEpoch ~/ 1000;
    final clips = <vs.VodClipRange>[];
    try {
      final day = DateTime.fromMillisecondsSinceEpoch(start * 1000, isUtc: true);
      for (final c in await listClips(id, day, endUtc)) {
        clips.add(vs.VodClipRange(c.start.millisecondsSinceEpoch ~/ 1000, c.end.millisecondsSinceEpoch ~/ 1000));
      }
    } catch (_) {
      // Playback still works without the clip list; it only cannot hop gaps.
    }
    final session = choice.kind == vod.VodTransportKind.local
        ? vs.VodSession.local(
            host: camera.lanIp!,
            localAuth: _LocalAuth(things[id]?.localAccessToken ?? _password ?? ''),
            connector: _connector,
            startUtc: start,
            endUtc: end,
            limiter: _limiter,
            clips: clips,
          )
        : vs.VodSession.relay(
            deviceId: id,
            auth: _relayAuth,
            connector: _connector,
            startUtc: start,
            endUtc: end,
            limiter: _limiter,
            clips: clips,
          );
    final bridgeId = 'vod:$id';
    _vodSources[bridgeId] = session;
    return LivePlayback(session, bridgeId, startUtc, onClose: () => _vodSources.remove(bridgeId));
  }

  // --------------------------------------------------- camera account --

  String _accountKey(String id) => 'cam_account:$id';

  final Map<String, (String, String)> _memoryAccounts = {};

  Future<(String, String)?> loadAccount(String id) async {
    final backend = secureBackend;
    if (backend == null) return _memoryAccounts[id];
    final raw = await backend.read(_accountKey(id));
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map;
      return ('${m['u']}', '${m['p']}');
    } catch (_) {
      return null;
    }
  }

  Future<void> saveAccount(String id, String user, String password) async {
    final backend = secureBackend;
    if (backend == null) {
      _memoryAccounts[id] = (user, password);
    } else {
      await backend.write(_accountKey(id), jsonEncode({'u': user, 'p': password}));
    }
  }

  Future<void> clearAccount(String id) async {
    _memoryAccounts.remove(id);
    await secureBackend?.delete(_accountKey(id));
  }

  /// ONE RTSP DESCRIBE with Digest on the camera's :554. A wrong account never
  /// triggers a second attempt.
  Future<bool> testAccount(String id, String user, String password) async {
    final host = cameras[id]?.lanIp;
    if (host == null) {
      throw const CameraActionException('The camera must be on this network to test the account.');
    }
    return rtspDigestLogin(host, user, password);
  }

  void close() {
    _closed = true;
    for (final p in _pollers.values) {
      p.stop();
    }
    _pollers.clear();
    for (final c in _localClients.values) {
      try {
        c.close();
      } catch (_) {}
    }
    _localClients.clear();
    router.invalidate();
    transport.close();
    if (!_motion.isClosed) unawaited(_motion.close());
  }
}

class _MemoryPins implements PinStore {
  final Map<String, String> _pins = {};
  @override
  String? read(String hostPort) => _pins[hostPort];
  @override
  Future<void> write(String hostPort, String sha256Hex) async => _pins[hostPort] = sha256Hex;
}

/// Search requests through the camera's own control path.
class _VodControlAdapter implements vod.VodControl {
  _VodControlAdapter(this._backend, this._camera);
  final CameraBackend _backend;
  final api.TapoCamera _camera;

  @override
  Future<List<dto.ControlItem>> send(List<Map<String, dynamic>> requests) async {
    // Builds (or reuses) the routed control so the local client exists.
    await _backend.control(_camera.id);
    final local = _backend._localClients[_camera.id];
    if (_camera.route == api.CameraRoute.local && !_camera.isShared && local != null) {
      return local.send(requests);
    }
    final thing = _backend.things[_camera.id];
    if (thing == null) throw const api.CameraRouteError(api.RouteFailure.cameraOffline);
    return _backend.passthrough.send(thing, requests);
  }
}

// -------------------------------------------------------------- actions --

/// `CameraActions` over a [CameraBackend].
class LiveCameraActions implements CameraActions {
  LiveCameraActions(this._backend);
  final CameraBackend _backend;

  @override
  Future<DayNightMode> setDayNight(String cameraId, DayNightMode mode) =>
      _backend.run(cameraId, (c) async {
        await c.setNightVision(_toApiMode(mode));
        return mode;
      });

  @override
  Future<bool> setAlarm(String cameraId, bool on) => _backend.run(cameraId, (c) async {
        await c.setSiren(on);
        return on;
      });

  @override
  Future<void> renameOnCamera(String cameraId, String name) async {
    final String normalized;
    try {
      normalized = normalizeCameraName(name);
    } catch (e) {
      throw describeCameraError(e);
    }
    await _backend.run(cameraId, (c) => c.rename(normalized));
    _backend.names.setPending(cameraId, normalized);
  }

  @override
  Future<void> setLocalName(String cameraId, String? name) => _backend.setLocalName(cameraId, name);

  @override
  Future<List<RecordingClip>> listClips(String cameraId, DateTime fromUtc, DateTime toUtc) =>
      _backend.listClips(cameraId, fromUtc, toUtc);

  @override
  Future<PlaybackControl> openPlayback(String cameraId, DateTime startUtc, DateTime endUtc) =>
      _backend.openPlayback(cameraId, startUtc, endUtc);

  @override
  Stream<MotionEvent> get motionEvents => _backend.motionEvents;

  @override
  Future<bool> testCameraAccount(String cameraId, String username, String password) async {
    try {
      return await _backend.testAccount(cameraId, username, password);
    } catch (e) {
      throw describeCameraError(e);
    }
  }

  @override
  Future<void> saveCameraAccount(String cameraId, String username, String password) =>
      _backend.saveAccount(cameraId, username, password);

  @override
  Future<void> clearCameraAccount(String cameraId) => _backend.clearAccount(cameraId);

  @override
  Future<String?> cameraAccountUser(String cameraId) async => (await _backend.loadAccount(cameraId))?.$1;
}

/// An SD playback: wraps a `VodSession`. The video itself is drawn by a
/// native view fed from the loopback bridge under [bridgeId].
class LivePlayback implements PlaybackControl {
  LivePlayback(this.session, this.bridgeId, DateTime start, {this.onClose})
      : _state = ValueNotifier(PlaybackState(position: start)) {
    _sub = session.states.listen(_onSession);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  final vs.VodSession session;

  /// Id to ask the `RelayBridge` for (`relay.urlFor(bridgeId)`).
  final String bridgeId;
  final void Function()? onClose;
  final ValueNotifier<PlaybackState> _state;
  late final StreamSubscription<vs.VodState> _sub;
  late final Timer _timer;
  bool _stopped = false;

  @override
  ValueListenable<PlaybackState> get state => _state;

  void _onSession(vs.VodState s) {
    _state.value = _state.value.copyWith(
      paused: s == vs.VodState.paused,
      ended: s == vs.VodState.stopped && session.endReason != null,
    );
  }

  void _tick() {
    final utc = session.lastPositionUtc;
    if (utc == null || _stopped) return;
    _state.value = _state.value.copyWith(position: DateTime.fromMillisecondsSinceEpoch(utc * 1000, isUtc: true));
  }

  @override
  Future<void> pause() => session.pause();

  @override
  Future<void> resume() => session.resume();

  @override
  Future<void> seekTo(DateTime utc) async {
    await session.seek(utc.millisecondsSinceEpoch ~/ 1000);
    _state.value = _state.value.copyWith(position: utc.toUtc(), ended: false);
  }

  @override
  Future<void> setSpeed(int speed) async {
    final label = '$speed/1';
    if (!vs.kVodSpeeds.contains(label)) return;
    session.setSpeed(label);
    _state.value = _state.value.copyWith(speed: speed);
  }

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _timer.cancel();
    await _sub.cancel();
    onClose?.call();
    await session.stop();
  }
}

/// Minimal fake used with `--dart-define=TOPO_DEMO=true`: no network at all.
class DemoCameraActions implements CameraActions {
  final _motion = StreamController<MotionEvent>.broadcast();
  final _accounts = <String, String>{};

  @override
  Future<DayNightMode> setDayNight(String cameraId, DayNightMode mode) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return mode;
  }

  @override
  Future<bool> setAlarm(String cameraId, bool on) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return on;
  }

  @override
  Future<void> renameOnCamera(String cameraId, String name) async {}

  @override
  Future<void> setLocalName(String cameraId, String? name) async {}

  @override
  Future<List<RecordingClip>> listClips(String cameraId, DateTime fromUtc, DateTime toUtc) async {
    final day = DateTime.utc(fromUtc.year, fromUtc.month, fromUtc.day, 8);
    return [
      for (var i = 0; i < 4; i++)
        RecordingClip(
          start: day.add(Duration(hours: i * 3)),
          end: day.add(Duration(hours: i * 3, minutes: 40)),
          eventType: i.isEven ? 1 : 2,
        ),
    ];
  }

  @override
  Future<PlaybackControl> openPlayback(String cameraId, DateTime startUtc, DateTime endUtc) async =>
      throw const CameraActionException('Recordings are not available in demo mode');

  @override
  Stream<MotionEvent> get motionEvents => _motion.stream;

  @override
  Future<bool> testCameraAccount(String cameraId, String username, String password) async => true;

  @override
  Future<void> saveCameraAccount(String cameraId, String username, String password) async =>
      _accounts[cameraId] = username;

  @override
  Future<void> clearCameraAccount(String cameraId) async => _accounts.remove(cameraId);

  @override
  Future<String?> cameraAccountUser(String cameraId) async => _accounts[cameraId];
}

// ------------------------------------------------------------ RTSP test --

/// One RTSP DESCRIBE on `:554/stream1` with Digest authentication. True when
/// the camera accepts the account. Never retries a wrong password.
Future<bool> rtspDigestLogin(
  String host,
  String user,
  String password, {
  int port = 554,
  Duration timeout = const Duration(seconds: 6),
}) async {
  final uri = 'rtsp://$host:$port/stream1';
  final socket = await Socket.connect(host, port, timeout: timeout);
  final iterator = StreamIterator<List<int>>(socket);
  final buffer = <int>[];
  try {
    Future<String> request(int cseq, String auth) async {
      socket.write('DESCRIBE $uri RTSP/1.0\r\nCSeq: $cseq\r\nAccept: application/sdp\r\n$auth\r\n');
      while (true) {
        final text = latin1.decode(buffer, allowInvalid: true);
        final end = text.indexOf('\r\n\r\n');
        if (end >= 0) {
          buffer.removeRange(0, end + 4);
          return text.substring(0, end);
        }
        if (!await iterator.moveNext().timeout(timeout)) return text;
        buffer.addAll(iterator.current);
      }
    }

    int status(String head) => int.tryParse(head.split(' ').elementAtOrNull(1) ?? '') ?? 0;

    final first = await request(1, '');
    if (status(first) == 200) return true;
    if (status(first) != 401) return false;
    final challenge = RegExp(r'WWW-Authenticate:\s*Digest\s+(.*)', caseSensitive: false).firstMatch(first)?.group(1);
    if (challenge == null) return false;
    String? field(String name) => RegExp('$name="([^"]*)"', caseSensitive: false).firstMatch(challenge)?.group(1);
    final realm = field('realm'), nonce = field('nonce');
    if (realm == null || nonce == null) return false;
    String md5hex(String s) => md5.convert(utf8.encode(s)).toString();
    final response = md5hex('${md5hex('$user:$realm:$password')}:$nonce:${md5hex('DESCRIBE:$uri')}');
    final second = await request(
      2,
      'Authorization: Digest username="$user", realm="$realm", nonce="$nonce", uri="$uri", response="$response"\r\n',
    );
    return status(second) == 200;
  } finally {
    await iterator.cancel();
    socket.destroy();
  }
}
