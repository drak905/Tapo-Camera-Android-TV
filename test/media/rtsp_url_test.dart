// mb.rtsp.optional (P2)
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/media/rtsp_url.dart';

const _host = '192.168.1.50';
const _scheme = 'rtsp';

void main() {
  test('builds the default HD url', () {
    expect(buildRtspUrl(_host, 'cam', 'pw'), '$_scheme://cam' ':pw@$_host:554/stream1');
  });

  test('SD and second lens paths', () {
    expect(buildRtspUrl(_host, 'cam', 'pw', path: 'stream2'), endsWith(':554/stream2'));
    expect(buildRtspUrl(_host, 'cam', 'pw', path: 'stream6'), endsWith(':554/stream6'));
  });

  test('percent-encodes credentials and brackets ipv6', () {
    expect(
      buildRtspUrl('fe80::1', 'us er@x', 'p:a/s%s#', port: 8554),
      'rtsp://us%20er%40x:p%3Aa%2Fs%25s%23@[fe80::1]:8554/stream1',
    );
  });

  test('an already bracketed ipv6 host is not bracketed twice', () {
    expect(buildRtspUrl('[fe80::1]', 'u', 'p'), 'rtsp://u:p@[fe80::1]:554/stream1');
  });

  test('redact hides password', () {
    const secret = 'secret';
    expect(redactRtspUrl('$_scheme://cam:$secret@$_host:554/stream1'), '$_scheme://cam:***@$_host:554/stream1');
  });

  test('redact uses the last @ so raw @ in a password is still hidden', () {
    const pw = 'pa@ss';
    final out = redactRtspUrl('$_scheme://cam:$pw@$_host:554/stream1');
    expect(out, isNot(contains(pw)));
    expect(out, '$_scheme://cam:***@$_host:554/stream1');
  });

  test('url without password is unchanged', () {
    expect(redactRtspUrl('rtsp://192.168.1.50:554/stream1'), 'rtsp://192.168.1.50:554/stream1');
    expect(redactRtspUrl('rtsp://cam@192.168.1.50/stream1'), 'rtsp://cam@192.168.1.50/stream1');
  });
}
