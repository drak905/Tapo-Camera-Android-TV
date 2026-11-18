// mb.local.session_connect: Digest (RFC 7616) for POST /stream on :8800.
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/media/digest.dart';

String _md5(String s) => md5.convert(s.codeUnits).toString();

void main() {
  group('rfc7616 vectors', () {
    test('md5', () {
      expect(
        digestResponse(
          username: 'Mufasa',
          realm: 'http-auth@example.org',
          password: 'Circle of Life',
          method: 'GET',
          uri: '/dir/index.html',
          nonce: '7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v',
          nc: '00000001',
          cnonce: 'f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ',
          qop: 'auth',
        ),
        '8ca523f5e9506fed4657c9700eebdbec',
      );
    });

    test('sha256', () {
      expect(
        digestResponse(
          username: 'Mufasa',
          realm: 'http-auth@example.org',
          password: 'Circle of Life',
          method: 'GET',
          uri: '/dir/index.html',
          nonce: '7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v',
          nc: '00000001',
          cnonce: 'f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ',
          qop: 'auth',
          algorithm: 'SHA-256',
        ),
        '753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1',
      );
    });
  });

  group('secret transform', () {
    test('md5 upper hex by default', () {
      expect(digestSecret('cloudpass'), '0318564DA313CFBFF096FE8CE56FA912');
    });

    test('sha256 upper hex when encrypt_type is 3', () {
      expect(
        digestSecret('local-access-token', encryptType: '3'),
        '4E5B2C20C1645A4EEDA8BD59251974653FFF883CA5480C9A54FBF87A263BD2C2',
      );
    });

    test('empty secret uses the default media password', () {
      expect(digestSecret(''), digestSecret(kDefaultMediaPassword));
    });
  });

  test('challenge parse reads realm qop nonce opaque algorithm encrypt_type userhash', () {
    final c = DigestChallenge.parse(
        'Digest realm="TP-LINK IP-CAM", qop="auth", nonce="8c5d1f22", opaque="6494321", algorithm=MD5, encrypt_type="3", userhash=true');
    expect(c.realm, 'TP-LINK IP-CAM');
    expect(c.qop, 'auth');
    expect(c.nonce, '8c5d1f22');
    expect(c.opaque, '6494321');
    expect(c.algorithm, 'MD5');
    expect(c.encryptType, '3');
    expect(c.userhash, isTrue);
  });

  test('authorization header exact md5 string', () {
    const challenge = DigestChallenge(
      realm: 'TP-LINK IP-CAM',
      qop: 'auth',
      nonce: '8c5d1f22',
      opaque: '6494321',
      algorithm: 'MD5',
    );
    final ha1 = _md5('admin:TP-LINK IP-CAM:0318564DA313CFBFF096FE8CE56FA912');
    final ha2 = _md5('POST:/stream');
    final response = _md5('$ha1:8c5d1f22:00000001:a1b2c3d4e5f6g7h8:auth:$ha2');
    expect(
      buildDigestAuthorization(challenge, secret: 'cloudpass', cnonce: 'a1b2c3d4e5f6g7h8'),
      'Digest username="admin",realm="TP-LINK IP-CAM",uri="/stream",algorithm=MD5,nonce="8c5d1f22",'
      'nc=00000001,cnonce="a1b2c3d4e5f6g7h8",qop=auth,response="$response",opaque="6494321"',
    );
  });

  test('qop uses the first token of a list', () {
    const challenge = DigestChallenge(realm: 'r', qop: 'auth,auth-int', nonce: 'n');
    final header = buildDigestAuthorization(challenge, secret: 'x', cnonce: 'c');
    expect(header, contains(',qop=auth,'));
    expect(header, isNot(contains('auth-int')));
  });

  test('cnonce alternates lowercase letter and digit, 16 chars', () {
    final c = generateCnonce();
    expect(c, matches(RegExp(r'^([a-z][0-9]){8}$')));
  });
}
