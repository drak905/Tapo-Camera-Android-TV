// Secure storage of the session secrets. Spec: hc.storage.secure, hc.local.lat_mode.
// Production backend: flutter_secure_storage (Keystore). Tests use a fake.

/// Key/value backend (flutter_secure_storage in production).
abstract class SecureBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<Map<String, String>> readAll();
}

/// Read/remove access to the old shared_preferences session (key `session`,
/// JSON `{base_url, token, refreshToken, saved_at}`).
abstract class LegacySessionPrefs {
  String? getString(String key);
  Future<void> remove(String key);
}

/// Cloud session held in secure storage.
class StoredSession {
  const StoredSession({required this.baseUrl, required this.token});
  final String baseUrl;
  final String token;

  /// Never prints the token.
  @override
  String toString() => throw UnimplementedError();
}

class SecureStore {
  SecureStore(SecureBackend backend);

  Future<void> saveSession(StoredSession session) => throw UnimplementedError();
  Future<StoredSession?> loadSession() => throw UnimplementedError();

  /// Stored only after the explicit "Remember password on this TV" choice.
  Future<void> savePassword(String username, String password) => throw UnimplementedError();
  Future<(String username, String password)?> loadPassword() => throw UnimplementedError();

  /// Per-camera local access token.
  Future<void> saveLat(String cameraId, String lat) => throw UnimplementedError();
  Future<String?> loadLat(String cameraId) => throw UnimplementedError();
  Future<void> removeLat(String cameraId) => throw UnimplementedError();

  /// 32 upper-case hex, created once and kept across sign-outs.
  Future<String> terminalUuid() => throw UnimplementedError();

  /// Deletes token, password, LATs and the TLS pins of cloud cameras; keeps
  /// the terminal uuid.
  Future<void> signOut() => throw UnimplementedError();

  /// Moves a legacy shared_preferences session into secure storage and
  /// removes the old key. Returns true when something was migrated.
  Future<bool> migrateLegacySession(LegacySessionPrefs prefs) => throw UnimplementedError();

  /// Never prints secrets.
  @override
  String toString() => throw UnimplementedError();
}