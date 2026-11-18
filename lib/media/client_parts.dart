/// Client-to-camera multipart parts (requests, acks, heartbeats).
library;

import 'dart:convert';
import 'dart:typed_data';

/// Client delimiter line: `--` + `--client-stream-boundary--`.
const String kClientDelimiter = '----client-stream-boundary--';

/// Heartbeat body exactly as the app writes it (with spaces, 63 bytes).
const String kHeartbeatBody = '{"type": "notification", "params": {"event_type": "heartbeat"}}';

/// `<delimiter>\r\n`, [headers] in insertion order, `Content-Type`,
/// `Content-Length`, blank line, [body], `\r\n`.
Uint8List encodeClientPart(
  List<int> body, {
  String contentType = 'application/json',
  List<(String, String)> headers = const [],
}) {
  final head = StringBuffer('$kClientDelimiter\r\n');
  for (final (k, v) in headers) {
    head.write('$k: $v\r\n');
  }
  head
    ..write('Content-Type: $contentType\r\n')
    ..write('Content-Length: ${body.length}\r\n\r\n');
  return Uint8List.fromList([...latin1.encode(head.toString()), ...body, 13, 10]);
}

/// Compact JSON (separators `,` and `:`, no ASCII escaping).
String compactJson(Object? value) => jsonEncode(value);

/// Preview request body. Windows `send_json` appends `seq` after the
/// existing keys, so it is last:
/// `{"type":"request","params":{"method":"get","preview":{"channels":[0],"resolutions":["VGA"],"audio":["default"]}},"seq":1}`.
/// [resolution] is `HD` (main) or `VGA` (minor); anything else throws [ArgumentError].
String previewRequestJson(String resolution, {int seq = 1, int channel = 0}) {
  if (resolution != 'HD' && resolution != 'VGA') {
    throw ArgumentError.value(resolution, 'resolution', 'must be HD or VGA');
  }
  if (channel < 0) throw ArgumentError.value(channel, 'channel', 'must be >= 0');
  return compactJson({
    'type': 'request',
    'params': {
      'method': 'get',
      'preview': {
        'channels': [channel],
        'resolutions': [resolution],
        'audio': ['default'],
      },
    },
    'seq': seq,
  });
}

/// `{"type":"request","params":{"method":"do","stop":"null"},"seq":N}`.
String stopRequestJson(int seq) => compactJson({
      'type': 'request',
      'params': {'method': 'do', 'stop': 'null'},
      'seq': seq,
    });

/// Range playback request body:
/// `{"type":"request","params":{"method":"get","playback":{"client_id":1,"channels":[0],"scale":"1/1","start_time":"..","end_time":"..","event_type":[1,2]}},"seq":N}`.
/// Times are UTC epoch seconds; [startUtc] must be > 0, [endUtc] >= [startUtc],
/// else [ArgumentError].
String playbackRequestJson(int startUtc, int endUtc, {int seq = 1}) {
  if (startUtc <= 0) throw ArgumentError.value(startUtc, 'startUtc', 'must be > 0');
  if (endUtc < startUtc) throw ArgumentError.value(endUtc, 'endUtc', 'must be >= startUtc');
  return compactJson({
    'type': 'request',
    'params': {
      'method': 'get',
      'playback': {
        'client_id': 1,
        'channels': [0],
        'scale': '1/1',
        'start_time': '$startUtc',
        'end_time': '$endUtc',
        'event_type': [1, 2],
      },
    },
    'seq': seq,
  });
}

/// Writes the parts of one session: owns the seq counter and the session id.
class ClientPartWriter {
  ClientPartWriter();

  int _seq = 0;

  /// Known after the camera's reply; `X-Session-Id` is then added to every
  /// part that does not carry it already.
  String? sessionId;

  /// Next request sequence number (1, 2, ...).
  int nextSeq() => ++_seq;

  /// A JSON control part for [compactBody].
  Uint8List json(String compactBody, {List<(String, String)> headers = const []}) {
    final all = [...headers];
    final id = sessionId;
    if (id != null && !all.any((h) => h.$1.toLowerCase() == 'x-session-id')) {
      all.add(('X-Session-Id', id));
    }
    return encodeClientPart(utf8.encode(compactBody), headers: all);
  }

  /// Flow-control ack: `X-Data-Received: <n>` then `X-Session-Id`, body
  /// `{"type":"notification","params":{"event_type":"stream_sequence"}}`.
  Uint8List ack(int received) => json(
        '{"type":"notification","params":{"event_type":"stream_sequence"}}',
        headers: [('X-Data-Received', '$received')],
      );

  /// The 15 s heartbeat part ([kHeartbeatBody]).
  Uint8List heartbeat() => json(kHeartbeatBody);
}
