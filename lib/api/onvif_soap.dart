// ONVIF SOAP 1.2 envelope and WS-Security UsernameToken digest (camera account
// only). Spec: ev.onvif.wsse_digest.

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import 'tapo_errors.dart';

const _wsseNs =
    'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd';
const _wsuNs =
    'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd';
const _soap12Ns = 'http://www.w3.org/2003/05/soap-envelope';
const _passwordDigestType =
    'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest';
const _base64BinaryType =
    'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary';

String _escape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// base64(sha1(nonce + created UTF-8 + password UTF-8)).
String wsseDigest({
  required List<int> nonce,
  required String created,
  required String password,
}) =>
    base64.encode(sha1.convert([...nonce, ...utf8.encode(created), ...utf8.encode(password)]).bytes);

String _utcStamp(DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  final u = now.toUtc();
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}T'
      '${two(u.hour)}:${two(u.minute)}:${two(u.second)}Z';
}

/// `<wsse:Security mustUnderstand>` fragment with UsernameToken (Username,
/// Password Type `...#PasswordDigest`, Nonce base64 with EncodingType
/// Base64Binary, wsu:Created). [created] defaults to now UTC `YYYY-MM-DDTHH:MM:SSZ`,
/// [nonce] to 16 random bytes. The plaintext password never appears.
String buildWsseHeader(
  String username,
  String password, {
  String? created,
  List<int>? nonce,
}) {
  final stamp = created ?? _utcStamp(DateTime.now());
  final rng = Random.secure();
  final salt = nonce ?? List<int>.generate(16, (_) => rng.nextInt(256));
  final digest = wsseDigest(nonce: salt, created: stamp, password: password);
  return '<wsse:Security xmlns:wsse="$_wsseNs" xmlns:wsu="$_wsuNs" xmlns:s="$_soap12Ns" '
      's:mustUnderstand="1"><wsse:UsernameToken>'
      '<wsse:Username>${_escape(username)}</wsse:Username>'
      '<wsse:Password Type="$_passwordDigestType">$digest</wsse:Password>'
      '<wsse:Nonce EncodingType="$_base64BinaryType">${base64.encode(salt)}</wsse:Nonce>'
      '<wsu:Created>${_escape(stamp)}</wsu:Created></wsse:UsernameToken></wsse:Security>';
}

/// SOAP 1.2 envelope (`http://www.w3.org/2003/05/soap-envelope`) with an
/// optional header fragment and the body fragment.
String buildSoapEnvelope(String bodyXml, [String? headerXml]) =>
    '<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="$_soap12Ns">'
    '<s:Header>${headerXml ?? ''}</s:Header><s:Body>$bodyXml</s:Body></s:Envelope>';

/// Parses XML without ever expanding a DTD. Returns null when it is not XML.
XmlDocument? parseXmlSafely(String text) {
  if (text.isEmpty || text.contains('<!DOCTYPE') || text.contains('<!ENTITY')) return null;
  try {
    return XmlDocument.parse(text);
  } on XmlException {
    return null;
  } catch (_) {
    return null;
  }
}

/// First descendant (or the element itself) with local name [local].
XmlElement? findLocal(XmlNode? node, String local) {
  if (node == null) return null;
  for (final e in node.descendants.whereType<XmlElement>()) {
    if (e.name.local == local) return e;
  }
  return null;
}

/// Trimmed text of the first descendant named [local], or ''.
String textLocal(XmlNode? node, String local) => findLocal(node, local)?.innerText.trim() ?? '';

/// First child element named [local].
XmlElement? childLocal(XmlElement? parent, String local) {
  if (parent == null) return null;
  for (final e in parent.childElements) {
    if (e.name.local == local) return e;
  }
  return null;
}

/// First child of the SOAP Body of [doc], or null.
XmlElement? soapBodyChild(XmlDocument doc) {
  final envelope = doc.rootElement;
  final body = childLocal(envelope, 'Body');
  if (body == null) return null;
  final children = body.childElements;
  return children.isEmpty ? null : children.first;
}

/// Validates a SOAP reply. A SOAP Fault throws `TapoDeviceError(code -1)`
/// without echoing secrets; HTTP 401 without a SOAP body throws
/// `TapoAuthError`; unparsable XML throws `TapoProtocolError`.
void checkSoapReply(int httpStatus, String body) {
  final doc = parseXmlSafely(body);
  XmlElement? first;
  var hasBody = false;
  if (doc != null) {
    hasBody = childLocal(doc.rootElement, 'Body') != null;
    first = soapBodyChild(doc);
  }
  if (!hasBody) {
    if (httpStatus == 401) throw TapoAuthError('The camera rejected the camera account (HTTP 401)');
    throw TapoProtocolError('Unparsable ONVIF reply (HTTP $httpStatus)');
  }
  if (first != null && first.name.local == 'Fault') {
    final reason = textLocal(first, 'Text');
    final code = first.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'Value')
        .map((e) => e.innerText.trim())
        .where((t) => t.isNotEmpty)
        .lastOrNull;
    final detail = [if (code != null) code, if (reason.isNotEmpty) reason].join(': ');
    final shown = detail.length > 200 ? detail.substring(0, 200) : detail;
    throw TapoDeviceError(
      'ONVIF SOAP fault${shown.isNotEmpty ? ': $shown' : ''}',
      code: -1,
    );
  }
  if (httpStatus < 200 || httpStatus >= 300) {
    throw TapoProtocolError('ONVIF HTTP $httpStatus without a SOAP Fault');
  }
  if (first == null) throw TapoProtocolError('Empty ONVIF SOAP Body');
}
