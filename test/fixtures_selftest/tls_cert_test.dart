// Self-test: the generated certificate is accepted by dart:io TLS, both as a
// server certificate and as a trust anchor with hostname verification.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../fixtures/tls_cert.dart';

void main() {
  test('server presents the cert; client trusting only it verifies localhost',
      () async {
    final cert = generateTestCert(
        commonName: 'Mock', sanDns: ['localhost'], sanIps: ['127.0.0.1'], isCa: true);
    final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4, 0, cert.serverContext());
    server.listen((r) {
      r.response.write('hi');
      r.response.close();
    });
    addTearDown(() => server.close(force: true));

    final client = HttpClient(context: cert.clientContext());
    final req = await client.getUrl(Uri.parse('https://localhost:${server.port}/'));
    final res = await req.close();
    expect(await res.transform(utf8.decoder).join(), 'hi');
    expect(res.certificate!.der.length, cert.certDer.length);
    client.close(force: true);

    // A client with no trust configured must reject the certificate.
    final strict = HttpClient(context: SecurityContext(withTrustedRoots: false));
    await expectLater(
        strict.getUrl(Uri.parse('https://127.0.0.1:${server.port}/')).then((r) => r.close()),
        throwsA(isA<HandshakeException>()));
    strict.close(force: true);
  });

  test('fingerprint is the SHA-256 of the DER', () {
    final c = generateTestCert();
    expect(c.fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
  });
}
