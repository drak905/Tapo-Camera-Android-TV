/// SD-card playback over the local :8800 media port or the cloud relay.
///
/// Plain MPEG-TS goes to ExoPlayer through the RelayBridge; control (pause,
/// resume, seek, speed) and end-of-recordings logic live here.
library;

import 'dart:typed_data';

import '../media/media_deps.dart';
import '../media/media_source.dart';
import '../media/media_transport.dart';
import '../media/stream_limiter.dart';

/// A recorded clip in UTC epoch seconds.
class VodClipRange {
  const VodClipRange(this.start, this.end);
  final int start;
  final int end;
}

enum VodState { idle, connecting, playing, paused, stopped, failed }

/// Speeds the UI may ask for. The request always asks `1/1`; speed is applied
/// client-side by pacing frames.
const List<String> kVodSpeeds = ['1/1', '2/1', '4/1', '8/1'];

/// Reason text of [VodSession.endReason] at the end of the last recording.
const String kEndOfRecordings = 'end of recordings';

/// Frame interval for [speed]: `2/1` halves [base], `8/1` divides it by 8.
/// Throws [ArgumentError] for a speed outside [kVodSpeeds].
Duration paceInterval(Duration base, String speed) => throw UnimplementedError();

/// Which path an SD playback takes.
enum VodTransportKind { local, relay, none }

class VodTransportChoice {
  const VodTransportChoice(this.kind, {this.failReason});
  final VodTransportKind kind;

  /// Set when [kind] is [VodTransportKind.none]: `not on this network`,
  /// `camera offline` or `shared camera cloud only`.
  final String? failReason;
}

const String kReasonNotOnNetwork = 'not on this network';
const String kReasonCameraOffline = 'camera offline';
const String kReasonSharedCloudOnly = 'shared camera cloud only';

/// Relay when the camera is cloud-routed (remote, shared role 1, offline on
/// LAN) and a signed-in relay provider exists; otherwise local :8800. Shared
/// cameras on the LAN still use the relay. When neither works the choice is
/// `none` with a reason. Playback and live view use the same limiter key.
VodTransportChoice selectVodTransport({
  required int role,
  required bool onLan,
  required bool online,
  required bool hasRelayProvider,
}) =>
    throw UnimplementedError();

class VodSession implements MediaSource {
  /// Local :8800 playback (Digest + Key-Exchange like live view).
  VodSession.local({
    required this.host,
    this.port = 8800,
    required LocalMediaAuth localAuth,
    required this.connector,
    required this.startUtc,
    required this.endUtc,
    this.limiter,
    this.clips = const [],
    this.stopLinger = const Duration(milliseconds: 150),
  })  : deviceId = null,
        relayAuth = null,
        heartbeatInterval = const Duration(seconds: 15);

  /// Relay playback (streamType 1, cloudType 2). Every start, seek and
  /// reconnect takes a NEW relay slot.
  VodSession.relay({
    required String this.deviceId,
    required CloudRelayAuth auth,
    required this.connector,
    required this.startUtc,
    required this.endUtc,
    this.limiter,
    this.clips = const [],
    this.heartbeatInterval = const Duration(seconds: 15),
    this.stopLinger = const Duration(milliseconds: 150),
  })  : host = null,
        port = 443,
        relayAuth = auth;

  final String? host;
  final int port;
  final String? deviceId;
  final CloudRelayAuth? relayAuth;
  final TransportConnector connector;
  final int startUtc;
  final int endUtc;
  final StreamLimiter? limiter;

  /// The day's clips (sorted); used to continue after `finished` and to
  /// recognise the end of recordings.
  final List<VodClipRange> clips;
  final Duration heartbeatInterval;
  final Duration stopLinger;

  VodState get state => throw UnimplementedError();
  Stream<VodState> get states => throw UnimplementedError();

  /// `end of recordings` once the last recording is done, else null.
  String? get endReason => throw UnimplementedError();

  /// Set when [state] is [VodState.failed]: `PlaybackRefusedException`,
  /// `SdCardOfflineException` or a relay error. Fatal: never retried.
  Object? get failure => throw UnimplementedError();

  /// Last position in UTC seconds (from the PtsTimeline in the api lane).
  int? get lastPositionUtc => throw UnimplementedError();
  void reportPosition(int utcSeconds) => throw UnimplementedError();

  /// Opens the transport, sends `get playback` from [startUtc] to [endUtc]
  /// (see `playbackRequestJson`), forwards video parts only. Acks every 25th
  /// `X-Data-Sequence`. Local connection loss reconnects and sends a new
  /// request at [lastPositionUtc]; a refusal (non-zero error_code) is fatal.
  /// `stream_status: finished` with a later clip starts a new request at that
  /// clip's start; without one the state is stopped with [kEndOfRecordings].
  /// `disk_status: offline` fails with `SdCardOfflineException`. A relay tunnel
  /// that closes at position >= last clip end - 1.5 s is the end of recordings.
  @override
  Stream<Uint8List> openTs() => throw UnimplementedError();

  /// `do pause` (`{"type":"request","params":{"method":"do","pause":"null"},"seq":N}`).
  Future<void> pause() => throw UnimplementedError();

  /// `do play`.
  Future<void> resume() => throw UnimplementedError();

  /// A fresh `get playback` at [utcSeconds] (relay: new slot). Also resumes a
  /// paused playback and restarts after the end of recordings.
  Future<void> seek(int utcSeconds) => throw UnimplementedError();

  /// Applies [speed] client-side (pacing). Throws [ArgumentError] for a speed
  /// outside [kVodSpeeds].
  void setSpeed(String speed) => throw UnimplementedError();
  String get speed => throw UnimplementedError();

  /// `do stop`, linger, close, release the lease.
  Future<void> stop() => throw UnimplementedError();
}
