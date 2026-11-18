// Camera name rules and pending-rename bookkeeping. Spec: hc.dto.rename.

import 'dart:convert';

import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../api/tapo_errors.dart';

/// Maximum UTF-8 bytes of a camera name.
const cameraNameMaxBytes = 32;

/// How long a name set on the camera is kept while the cloud still reports
/// the old alias.
const pendingRenameTtl = Duration(hours: 24);

/// Rejected name (empty, control characters, > 32 UTF-8 bytes).
class CameraNameError extends TapoError {
  CameraNameError(super.message);
}

bool _isControl(int c) => c < 0x20 || (c >= 0x7F && c <= 0x9F);

/// NFC-normalise, trim, require non-empty, no control characters (category
/// Cc), at most [cameraNameMaxBytes] UTF-8 BYTES. Returns the normalised
/// name or throws [CameraNameError].
String normalizeCameraName(String raw) {
  final name = unorm.nfc(raw).trim();
  if (name.isEmpty) throw CameraNameError('Enter a name.');
  if (name.runes.any(_isControl)) {
    throw CameraNameError('The name cannot contain line breaks or tabs.');
  }
  final size = utf8.encode(name).length;
  if (size > cameraNameMaxBytes) {
    throw CameraNameError(
      'The name is too long ($size of $cameraNameMaxBytes bytes). '
      'Letters with accents count as 2-3 bytes.',
    );
  }
  return name;
}

/// Only owned cloud cameras (role 0) are renamed on the camera; shared and
/// manual cameras keep a local display name.
bool renamesOnCamera({required bool isCloudCamera, required int role}) => isCloudCamera && role == 0;

/// Display names with a pending rename that wins over the cloud alias until
/// the cloud alias equals it or 24 h passed.
class CameraNames {
  CameraNames({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Map<String, String> _local = {};
  final Map<String, (String, DateTime)> _pending = {};

  void setPending(String cameraId, String name) => _pending[cameraId] = (name, _clock());

  void setLocalName(String cameraId, String name) => _local[cameraId] = name;

  /// Name to show for [cameraId]: local name (shared/manual) first, then the
  /// pending rename (while valid), else [cloudAlias].
  String display(String cameraId, String cloudAlias) {
    final local = _local[cameraId];
    if (local != null && local.isNotEmpty) return local;
    final pending = _pending[cameraId];
    if (pending == null) return cloudAlias;
    final (name, since) = pending;
    final age = _clock().difference(since);
    if (name == cloudAlias || age.isNegative || age > pendingRenameTtl) {
      _pending.remove(cameraId);
      return cloudAlias;
    }
    return name;
  }
}
