// Camera name rules and pending-rename bookkeeping. Spec: hc.dto.rename.

import '../api/tapo_errors.dart';

/// Maximum UTF-8 bytes of a camera name.
const cameraNameMaxBytes = 32;

/// Rejected name (empty, control characters, > 32 UTF-8 bytes).
class CameraNameError extends TapoError {
  CameraNameError(super.message);
}

/// NFC-normalise, trim, require non-empty, no control characters (category
/// Cc), at most [cameraNameMaxBytes] UTF-8 BYTES. Returns the normalised
/// name or throws [CameraNameError]. NFC needs a Unicode normalisation
/// package (e.g. unorm_dart).
String normalizeCameraName(String raw) => throw UnimplementedError();

/// Only owned cloud cameras (role 0) are renamed on the camera; shared and
/// manual cameras keep a local display name.
bool renamesOnCamera({required bool isCloudCamera, required int role}) =>
    throw UnimplementedError();

/// Display names with a pending rename that wins over the cloud alias until
/// the cloud alias equals it or 24 h passed.
class CameraNames {
  CameraNames({DateTime Function()? clock});

  void setPending(String cameraId, String name) => throw UnimplementedError();
  void setLocalName(String cameraId, String name) => throw UnimplementedError();

  /// Name to show for [cameraId]: local name (shared/manual) first, then the
  /// pending rename (while valid), else [cloudAlias].
  String display(String cameraId, String cloudAlias) => throw UnimplementedError();
}