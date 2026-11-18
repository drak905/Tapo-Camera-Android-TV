// Secure storage of the session secrets. Spec: hc.storage.secure, hc.local.lat_mode.
// Production backend: flutter_secure_storage (Keystore). Tests use a fake.

import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/camera_transport.dart' show PinStore;

/// Key/value backend (flutter_secure_storage in production).
abstract class SecureBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<Map<String, String>> readAll();
}

/// Android Keystore backed implementation.
class KeystoreBackend implements SecureBackend {
  KeystoreBackend([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();
}

/// Read/remove access to the old shared_preferences session (key `session`,
/// JSON `{base_url, token, refreshToken, saved_at}`).
abstract class LegacySessionPrefs {
  String? getString(String key);
  Future<void> remove(String key);
}

/// [LegacySessionPrefs] over `shared_preferences`.
class SharedPreferencesLegacy implements LegacySessionPrefs {
  SharedPreferencesLegacy(this._prefs);
  final SharedPreferences _prefs;

  @override
  String? getString(String key) => _prefs.getString(key);

  @override
  Future<void> remove(String key) => _prefs.remove(key);
}

/// Cloud session held in secure storage.
class StoredSession {
  const StoredSession({required this.baseUrl, required this.token});
  final String baseUrl;
  final String token;

  /// Never prints the token.
  @override
  String toString() => 'StoredSession(baseUrl: $baseUrl)';
}

const _sessionKey = 'session';
const _passwordKey = 'account';
const _latPrefix = 'lat:';
const _terminalKey = 'terminal_uuid';
const _pinPrefix = 'pin:';

/// TLS pins (`host:port` -> sha256 hex) of one scope in secure storage. Loaded
/// once so [read] stays synchronous.
class SecurePinStore implements PinStore {
  SecurePinStore._(this._backend, this._scope, this._pins);

  final SecureBackend _backend;
  final String _scope;
  final Map<String, String> _pins;

  @override
  String? read(String hostPort) => _pins[hostPort];

  @override
  Future<void> write(String hostPort, String sha256Hex) async {
    _pins[hostPort] = sha256Hex;
    await _backend.write('$_pinPrefix$_scope:$hostPort', sha256Hex);
  }
}

class SecureStore {
  SecureStore(SecureBackend backend) : _backend = backend;

  final SecureBackend _backend;
  Future<String>? _terminal;

  Future<void> saveSession(StoredSession session) => _backend.write(
        _sessionKey,
        jsonEncode({'base_url': session.baseUrl, 'token': session.token}),
      );

  Future<StoredSession?> loadSession() async {
    final raw = await _backend.read(_sessionKey);
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw);
      if (map is Map && map['base_url'] is String && map['token'] is String) {
        final token = map['token'] as String;
        if (token.isEmpty) return null;
        return StoredSession(baseUrl: map['base_url'] as String, token: token);
      }
    } on FormatException {
      // fall through: unreadable entries count as no session
    }
    return null;
  }

  /// Stored only after the explicit "Remember password on this TV" choice.
  Future<void> savePassword(String username, String password) =>
      _backend.write(_passwordKey, jsonEncode({'u': username, 'p': password}));

  Future<(String username, String password)?> loadPassword() async {
    final raw = await _backend.read(_passwordKey);
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw);
      if (map is Map && map['u'] is String && map['p'] is String) {
        return (map['u'] as String, map['p'] as String);
      }
    } on FormatException {
      // unreadable
    }
    return null;
  }

  /// Per-camera local access token.
  Future<void> saveLat(String cameraId, String lat) => _backend.write('$_latPrefix$cameraId', lat);

  Future<String?> loadLat(String cameraId) async {
    final lat = await _backend.read('$_latPrefix$cameraId');
    return (lat == null || lat.isEmpty) ? null : lat;
  }

  Future<void> removeLat(String cameraId) => _backend.delete('$_latPrefix$cameraId');

  /// TLS pins of one scope (`cloud` cameras are wiped on sign-out, `manual`
  /// cameras are not).
  Future<SecurePinStore> loadPins({String scope = 'cloud'}) async {
    final prefix = '$_pinPrefix$scope:';
    final all = await _backend.readAll();
    return SecurePinStore._(_backend, scope, {
      for (final e in all.entries)
        if (e.key.startsWith(prefix)) e.key.substring(prefix.length): e.value,
    });
  }

  /// 32 upper-case hex, created once and kept across sign-outs.
  Future<String> terminalUuid() => _terminal ??= _loadOrCreateTerminal();

  Future<String> _loadOrCreateTerminal() async {
    final existing = await _backend.read(_terminalKey);
    if (existing != null && RegExp(r'^[0-9A-F]{32}$').hasMatch(existing)) return existing;
    final rng = Random.secure();
    final fresh = List.generate(16, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    await _backend.write(_terminalKey, fresh);
    return fresh;
  }

  /// Deletes token, password, LATs and the TLS pins of cloud cameras; keeps
  /// the terminal uuid.
  Future<void> signOut() async {
    final all = await _backend.readAll();
    for (final key in all.keys) {
      if (key == _sessionKey ||
          key == _passwordKey ||
          key.startsWith(_latPrefix) ||
          key.startsWith('$_pinPrefix${'cloud'}:')) {
        await _backend.delete(key);
      }
    }
  }

  /// Moves a legacy shared_preferences session into secure storage and
  /// removes the old key. Returns true when something was migrated.
  Future<bool> migrateLegacySession(LegacySessionPrefs prefs) async {
    final raw = prefs.getString(_sessionKey);
    if (raw == null) return false;
    var migrated = false;
    try {
      final map = jsonDecode(raw);
      if (map is Map && map['base_url'] is String && map['token'] is String && (map['token'] as String).isNotEmpty) {
        await saveSession(StoredSession(baseUrl: map['base_url'] as String, token: map['token'] as String));
        migrated = true;
      }
    } on FormatException {
      // corrupt: dropped below
    }
    await prefs.remove(_sessionKey);
    return migrated;
  }

  /// Never prints secrets.
  @override
  String toString() => 'SecureStore()';
}
