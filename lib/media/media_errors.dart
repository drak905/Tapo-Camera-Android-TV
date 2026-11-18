/// Typed errors of the media layer (local :8800, cloud relay, VOD playback).
///
/// Messages must never contain secrets (local access token, password, relay
/// token, ELB cookie, bridge key); run text through [redactSecrets] first.
library;

class MediaException implements Exception {
  const MediaException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Digest login rejected twice or the camera refused the credentials.
/// Never retried: repeated logins lock the camera out.
class MediaAuthException extends MediaException {
  const MediaAuthException(super.message);
}

/// The camera (or the per-camera [StreamLimiter]) allows no further media
/// session. Fatal: callers must not retry in a loop.
class StreamLimitException extends MediaException {
  const StreamLimitException(super.message, {this.errorCode});
  final int? errorCode;
}

/// The camera answered a stream request with a non-zero, non-limit error code.
class StreamRefusedException extends MediaException {
  const StreamRefusedException(super.message, {required this.errorCode});
  final int errorCode;
}

/// More than 50 consecutive media parts failed their integrity check.
class BrokenSessionException extends MediaException {
  const BrokenSessionException(super.message);
}

/// A single media part could not be decrypted (bad length, nonce or HMAC).
/// Not fatal: the part is dropped.
class PartDecryptException extends MediaException {
  const PartDecryptException(super.message);
}

/// Malformed multipart framing (missing or negative Content-Length, part or
/// header block too large).
class MultipartFormatException extends MediaException {
  const MultipartFormatException(super.message);
}

/// The cloud CIPC API or a relay node refused. [fatal] means retrying the
/// same request cannot help (-1007 offline, -1103 not bound, -52407, -52212,
/// -100001, -20675, 3 illegal_request).
class RelayException extends MediaException {
  const RelayException(super.message, {this.code, this.fatal = false});
  final int? code;
  final bool fatal;
}

/// A relay media part had `X-If-Encrypt: 1` but no key schedule is known.
/// [headerNames] lists the part's header NAMES only (never values), so a live
/// capture can decide the key schedule.
class EncryptedRelayMediaException extends MediaException {
  const EncryptedRelayMediaException(super.message, {required this.headerNames});
  final List<String> headerNames;
}

/// SD playback refused by the camera (non-zero `error_code`). Fatal.
class PlaybackRefusedException extends MediaException {
  const PlaybackRefusedException(super.message, {required this.errorCode});
  final int errorCode;
}

/// `disk_status: offline` notification: no SD card. Fatal.
class SdCardOfflineException extends MediaException {
  const SdCardOfflineException() : super('SD card not available');
}

/// Replaces every non-empty entry of [secrets] in [text] with `***`, and any
/// `k=` query value of a bridge URL and RTSP userinfo password.
String redactSecrets(String text, Iterable<String> secrets) => throw UnimplementedError();
