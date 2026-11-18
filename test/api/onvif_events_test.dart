// Specs ev.onvif.parse_notifications (tier 1) and ev.onvif.pullpoint_flow
// (tier 2), both P2 and only used with a camera account. Samples are shortened
// from tests/unit/_onvif_samples.py in the Windows repo.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/alarm_poller.dart';
import 'package:tapo_tv/api/onvif_events.dart';

const _twoEvents =
    '<env:Envelope xmlns:env="http://www.w3.org/2003/05/soap-envelope" xmlns:tev="http://www.onvif.org/ver10/events/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema" xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2"><env:Header/><env:Body><tev:PullMessagesResponse><tev:CurrentTime>2025-01-03T10:00:05Z</tev:CurrentTime><tev:TerminationTime>2025-01-03T10:01:05Z</tev:TerminationTime><wsnt:NotificationMessage><wsnt:Topic Dialect="http://www.onvif.org/ver10/tev/topicExpression/ConcreteSet">tns1:RuleEngine/CellMotionDetector/Motion</wsnt:Topic><wsnt:Message><tt:Message UtcTime="2025-01-03T10:00:01Z" PropertyOperation="Changed"><tt:Source><tt:SimpleItem Name="Rule" Value="MyMotionDetectorRule"/></tt:Source><tt:Data><tt:SimpleItem Name="IsMotion" Value="true"/></tt:Data></tt:Message></wsnt:Message></wsnt:NotificationMessage><wsnt:NotificationMessage><wsnt:Topic Dialect="http://www.onvif.org/ver10/tev/topicExpression/ConcreteSet">tns1:RuleEngine/CellMotionDetector/Motion</wsnt:Topic><wsnt:Message><tt:Message UtcTime="2025-01-03T10:00:04.250Z" PropertyOperation="Changed"><tt:Data><tt:SimpleItem Name="IsMotion" Value="false"/></tt:Data></tt:Message></wsnt:Message></wsnt:NotificationMessage></tev:PullMessagesResponse></env:Body></env:Envelope>';

String _single(String topic, String itemName, String value, {String utc = '2025-01-03T10:00:09Z'}) =>
    '<env:Envelope xmlns:env="http://www.w3.org/2003/05/soap-envelope" xmlns:tev="http://www.onvif.org/ver10/events/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema" xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2"><env:Body><tev:PullMessagesResponse><wsnt:NotificationMessage><wsnt:Topic>$topic</wsnt:Topic><wsnt:Message><tt:Message ${utc.isEmpty ? '' : 'UtcTime="$utc"'}><tt:Data><tt:SimpleItem Name="$itemName" Value="$value"/></tt:Data></tt:Message></wsnt:Message></wsnt:NotificationMessage></tev:PullMessagesResponse></env:Body></env:Envelope>';

void main() {
  group('bodies', () {
    test('create pullpoint and pull messages bodies', () {
      expect(
        buildCreatePullPointBody(),
        '<tev:CreatePullPointSubscription xmlns:tev="http://www.onvif.org/ver10/events/wsdl">'
        '<tev:InitialTerminationTime>PT60S</tev:InitialTerminationTime>'
        '</tev:CreatePullPointSubscription>',
      );
      expect(
        buildPullMessagesBody(),
        '<tev:PullMessages xmlns:tev="http://www.onvif.org/ver10/events/wsdl">'
        '<tev:Timeout>PT5S</tev:Timeout><tev:MessageLimit>10</tev:MessageLimit></tev:PullMessages>',
      );
    });
  });

  group('parse notifications', () {
    test('parse pull messages motion true and false', () {
      final n = parseNotifications(_twoEvents);
      expect(n, hasLength(2));
      expect(n[0].topic, 'tns1:RuleEngine/CellMotionDetector/Motion');
      expect(n[0].active, isTrue);
      expect(n[0].utc, DateTime.utc(2025, 1, 3, 10, 0, 1));
      expect(n[0].source, {'Rule': 'MyMotionDetectorRule'});
      expect(n[0].data, {'IsMotion': 'true'});
      expect(n[1].active, isFalse);
    });

    test('fractional UtcTime', () {
      final n = parseNotifications(_twoEvents);
      expect(n[1].utc, DateTime.utc(2025, 1, 3, 10, 0, 4, 250));
      expect(n[1].utc.isUtc, isTrue);
    });

    test('parse State item variant', () {
      final n = parseNotifications(_single('tns1:VideoSource/MotionAlarm', 'State', '1'));
      expect(n.single.topic, 'tns1:VideoSource/MotionAlarm');
      expect(n.single.active, isTrue);
      expect(parseNotifications(_single('tns1:VideoSource/MotionAlarm', 'State', '0')).single.active, isFalse);
    });

    test('values are case insensitive and unknown values are ignored', () {
      expect(parseNotifications(_single('t', 'IsMotion', 'TRUE')).single.active, isTrue);
      expect(parseNotifications(_single('t', 'IsMotion', 'False')).single.active, isFalse);
      expect(parseNotifications(_single('t', 'IsMotion', 'maybe')), isEmpty);
      expect(parseNotifications(_single('t', 'Other', 'true')), isEmpty);
    });

    test('any topic with IsMotion or State is kept with its topic string', () {
      final n = parseNotifications(_single('tns1:RuleEngine/MyRuleDetector/PeopleDetect', 'IsMotion', 'true'));
      expect(n.single.topic, 'tns1:RuleEngine/MyRuleDetector/PeopleDetect');
    });

    test('missing UtcTime uses now', () {
      final now = DateTime.utc(2030, 5, 6, 7, 8, 9);
      final n = parseNotifications(_single('t', 'IsMotion', 'true', utc: ''), now: now);
      expect(n.single.utc, now);
    });

    test('parse empty response', () {
      const empty =
          '<env:Envelope xmlns:env="http://www.w3.org/2003/05/soap-envelope" xmlns:tev="http://www.onvif.org/ver10/events/wsdl"><env:Body><tev:PullMessagesResponse><tev:CurrentTime>2025-01-03T10:00:05Z</tev:CurrentTime></tev:PullMessagesResponse></env:Body></env:Envelope>';
      expect(parseNotifications(empty), isEmpty);
    });

    test('garbage never throws', () {
      for (final g in [
        '',
        'not xml',
        '<a><b></a>',
        '<?xml version="1.0"?>',
        '\u0000\u0001\u0002',
        '<env:Envelope><env:Body><wsnt:NotificationMessage></wsnt:NotificationMessage></env:Body></env:Envelope>',
        '<wsnt:NotificationMessage><tt:Message UtcTime="garbage"><tt:SimpleItem Name="IsMotion" Value="true"/></tt:Message></wsnt:NotificationMessage>',
        _twoEvents.substring(0, 300),
      ]) {
        expect(() => parseNotifications(g), returnsNormally, reason: g);
      }
    });
  });

  group('pullpoint flow', () {
    const base = 'http://192.168.1.50:2020';
    const capsXml =
        '<env:Envelope xmlns:env="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema"><env:Body><tds:GetCapabilitiesResponse><tds:Capabilities><tt:Events><tt:XAddr>$base/onvif/event_service</tt:XAddr></tt:Events></tds:Capabilities></tds:GetCapabilitiesResponse></env:Body></env:Envelope>';
    const subscribeXml =
        '<env:Envelope xmlns:env="http://www.w3.org/2003/05/soap-envelope" xmlns:tev="http://www.onvif.org/ver10/events/wsdl" xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2" xmlns:wsa5="http://www.w3.org/2005/08/addressing"><env:Body><tev:CreatePullPointSubscriptionResponse><tev:SubscriptionReference><wsa5:Address>$base/onvif/pullpoint?sub=abc</wsa5:Address></tev:SubscriptionReference><wsnt:CurrentTime>2025-01-03T10:00:00Z</wsnt:CurrentTime><wsnt:TerminationTime>2025-01-03T10:01:00Z</wsnt:TerminationTime></tev:CreatePullPointSubscriptionResponse></env:Body></env:Envelope>';
    const okXml =
        '<env:Envelope xmlns:env="http://www.w3.org/2003/05/soap-envelope"><env:Body><x:Ok xmlns:x="urn:x"/></env:Body></env:Envelope>';
    const emptyPull =
        '<env:Envelope xmlns:env="http://www.w3.org/2003/05/soap-envelope" xmlns:tev="http://www.onvif.org/ver10/events/wsdl"><env:Body><tev:PullMessagesResponse><tev:CurrentTime>2025-01-03T10:00:05Z</tev:CurrentTime><tev:TerminationTime>2025-01-03T10:01:05Z</tev:TerminationTime></tev:PullMessagesResponse></env:Body></env:Envelope>';

    FakeOnvif fake({int failPulls = 0, List<String>? pulls}) =>
        FakeOnvif(capsXml, subscribeXml, okXml, emptyPull, failPulls: failPulls, pulls: pulls);

    OnvifEventSubscriber subscriber(
      FakeOnvif t,
      List<MotionEvent> events, {
      void Function(MotionEvent)? onEvent,
      DateTime Function()? clock,
    }) =>
        OnvifEventSubscriber(
          cameraId: 'cam-1',
          transport: t,
          username: 'camuser',
          password: 'campass',
          onEvent: onEvent ?? events.add,
          clock: clock,
        );

    test('subscriber delivers events and uses subscription path', () {
      fakeAsync((async) {
        final t = fake(pulls: [_twoEvents]);
        final events = <MotionEvent>[];
        final s = subscriber(t, events, clock: async.getClock(DateTime.utc(2025, 1, 3, 10)).now);
        s.start();
        async.elapse(const Duration(seconds: 12));
        expect(events, isNotEmpty);
        expect(events.first.cameraId, 'cam-1');
        expect(events.first.active, isTrue);
        expect(events.first.source, 'onvif');
        expect(events.first.topic, 'tns1:RuleEngine/CellMotionDetector/Motion');
        expect(t.paths('GetCapabilities').first, '/onvif/device_service');
        expect(t.paths('CreatePullPointSubscription').first, '/onvif/event_service');
        expect(t.paths('PullMessages'), everyElement('/onvif/pullpoint?sub=abc'));
        for (final soap in t.bodies) {
          expect(soap, isNot(contains('campass')));
        }
        s.stop();
      });
    });

    test('pull messages body has Timeout and MessageLimit', () {
      fakeAsync((async) {
        final t = fake();
        final s = subscriber(t, []);
        s.start();
        async.elapse(const Duration(seconds: 6));
        final pull = t.bodies.firstWhere((b) => b.contains('PullMessages>') || b.contains('<tev:PullMessages'));
        expect(pull, contains('<tev:Timeout>PT5S</tev:Timeout><tev:MessageLimit>10</tev:MessageLimit>'));
        expect(pull, contains('http://www.onvif.org/ver10/events/wsdl/PullPointSubscription/PullMessagesRequest'));
        expect(pull, contains('$base/onvif/pullpoint?sub=abc'), reason: 'wsa:To');
        s.stop();
      });
    });

    test('resubscribes after failures with backoff', () {
      fakeAsync((async) {
        final t = fake(failPulls: 3)..now = async.getClock(DateTime.utc(2025)).now;
        final s = subscriber(t, []);
        s.start();
        async.elapse(const Duration(seconds: 30));
        final creates = t.times('CreatePullPointSubscription');
        expect(creates.length, greaterThanOrEqualTo(4));
        // Failures at t=0 (pull fails instantly): resubscribe after 1 s, 2 s, 4 s.
        final gaps = [for (var i = 1; i < 4; i++) creates[i].difference(creates[i - 1]).inSeconds];
        expect(gaps, [1, 2, 4]);
        s.stop();
      });
    });

    test('callback exception does not kill the loop', () {
      fakeAsync((async) {
        final t = fake(pulls: [_twoEvents, _twoEvents]);
        var calls = 0;
        final s = subscriber(t, [], onEvent: (_) {
          calls++;
          throw StateError('listener bug');
        });
        s.start();
        async.elapse(const Duration(seconds: 25));
        expect(calls, greaterThanOrEqualTo(3), reason: 'later events are still delivered');
        expect(t.paths('PullMessages').length, greaterThanOrEqualTo(2));
        s.stop();
      });
    });

    test('stop is prompt and idempotent', () {
      fakeAsync((async) {
        final t = fake();
        final s = subscriber(t, []);
        s.start();
        async.elapse(const Duration(seconds: 2)); // a pull is in flight (5 s long poll)
        var stopped = 0;
        s.stop().then((_) => stopped++);
        s.stop().then((_) => stopped++);
        async.elapse(const Duration(milliseconds: 100));
        expect(stopped, 2, reason: 'does not wait for the long poll');
        final pulls = t.paths('PullMessages').length;
        async.elapse(const Duration(seconds: 60));
        expect(t.paths('PullMessages').length, pulls);
        expect(t.paths('Unsubscribe'), hasLength(1));
      });
    });
  });
}

/// In-memory ONVIF camera: answers by SOAP action, long-polls PullMessages for 5 s.
class FakeOnvif implements OnvifTransport {
  FakeOnvif(this.caps, this.subscribe, this.ok, this.emptyPull, {this.failPulls = 0, List<String>? pulls})
      : _pulls = List.of(pulls ?? const []);

  final String caps, subscribe, ok, emptyPull;
  int failPulls;
  DateTime Function() now = DateTime.now;
  final List<String> _pulls;
  final List<(String action, String path, String body, DateTime at)> calls = [];

  List<String> get bodies => [for (final c in calls) c.$3];
  List<String> paths(String action) => [for (final c in calls) if (c.$1 == action) c.$2];
  List<DateTime> times(String action) => [for (final c in calls) if (c.$1 == action) c.$4];

  static String _actionOf(String soap) {
    for (final a in [
      'GetCapabilities',
      'CreatePullPointSubscription',
      'PullMessages',
      'Renew',
      'Unsubscribe',
    ]) {
      if (soap.contains('<tev:$a') || soap.contains('<wsnt:$a') || soap.contains('<tds:$a')) return a;
    }
    return 'unknown';
  }

  @override
  Future<String> post(String path, String soapXml, {required Duration timeout}) async {
    final action = _actionOf(soapXml);
    calls.add((action, path, soapXml, now()));
    switch (action) {
      case 'GetCapabilities':
        return caps;
      case 'CreatePullPointSubscription':
        return subscribe;
      case 'PullMessages':
        if (failPulls > 0) {
          failPulls--;
          throw TimeoutException('camera went away');
        }
        await Future<void>.delayed(const Duration(seconds: 5));
        return _pulls.isEmpty ? emptyPull : _pulls.removeAt(0);
      default:
        return ok;
    }
  }
}
