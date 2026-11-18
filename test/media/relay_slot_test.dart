// mb.relay.slot_request: CIPC slot request, cloudType 2 (lives in lib/media/relay per LANES.md).
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/media/media_deps.dart';
import 'package:tapo_tv/media/media_errors.dart';
import 'package:tapo_tv/media/relay/relay_slot.dart';

import 'helpers/fakes.dart';

void main() {
  test('body key set and cloudType 2 (preview)', () async {
    final auth = FakeCloudAuth();
    final slot = await RelaySlotClient(auth).requestSlot('DEV', resolution: 'HD');
    final post = auth.posts.single;
    expect(post.url.toString(), 'https://cipc.example.com/v2/relay/request');
    expect(post.body.keys.toList(), [
      'deviceId',
      'dataTimeoutCount',
      'cloudType',
      'deviceType',
      'playerId',
      'rootCaVer',
      'preConnection',
      'resolution',
      'streamType',
      'customParams',
      'trackId',
    ]);
    expect(post.body['cloudType'], 2);
    expect(post.body['dataTimeoutCount'], 0);
    expect(post.body['deviceType'], 'SMART.IPCAMERA');
    expect(post.body['playerId'], auth.terminalUuid);
    expect(post.body['rootCaVer'], '1');
    expect(post.body['preConnection'], 0);
    expect(post.body['resolution'], 'HD');
    expect(post.body['streamType'], 0);
    expect(post.body['customParams'], '{}');
    expect(post.body['trackId'], matches(RegExp(r'^[0-9a-f-]{36}$')));
    expect(slot.trackId, post.body['trackId']);
    expect(slot.relayHost, 'relay.example.com');
    expect(slot.token, 'RELAYTOKEN1');
  });

  test('playback slot uses streamType 1, channelId 0 and no resolution', () async {
    final auth = FakeCloudAuth();
    await RelaySlotClient(auth).requestSlot('DEV', streamType: kRelayPlayback);
    final body = auth.posts.single.body;
    expect(body['streamType'], 1);
    expect(body['channelId'], '0');
    expect(body['cloudType'], 2);
    expect(body.containsKey('resolution'), isFalse);
    expect(body.containsKey('preConnection'), isFalse);
    expect(body.keys.last, 'trackId');
  });

  test('headers: raw token before semicolon, app headers, no signature', () async {
    final auth = FakeCloudAuth();
    await RelaySlotClient(auth).requestSlot('DEV', model: 'C210');
    final h = auth.posts.single.headers;
    expect(h['Authorization'], 'ACCOUNTTOKEN');
    expect(h['Content-Type'], 'application/json; charset=UTF-8');
    expect(h['Accept'], '*/*');
    expect(h['User-Agent'], 'Tapo_APP/C210/3.22.806_Android/Android 14');
    expect(h['X-Request-Signature'], matches(RegExp(r'^[A-Za-z0-9]{10}$')));
    expect(h['X-Client-Id'], auth.terminalUuid);
    expect(h['X-Source'], 'tapo-app');
    expect(h['X-Brand'], 'TPLINK');
    expect(h['X-Ca-Type'], 'cloud-self');
    expect(h['Connection'], 'close');
    expect(h.containsKey('X-Authorization'), isFalse);
  });

  test('fatal codes map to no-retry errors', () async {
    for (final code in [-1007, -1103, -52407, -52212, -100001, -20675, 3]) {
      final auth = FakeCloudAuth(replies: [FakeCloudAuth.error(code)]);
      await expectLater(
        RelaySlotClient(auth).requestSlot('DEV'),
        throwsA(isA<RelayException>().having((e) => e.fatal, 'fatal', isTrue).having((e) => e.code, 'code', code)),
        reason: '$code',
      );
      expect(auth.posts, hasLength(1), reason: 'no retry for $code');
    }
  });

  test('other error code is not fatal', () async {
    final auth = FakeCloudAuth(replies: [FakeCloudAuth.error(-9999)]);
    await expectLater(RelaySlotClient(auth).requestSlot('DEV'),
        throwsA(isA<RelayException>().having((e) => e.fatal, 'fatal', isFalse)));
  });

  test('1102 triggers one re-login then retries once', () async {
    final auth = FakeCloudAuth(replies: [FakeCloudAuth.error(-1102), FakeCloudAuth.relayOk()]);
    final slot = await RelaySlotClient(auth).requestSlot('DEV');
    expect(auth.reloginCount, 1);
    expect(auth.posts, hasLength(2));
    expect(slot.token, 'RELAYTOKEN1');
  });

  test('http 401 also triggers one re-login; a second rejection is fatal', () async {
    final auth = FakeCloudAuth(replies: [const CipcResponse(401, {})]);
    await expectLater(RelaySlotClient(auth).requestSlot('DEV'),
        throwsA(isA<RelayException>().having((e) => e.fatal, 'fatal', isTrue)));
    expect(auth.reloginCount, 1);
    expect(auth.posts, hasLength(2));
  });

  test('cloudType is 1 only when the device list says isSupportIoTCloud false', () {
    expect(RelaySlotClient.cloudTypeFor(null), 2);
    expect(RelaySlotClient.cloudTypeFor({'isSupportIoTCloud': true}), 2);
    expect(RelaySlotClient.cloudTypeFor({'isSupportIoTCloud': false}), 1);
    expect(RelaySlotClient.cloudTypeFor({'is_support_iot_cloud': false}), 1);
  });

  test('slot parses relayUrl and keeps secrets out of toString', () {
    final slot = RelaySlot.fromResult(
      {
        'relayUrl': 'https://relay.example.com:8443/relayservice?deviceid=DEV&type=video',
        'relayToken': 'SECRETTOKEN',
        'relayIp': '10.0.0.9',
        'elbCookie': 'AWSELB=secretcookie',
      },
      deviceId: 'DEV',
      trackId: 't',
      resolution: 'VGA',
    );
    expect(slot.relayHost, 'relay.example.com');
    expect(slot.relayPort, 8443);
    expect(slot.relayPath, '/relayservice?deviceid=DEV&type=video');
    expect(slot.relayIp, '10.0.0.9');
    expect('$slot', isNot(contains('SECRETTOKEN')));
    expect('$slot', isNot(contains('secretcookie')));
  });

  test('slot without token or address throws', () {
    expect(
      () => RelaySlot.fromResult({'relayUrl': 'https://r.example.com/x'}, deviceId: 'D', trackId: 't', resolution: 'VGA'),
      throwsA(isA<RelayException>()),
    );
  });
}
