// ONVIF PullPoint events (optional, only with a camera account).
// Spec: ev.onvif.pullpoint_flow, ev.onvif.parse_notifications.

import 'dart:async';

import 'alarm_poller.dart';

const onvifActionPull =
    'http://www.onvif.org/ver10/events/wsdl/PullPointSubscription/PullMessagesRequest';
const onvifActionRenew = 'http://docs.oasis-open.org/wsn/bw-2/SubscriptionManager/RenewRequest';
const onvifActionUnsubscribe =
    'http://docs.oasis-open.org/wsn/bw-2/SubscriptionManager/UnsubscribeRequest';

/// `<tev:CreatePullPointSubscription ...><tev:InitialTerminationTime>PT60S...`
String buildCreatePullPointBody() => throw UnimplementedError();

/// `<tev:PullMessages ...><tev:Timeout>PT5S</tev:Timeout><tev:MessageLimit>10...`
String buildPullMessagesBody({int timeoutSeconds = 5, int messageLimit = 10}) =>
    throw UnimplementedError();

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

/// Active comes from SimpleItem IsMotion (or State): true/1 and false/0,
/// case-insensitive, anything else is ignored. Missing UtcTime uses [now].
/// Garbage returns an empty list and never throws.
List<OnvifNotification> parseNotifications(String xml, {DateTime? now}) =>
    throw UnimplementedError();

/// One short SOAP POST per call to `http://host:2020<path>`.
abstract class OnvifTransport {
  /// Returns the reply body; throws on network failure.
  Future<String> post(String path, String soapXml, {required Duration timeout});
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
  });

  void start() => throw UnimplementedError();

  /// Prompt and idempotent.
  Future<void> stop() => throw UnimplementedError();
}