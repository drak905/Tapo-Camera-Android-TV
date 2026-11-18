// mb.local.multipart_framing (client side), mb.local.preview_flow JSON, vod request JSON.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/media/client_parts.dart';

String _text(List<int> b) => latin1.decode(b);

void main() {
  test('encode client part json exact', () {
    expect(
      _text(encodeClientPart(utf8.encode('{"type":"request","seq":1}'))),
      '----client-stream-boundary--\r\nContent-Type: application/json\r\nContent-Length: 26\r\n\r\n{"type":"request","seq":1}\r\n',
    );
  });

  test('extra headers precede content-type', () {
    expect(
      _text(encodeClientPart(
        utf8.encode('ab'),
        contentType: 'audio/mp2t',
        headers: [('X-If-Encrypt', '1'), ('X-Session-Id', '9')],
      )),
      '----client-stream-boundary--\r\nX-If-Encrypt: 1\r\nX-Session-Id: 9\r\nContent-Type: audio/mp2t\r\nContent-Length: 2\r\n\r\nab\r\n',
    );
  });

  test('ack part exact', () {
    final w = ClientPartWriter()..sessionId = '9';
    expect(
      _text(w.ack(25)),
      '----client-stream-boundary--\r\nX-Data-Received: 25\r\nX-Session-Id: 9\r\nContent-Type: application/json\r\n'
      'Content-Length: 65\r\n\r\n{"type":"notification","params":{"event_type":"stream_sequence"}}\r\n',
    );
  });

  test('heartbeat part exact, 63 bytes with spaces', () {
    expect(
      _text(ClientPartWriter().heartbeat()),
      '----client-stream-boundary--\r\nContent-Type: application/json\r\nContent-Length: 63\r\n\r\n'
      '{"type": "notification", "params": {"event_type": "heartbeat"}}\r\n',
    );
  });

  test('seq starts at 1 and increments', () {
    final w = ClientPartWriter();
    expect([w.nextSeq(), w.nextSeq(), w.nextSeq()], [1, 2, 3]);
  });

  test('session id header is added once known', () {
    final w = ClientPartWriter();
    expect(_text(w.json('{}')), isNot(contains('X-Session-Id')));
    w.sessionId = '9';
    expect(_text(w.json('{}')), contains('X-Session-Id: 9\r\n'));
  });

  test('compact json has no spaces and keeps non-ascii', () {
    expect(compactJson({'a': [1, 2], 'b': 'é'}), '{"a":[1,2],"b":"é"}');
  });

  group('request bodies', () {
    test('preview request exact json (VGA)', () {
      expect(
        previewRequestJson('VGA'),
        '{"type":"request","params":{"method":"get","preview":{"channels":[0],"resolutions":["VGA"],"audio":["default"]}},"seq":1}',
      );
    });

    test('preview request HD', () {
      expect(previewRequestJson('HD', seq: 2), contains('"resolutions":["HD"]'));
    });

    test('preview rejects other resolutions', () {
      expect(() => previewRequestJson('4K'), throwsArgumentError);
    });

    test('stop request json', () {
      expect(stopRequestJson(3), '{"type":"request","params":{"method":"do","stop":"null"},"seq":3}');
    });

    test('range playback request exact json', () {
      final body = playbackRequestJson(1700000000, 1700086399, seq: 1);
      expect(
        body,
        '{"type":"request","params":{"method":"get","playback":{"client_id":1,"channels":[0],"scale":"1/1",'
        '"start_time":"1700000000","end_time":"1700086399","event_type":[1,2]}},"seq":1}',
      );
    });

    test('playback start 0 raises, end before start raises', () {
      expect(() => playbackRequestJson(0, 10), throwsArgumentError);
      expect(() => playbackRequestJson(100, 99), throwsArgumentError);
    });
  });
}
