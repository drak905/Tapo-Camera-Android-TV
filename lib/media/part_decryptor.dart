/// Decides what happens to a media part's body before it reaches ExoPlayer.
library;

import 'dart:typed_data';

import 'local8800/stream_crypto.dart';
import 'multipart_reader.dart';

abstract class PartDecryptor {
  /// The plain body of [part], or null when the part must be dropped (bad
  /// HMAC, bad nonce, bad length). More than 50 consecutive drops throw
  /// `BrokenSessionException`. Only parts with `X-If-Encrypt: 1` are decrypted.
  Uint8List? decrypt(MultipartPart part);
}

/// Relay: parts are plain. A part with `X-If-Encrypt: 1` throws
/// `EncryptedRelayMediaException` (header names only) instead of feeding
/// ciphertext to ExoPlayer.
class PassthroughDecryptor implements PartDecryptor {
  const PassthroughDecryptor();
  @override
  Uint8List? decrypt(MultipartPart part) => throw UnimplementedError();
}

/// Local :8800 with legacy MD5 keys (fixed IV, fresh cipher per part).
class Md5PartDecryptor implements PartDecryptor {
  Md5PartDecryptor(this.keys);
  final StreamKeys keys;
  @override
  Uint8List? decrypt(MultipartPart part) => throw UnimplementedError();
}

/// Local :8800 with HKDF keys: IV from `X-Nonce`, optional `X-Data-Hmac`.
class HkdfPartDecryptor implements PartDecryptor {
  HkdfPartDecryptor(this.keys);
  final StreamKeys keys;
  @override
  Uint8List? decrypt(MultipartPart part) => throw UnimplementedError();
}
