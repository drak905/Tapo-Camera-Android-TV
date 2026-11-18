// ONVIF SOAP 1.2 envelope and WS-Security UsernameToken digest (camera account
// only). Spec: ev.onvif.wsse_digest.

/// base64(sha1(nonce + created UTF-8 + password UTF-8)).
String wsseDigest({
  required List<int> nonce,
  required String created,
  required String password,
}) =>
    throw UnimplementedError();

/// `<wsse:Security mustUnderstand>` fragment with UsernameToken (Username,
/// Password Type `...#PasswordDigest`, Nonce base64 with EncodingType
/// Base64Binary, wsu:Created). [created] defaults to now UTC `YYYY-MM-DDTHH:MM:SSZ`,
/// [nonce] to 16 random bytes. The plaintext password never appears.
String buildWsseHeader(
  String username,
  String password, {
  String? created,
  List<int>? nonce,
}) =>
    throw UnimplementedError();

/// SOAP 1.2 envelope (`http://www.w3.org/2003/05/soap-envelope`) with an
/// optional header fragment and the body fragment.
String buildSoapEnvelope(String bodyXml, [String? headerXml]) => throw UnimplementedError();

/// Validates a SOAP reply. A SOAP Fault throws `TapoDeviceError(code -1)`
/// without echoing secrets; HTTP 401 without a SOAP body throws
/// `TapoAuthError`; unparsable XML throws `TapoProtocolError`.
void checkSoapReply(int httpStatus, String body) => throw UnimplementedError();