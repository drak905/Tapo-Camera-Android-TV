// Spec hc.cloud.signing (tier 1). Golden vector from the Windows repo
// tests/phase2/test_cloud_signing.py.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/tapo_signing.dart';

const _secret = '6ed7d97f3e73467f8a5bab90b577ba4c';
const _accessKey = '4d11b6b9d5ea4d19a829adbb9714b057';
const _body = '{"appType":"TP-Link_Tapo_Android","cloudUserName":"user@example.com"}';
const _nonce = '2f1a6c3e-8b7d-4e21-9a55-0c4d3b2a1f00';
final _url = Uri.parse(
  'https://n-wap.i.tplinkcloud.com/api/v2/account/getAccountStatusAndUrl',
);

void main() {
  test('golden vector byte exact', () {
    final h = signCloudRequest(
      body: utf8.encode(_body),
      url: _url,
      nonce: _nonce,
      accessKey: _accessKey,
      secretKey: _secret,
    );
    expect(h.contentMd5, 'Tm1i6bgNP+L0b9fkTC+BUA==');
    expect(h.signature, 'd3e911ddfed0a8f151fa2d9ceef11062fc3a1a6f');
    expect(
      h.xAuthorization,
      'Timestamp=9999999999, Nonce=$_nonce, AccessKey=$_accessKey, '
      'Signature=d3e911ddfed0a8f151fa2d9ceef11062fc3a1a6f',
    );
  });

  test('the app constants are the default keys', () {
    final h = signCloudRequest(body: utf8.encode(_body), url: _url, nonce: _nonce);
    expect(h.signature, 'd3e911ddfed0a8f151fa2d9ceef11062fc3a1a6f');
  });

  test('empty body hashes braces', () {
    expect(cloudContentMd5(const []), 'mZFLkyvTelC5g8XnyQrpOw==');
    expect(cloudContentMd5(utf8.encode('{}')), 'mZFLkyvTelC5g8XnyQrpOw==');
  });

  test('path excludes query', () {
    final plain = signCloudRequest(body: utf8.encode(_body), url: _url, nonce: _nonce);
    final withQuery = signCloudRequest(
      body: utf8.encode(_body),
      url: _url.replace(queryParameters: {'token': 'abc', 'appName': 'x'}),
      nonce: _nonce,
    );
    expect(withQuery.signature, plain.signature);
  });

  test('nonce is a random lower-case uuid when not given', () {
    final a = signCloudRequest(body: utf8.encode(_body), url: _url);
    final b = signCloudRequest(body: utf8.encode(_body), url: _url);
    final re = RegExp(
      r'Nonce=([0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}),',
    );
    expect(re.hasMatch(a.xAuthorization), isTrue);
    expect(
      re.firstMatch(a.xAuthorization)!.group(1),
      isNot(re.firstMatch(b.xAuthorization)!.group(1)),
    );
  });
}
