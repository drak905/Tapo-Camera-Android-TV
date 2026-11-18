// Spec hc.storage.secure, hc.cloud.terminal_uuid and the storage part of
// hc.local.lat_mode (tier 3), against an in-memory backend.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/state/secure_store.dart';

class _MemBackend implements SecureBackend {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
  @override
  Future<Map<String, String>> readAll() async => Map.of(data);
}

class _LegacyPrefs implements LegacySessionPrefs {
  _LegacyPrefs(this.values);
  final Map<String, String> values;
  @override
  String? getString(String key) => values[key];
  @override
  Future<void> remove(String key) async => values.remove(key);
}

void main() {
  test('roundtrip with fake backend', () async {
    final backend = _MemBackend();
    final store = SecureStore(backend);
    await store.saveSession(const StoredSession(baseUrl: 'https://eu-wap.example.com', token: 'tok-1'));
    await store.savePassword('user@example.com', 'pw-1');
    await store.saveLat('cam-1', 'lat-1');
    final again = SecureStore(backend);
    final s = await again.loadSession();
    expect(s?.token, 'tok-1');
    expect(s?.baseUrl, 'https://eu-wap.example.com');
    expect(await again.loadPassword(), ('user@example.com', 'pw-1'));
    expect(await again.loadLat('cam-1'), 'lat-1');
    expect(await again.loadLat('cam-2'), isNull);
  });

  test('password is only stored on explicit request', () async {
    final backend = _MemBackend();
    final store = SecureStore(backend);
    await store.saveSession(const StoredSession(baseUrl: 'https://x.example.com', token: 'tok-1'));
    expect(await store.loadPassword(), isNull);
    expect(backend.data.values.join(' '), isNot(contains('pw-')));
  });

  test('sign out wipes token password lat', () async {
    final backend = _MemBackend();
    final store = SecureStore(backend);
    final uuid = await store.terminalUuid();
    await store.saveSession(const StoredSession(baseUrl: 'https://x.example.com', token: 'tok-1'));
    await store.savePassword('user@example.com', 'pw-1');
    await store.saveLat('cam-1', 'lat-1');
    await store.signOut();
    expect(await store.loadSession(), isNull);
    expect(await store.loadPassword(), isNull);
    expect(await store.loadLat('cam-1'), isNull);
    expect(await store.terminalUuid(), uuid, reason: 'terminal uuid survives sign-out');
    expect(backend.data.values.join(' '), isNot(contains('tok-1')));
    expect(backend.data.values.join(' '), isNot(contains('lat-1')));
  });

  test('legacy shared_preferences session migrated and removed', () async {
    final backend = _MemBackend();
    final store = SecureStore(backend);
    final prefs = _LegacyPrefs({
      'session': jsonEncode({
        'base_url': 'https://eu-wap.example.com',
        'token': 'tok-old',
        'refreshToken': 'ref-old',
        'saved_at': 1735900000,
      }),
    });
    expect(await store.migrateLegacySession(prefs), isTrue);
    expect(prefs.values.containsKey('session'), isFalse);
    final s = await store.loadSession();
    expect(s?.token, 'tok-old');
    expect(s?.baseUrl, 'https://eu-wap.example.com');
    // Nothing left to migrate the second time.
    expect(await store.migrateLegacySession(prefs), isFalse);
  });

  test('corrupt legacy session is removed without crashing', () async {
    final store = SecureStore(_MemBackend());
    final prefs = _LegacyPrefs({'session': 'not json'});
    expect(await store.migrateLegacySession(prefs), isFalse);
    expect(prefs.values.containsKey('session'), isFalse);
  });

  test('terminal uuid format and stability', () async {
    final backend = _MemBackend();
    final uuid = await SecureStore(backend).terminalUuid();
    expect(RegExp(r'^[0-9A-F]{32}$').hasMatch(uuid), isTrue);
    expect(await SecureStore(backend).terminalUuid(), uuid);
  });

  test('to_string never shows secrets', () async {
    final backend = _MemBackend();
    final store = SecureStore(backend);
    await store.saveSession(const StoredSession(baseUrl: 'https://x.example.com', token: 'tok-secret-1'));
    await store.savePassword('user@example.com', 'pw-secret-1');
    await store.saveLat('cam-1', 'lat-secret-1');
    final text = [
      '$store',
      '${await store.loadSession()}',
      '${const StoredSession(baseUrl: 'u', token: 'tok-secret-1')}',
    ].join('\n');
    for (final secret in ['tok-secret-1', 'pw-secret-1', 'lat-secret-1']) {
      expect(text, isNot(contains(secret)));
    }
  });

  test('lat never in toString', () async {
    final store = SecureStore(_MemBackend());
    await store.saveLat('cam-1', 'lat-secret-2');
    expect('$store', isNot(contains('lat-secret-2')));
  });
}
