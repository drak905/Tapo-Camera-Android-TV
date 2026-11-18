// Errors shared by the local control stack (TDP, v3, TPAP, transport) and the
// cloud passthrough. Messages must never contain passwords, tokens, LATs,
// stok values or keys.

/// Base class of every error raised by the control stack.
class TapoError implements Exception {
  TapoError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Wrong password / device_confirm mismatch / TPAP refusal. Arms the breaker.
class TapoAuthError extends TapoError {
  TapoAuthError(super.message);
}

/// The camera blocks logins (-40404 / -40408). [secLeft] is the wait in seconds.
class TapoLockedError extends TapoError {
  TapoLockedError(super.message, {this.secLeft});
  final int? secLeft;
}

/// Unusable or malformed data (never a cast error).
class TapoProtocolError extends TapoError {
  TapoProtocolError(super.message);
}

/// The camera answered a command with a non-zero error_code.
class TapoDeviceError extends TapoError {
  TapoDeviceError(super.message, {required this.code, this.method});
  final int code;
  final String? method;
}

/// The session (stok, seq, tag) is no longer valid: re-login once.
class TapoSessionInvalid extends TapoError {
  TapoSessionInvalid(super.message);
}

/// The leaf certificate changed since first contact (TOFU pin).
class CertificateMismatch extends TapoError {
  CertificateMismatch(super.message);
}

/// A request timed out. Timeouts are never retried.
class TapoTimeoutError extends TapoError {
  TapoTimeoutError(super.message);
}