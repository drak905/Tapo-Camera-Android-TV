// Golden crypto fixtures (hex computed from the Windows implementation, see
// specs/android_tv_port_spec.json mb.local.key_md5 / mb.local.key_hkdf).
import 'dart:typed_data';

import 'fakes.dart';

/// 188-byte plaintext: 0x47 0x40 0x00 0x10 then bytes 0..183.
Uint8List goldenPlaintext() => Uint8List.fromList([0x47, 0x40, 0x00, 0x10, for (var i = 0; i < 184; i++) i]);

const kHkdfNonce = '0123456789abcdef0123456789abcdef';
const kHkdfSalt = 'fedcba9876543210fedcba9876543210';
const kHkdfLat = 'local-access-token';
const kHkdfAesKeyHex = '0a6e6cb5d694ce1b2f081fb2c3b88d96';
const kHkdfHmacKeyHex = '941348d22b7ba9eaa114b393798ecade';
const kHkdfIvHex = '000102030405060708090a0b0c0d0e0f';
const kHkdfHmacB64 = 'dUifIYhlkuXvqtMjeF8lsU0TIqIEjLkDhRKaLIQzYBM=';
const kHkdfKeyExchange =
    'cipher="AES_128_CBC" username="admin" padding="PKCS7_16" algorithm="HKDF" encrypt_type="3" nonce="$kHkdfNonce" salt="$kHkdfSalt"';

const kMd5NonceAdmin = '0d4a5e9f3b2c1a77';
const kMd5AdminKeyHex = '62c1b78af0e55ddf735e142052110aee';
const kMd5AdminIvHex = '65c2e710f689f298effbb35b974d7ce6';
const kMd5KeyExchangeAdmin = 'username="admin" nonce="$kMd5NonceAdmin" cipher="AES_128_CBC"';

const _hkdfCipherHex = '98d0d2d6927239bacfa3da8f429884cf1d7b0d861262b856fe4db48440c7a6bdb49ee5f2031c32cb5556b4f5f95b38f5ed2495e1a73bf079b78ad807189e5801c0c1920628c870b152b9b579f6c91f63591f1b8a79440f4581275be4c5d4e1a4961af84c26bed0f3d22d73ec59be39b7c7d2f2097120c6f2bc265133001c2324c8026315718904db94c065f617040acb28632e5485788b9ac00d34f8f61790ba9052b0752a3e585f805669700c26d835532bb99c7d683291bd8e444bd39441e1';
const _md5CipherHex = 'b9b628f7b3d274ffd4822a4faaafccbf4b06df24b8b1af2e61f46b662392857eb7d7cf24ad54eb0ad874272d9ca9b943d811f2dd3518ea72f134c06df5ff1b56ad4a40d6c4e451d99fba7ee91222fc82e286c12e16e4fad2ade861b64f2c083a676742fc83943fef801dba9a33fb02662839fbb5f9d74e74f770495e88017390f57182d91130c4fdf6b4f500af6ded8275cd5675e1d383e109527919aef3f15e265fc90be57c9e328990ee6feb12f1bba3397c7d0f972f4c24258a88b39aad76';

/// AES-128-CBC ciphertext (192 bytes) of [goldenPlaintext] with the HKDF key and IV kHkdfIvHex.
Uint8List hkdfCiphertext() => fromHex(_hkdfCipherHex);

/// AES-128-CBC ciphertext (192 bytes) of [goldenPlaintext] with the md5_admin key and IV.
Uint8List md5AdminCiphertext() => fromHex(_md5CipherHex);