/// Decides what happens to a media part's body before it reaches ExoPlayer.
library;

import 'dart:typed_data';

import 'local8800/stream_crypto.dart';
import 'media_errors.dart';
import 'multipart_reader.dart';

abstract class PartDecryptor {
  /// The plain body of [part], or null when the part must be dropped (bad
  /// HMAC, bad nonce, bad length). More than 50 consecutive drops throw
  /// `BrokenSessionException`. Only parts with `X-If-Encrypt: 1` are decrypted.
  Uint8List? decrypt(MultipartPart part);
}

bool _isEncrypted(MultipartPart part) => (part.header('X-If-Encrypt') ?? '').trim() == '1';

/// Relay: parts are plain. A part with `X-If-Encrypt: 1` throws
/// `EncryptedRelayMediaException` (header names only) instead of feeding
/// ciphertext to ExoPlayer.
class PassthroughDecryptor implements PartDecryptor {
  const PassthroughDecryptor();
  @override
  Uint8List? decrypt(MultipartPart part) {
    if (_isEncrypted(part)) {
      throw EncryptedRelayMediaException(
        'relay media part is encrypted and no key schedule is known',
        headerNames: part.headers.keys.toList(),
      );
    }
    return part.body;
  }
}

const int _maxConsecutiveFailures = 50;

abstract class _KeyedDecryptor implements PartDecryptor {
  _KeyedDecryptor(this.keys);
  final StreamKeys keys;
  int _failures = 0;

  Uint8List decryptOne(MultipartPart part);

  @override
  Uint8List? decrypt(MultipartPart part) {
    if (!_isEncrypted(part)) return part.body;
    try {
      final plain = decryptOne(part);
      _failures = 0;
      return plain;
    } on PartDecryptException {
      _failures++;
      if (_failures > _maxConsecutiveFailures) {
        throw const BrokenSessionException('too many consecutive undecryptable media parts');
      }
      return null;
    }
  }
}

/// Local :8800 with legacy MD5 keys (fixed IV, fresh cipher per part).
class Md5PartDecryptor extends _KeyedDecryptor {
  Md5PartDecryptor(super.keys);
  @override
  Uint8List decryptOne(MultipartPart part) => decryptPart(keys, part.body);
}

/// Local :8800 with HKDF keys: IV from `X-Nonce`, optional `X-Data-Hmac`.
class HkdfPartDecryptor extends _KeyedDecryptor {
  HkdfPartDecryptor(super.keys);
  @override
  Uint8List decryptOne(MultipartPart part) =>
      decryptPart(keys, part.body, ivHex: part.header('X-Nonce'), hmacB64: part.header('X-Data-Hmac'));
}
