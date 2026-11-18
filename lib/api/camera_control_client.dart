// Local login state machine (TPAP / secure v3 / legacy MD5) with the auth
// circuit breaker. Spec: hc.local.login_flow, hc.local.breaker, hc.local.lat_mode.

import 'dart:math';

import 'camera_dtos.dart';
import 'camera_transport.dart';

/// Secrets of one camera. Never printed.
class LocalSecrets {
  const LocalSecrets({this.password = '', this.lat});
  final String password;

  /// Cloud-issued local access token (LAT mode), or null.
  final String? lat;

  @override
  String toString() => throw UnimplementedError();
}

/// TDP hint for the first login step.
enum LocalProtocolHint { probe, tpap }

class CameraControlClient {
  /// [clock] drives the 120 s breaker. [cnonce] overrides the random cnonce.
  /// [rng]/[sleep] feed the TPAP authenticator.
  CameraControlClient({
    required CameraChannel channel,
    required LocalSecrets secrets,
    LocalProtocolHint hint = LocalProtocolHint.probe,
    int userHashType = 0,
    DateTime Function()? clock,
    String Function()? cnonce,
    Random? rng,
    Future<void> Function(Duration d)? sleep,
  });

  /// Breaker length after an auth failure.
  static const authBackoff = Duration(seconds: 120);

  /// `login` steps: v3 step 1 -> (-40211 TPAP | -40413 v3 | else legacy).
  /// Throws `TapoAuthError`, `TapoLockedError` (-40404/-40408, not breakered),
  /// `TapoProtocolError`. While the breaker is armed it fails fast with the
  /// same error and sends nothing.
  Future<void> login() => throw UnimplementedError();

  /// Sends a batch through the session. Logs in first when there is no
  /// session (re-login once and retry once on
  /// session-invalid; a second failure raises). Seq is burned on every attempt.
  Future<List<ControlItem>> send(List<Map<String, dynamic>> requests) =>
      throw UnimplementedError();

  /// Time until a new login is allowed after an auth failure, else null.
  Duration? get authRetryAfter => throw UnimplementedError();

  /// Clears the breaker (user re-entered the password or the LAT changed).
  void resetAuthBackoff() => throw UnimplementedError();

  /// Session valid (a login succeeded and has not been invalidated).
  bool get loggedIn => throw UnimplementedError();

  void close() => throw UnimplementedError();
}