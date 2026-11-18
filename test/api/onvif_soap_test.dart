// Spec ev.onvif.wsse_digest (tier 1, P2). Ported from
// tests/unit/test_onvif_soap.py in the Windows repo. XML is checked with
// regular expressions because no XML package is available to the tests.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/onvif_soap.dart';
import 'package:tapo_tv/api/tapo_errors.dart';

const _created = '2024-01-01T00:00:00Z';
final _nonce = utf8.encode('0123456789abcdef');
const _wsse = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd';
const _soap12 = 'http://www.w3.org/2003/05/soap-envelope';
const _tds = 'http://www.onvif.org/ver10/device/wsdl';
const _devInfo = '<tds:GetDeviceInformation xmlns:tds="$_tds"/>';

String _textOf(String xml, String local) {
  final m = RegExp('<(?:\\w+:)?$local\\b[^>]*>([^<]*)</(?:\\w+:)?$local>').firstMatch(xml);
  expect(m, isNotNull, reason: 'element $local not found in $xml');
  return m!.group(1)!;
}

void main() {
  test('wsse digest known vector', () {
    expect(
      wsseDigest(nonce: _nonce, created: _created, password: 'campass'),
      'LR6Iva2OZQZwaVZPTZaUJCerU4E=',
    );
    final header = buildWsseHeader('camuser', 'campass', created: _created, nonce: _nonce);
    expect(_textOf(header, 'Username'), 'camuser');
    expect(_textOf(header, 'Password'), 'LR6Iva2OZQZwaVZPTZaUJCerU4E=');
    expect(header, contains('#PasswordDigest'));
    expect(_textOf(header, 'Nonce'), 'MDEyMzQ1Njc4OWFiY2RlZg==');
    expect(header, contains('Base64Binary'));
    expect(_textOf(header, 'Created'), _created);
    expect(header, contains(_wsse));
    expect(header, matches(RegExp(r'mustUnderstand="(1|true)"')));
  });

  test('wsse digest fixed literal', () {
    final literal = base64.encode(
      sha1.convert(utf8.encode('0123456789abcdef2024-01-01T00:00:00Zcampass')).bytes,
    );
    expect(wsseDigest(nonce: _nonce, created: _created, password: 'campass'), literal);
  });

  test('header never contains the plaintext password', () {
    expect(buildWsseHeader('u', 'S3cret-Pass'), isNot(contains('S3cret-Pass')));
    final env = buildSoapEnvelope(_devInfo, buildWsseHeader('u', 'S3cret-Pass'));
    expect(env, isNot(contains('S3cret-Pass')));
  });

  test('header defaults are fresh and consistent', () {
    final a = buildWsseHeader('camuser', 'campass');
    final b = buildWsseHeader('camuser', 'campass');
    expect(_textOf(a, 'Nonce'), isNot(_textOf(b, 'Nonce')));
    final nonce = base64.decode(_textOf(a, 'Nonce'));
    expect(nonce.length, greaterThanOrEqualTo(16));
    final created = _textOf(a, 'Created');
    expect(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z$').hasMatch(created), isTrue);
    final skew = DateTime.now().toUtc().difference(DateTime.parse(created)).inSeconds.abs();
    expect(skew, lessThan(60));
    expect(
      _textOf(a, 'Password'),
      base64.encode(sha1.convert([...nonce, ...utf8.encode(created), ...utf8.encode('campass')]).bytes),
    );
  });

  test('envelope structure', () {
    final env = buildSoapEnvelope(_devInfo);
    expect(env, contains(_soap12));
    expect(env, matches(RegExp(r'<(\w+:)?Envelope\b')));
    final body = RegExp(r'<(?:\w+:)?Body>(.*)</(?:\w+:)?Body>', dotAll: true).firstMatch(env);
    expect(body?.group(1)?.trim(), _devInfo);
    final withHeader = buildSoapEnvelope(_devInfo, buildWsseHeader('u', 'p', created: _created, nonce: _nonce));
    expect(withHeader, matches(RegExp(r'<(\w+:)?Header>.*Security.*</(\w+:)?Header>', dotAll: true)));
  });

  test('SOAP fault maps to device error', () {
    const fault = '<env:Envelope xmlns:env="$_soap12"><env:Body><env:Fault><env:Code>'
        '<env:Value>env:Sender</env:Value></env:Code><env:Reason><env:Text xml:lang="en">'
        'Sender not authorized</env:Text></env:Reason></env:Fault></env:Body></env:Envelope>';
    expect(
      () => checkSoapReply(500, fault),
      throwsA(isA<TapoDeviceError>()
          .having((e) => e.code, 'code', -1)
          .having((e) => e.message, 'message', isNot(contains('WRONG-pass-123')))),
    );
  });

  test('http 401 without soap body is an auth error, garbage a protocol error', () {
    expect(() => checkSoapReply(401, ''), throwsA(isA<TapoAuthError>()));
    expect(() => checkSoapReply(200, 'not xml at all'), throwsA(isA<TapoProtocolError>()));
    expect(() => checkSoapReply(200, buildSoapEnvelope('<a/>')), returnsNormally);
  });
}
