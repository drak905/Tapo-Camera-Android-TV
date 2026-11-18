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
}) {
  var h = host;
  if (h.contains(':') && !h.startsWith('[')) h = '[$h]';
  return 'rtsp://${Uri.encodeComponent(username)}:${Uri.encodeComponent(password)}@$h:$port/$path';
}

/// Replaces the password in the userinfo with `***`. The last `@` ends the
/// userinfo. URLs without a password are returned unchanged.
String redactRtspUrl(String url) {
  final schemeEnd = url.indexOf('://');
  if (schemeEnd < 0) return url;
  final start = schemeEnd + 3;
  final slash = url.indexOf('/', start);
  final authorityEnd = slash < 0 ? url.length : slash;
  final at = url.lastIndexOf('@', authorityEnd - 1);
  if (at < start) return url;
  final userinfo = url.substring(start, at);
  final colon = userinfo.indexOf(':');
  if (colon < 0) return url;
  return '${url.substring(0, start)}${userinfo.substring(0, colon)}:***${url.substring(at)}';
}