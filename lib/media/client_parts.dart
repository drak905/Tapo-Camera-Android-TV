/// Client-to-camera multipart parts (requests, acks, heartbeats).
library;

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
}) =>
    throw UnimplementedError();

/// Compact JSON (separators `,` and `:`, no ASCII escaping).
String compactJson(Object? value) => throw UnimplementedError();

/// Preview request body, seq right after type:
/// `{"type":"request","seq":1,"params":{"method":"get","preview":{"channels":[0],"resolutions":["VGA"],"audio":["default"]}}}`.
/// [resolution] is `HD` (main) or `VGA` (minor); anything else throws [ArgumentError].
String previewRequestJson(String resolution, {int seq = 1, int channel = 0}) => throw UnimplementedError();

/// `{"type":"request","params":{"method":"do","stop":"null"},"seq":N}`.
String stopRequestJson(int seq) => throw UnimplementedError();

/// Range playback request body:
/// `{"type":"request","params":{"method":"get","playback":{"client_id":1,"channels":[0],"scale":"1/1","start_time":"..","end_time":"..","event_type":[1,2]}},"seq":N}`.
/// Times are UTC epoch seconds; [startUtc] must be > 0, [endUtc] >= [startUtc],
/// else [ArgumentError].
String playbackRequestJson(int startUtc, int endUtc, {int seq = 1}) => throw UnimplementedError();

/// Writes the parts of one session: owns the seq counter and the session id.
class ClientPartWriter {
  ClientPartWriter();

  /// Known after the camera's reply; `X-Session-Id` is then added to every
  /// part that does not carry it already.
  String? sessionId;

  /// Next request sequence number (1, 2, ...).
  int nextSeq() => throw UnimplementedError();

  /// A JSON control part for [compactBody].
  Uint8List json(String compactBody, {List<(String, String)> headers = const []}) => throw UnimplementedError();

  /// Flow-control ack: `X-Data-Received: <n>` then `X-Session-Id`, body
  /// `{"type":"notification","params":{"event_type":"stream_sequence"}}`.
  Uint8List ack(int received) => throw UnimplementedError();

  /// The 15 s heartbeat part ([kHeartbeatBody]).
  Uint8List heartbeat() => throw UnimplementedError();
}
