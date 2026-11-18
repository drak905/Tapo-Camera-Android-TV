/// RTSP URL for the optional camera-account path (P2).
library;

/// `rtsp://<user>:<pass>@<host>:<port>/<path>`; credentials percent-encoded
/// with nothing safe (`@ : / % #` and spaces never appear raw); an IPv6 host
/// is bracketed exactly once. [path] is `stream1` (HD), `stream2` (SD),
/// `stream6` / `stream7` (second lens).
String buildRtspUrl(
  String host,
  String username,
  String password, {
  String path = 'stream1',
  int port = 554,
}) =>
    throw UnimplementedError();

/// Replaces the password in the userinfo with `***`. The last `@` ends the
/// userinfo. URLs without a password are returned unchanged.
String redactRtspUrl(String url) => throw UnimplementedError();
