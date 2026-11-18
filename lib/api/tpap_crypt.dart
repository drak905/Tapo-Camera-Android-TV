// Passcode shaping for TPAP register `extra_crypt`. Spec: hc.local.tpap_extra_crypt.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const _c64 = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

String _b64x24(int b2, int b1, int b0, int n) {
  var v = (b2 << 16) | (b1 << 8) | b0;
  final out = StringBuffer();
  for (var i = 0; i < n; i++) {
    out.write(_c64[v & 63]);
    v >>= 6;
  }
  return out.toString();
}

List<int> _md5(List<int> data) => md5.convert(data).bytes;
List<int> _sha256(List<int> data) => sha256.convert(data).bytes;

/// md5-crypt ($1$). [prefix] like `$1$3azHgidD$`. Returns the full hash, or
/// null when [prefix] does not start with `$1$`.
String? md5Crypt(String key, String prefix) {
  if (key.length > 30000 || !prefix.startsWith(r'$1$')) return null;
  final k = utf8.encode(key);
  final rest = prefix.substring(3);
  final end = rest.indexOf(r'$');
  final saltEnd = end >= 0 ? (end < 8 ? end : 8) : (rest.length < 8 ? rest.length : 8);
  final saltText = rest.substring(0, saltEnd);
  final salt = utf8.encode(saltText);
  final magicSalt = utf8.encode(r'$1$') + salt;
  final alt = _md5([...k, ...salt, ...k]);
  final ctx = BytesBuilder()..add(k)..add(magicSalt);
  var n = k.length;
  while (n > 16) {
    ctx.add(alt);
    n -= 16;
  }
  ctx.add(alt.sublist(0, n));
  n = k.length;
  while (n > 0) {
    ctx.add((n & 1) != 0 ? const [0] : (k.isEmpty ? const <int>[] : [k[0]]));
    n >>= 1;
  }
  var fin = _md5(ctx.toBytes());
  for (var i = 0; i < 1000; i++) {
    final b = BytesBuilder()..add((i & 1) != 0 ? k : fin);
    if (i % 3 != 0) b.add(salt);
    if (i % 7 != 0) b.add(k);
    b.add((i & 1) != 0 ? fin : k);
    fin = _md5(b.toBytes());
  }
  final f = fin;
  final enc = StringBuffer();
  for (final g in const [
    [0, 6, 12],
    [1, 7, 13],
    [2, 8, 14],
    [3, 9, 15],
    [4, 10, 5],
  ]) {
    enc.write(_b64x24(f[g[0]], f[g[1]], f[g[2]], 4));
  }
  enc.write(_b64x24(0, 0, f[11], 2));
  return '\$1\$$saltText\$$enc';
}

/// sha256-crypt (Drepper). [prefix] like `$5$[rounds=N$]salt`; salt <= 16
/// chars, default 5000 rounds, rounds clamped to 1000..999999999.
String sha256Crypt(String key, String prefix) {
  var rest = prefix.startsWith(r'$5$') ? prefix.substring(3) : prefix;
  var rounds = 5000;
  var custom = false;
  if (rest.startsWith('rounds=')) {
    final parts = rest.split(r'$');
    final parsed = parts.length > 1 ? int.tryParse(parts[0].substring(7)) : null;
    if (parsed != null) {
      rounds = parsed < 1000 ? 1000 : (parsed > 999999999 ? 999999999 : parsed);
      rest = parts[1];
      custom = true;
    }
  }
  final end = rest.indexOf(r'$');
  final saltLen = end > 0 ? end : rest.length;
  final saltText = rest.substring(0, saltLen < 16 ? saltLen : 16);
  final k = utf8.encode(key);
  final s = utf8.encode(saltText);

  final alt = _sha256([...k, ...s, ...k]);
  final ctx = BytesBuilder()..add(k)..add(s);
  var n = k.length;
  while (n > 32) {
    ctx.add(alt);
    n -= 32;
  }
  ctx.add(alt.sublist(0, n));
  n = k.length;
  while (n > 0) {
    ctx.add((n & 1) != 0 ? alt : k);
    n >>= 1;
  }
  final a = _sha256(ctx.toBytes());

  final dpIn = BytesBuilder();
  for (var i = 0; i < k.length; i++) {
    dpIn.add(k);
  }
  final dp = _sha256(dpIn.toBytes());
  final p = _repeatTo(dp, k.length);
  final dsIn = BytesBuilder();
  for (var i = 0; i < 16 + a[0]; i++) {
    dsIn.add(s);
  }
  final ds = _sha256(dsIn.toBytes());
  final sb = _repeatTo(ds, s.length);

  var c = a;
  for (var i = 0; i < rounds; i++) {
    final b = BytesBuilder()..add((i & 1) != 0 ? p : c);
    if (i % 3 != 0) b.add(sb);
    if (i % 7 != 0) b.add(p);
    b.add((i & 1) != 0 ? c : p);
    c = _sha256(b.toBytes());
  }
  const order = [
    [0, 10, 20],
    [21, 1, 11],
    [12, 22, 2],
    [3, 13, 23],
    [24, 4, 14],
    [15, 25, 5],
    [6, 16, 26],
    [27, 7, 17],
    [18, 28, 8],
    [9, 19, 29],
  ];
  final enc = StringBuffer();
  for (final g in order) {
    enc.write(_b64x24(c[g[0]], c[g[1]], c[g[2]], 4));
  }
  enc.write(_b64x24(0, c[31], c[30], 3));
  return '\$5\$${custom ? 'rounds=$rounds\$' : ''}$saltText\$$enc';
}

List<int> _repeatTo(List<int> block, int length) {
  final out = <int>[];
  while (out.length < length) {
    out.addAll(block);
  }
  return out.sublist(0, length);
}

/// `out[i] = dictionary[(cred[i] xor tmpkey[i]) % dictionary.length]` over the
/// longer of the two, missing bytes padded with 187.
String authkeyCrypt(String credential, String tmpkey, String dictionary) {
  final n = credential.length > tmpkey.length ? credential.length : tmpkey.length;
  final out = StringBuffer();
  for (var i = 0; i < n; i++) {
    final c = i < credential.length ? credential.codeUnitAt(i) : 187;
    final k = i < tmpkey.length ? tmpkey.codeUnitAt(i) : 187;
    out.write(dictionary[(c ^ k) % dictionary.length]);
  }
  return out.toString();
}

final _b64Text = RegExp(r'^[A-Za-z0-9+/]*={0,2}$');

/// Applies the register reply's `extra_crypt` (`{type, params}`) to
/// [credential]. Missing, malformed or unknown variants return it unchanged.
/// Types (case-insensitive): `password_shadow` (`passwd_id` 1 md5-crypt with
/// `passwd_prefix`, 2 sha1 hex, 5 sha256-crypt; 3 and others unchanged),
/// `password_authkey` (`authkey_tmpkey`, `authkey_dictionary`),
/// `password_sha_with_salt` (`sha_name` 0 = 'admin' else 'user', `sha_salt` b64).
String applyExtraCrypt(String credential, Object? extraCrypt) {
  if (extraCrypt is! Map) return credential;
  final kind = extraCrypt['type'];
  final params = extraCrypt['params'];
  if (kind is! String || params is! Map) return credential;
  switch (kind.toLowerCase()) {
    case 'password_shadow':
      final id = params['passwd_id'];
      final prefix = params['passwd_prefix'];
      if (id == 1 && prefix is String) return md5Crypt(credential, prefix) ?? credential;
      if (id == 2) return sha1.convert(utf8.encode(credential)).toString();
      if (id == 5 && prefix is String) return sha256Crypt(credential, prefix);
      return credential;
    case 'password_authkey':
      final tmpkey = params['authkey_tmpkey'];
      final dictionary = params['authkey_dictionary'];
      if (tmpkey is String && dictionary is String && dictionary.isNotEmpty) {
        return authkeyCrypt(credential, tmpkey, dictionary);
      }
      return credential;
    case 'password_sha_with_salt':
      final salt = params['sha_salt'];
      if (salt is! String || salt.length % 4 != 0 || !_b64Text.hasMatch(salt)) return credential;
      try {
        final name = params['sha_name'] == 0 ? 'admin' : 'user';
        final raw = utf8.decode(base64.decode(salt), allowMalformed: true);
        return sha256.convert(utf8.encode('$name$raw$credential')).toString();
      } on FormatException {
        return credential;
      }
  }
  return credential;
}
