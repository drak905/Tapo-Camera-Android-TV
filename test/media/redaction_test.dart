// mb.security.bridge: errors never contain secrets.
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/media/media_errors.dart';

void main() {
  const secrets = ['local-access-token', 'cloudpass', 'RELAYTOKEN1', 'AWSELB=abc123'];

  test('errors never contain secrets', () {
    final text = 'login failed for cloudpass with local-access-token; relay RELAYTOKEN1 cookie AWSELB=abc123';
    final out = redactSecrets(text, secrets);
    for (final s in secrets) {
      expect(out, isNot(contains(s)));
    }
    expect(out, contains('***'));
  });

  test('empty secrets are ignored', () {
    expect(redactSecrets('nothing to hide', ['', 'zzz']), 'nothing to hide');
  });

  test('bridge key in a URL is redacted', () {
    final out = redactSecrets('GET http://127.0.0.1:4000/camera/D.ts?k=abcd1234&n=5 failed', const []);
    expect(out, isNot(contains('abcd1234')));
    expect(out, contains('/camera/D.ts'));
  });

  test('rtsp password in a URL is redacted', () {
    const pw = 'hunter2';
    const host = '192.168.1.50';
    final out = redactSecrets('open ${'rtsp'}://cam:$pw@$host:554/stream1 failed', const []);
    expect(out, isNot(contains(pw)));
  });
}
