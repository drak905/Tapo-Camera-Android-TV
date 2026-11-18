// Shared plumbing of the Tier 2 integration tests: a dart:io MediaTransport,
// the connector the media classes use against the Dart mocks, stream helpers
// and the loopback-inspection probe for :8800.
//
// Why the TLS fallback exists: HTTP-inspecting security software on the dev PC
// (AdGuard) answers the plain, non-HTTP multipart traffic that follows the 200
// of :8800 with a 400 page. [tls8800Needed] detects that exactly like the
// fixture self-tests do; every test that talks to MockMedia8800 then starts the
// mock with `useTls = true` (tag `adguard-tls`). The wire protocol above TLS is
// unchanged. On a clean machine the same tests run over plain TCP.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/media/media_transport.dart';

import '../../fixtures/mock_media8800.dart';
import '../../fixtures_selftest/raw_clients.dart';

/// Tag of every test whose :8800 leg may run inside TLS on this machine.
const String tagAdguardTls = 'adguard-tls';

/// A [MediaTransport] over a dart:io socket (plain or TLS).
class SocketMediaTransport implements MediaTransport {
  SocketMediaTransport(this._socket) {
    // Write errors after a peer reset are reported on `done`; the read side
    // (input) already carries the failure to the protocol code.
    _socket.done.ignore();
  }
  final Socket _socket;
  bool _closed = false;

  @override
  Stream<Uint8List> get input => _socket;

  @override
  void add(List<int> data) => _socket.add(data);

  @override
  Future<void> flush() => _socket.flush();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _socket.close().timeout(const Duration(seconds: 1));
    } catch (_) {}
    _socket.destroy();
  }
}

/// Connection log of one [TestConnector].
class ConnectLog {
  ConnectLog(this.host, this.port, this.tls, this.serverName);
  final String host;
  final int port;
  final bool tls;
  final String? serverName;
}

/// TransportConnector for the mocks.
///
/// * [context]: trust store for TLS (the MockRelay certificate); when null the
///   self-signed :8800 mock certificate is accepted (tests only).
/// * [maxConnect]: upper bound of the TCP connect wait. A closed loopback port
///   takes about 2 s to be refused on Windows; failover tests set 1.2 s.
/// * [forceTls]: wrap the connection in TLS even when the caller asked for plain
///   TCP (the AdGuard fallback of MockMedia8800).
class TestConnector {
  TestConnector({this.context, this.maxConnect = const Duration(seconds: 5), this.forceTls = false});
  final SecurityContext? context;
  final Duration maxConnect;
  final bool forceTls;
  final List<ConnectLog> log = [];
  int opened = 0;

  Future<MediaTransport> call(
    String host,
    int port, {
    bool tls = false,
    String? serverName,
    Duration? timeout,
  }) async {
    log.add(ConnectLog(host, port, tls || forceTls, serverName));
    var wait = maxConnect;
    if (timeout != null && timeout < wait) wait = timeout;
    final raw = await Socket.connect(host, port, timeout: wait);
    raw.setOption(SocketOption.tcpNoDelay, true);
    opened++;
    if (!tls && !forceTls) return SocketMediaTransport(raw);
    final secured = await SecureSocket.secure(
      raw,
      host: serverName ?? host,
      context: context,
      onBadCertificate: context == null ? (_) => true : null,
    );
    return SocketMediaTransport(secured);
  }
}

bool? _tls8800;

/// true when plain :8800 traffic is rejected by local HTTP inspection.
Future<bool> tls8800Needed() async => _tls8800 ??= await _probePlainBlocked();

Future<bool> _probePlainBlocked() async {
  final m = await MockMedia8800().start();
  MediaRaw? c;
  try {
    c = await MediaRaw.connect('127.0.0.1', m.port);
    await c.handshake('cloudpass');
    c.sendRequest(const {
      'method': 'get',
      'preview': {
        'channels': [0],
        'resolutions': ['VGA'],
        'audio': ['default'],
      },
    }, 1);
    final line = await c.reader.readLine().timeout(const Duration(seconds: 3));
    return line != null && line.startsWith('HTTP/');
  } catch (_) {
    return false;
  } finally {
    await c?.close();
    await m.stop();
  }
}

/// Starts [m] in the mode this machine needs and returns the connector to use.
Future<TestConnector> startMedia8800(MockMedia8800 m) async {
  final tls = await tls8800Needed();
  m.useTls = tls;
  await m.start();
  addTearDown(m.stop);
  return TestConnector(forceTls: tls);
}

/// Polls [cond] until true or [timeout]; returns the last value.
Future<bool> eventually(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 4),
  Duration every = const Duration(milliseconds: 25),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (cond()) return true;
    await Future<void>.delayed(every);
  }
  return cond();
}

/// Reads [source] until at least [minBytes] arrived, then cancels it.
/// Errors of the stream are rethrown; [timeout] bounds the whole read.
Future<Uint8List> collect(
  Stream<Uint8List> source, {
  int minBytes = 188 * 64,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final out = BytesBuilder(copy: false);
  final done = Completer<void>();
  late final StreamSubscription<Uint8List> sub;
  sub = source.listen(
    (chunk) {
      out.add(chunk);
      if (out.length >= minBytes && !done.isCompleted) done.complete();
    },
    onError: (Object e, StackTrace s) {
      if (!done.isCompleted) done.completeError(e, s);
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
    cancelOnError: true,
  );
  try {
    await done.future.timeout(timeout);
  } finally {
    await sub.cancel();
  }
  return out.takeBytes();
}

/// Waits for the first error of [source] (or fails when data/end arrives first).
Future<Object> firstError(Stream<Uint8List> source, {Duration timeout = const Duration(seconds: 8)}) async {
  final done = Completer<Object>();
  late final StreamSubscription<Uint8List> sub;
  sub = source.listen(
    (_) {},
    onError: (Object e, StackTrace s) {
      if (!done.isCompleted) done.complete(e);
    },
    onDone: () {
      if (!done.isCompleted) done.completeError(StateError('stream ended without an error'));
    },
  );
  try {
    return await done.future.timeout(timeout);
  } finally {
    await sub.cancel();
  }
}

/// Every complete 188-byte packet of [bytes] starts with the sync byte.
void expectTsPackets(Uint8List bytes, {int minPackets = 8}) {
  final whole = bytes.length ~/ 188;
  expect(whole, greaterThanOrEqualTo(minPackets), reason: 'too few TS packets (${bytes.length} bytes)');
  for (var i = 0; i < whole; i++) {
    if (bytes[i * 188] != 0x47) fail('TS sync byte missing at packet $i');
  }
}

/// [bytes] starts with the first [n] bytes of the mock's sample clip.
void expectSamplePrefix(Uint8List bytes, Uint8List sample, {int n = 188 * 16}) {
  expect(bytes.length, greaterThanOrEqualTo(n));
  expect(bytes.sublist(0, n), sample.sublist(0, n), reason: 'stream does not start with the sample TS');
}
