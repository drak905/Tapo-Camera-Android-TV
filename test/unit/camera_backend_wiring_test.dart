// CameraBackend wiring: the app's media sources use the production adapters
// (TapoCloudRelayAuth, LocalSecretsMediaAuth, FailoverSource for owned LAN
// cameras) instead of private copies. No network: sources are only built.
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/camera_router.dart';
import 'package:tapo_tv/api/cloud_relay_auth.dart';
import 'package:tapo_tv/api/cloud_transport.dart';
import 'package:tapo_tv/api/tapo_cloud.dart';
import 'package:tapo_tv/media/failover_source.dart';
import 'package:tapo_tv/state/camera_actions_impl.dart';

class _NoNetwork implements CloudTransport {
  @override
  Future<CloudResponse> send(CloudRequest request) async => throw const CloudTransportError('offline');
  @override
  void close() {}
}

CameraBackend _backend({String token = 'tok'}) {
  final cloud = TapoCloud.withTransport(terminalUuid: 'A1B2C3D4E5F60718293A4B5C6D7E8F90', transport: _NoNetwork())
    ..token = token;
  final b = CameraBackend(
    cloud: cloud,
    baseUrl: 'https://eu.example.com',
    terminalUuid: 'A1B2C3D4E5F60718293A4B5C6D7E8F90',
    transport: _NoNetwork(),
    discover: () async => const [],
  );
  addTearDown(b.close);
  return b;
}

const _owner = TapoCamera(
  id: 'own',
  name: 'Own',
  model: 'C200',
  role: CameraRole.owner,
  online: true,
  route: CameraRoute.local,
  lanIp: '192.168.1.20',
);

void main() {
  test('the relay auth is the production TapoCloudRelayAuth', () {
    expect(_backend().relayAuth, isA<TapoCloudRelayAuth>());
  });

  test('an owned LAN camera streams locally with a relay fallback when signed in', () {
    final b = _backend();
    b.cameras['own'] = _owner;
    final source = b.sourceFor('own', 'HD');
    expect(source, isA<FailoverSource>().having((s) => s.hasFallback, 'hasFallback', isTrue));
  });

  test('without a cloud session the owned LAN camera has no fallback', () {
    final b = _backend(token: '');
    b.cameras['own'] = _owner;
    expect(b.sourceFor('own', 'VGA'), isA<FailoverSource>().having((s) => s.hasFallback, 'hasFallback', isFalse));
  });

  test('a shared camera on the LAN never streams locally', () {
    final b = _backend();
    b.cameras['sh'] = const TapoCamera(
      id: 'sh',
      name: 'Shared',
      model: 'C200',
      role: CameraRole.shared,
      online: true,
      route: CameraRoute.cloud,
      lanIp: '192.168.1.21',
    );
    expect(b.sourceFor('sh', 'VGA'), isNot(isA<FailoverSource>()));
  });

  test('the local media secret is the LAT, else the password', () {
    final b = _backend();
    expect(b.localMediaAuth('own').digestSecret, isEmpty, reason: 'nothing known yet');
  });
}
