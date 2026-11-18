import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/cloud_transport.dart';
import '../api/relay_bridge.dart';
import '../media/http_ts_source.dart';
import '../api/tapo_cloud.dart';
import '../media/remote_stream_gate.dart' show kDefaultMaxRemoteStreams, kMaxRemoteStreamsLimit;
import '../player/stream_queue.dart';
import 'camera_actions.dart';
import 'camera_actions_impl.dart';
import 'camera_sort.dart';
import 'camera_view_model.dart';
import 'grids.dart';
import 'io_transports.dart';
import 'secure_store.dart';

enum AuthStage { starting, signedOut, mfa, signedIn }

class Camera {
  Camera(this.raw);
  final Map<String, dynamic> raw;

  String get deviceId => '${raw['deviceId'] ?? ''}';
  String get name => view?.displayName ?? '${raw['alias'] ?? raw['deviceName'] ?? 'Camera'}'.trim();
  String get model => '${raw['deviceModel'] ?? ''}';
  String get firmware => '${raw['fwVer'] ?? ''}'.split(' ').first;

  /// Account list status; not a live reachability check (the relay can still
  /// work while this reports 0), so it is only used as a hint.
  bool get reportedOnline => raw['status'] == 1;

  /// View model from the api lane (role, online, route, capabilities).
  CameraViewModel? view;
  bool get online => view?.online ?? reportedOnline;
  CameraRoute get route => view?.route ?? CameraRoute.cloud;
  bool get isShared => view?.isShared ?? ('${raw['role'] ?? 0}' != '0');
  Set<CameraCapability> get capabilities => view?.capabilities ?? const {};
  String? get localName => view?.localName;

  /// null = unknown.
  DayNightMode? dayNight;
  bool? alarm;

  bool? privacy;
  bool? ptz;
  String? stateError;
  DateTime? checkedAt;
}

class PendingMfa {
  PendingMfa({
    required this.baseUrl,
    required this.username,
    required this.password,
    required this.processId,
    required this.types,
  });
  final String baseUrl;
  final String username;
  final String password;
  final String processId;
  final List<int> types;
  int? requestedType;
}

class AppState extends ChangeNotifier {
  /// UI test mode (`--dart-define=TOPO_DEMO=true`): fake cameras, no cloud.
  static const demo = bool.fromEnvironment('TOPO_DEMO');

  static const _kSession = 'session';
  static const _kTerminal = 'terminal_uuid';
  static const _kLivePreviews = 'live_previews';
  static const _kPtzStep = 'ptz_step';
  static const _kGuideSeen = 'guide_seen';
  static const _kAccount = 'account_hint';
  static const _kGrids = 'grids';
  static const _kActiveGrid = 'active_grid';
  static const _kFavoriteGrid = 'favorite_grid';
  static const _kCameraSort = 'camera_sort';
  static const _kMaxRemote = 'max_remote_streams';
  static const _kRememberPassword = 'remember_password';
  static const _kMotionNotifications = 'motion_notifications';

  /// [secureStore] holds the session token (and the password only after the
  /// opt-in); without it the session stays in shared_preferences (tests).
  /// [useBackend] wires the real control, discovery and media stack.
  AppState({SecureStore? secureStore, SecureBackend? secureBackend, this.useBackend = false})
      : _secure = secureStore,
        // ignore: prefer_initializing_formals
        _secureBackend = secureBackend;

  final SecureStore? _secure;
  final SecureBackend? _secureBackend;
  final bool useBackend;
  CameraBackend? _backend;

  late SharedPreferences _prefs;
  late SecurityContext _context;
  bool _bootstrapped = false;
  TapoCloud? _client;
  String _baseUrl = loginUrl;
  late final RelayBridge relay = useBackend && !demo
      ? RelayBridge.sources((id, resolution) => _backend?.sourceFor(id, resolution))
      : demo && _demoStream.isNotEmpty
          // The native player only accepts bridge URLs, so the demo stream is
          // proxied through the bridge like a camera.
          ? RelayBridge.sources(
              (id, _) => HttpTsSource(Uri.parse('$_demoStream?cam=${Uri.encodeComponent(id)}')))
          : RelayBridge(_resolveForRelay);

  AuthStage stage = AuthStage.starting;
  PendingMfa? pendingMfa;
  List<Camera> cameras = [];
  bool loadingCameras = false;
  String? camerasError;
  String accountHint = '';

  /// False while the app is in the background: all video is stopped.
  bool foreground = true;

  bool livePreviews = true;
  int ptzStep = 10;
  bool guideSeen = false;

  /// User-saved multi-view grids (the built-in "All cameras" is not stored).
  List<GridPreset> savedGrids = [];
  String activeGridId = GridPreset.allCamerasId;

  /// Grid pinned to the top of the home page, if any.
  String? favoriteGridId;

  TapoCloud? get client => _client;

  Future<void> init() async {
    if (!_bootstrapped) {
      _prefs = await SharedPreferences.getInstance();
      final pem = await rootBundle.load('assets/tapo-cloud-roots.pem');
      _context = TapoCloud.buildContext(pem.buffer.asUint8List());
      livePreviews = _prefs.getBool(_kLivePreviews) ?? true;
      ptzStep = _prefs.getInt(_kPtzStep) ?? 10;
      guideSeen = _prefs.getBool(_kGuideSeen) ?? false;
      accountHint = _prefs.getString(_kAccount) ?? '';
      _cameraSort = CameraSort.parse(_prefs.getString(_kCameraSort));
      _maxRemoteStreams = (_prefs.getInt(_kMaxRemote) ?? kDefaultMaxRemoteStreams).clamp(1, kMaxRemoteStreamsLimit);
      _rememberPassword = _prefs.getBool(_kRememberPassword) ?? false;
      _motionNotifications = _prefs.getBool(_kMotionNotifications) ?? true;
      _loadGrids();
      await Snapshots.instance.init();
      await relay.start();
      _bootstrapped = true;
    }
    camerasError = null;

    if (demo) {
      cameras = [
        for (final (name, model, ptz, privacy) in const [
          ('Living room', 'C200', true, false),
          ('Front door', 'C320WS', false, false),
          ('Garden', 'C500', true, false),
          ('Baby room', 'C210', true, true),
          ('Garage', 'C110', false, false),
        ])
          Camera({'deviceId': 'demo-$name', 'alias': name, 'deviceModel': model, '_ptz': ptz, '_privacy': privacy}),
      ];
      actions ??= DemoCameraActions();
      stage = AuthStage.signedIn;
      notifyListeners();
      for (final c in cameras) {
        unawaited(refreshCameraState(c));
      }
      return;
    }

    final saved = await _loadSession();
    if (saved != null) {
      try {
        final client = (await _newClient())..token = saved.token;
        final baseUrl = saved.baseUrl;
        final devices = await client.listCameras(baseUrl);
        _setSignedIn(client, baseUrl, devices);
        return;
      } on TapoException catch (e) {
        if (e.code != null) await _clearSession();
        // Without a code it was a network problem: keep the session and let
        // the user retry from the sign-in screen.
        camerasError = e.message;
      } catch (_) {
        await _clearSession();
      }
    }
    stage = AuthStage.signedOut;
    notifyListeners();
  }

  bool _hasSession = false;
  bool get hasSavedSession => _hasSession || _prefs.getString(_kSession) != null;

  Future<StoredSession?> _loadSession() async {
    final secure = _secure;
    if (secure != null) {
      await secure.migrateLegacySession(_PrefsLegacy(_prefs));
      final stored = await secure.loadSession();
      _hasSession = stored != null;
      return stored;
    }
    final raw = _prefs.getString(_kSession);
    if (raw == null) return null;
    try {
      final session = jsonDecode(raw) as Map<String, dynamic>;
      return StoredSession(baseUrl: '${session['base_url'] ?? loginUrl}', token: '${session['token']}');
    } catch (_) {
      await _prefs.remove(_kSession);
      return null;
    }
  }

  Future<void> _clearSession() async {
    _hasSession = false;
    await _prefs.remove(_kSession);
    await _secure?.signOut();
  }

  Future<void> retrySavedSession() async {
    stage = AuthStage.starting;
    notifyListeners();
    await init();
  }

  Future<String> _terminalUuid() async {
    final secure = _secure;
    if (secure != null) return secure.terminalUuid();
    var terminal = _prefs.getString(_kTerminal);
    if (terminal == null || terminal.isEmpty) {
      terminal = randomUuid().replaceAll('-', '').toUpperCase();
      await _prefs.setString(_kTerminal, terminal);
    }
    return terminal;
  }

  Future<TapoCloud> _newClient() async => TapoCloud(terminalUuid: await _terminalUuid(), context: _context);

  (TapoCloud, String, Map<String, dynamic>)? _resolveForRelay(String deviceId) {
    final client = _client;
    if (client == null) return null;
    for (final c in cameras) {
      if (c.deviceId == deviceId) return (client, _baseUrl, c.raw);
    }
    return null;
  }

  /// Demo mode only: an MPEG-TS URL used instead of the cloud relay, e.g.
  /// `--dart-define=TOPO_DEMO_STREAM=http://127.0.0.1:8099/live.ts` with
  /// `adb reverse tcp:8099 tcp:8099`.
  static const _demoStream = String.fromEnvironment('TOPO_DEMO_STREAM');

  String streamUrl(Camera camera) => relay.urlFor(camera.deviceId);

  // ---------------------------------------------------------------- Auth --

  /// Returns true when a verification step is needed.
  Future<bool> login(String username, String password) async {
    username = username.trim();
    if (username.isEmpty || password.isEmpty) {
      throw TapoException('Enter your Tapo email and password');
    }
    final client = await _newClient();
    final result = await client.login(username, password);
    final processId = result.mfaProcessId;
    accountHint = username;
    await _prefs.setString(_kAccount, username);
    if (processId != null && processId.isNotEmpty) {
      _client?.close();
      _client = client;
      pendingMfa = PendingMfa(
        baseUrl: result.baseUrl,
        username: username,
        password: password,
        processId: processId,
        types: result.mfaTypes,
      );
      stage = AuthStage.mfa;
      notifyListeners();
      return true;
    }
    await _finishLogin(client, result.baseUrl, result.result, username: username, password: password);
    return false;
  }

  Future<void> requestMfa(int type) async {
    final pending = pendingMfa;
    final client = _client;
    if (pending == null || client == null) throw TapoException('Sign in again');
    await client.requestMfa(pending.baseUrl, pending.username, pending.password, type);
    pending.requestedType = type;
    notifyListeners();
  }

  Future<void> verifyMfa(String code) async {
    final pending = pendingMfa;
    final client = _client;
    if (pending == null || client == null) throw TapoException('Sign in again');
    final type = pending.requestedType;
    if (type == null) throw TapoException('Request a verification code first');
    code = code.trim();
    if (code.isEmpty) throw TapoException('Enter the verification code');
    final result = await client.verifyMfa(pending.baseUrl, pending.username, code, pending.processId, type);
    await _finishLogin(client, pending.baseUrl, result, username: pending.username, password: pending.password);
  }

  void cancelMfa() {
    pendingMfa = null;
    stage = AuthStage.signedOut;
    notifyListeners();
  }

  Future<void> _finishLogin(
    TapoCloud client,
    String baseUrl,
    Map<String, dynamic> result, {
    String? username,
    String? password,
  }) async {
    final token = result['token'];
    if (token == null || '$token'.isEmpty) {
      throw TapoException('The cloud did not return a session token');
    }
    client.token = '$token';
    final devices = await client.listCameras(baseUrl);
    // The password is stored only after the explicit opt-in (secure storage).
    final secure = _secure;
    if (secure != null) {
      await secure.saveSession(StoredSession(baseUrl: baseUrl, token: '$token'));
      if (_rememberPassword && username != null && password != null) {
        await secure.savePassword(username, password);
      }
    } else {
      await _prefs.setString(
        _kSession,
        jsonEncode({
          'base_url': baseUrl,
          'token': '$token',
          'refreshToken': result['refreshToken'],
          'saved_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        }),
      );
    }
    _hasSession = true;
    if (_rememberPassword && useBackend && username != null && password != null) {
      client.rememberCredentials(username: username, password: password, baseUrl: baseUrl);
    }
    pendingMfa = null;
    _setSignedIn(client, baseUrl, devices);
  }

  void _setSignedIn(TapoCloud client, String baseUrl, List<Map<String, dynamic>> devices) {
    if (!identical(_client, client)) _client?.close();
    _client = client;
    _baseUrl = baseUrl;
    cameras = devices.map(Camera.new).toList();
    camerasError = null;
    stage = AuthStage.signedIn;
    if (cameras.isNotEmpty) cleanGridSlots();
    notifyListeners();
    for (final camera in cameras) {
      unawaited(refreshCameraState(camera));
    }
    if (useBackend) unawaited(_attachBackend(client, baseUrl));
  }

  /// Builds the real control/discovery/media stack and gives every camera its
  /// view model (route, role, online, capabilities).
  Future<void> _attachBackend(TapoCloud client, String baseUrl) async {
    try {
      _backend?.close();
      final backend = CameraBackend(
        cloud: client,
        baseUrl: baseUrl,
        terminalUuid: await _terminalUuid(),
        transport: HttpCloudTransport(_context),
        maxRemoteStreams: _maxRemoteStreams,
        secureStore: _secure,
        secureBackend: _secureBackend,
        prefs: _prefs,
        pins: PrefsPinStore(_prefs),
        tlsContext: _context,
        rememberPassword: () => _rememberPassword,
      );
      _backend = backend;
      actions = backend.actions;
      await _applyViews(backend);
      backend.startMotion(() => [for (final c in cameras) c.deviceId]);
    } catch (e) {
      camerasError = e.toString();
      _handleAuthFailure(e);
      notifyListeners();
    }
  }

  Future<void> _applyViews(CameraBackend backend) async {
    final devices = [for (final c in cameras) c.raw];
    final views = await backend.loadViews(devices);
    for (final camera in cameras) {
      final view = views[camera.deviceId];
      if (view != null) camera.view = view;
    }
    notifyListeners();
    // Optional controls (night vision, siren) appear once a camera has said
    // which components it has.
    unawaited(backend.loadCapabilities(devices, (id, view) {
      final camera = cameraById(id);
      if (camera == null) return;
      camera.view = view;
      notifyListeners();
    }));
  }

  Future<void> logout() async {
    _client?.close();
    _client = null;
    _backend?.close();
    _backend = null;
    if (!demo) actions = null;
    if (useBackend) await PrefsPinStore(_prefs).clear();
    cameras = [];
    pendingMfa = null;
    await _clearSession();
    // Forget the terminal identity too so the next sign-in asks for MFA.
    if (_secure == null) await _prefs.remove(_kTerminal);
    stage = AuthStage.signedOut;
    notifyListeners();
  }

  void _handleAuthFailure(Object error) {
    if (error is TapoException && error.isAuthError) {
      unawaited(logout());
    }
  }

  // ------------------------------------------------------------- Cameras --

  Future<void> refreshCameras() async {
    if (demo) return;
    final client = _client;
    if (client == null) return;
    loadingCameras = true;
    camerasError = null;
    notifyListeners();
    try {
      final devices = await client.listCameras(_baseUrl);
      final previous = {for (final c in cameras) c.deviceId: c};
      cameras = devices.map((d) {
        final camera = Camera(d);
        final old = previous[camera.deviceId];
        camera.privacy = old?.privacy;
        camera.ptz = old?.ptz;
        return camera;
      }).toList();
      if (cameras.isNotEmpty) cleanGridSlots();
      final backend = _backend;
      if (backend != null) unawaited(_applyViews(backend));
      for (final camera in cameras) {
        unawaited(refreshCameraState(camera, force: true));
      }
    } catch (e) {
      camerasError = e.toString();
      _handleAuthFailure(e);
    } finally {
      loadingCameras = false;
      notifyListeners();
    }
  }

  Future<void> refreshCameraState(Camera camera, {bool force = false}) async {
    if (demo) {
      camera.ptz = camera.raw['_ptz'] == true;
      camera.privacy ??= camera.raw['_privacy'] == true;
      notifyListeners();
      return;
    }
    final client = _client;
    if (client == null) return;
    final backend = _backend;
    if (backend != null) {
      final checked = camera.checkedAt;
      if (!force && checked != null && DateTime.now().difference(checked) < const Duration(seconds: 10)) return;
      camera.checkedAt = DateTime.now();
      try {
        final status = await backend.readStatus(camera.deviceId);
        camera.privacy = status.privacy;
        camera.dayNight = status.dayNight;
        camera.ptz = status.ptz;
        camera.stateError = null;
      } catch (e) {
        camera.stateError = e.toString();
        _handleAuthFailure(e);
      }
      notifyListeners();
      return;
    }
    final checked = camera.checkedAt;
    if (!force && checked != null && DateTime.now().difference(checked) < const Duration(seconds: 10)) {
      return;
    }
    camera.checkedAt = DateTime.now();
    try {
      camera.privacy = await client.getPrivacyMode(_baseUrl, camera.deviceId);
      camera.stateError = null;
    } catch (e) {
      camera.stateError = e.toString();
      _handleAuthFailure(e);
    }
    try {
      camera.ptz ??= await client.ptzSupported(_baseUrl, camera.deviceId);
    } catch (_) {
      camera.ptz ??= null;
    }
    notifyListeners();
  }

  Future<void> setPrivacy(Camera camera, bool enabled) async {
    if (demo) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      camera.privacy = enabled;
      notifyListeners();
      return;
    }
    final client = _client;
    if (client == null) return;
    final backend = _backend;
    if (backend != null) {
      camera.privacy = await backend.setPrivacy(camera.deviceId, enabled);
      camera.checkedAt = DateTime.now();
      notifyListeners();
      return;
    }
    camera.privacy = await client.setPrivacyMode(_baseUrl, camera.deviceId, enabled);
    camera.checkedAt = DateTime.now();
    notifyListeners();
  }

  Future<void> move(Camera camera, int x, int y) async {
    if (demo) return Future<void>.delayed(const Duration(milliseconds: 300));
    final client = _client;
    if (client == null) return;
    final backend = _backend;
    if (backend != null) return backend.move(camera.deviceId, x, y);
    await client.moveMotor(_baseUrl, camera.deviceId, x, y);
  }

  void setForeground(bool value) {
    if (foreground == value) return;
    foreground = value;
    notifyListeners();
  }

  // ------------------------------------------------------------ Settings --

  Future<void> setLivePreviews(bool value) async {
    livePreviews = value;
    await _prefs.setBool(_kLivePreviews, value);
    notifyListeners();
  }

  Future<void> setPtzStep(int value) async {
    ptzStep = value;
    await _prefs.setInt(_kPtzStep, value);
    notifyListeners();
  }

  Future<void> markGuideSeen() async {
    guideSeen = true;
    await _prefs.setBool(_kGuideSeen, true);
    notifyListeners();
  }

  // ---------------------------------------------------------- Multi-view --

  void _loadGrids() {
    try {
      final raw = jsonDecode(_prefs.getString(_kGrids) ?? '[]') as List;
      savedGrids = [for (final g in raw) GridPreset.fromJson(Map<String, dynamic>.from(g as Map))];
    } catch (_) {
      savedGrids = [];
    }
    activeGridId = _prefs.getString(_kActiveGrid) ?? GridPreset.allCamerasId;
    favoriteGridId = _prefs.getString(_kFavoriteGrid);
  }

  Future<void> _saveGrids() =>
      _prefs.setString(_kGrids, jsonEncode([for (final g in savedGrids) g.toJson()]));

  /// Built-in grid showing every camera (first nine) in a fitting layout.
  GridPreset get allCamerasGrid {
    final ordered = sortedCameras;
    final layout = GridLayout.fitting(ordered.length);
    return GridPreset(
      id: GridPreset.allCamerasId,
      name: 'All cameras',
      layout: layout,
      slots: [for (final c in ordered.take(layout.slots)) c.deviceId],
    );
  }

  /// All grids in switching order: "All cameras" first, then saved ones.
  List<GridPreset> get grids => [allCamerasGrid, ...savedGrids];

  GridPreset gridById(String id) => grids.firstWhere((g) => g.id == id, orElse: () => allCamerasGrid);

  Camera? cameraById(String? deviceId) {
    if (deviceId == null) return null;
    for (final c in cameras) {
      if (c.deviceId == deviceId) return c;
    }
    return null;
  }

  /// Index in the sorted list, which is what the live view and the digit keys use.
  int cameraIndex(String deviceId) => sortedCameras.indexWhere((c) => c.deviceId == deviceId);

  GridPreset? get favoriteGrid {
    final id = favoriteGridId;
    if (id == null) return null;
    for (final g in grids) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// Pins [id] to the home page, or unpins with null.
  Future<void> setFavoriteGrid(String? id) async {
    favoriteGridId = id;
    if (id == null) {
      await _prefs.remove(_kFavoriteGrid);
    } else {
      await _prefs.setString(_kFavoriteGrid, id);
    }
    notifyListeners();
  }

  Future<void> setActiveGrid(String id) async {
    activeGridId = id;
    await _prefs.setString(_kActiveGrid, id);
    notifyListeners();
  }

  /// Inserts or replaces a saved grid; returns the stored preset.
  Future<GridPreset> saveGrid(GridPreset grid) async {
    final stored = grid.id.isEmpty
        ? GridPreset(
            id: 'g${DateTime.now().millisecondsSinceEpoch}',
            name: grid.name,
            layout: grid.layout,
            slots: grid.slots,
          )
        : grid;
    final i = savedGrids.indexWhere((g) => g.id == stored.id);
    if (i >= 0) {
      savedGrids[i] = stored;
    } else {
      savedGrids.add(stored);
    }
    await _saveGrids();
    notifyListeners();
    return stored;
  }

  Future<void> deleteGrid(String id) async {
    savedGrids.removeWhere((g) => g.id == id);
    if (favoriteGridId == id) {
      favoriteGridId = null;
      await _prefs.remove(_kFavoriteGrid);
    }
    if (activeGridId == id) {
      activeGridId = GridPreset.allCamerasId;
      await _prefs.setString(_kActiveGrid, activeGridId);
    }
    await _saveGrids();
    notifyListeners();
  }

  // ------------------------------------------- Sort, limits, camera account --

  CameraSort _cameraSort = CameraSort.nameAsc;
  int _maxRemoteStreams = kDefaultMaxRemoteStreams;
  bool _rememberPassword = false;

  /// Control interface (api lane adapter, or a fake in tests).
  CameraActions? get actions => _actions;
  CameraActions? _actions;
  set actions(CameraActions? value) {
    _actions = value;
    _motionSub?.cancel();
    _motionSub = value?.motionEvents.listen(_motionEvents.add, onError: (Object _) {});
  }

  final _motionEvents = StreamController<MotionEvent>.broadcast();
  StreamSubscription<MotionEvent>? _motionSub;

  /// Motion events of the current control interface (the toast host listens).
  Stream<MotionEvent> get motionEvents => _motionEvents.stream;

  bool _motionNotifications = true;

  /// Motion toasts on or off (default on).
  bool get motionNotifications => _motionNotifications;

  Future<void> setMotionNotifications(bool value) async {
    _motionNotifications = value;
    await _prefs.setBool(_kMotionNotifications, value);
    notifyListeners();
  }

  CameraSort get cameraSort => _cameraSort;

  Future<void> setCameraSort(CameraSort sort) async {
    _cameraSort = sort;
    await _prefs.setString(_kCameraSort, sort.storageValue);
    notifyListeners();
  }

  /// Cameras in the chosen sort order (home list, live prev/next, digit keys,
  /// the "All cameras" grid).
  List<Camera> get sortedCameras => sortCameras<Camera>(cameras, _cameraSort, (c) => c.name);

  /// 1..8, default 4.
  int get maxRemoteStreams => _maxRemoteStreams;

  Future<void> setMaxRemoteStreams(int value) async {
    _maxRemoteStreams = value.clamp(1, kMaxRemoteStreamsLimit);
    await _prefs.setInt(_kMaxRemote, _maxRemoteStreams);
    _backend?.setMaxRemoteStreams(_maxRemoteStreams);
    notifyListeners();
  }

  /// Opt-in, default false. While off, a stored password is never read; sign
  /// out deletes it (SecureStore.signOut).
  bool get rememberPassword => _rememberPassword;

  Future<void> setRememberPassword(bool value) async {
    _rememberPassword = value;
    await _prefs.setBool(_kRememberPassword, value);
    notifyListeners();
  }

  CameraActions _requireActions() =>
      actions ?? (throw const CameraActionException('Camera control is not available yet'));

  /// Optimistic update; restores the previous value and rethrows on failure.
  Future<void> setDayNight(Camera camera, DayNightMode mode) async {
    final control = _requireActions();
    final previous = camera.dayNight;
    camera.dayNight = mode;
    notifyListeners();
    try {
      camera.dayNight = await control.setDayNight(camera.deviceId, mode);
    } catch (_) {
      camera.dayNight = previous;
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  Future<void> setAlarm(Camera camera, bool on) async {
    final control = _requireActions();
    final previous = camera.alarm;
    camera.alarm = on;
    notifyListeners();
    try {
      camera.alarm = await control.setAlarm(camera.deviceId, on);
    } catch (_) {
      camera.alarm = previous;
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  CameraViewModel _baseView(Camera camera) =>
      camera.view ?? CameraViewModel(id: camera.deviceId, displayName: camera.name, model: camera.model, online: camera.online);

  /// Owned: renames on the camera; shared/manual: local display name only.
  Future<void> renameCamera(Camera camera, String name) async {
    final control = _requireActions();
    final view = _baseView(camera);
    if (camera.isShared) {
      await control.setLocalName(camera.deviceId, name);
      camera.view = view.copyWith(displayName: name, localName: name);
    } else {
      await control.renameOnCamera(camera.deviceId, name);
      camera.view = view.copyWith(displayName: name, clearLocalName: true);
    }
    notifyListeners();
  }

  /// Removes the local name of a shared camera; the cloud alias shows again.
  Future<void> resetCameraName(Camera camera) async {
    final control = _requireActions();
    await control.setLocalName(camera.deviceId, null);
    final alias = '${camera.raw['alias'] ?? camera.raw['deviceName'] ?? 'Camera'}'.trim();
    camera.view = _baseView(camera).copyWith(displayName: alias, clearLocalName: true);
    notifyListeners();
  }

  /// Per-camera account (RTSP/ONVIF), if one is stored.
  Future<String?> cameraAccountUser(Camera camera) async => actions?.cameraAccountUser(camera.deviceId);

  /// Empty username and password clear the account. Otherwise exactly one
  /// login test is made and the account is saved only when it works.
  Future<bool> saveCameraAccount(Camera camera, String username, String password) async {
    final control = _requireActions();
    if (username.isEmpty && password.isEmpty) {
      await control.clearCameraAccount(camera.deviceId);
      return true;
    }
    if (!await control.testCameraAccount(camera.deviceId, username, password)) return false;
    await control.saveCameraAccount(camera.deviceId, username, password);
    return true;
  }

  /// Drops unknown camera ids and duplicates inside one saved grid. Cameras
  /// added later are never put into a saved grid.
  void cleanGridSlots() {
    final known = {for (final c in cameras) c.deviceId};
    var changed = false;
    savedGrids = [
      for (final grid in savedGrids)
        () {
          final seen = <String>{};
          final slots = <String?>[
            for (final id in grid.slots)
              if (id != null && known.contains(id) && seen.add(id)) id else null,
          ];
          if (!listEquals(slots, grid.slots)) changed = true;
          return grid.copyWith(slots: slots);
        }(),
    ];
    if (changed) {
      unawaited(_saveGrids());
      notifyListeners();
    }
  }

  String get regionHost => Uri.tryParse(_baseUrl)?.host ?? _baseUrl;
}

/// Lets [SecureStore.migrateLegacySession] read and remove the old
/// shared_preferences session.
class _PrefsLegacy implements LegacySessionPrefs {
  _PrefsLegacy(this._prefs);
  final SharedPreferences _prefs;

  @override
  String? getString(String key) => _prefs.getString(key);

  @override
  Future<void> remove(String key) => _prefs.remove(key);
}
