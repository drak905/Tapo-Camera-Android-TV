// vod.transport.routing: ONE VodTransportKind / VodTransportChoice shared by
// the search side (vod_client.dart) and the playback side (vod_session.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/camera_router.dart';
import 'package:tapo_tv/api/vod_client.dart' as vc;
import 'package:tapo_tv/api/vod_session.dart' as vs;
import 'package:tapo_tv/api/vod_transport.dart' as vt;

void main() {
  test('both libraries re-export the same types', () {
    expect(identical(vc.VodTransportKind.local, vs.VodTransportKind.local), isTrue);
    expect(identical(vc.VodTransportKind.relay, vt.VodTransportKind.relay), isTrue);
    expect(vc.VodTransportKind.values, [vt.VodTransportKind.local, vt.VodTransportKind.relay, vt.VodTransportKind.none]);
    final vt.VodTransportChoice fromSearch = vc.chooseVodTransport(
      const TapoCamera(id: 'c', name: 'C', model: 'C200', role: CameraRole.owner, online: true, route: CameraRoute.cloud),
      relayAvailable: false,
    );
    final vt.VodTransportChoice fromPlayback =
        vs.selectVodTransport(role: 0, onLan: false, online: true, hasRelayProvider: false);
    expect(fromSearch.kind, vt.VodTransportKind.none);
    expect(fromSearch.failure, vt.VodFailReason.notOnThisNetwork);
    expect(fromPlayback.failure, vt.VodFailReason.notOnThisNetwork);
    expect(fromSearch.failReason, vs.kReasonNotOnNetwork);
  });

  test('a successful choice has no failure', () {
    final c = vs.selectVodTransport(role: 0, onLan: true, online: true, hasRelayProvider: false);
    expect(c.kind, vt.VodTransportKind.local);
    expect(c.failure, isNull);
    expect(c.failReason, isNull);
  });
}
