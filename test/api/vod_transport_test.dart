// vod.transport.routing: which path an SD playback takes.
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/vod_session.dart';

void main() {
  test('lan owned camera uses local', () {
    final c = selectVodTransport(role: 0, onLan: true, online: true, hasRelayProvider: true);
    expect(c.kind, VodTransportKind.local);
    expect(c.failReason, isNull);
  });

  test('lan owned camera uses local without a cloud sign-in too', () {
    expect(selectVodTransport(role: 0, onLan: true, online: true, hasRelayProvider: false).kind, VodTransportKind.local);
  });

  test('remote camera uses relay', () {
    final c = selectVodTransport(role: 0, onLan: false, online: true, hasRelayProvider: true);
    expect(c.kind, VodTransportKind.relay);
  });

  test('shared camera on LAN uses relay', () {
    final c = selectVodTransport(role: 1, onLan: true, online: true, hasRelayProvider: true);
    expect(c.kind, VodTransportKind.relay);
  });

  test('unreachable camera fails fast with reason', () {
    final c = selectVodTransport(role: 0, onLan: false, online: true, hasRelayProvider: false);
    expect(c.kind, VodTransportKind.none);
    expect(c.failReason, kReasonNotOnNetwork);
  });

  test('offline camera fails with camera offline', () {
    final c = selectVodTransport(role: 0, onLan: false, online: false, hasRelayProvider: true);
    expect(c.kind, VodTransportKind.none);
    expect(c.failReason, kReasonCameraOffline);
  });

  test('shared camera without a signed-in relay provider is cloud only', () {
    final c = selectVodTransport(role: 1, onLan: true, online: true, hasRelayProvider: false);
    expect(c.kind, VodTransportKind.none);
    expect(c.failReason, kReasonSharedCloudOnly);
  });
}
