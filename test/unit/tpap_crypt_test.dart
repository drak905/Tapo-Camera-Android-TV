// Spec hc.local.tpap_extra_crypt (tier 1). Drepper vectors are the public
// crypt(3) test vectors; the rest is computed here with package:crypto.

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/tpap_crypt.dart';

String _refAuthkey(String cred, String tmpkey, String dictionary) {
  final n = max(cred.length, tmpkey.length);
  final out = StringBuffer();
  for (var i = 0; i < n; i++) {
    final a = i < cred.length ? cred.codeUnitAt(i) : 187;
    final b = i < tmpkey.length ? tmpkey.codeUnitAt(i) : 187;
    out.write(dictionary[(a ^ b) % dictionary.length]);
  }
  return out.toString();
}

void main() {
  test('sha256 crypt drepper vectors', () {
    expect(sha256Crypt('Hello world!', r'$5$saltstring'),
        r'$5$saltstring$5B8vYYiY.CVt1RlTTf8KbXBH3hsxY/GNooZaBBGWEc5');
    expect(sha256Crypt('Hello world!', r'$5$rounds=10000$saltstringsaltstring'),
        r'$5$rounds=10000$saltstringsaltst$3xv.VbSHBb41AL9AvLeujZkZRBAwqFMz2.opqey6IcA');
  });

  test('sha256 crypt clamps rounds and truncates salt', () {
    final low = sha256Crypt('pw', r'$5$rounds=10$abc');
    expect(low, startsWith(r'$5$rounds=1000$abc$'));
    final salt = sha256Crypt('pw', r'$5$0123456789abcdefXYZ');
    expect(salt, startsWith(r'$5$0123456789abcdef$'));
  });

  test('md5 crypt vector and prefix check', () {
    expect(md5Crypt('password', r'$1$3azHgidD$'), r'$1$3azHgidD$SrJPt7B.9rekpmwJwtON31');
    expect(md5Crypt('password', r'$5$3azHgidD$'), isNull);
    expect(md5Crypt('password', 'plain'), isNull);
  });

  group('apply extra crypt variants', () {
    const cred = 'ABCDEF0123456789';

    test('missing or malformed leaves the passcode unchanged', () {
      for (final bad in <Object?>[
        null,
        'x',
        <Object?>[],
        {'type': 5, 'params': {}},
        {'type': 'password_shadow'},
        {'type': 'password_shadow', 'params': 'x'},
        {'type': 'unknown_kind', 'params': {'passwd_id': 1}},
      ]) {
        expect(applyExtraCrypt(cred, bad), cred, reason: '$bad');
      }
    });

    test('password shadow ids', () {
      Map<String, dynamic> shadow(Object id, [String? prefix]) => {
            'type': 'password_shadow',
            'params': {'passwd_id': id, 'passwd_prefix': ?prefix},
          };
      expect(applyExtraCrypt(cred, shadow(2)), sha1.convert(utf8.encode(cred)).toString());
      expect(applyExtraCrypt(cred, shadow(5, r'$5$saltstring')), sha256Crypt(cred, r'$5$saltstring'));
      expect(applyExtraCrypt(cred, shadow(1, r'$1$3azHgidD$')), md5Crypt(cred, r'$1$3azHgidD$'));
      expect(applyExtraCrypt(cred, shadow(1, r'$5$notmd5')), cred); // wrong prefix: unchanged
      expect(applyExtraCrypt(cred, shadow(3)), cred); // needs a user name
      expect(applyExtraCrypt(cred, shadow(9)), cred);
      expect(applyExtraCrypt(cred, shadow(5)), cred); // prefix missing
    });

    test('type is case insensitive', () {
      expect(
        applyExtraCrypt(cred, {'type': 'PASSWORD_SHADOW', 'params': {'passwd_id': 2}}),
        sha1.convert(utf8.encode(cred)).toString(),
      );
    });

    test('sha with salt', () {
      final salt = base64.encode(utf8.encode('somesalt'));
      String expected(String who) => sha256.convert(utf8.encode('${who}somesalt$cred')).toString();
      expect(
        applyExtraCrypt(cred, {
          'type': 'password_sha_with_salt',
          'params': {'sha_name': 0, 'sha_salt': salt},
        }),
        expected('admin'),
      );
      expect(
        applyExtraCrypt(cred, {
          'type': 'password_sha_with_salt',
          'params': {'sha_name': 1, 'sha_salt': salt},
        }),
        expected('user'),
      );
      expect(
        applyExtraCrypt(cred, {
          'type': 'password_sha_with_salt',
          'params': {'sha_name': 0, 'sha_salt': '***not base64***'},
        }),
        cred,
      );
    });

    test('authkey variant', () {
      expect(
        applyExtraCrypt(cred, {
          'type': 'password_authkey',
          'params': {'authkey_tmpkey': 'k3y', 'authkey_dictionary': 'abcdefghij'},
        }),
        _refAuthkey(cred, 'k3y', 'abcdefghij'),
      );
      expect(
        applyExtraCrypt(cred, {
          'type': 'password_authkey',
          'params': {'authkey_tmpkey': 'k3y', 'authkey_dictionary': ''},
        }),
        cred,
      );
    });
  });

  test('authkey', () {
    expect(authkeyCrypt('abc', 'xy', 'ABCDEFGHIJKLMNOP'), _refAuthkey('abc', 'xy', 'ABCDEFGHIJKLMNOP'));
    expect(authkeyCrypt('a', 'longerkey', 'ABCDEFG'), _refAuthkey('a', 'longerkey', 'ABCDEFG'));
    expect(authkeyCrypt('abc', 'xy', 'ABCDEFGHIJKLMNOP').length, 3);
    expect(authkeyCrypt('a', 'longerkey', 'ABCDEFG').length, 9);
  });
}
