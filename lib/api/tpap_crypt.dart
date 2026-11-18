// Passcode shaping for TPAP register `extra_crypt`. Spec: hc.local.tpap_extra_crypt.

/// md5-crypt ($1$). [prefix] like `$1$3azHgidD$`. Returns the full hash, or
/// null when [prefix] does not start with `$1$`.
String? md5Crypt(String key, String prefix) => throw UnimplementedError();

/// sha256-crypt (Drepper). [prefix] like `$5$[rounds=N$]salt`; salt <= 16
/// chars, default 5000 rounds, rounds clamped to 1000..999999999.
String sha256Crypt(String key, String prefix) => throw UnimplementedError();

/// `out[i] = dictionary[(cred[i] xor tmpkey[i]) % dictionary.length]` over the
/// longer of the two, missing bytes padded with 187.
String authkeyCrypt(String credential, String tmpkey, String dictionary) =>
    throw UnimplementedError();

/// Applies the register reply's `extra_crypt` (`{type, params}`) to
/// [credential]. Missing, malformed or unknown variants return it unchanged.
/// Types (case-insensitive): `password_shadow` (`passwd_id` 1 md5-crypt with
/// `passwd_prefix`, 2 sha1 hex, 5 sha256-crypt; 3 and others unchanged),
/// `password_authkey` (`authkey_tmpkey`, `authkey_dictionary`),
/// `password_sha_with_salt` (`sha_name` 0 = 'admin' else 'user', `sha_salt` b64).
String applyExtraCrypt(String credential, Object? extraCrypt) => throw UnimplementedError();