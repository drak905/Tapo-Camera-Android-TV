// dart:io / plugin implementations of the seams the state layer needs: the
// secure key/value backend and the TLS pin store. The cloud HTTPS transport
// (HttpCloudTransport), the camera link (SocketCameraLink) and TDP discovery
// (discoverTdp) live in the api lane (lib/api/).
//
// Nothing here is used by widget tests (they inject fakes); AppState builds
// these only when `useBackend` is on.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/camera_transport.dart';
import 'secure_store.dart';

/// flutter_secure_storage (Android Keystore) as [SecureBackend].
class FlutterSecureBackend implements SecureBackend {
  FlutterSecureBackend([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();
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

/// Certificate pins (a SHA-256 of a public certificate, not a secret) kept in
/// shared_preferences under `tls_pin:<host:port>`.
class PrefsPinStore implements PinStore {
  PrefsPinStore(this._prefs);
  final SharedPreferences _prefs;
  static const _prefix = 'tls_pin:';

  @override
  String? read(String hostPort) => _prefs.getString('$_prefix$hostPort');

  @override
  Future<void> write(String hostPort, String sha256Hex) async {
    await _prefs.setString('$_prefix$hostPort', sha256Hex);
  }

  /// Forgets every pin (sign out).
  Future<void> clear() async {
    for (final key in _prefs.getKeys().where((k) => k.startsWith(_prefix)).toList()) {
      await _prefs.remove(key);
    }
  }
}
