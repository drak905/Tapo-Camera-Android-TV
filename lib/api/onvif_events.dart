// ONVIF PullPoint events (optional, only with a camera account).
// Spec: ev.onvif.pullpoint_flow, ev.onvif.parse_notifications.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import 'alarm_poller.dart';
import 'onvif_soap.dart';
import 'tapo_errors.dart';

const onvifActionPull =
    'http://www.onvif.org/ver10/events/wsdl/PullPointSubscription/PullMessagesRequest';
const onvifActionRenew = 'http://docs.oasis-open.org/wsn/bw-2/SubscriptionManager/RenewRequest';
const onvifActionUnsubscribe =
    'http://docs.oasis-open.org/wsn/bw-2/SubscriptionManager/UnsubscribeRequest';

const _tevNs = 'http://www.onvif.org/ver10/events/wsdl';
const _tdsNs = 'http://www.onvif.org/ver10/device/wsdl';
const _wsntNs = 'http://docs.oasis-open.org/wsn/b-2';
const _wsaNs = 'http://www.w3.org/2005/08/addressing';
const _defaultServicePath = '/onvif/service';
const _deviceServicePath = '/onvif/device_service';
const _subscriptionTtlSeconds = 60;
const _maxBackoff = Duration(seconds: 30);
const _unsubscribeTimeout = Duration(seconds: 2);

/// `<tev:CreatePullPointSubscription ...><tev:InitialTerminationTime>PT60S...`
String buildCreatePullPointBody() =>
    '<tev:CreatePullPointSubscription xmlns:tev="$_tevNs">'
    '<tev:InitialTerminationTime>PT${_subscriptionTtlSeconds}S</tev:InitialTerminationTime>'
    '</tev:CreatePullPointSubscription>';

/// `<tev:PullMessages ...><tev:Timeout>PT5S</tev:Timeout><tev:MessageLimit>10...`
String buildPullMessagesBody({int timeoutSeconds = 5, int messageLimit = 10}) =>
    '<tev:PullMessages xmlns:tev="$_tevNs"><tev:Timeout>PT${timeoutSeconds}S</tev:Timeout>'
    '<tev:MessageLimit>$messageLimit</tev:MessageLimit></tev:PullMessages>';

/// One parsed NotificationMessage.
class OnvifNotification {
  const OnvifNotification({
    required this.topic,
    required this.active,
    required this.utc,
    this.source = const {},
    this.data = const {},
  });
  final String topic;
  final bool active;
  final DateTime utc;
  final Map<String, String> source;
  final Map<String, String> data;
}

Map<String, String> _simpleItems(XmlElement? parent) {
  if (parent == null) return const {};
  final out = <String, String>{};
  for (final e in parent.descendants.whereType<XmlElement>()) {
    if (e.name.local != 'SimpleItem') continue;
    final name = e.getAttribute('Name');
    if (name != null && name.isNotEmpty) out[name] = e.getAttribute('Value') ?? '';
  }
  return out;
}

DateTime? _parseUtc(String? text) {
  if (text == null || text.trim().isEmpty) return null;
  final parsed = DateTime.tryParse(text.trim());
  if (parsed == null) return null;
  return parsed.isUtc
      ? parsed
      : DateTime.utc(parsed.year, parsed.month, parsed.day, parsed.hour, parsed.minute,
          parsed.second, parsed.millisecond, parsed.microsecond);
}

/// Active comes from SimpleItem IsMotion (or State): true/1 and false/0,
/// case-insensitive, anything else is ignored. Missing UtcTime uses [now].
/// Garbage returns an empty list and never throws.
List<OnvifNotification> parseNotifications(String xml, {DateTime? now}) {
  try {
    final doc = parseXmlSafely(xml);
    if (doc == null) return const [];
    return _notificationsFrom(doc, now);
  } catch (_) {
    return const [];
  }
}

List<OnvifNotification> _notificationsFrom(XmlNode root, DateTime? now) {
  final out = <OnvifNotification>[];
  for (final note in root.descendants.whereType<XmlElement>()) {
    if (note.name.local != 'NotificationMessage') continue;
    final outer = childLocal(note, 'Message');
    if (outer == null) continue;
    final message = childLocal(outer, 'Message') ?? outer;
    final data = _simpleItems(childLocal(message, 'Data'));
    final raw = data['IsMotion'] ?? data['State'];
    final value = (raw ?? '').trim().toLowerCase();
    final bool active;
    if (value == 'true' || value == '1') {
      active = true;
    } else if (value == 'false' || value == '0') {
      active = false;
    } else {
      continue;
    }
    out.add(OnvifNotification(
      topic: textLocal(note, 'Topic'),
      active: active,
      utc: _parseUtc(message.getAttribute('UtcTime')) ?? (now ?? DateTime.now()).toUtc(),
      source: _simpleItems(childLocal(message, 'Source')),
      data: data,
    ));
  }
  return out;
}

/// One short SOAP POST per call to `http://host:2020<path>`.
abstract class OnvifTransport {
  /// Returns the reply body; throws on network failure.
  Future<String> post(String path, String soapXml, {required Duration timeout});
}

/// [OnvifTransport] over `dart:io`: one connection per call.
class HttpOnvifTransport implements OnvifTransport {
  HttpOnvifTransport(this.host, {this.port = 2020});
  final String host;
  final int port;

  @override
  Future<String> post(String path, String soapXml, {required Duration timeout}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      return await _post(client, path, soapXml).timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _post(HttpClient client, String path, String soapXml) async {
    final request = await client.postUrl(Uri(scheme: 'http', host: host, port: port).resolve(path));
    request.headers.set('Content-Type', 'application/soap+xml; charset=utf-8');
    request.headers.set('Connection', 'close');
    request.add(utf8.encode(soapXml));
    final response = await request.close();
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > 8 * 1024 * 1024) throw TapoProtocolError('ONVIF reply is too large');
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    // Faults and 401 are diagnosed from the body; surface the status otherwise.
    if (response.statusCode >= 400) checkSoapReply(response.statusCode, text);
    return text;
  }
}

class _Subscription {
  _Subscription(this.path, this.address, this.renewAt);
  final String path;
  final String address;
  DateTime renewAt;
  bool unsubscribed = false;
}

String _durationText(int seconds) => 'PT${seconds}S';

String _pathOf(String address, String fallback) {
  final uri = Uri.tryParse(address);
  if (uri == null || uri.path.isEmpty) return fallback;
  return uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
}

class OnvifEventSubscriber {
  /// Flow: GetCapabilities -> events path (fallback /onvif/service) ->
  /// CreatePullPointSubscription (PT60S) -> loop PullMessages (PT5S, 10) on the
  /// subscription path -> Renew before expiry -> Unsubscribe on stop. Any
  /// failure re-subscribes with backoff doubling from 1 s to 30 s. An
  /// [onEvent] exception never stops the loop.
  OnvifEventSubscriber({
    required String cameraId,
    required OnvifTransport transport,
    required String username,
    required String password,
    required void Function(MotionEvent event) onEvent,
    DateTime Function()? clock,
  })  : _cameraId = cameraId,
        _transport = transport,
        _username = username,
        _password = password,
        _onEvent = onEvent,
        _clock = clock ?? DateTime.now;

  final String _cameraId;
  final OnvifTransport _transport;
  final String _username;
  final String _password;
  final void Function(MotionEvent event) _onEvent;
  final DateTime Function() _clock;

  static const _pullSeconds = 5;
  static const _netTimeout = Duration(seconds: 5);

  bool _started = false;
  bool _stopped = false;
  _Subscription? _sub;
  Future<void>? _stopFuture;
  final Completer<void> _wake = Completer<void>();

  void start() {
    if (_started || _stopped) return;
    _started = true;
    unawaited(_run());
  }

  /// Prompt and idempotent.
  Future<void> stop() => _stopFuture ??= _doStop();

  Future<void> _doStop() async {
    _stopped = true;
    if (!_wake.isCompleted) _wake.complete();
    final sub = _sub;
    if (sub != null) await _unsubscribe(sub);
  }

  // ----------------------------------------------------------------- loop

  Future<void> _run() async {
    var backoff = const Duration(seconds: 1);
    while (!_stopped) {
      try {
        var sub = _sub;
        if (sub == null) {
          sub = await _subscribe();
          if (_stopped) {
            await _unsubscribe(sub);
            break;
          }
          _sub = sub;
        }
        if (!_clock().isBefore(sub.renewAt)) await _renew(sub);
        if (_stopped) break;
        await _pull(sub);
        backoff = const Duration(seconds: 1);
      } catch (_) {
        if (_stopped) break;
        final old = _sub;
        _sub = null;
        if (old != null) unawaited(_unsubscribe(old));
        await Future.any([Future<void>.delayed(backoff), _wake.future]);
        final doubled = backoff * 2;
        backoff = doubled > _maxBackoff ? _maxBackoff : doubled;
      }
    }
  }

  String _envelope(String body, {String action = '', String to = ''}) {
    var header = buildWsseHeader(_username, _password);
    if (action.isNotEmpty) {
      header += '<wsa:Action xmlns:wsa="$_wsaNs">$action</wsa:Action>';
      if (to.isNotEmpty) {
        header += '<wsa:To xmlns:wsa="$_wsaNs">${_xmlEscape(to)}</wsa:To>';
      }
    }
    return buildSoapEnvelope(body, header);
  }

  static String _xmlEscape(String text) =>
      text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  Future<XmlElement> _call(
    String path,
    String body, {
    String action = '',
    String to = '',
    Duration timeout = _netTimeout,
  }) async {
    final reply = await _transport.post(path, _envelope(body, action: action, to: to), timeout: timeout);
    checkSoapReply(200, reply);
    return soapBodyChild(parseXmlSafely(reply)!)!;
  }

  Future<String> _eventsPath() async {
    try {
      final resp = await _call(
        _deviceServicePath,
        '<tds:GetCapabilities xmlns:tds="$_tdsNs"><tds:Category>All</tds:Category></tds:GetCapabilities>',
      );
      final events = findLocal(resp, 'Events');
      final xaddr = textLocal(events, 'XAddr');
      return xaddr.isEmpty ? _defaultServicePath : _pathOf(xaddr, _defaultServicePath);
    } on TapoDeviceError {
      return _defaultServicePath;
    } on TapoProtocolError {
      return _defaultServicePath;
    }
  }

  Duration _remainingTtl(XmlNode resp) {
    final current = _parseUtc(textLocal(resp, 'CurrentTime'));
    final termination = _parseUtc(textLocal(resp, 'TerminationTime'));
    if (current == null || termination == null) return const Duration(seconds: _subscriptionTtlSeconds);
    final left = termination.difference(current);
    return left.isNegative ? Duration.zero : left;
  }

  void _scheduleRenew(_Subscription sub, Duration ttl) {
    const margin = Duration(seconds: _pullSeconds + 5 + 2);
    final base = margin > const Duration(seconds: 10) ? margin : const Duration(seconds: 10);
    final half = Duration(microseconds: ttl.inMicroseconds ~/ 2);
    final lead = base < half ? base : half;
    sub.renewAt = _clock().add(ttl - lead);
  }

  Future<_Subscription> _subscribe() async {
    final path = await _eventsPath();
    final resp = await _call(path, buildCreatePullPointBody());
    final address = textLocal(findLocal(resp, 'SubscriptionReference'), 'Address');
    final sub = _Subscription(_pathOf(address, path), address, _clock());
    _scheduleRenew(sub, _remainingTtl(resp));
    return sub;
  }

  Future<void> _renew(_Subscription sub) async {
    final resp = await _call(
      sub.path,
      '<wsnt:Renew xmlns:wsnt="$_wsntNs"><wsnt:TerminationTime>'
      '${_durationText(_subscriptionTtlSeconds)}</wsnt:TerminationTime></wsnt:Renew>',
      action: onvifActionRenew,
      to: sub.address,
    );
    _scheduleRenew(sub, _remainingTtl(resp));
  }

  Future<void> _pull(_Subscription sub) async {
    final resp = await _call(
      sub.path,
      buildPullMessagesBody(timeoutSeconds: _pullSeconds),
      action: onvifActionPull,
      to: sub.address,
      timeout: const Duration(seconds: _pullSeconds) + _netTimeout,
    );
    if (_stopped) return;
    if (findLocal(resp, 'TerminationTime') != null) _scheduleRenew(sub, _remainingTtl(resp));
    for (final n in _notificationsFrom(resp, _clock())) {
      _deliver(n);
    }
  }

  void _deliver(OnvifNotification n) {
    final lower = n.topic.toLowerCase();
    final type = (lower.contains('people') || lower.contains('person')) ? 'person' : 'motion';
    try {
      _onEvent(MotionEvent(
        cameraId: _cameraId,
        active: n.active,
        type: type,
        timestamp: n.utc,
        topic: n.topic,
        source: 'onvif',
      ));
    } catch (_) {
      // a listener bug must not stop the loop
    }
  }

  /// Best effort, short timeout, never throws, at most once per subscription.
  Future<void> _unsubscribe(_Subscription sub) async {
    if (sub.unsubscribed) return;
    sub.unsubscribed = true;
    try {
      await _transport.post(
        sub.path,
        _envelope(
          '<wsnt:Unsubscribe xmlns:wsnt="$_wsntNs"/>',
          action: onvifActionUnsubscribe,
          to: sub.address,
        ),
        timeout: _unsubscribeTimeout,
      );
    } catch (_) {
      // best effort
    }
  }
}
