/// SD-card playback over the local :8800 media port or the cloud relay.
///
/// Plain MPEG-TS goes to ExoPlayer through the RelayBridge; control (pause,
/// resume, seek, speed) and end-of-recordings logic live here.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../media/client_parts.dart';
import '../media/local8800/media_session.dart';
import '../media/media_deps.dart';
import '../media/media_errors.dart';
import '../media/media_source.dart';
import '../media/media_transport.dart';
import '../media/multipart_reader.dart';
import '../media/part_decryptor.dart';
import '../media/preview_stream.dart' show kStreamLimitCodes;
import '../media/relay/relay_slot.dart';
import '../media/relay/relay_tunnel.dart';
import '../media/stream_limiter.dart';
import 'vod_transport.dart';

export 'vod_transport.dart';

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
Duration paceInterval(Duration base, String speed) {
  final index = kVodSpeeds.indexOf(speed);
  if (index < 0) throw ArgumentError.value(speed, 'speed', 'must be one of $kVodSpeeds');
  final factor = int.parse(speed.split('/').first);
  return Duration(microseconds: base.inMicroseconds ~/ factor);
}

/// Relay when the camera is cloud-routed (remote, shared role 1, offline on
/// LAN) and a signed-in relay provider exists; otherwise local :8800. Shared
/// cameras on the LAN still use the relay. When neither works the choice is
/// `none` with a reason. Playback and live view use the same limiter key.
VodTransportChoice selectVodTransport({
  required int role,
  required bool onLan,
  required bool online,
  required bool hasRelayProvider,
}) {
  if (role == 1) {
    if (!hasRelayProvider) return const VodTransportChoice.failed(VodFailReason.sharedCameraCloudOnly);
    if (!online) return const VodTransportChoice.failed(VodFailReason.cameraOffline);
    return const VodTransportChoice.use(VodTransportKind.relay);
  }
  if (onLan) return const VodTransportChoice.use(VodTransportKind.local);
  if (!online) return const VodTransportChoice.failed(VodFailReason.cameraOffline);
  if (hasRelayProvider) return const VodTransportChoice.use(VodTransportKind.relay);
  return const VodTransportChoice.failed(VodFailReason.notOnThisNetwork);
}

enum _End { seek, stop, finished, closed, fatal }

class _Outcome {
  const _Outcome(this.end, {this.error, this.played = false});
  final _End end;
  final Object? error;

  /// The camera accepted the request and sent media.
  final bool played;
}

class VodSession implements MediaSource {
  /// Local :8800 playback (Digest + Key-Exchange like live view).
  VodSession.local({
    required this.host,
    this.port = 8800,
    required LocalMediaAuth this.localAuth,
    required this.connector,
    required this.startUtc,
    required this.endUtc,
    this.limiter,
    this.clips = const [],
    this.stopLinger = const Duration(milliseconds: 150),
  })  : deviceId = null,
        relayAuth = null,
        heartbeatInterval = const Duration(seconds: 15) {
    _resumeAt = startUtc;
  }

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
        localAuth = null,
        relayAuth = auth {
    _resumeAt = startUtc;
  }

  final String? host;
  final int port;
  final String? deviceId;
  final LocalMediaAuth? localAuth;
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

  static const int _ackEvery = 25;
  static const int _maxEarlyParts = 8;
  static const int _maxFailedAttempts = 5;
  static const Duration _backoffInitial = Duration(milliseconds: 500);
  static const Duration _backoffMax = Duration(seconds: 10);

  VodState _state = VodState.idle;
  final StreamController<VodState> _states = StreamController<VodState>.broadcast();
  String? _endReason;
  Object? _failure;
  int? _lastPosition;
  late int _resumeAt;
  String _speed = '1/1';

  StreamController<Uint8List>? _out;
  bool _loopRunning = false;
  bool _stopping = false;
  int _generation = 0;
  StreamLease? _lease;

  _Attempt? _attempt;

  VodState get state => _state;
  Stream<VodState> get states => _states.stream;

  /// `end of recordings` once the last recording is done, else null.
  String? get endReason => _endReason;

  /// Set when [state] is [VodState.failed]: `PlaybackRefusedException`,
  /// `SdCardOfflineException` or a relay error. Fatal: never retried.
  Object? get failure => _failure;

  /// Last position in UTC seconds (from the PtsTimeline in the api lane).
  int? get lastPositionUtc => _lastPosition;
  void reportPosition(int utcSeconds) => _lastPosition = utcSeconds;

  String get speed => _speed;

  /// Applies [speed] client-side (pacing). Throws [ArgumentError] for a speed
  /// outside [kVodSpeeds].
  void setSpeed(String speed) {
    if (!kVodSpeeds.contains(speed)) {
      throw ArgumentError.value(speed, 'speed', 'must be one of $kVodSpeeds');
    }
    _speed = speed;
  }

  void _setState(VodState s) {
    if (_state == s) return;
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  /// Opens the transport, sends `get playback` from [startUtc] to [endUtc]
  /// (see `playbackRequestJson`), forwards video parts only. Acks every 25th
  /// `X-Data-Sequence`. Local connection loss reconnects and sends a new
  /// request at [lastPositionUtc]; a refusal (non-zero error_code) is fatal.
  /// `stream_status: finished` with a later clip starts a new request at that
  /// clip's start; without one the state is stopped with [kEndOfRecordings].
  /// `disk_status: offline` fails with `SdCardOfflineException`. A relay tunnel
  /// that closes at position >= last clip end - 1.5 s is the end of recordings.
  @override
  Stream<Uint8List> openTs() {
    final pending = _out;
    if (pending != null && !pending.isClosed && !pending.hasListener) return pending.stream;
    return _newOut(startOnListen: true).stream;
  }

  StreamController<Uint8List> _newOut({required bool startOnListen}) {
    final gen = ++_generation;
    _stopping = false;
    _endReason = null;
    _failure = null;
    late final StreamController<Uint8List> c;
    c = StreamController<Uint8List>(
      onListen: startOnListen ? () => _startLoop(gen) : null,
      onCancel: () => _onConsumerCancel(gen),
    );
    _out = c;
    return c;
  }

  void _onConsumerCancel(int gen) {
    if (gen != _generation) return;
    unawaited(stop());
  }

  void _startLoop(int gen) {
    if (_loopRunning) return;
    _loopRunning = true;
    unawaited(_loop(gen).whenComplete(() => _loopRunning = false));
  }

  Future<void> _loop(int gen) async {
    var backoff = _backoffInitial;
    var failedAttempts = 0;
    try {
      final lim = limiter;
      if (lim != null) {
        try {
          _lease = await lim.acquire(deviceId ?? host ?? '');
        } catch (e) {
          _fail(gen, e);
          return;
        }
        if (gen != _generation || _stopping) {
          _releaseLease();
          return;
        }
      }
      while (gen == _generation && !_stopping) {
        if (_resumeAt >= endUtc) {
          _finishRecordings(gen);
          return;
        }
        final outcome = await _runAttempt(gen);
        if (gen != _generation || _stopping) return;
        switch (outcome.end) {
          case _End.stop:
            return;
          case _End.seek:
            backoff = _backoffInitial;
            failedAttempts = 0;
            continue;
          case _End.fatal:
            _fail(gen, outcome.error ?? const MediaException('playback failed'));
            return;
          case _End.finished:
            final position = _lastPosition ?? _resumeAt;
            final next = _nextClipStart(position);
            if (next != null && next < endUtc && next > _resumeAt) {
              _resumeAt = next;
              _lastPosition = null;
              continue;
            }
            _finishRecordings(gen);
            return;
          case _End.closed:
            final position = _lastPosition ?? _resumeAt;
            if (clips.isNotEmpty && position * 1000 >= clips.last.end * 1000 - 1500) {
              _finishRecordings(gen);
              return;
            }
            if (outcome.played) {
              backoff = _backoffInitial;
              failedAttempts = 0;
            } else {
              failedAttempts++;
              if (failedAttempts >= _maxFailedAttempts) {
                _fail(gen, outcome.error ?? const MediaException('camera closed the media connection'));
                return;
              }
            }
            if (_lastPosition != null) _resumeAt = _lastPosition!;
            _setState(VodState.connecting);
            await Future<void>.delayed(backoff);
            backoff = backoff * 2 > _backoffMax ? _backoffMax : backoff * 2;
        }
      }
    } catch (e) {
      if (gen == _generation && !_stopping) _fail(gen, e);
    }
  }

  int? _nextClipStart(int position) {
    for (final c in clips) {
      if (c.start > position) return c.start;
    }
    return null;
  }

  void _finishRecordings(int gen) {
    if (gen != _generation) return;
    _endReason = kEndOfRecordings;
    _releaseLease();
    _setState(VodState.stopped);
    final out = _out;
    if (out != null && !out.isClosed) unawaited(out.close());
  }

  void _fail(int gen, Object error) {
    if (gen != _generation) return;
    _failure = error;
    _releaseLease();
    _setState(VodState.failed);
    final out = _out;
    if (out != null && !out.isClosed) {
      out.addError(error);
      unawaited(out.close());
    }
  }

  void _releaseLease() {
    _lease?.release();
    _lease = null;
  }

  bool _isFatal(Object e) =>
      e is MediaAuthException ||
      e is StreamLimitException ||
      e is StreamRefusedException ||
      e is PlaybackRefusedException ||
      e is SdCardOfflineException ||
      e is EncryptedRelayMediaException ||
      (e is RelayException && e.fatal);

  Future<MediaSession> _open() async {
    final relay = relayAuth;
    if (relay == null) {
      return MediaSession.connect(host: host!, port: port, auth: localAuth!, connector: connector);
    }
    final slot = await RelaySlotClient(relay).requestSlot(deviceId!, streamType: kRelayPlayback, cloudType: 2);
    final tunnel = await RelayTunnel.open(
      slot,
      connector: connector,
      clientModel: relay.clientModel,
      terminalUuid: relay.terminalUuid,
      appVersion: relay.appVersion,
    );
    return MediaSession.overTunnel(tunnel.transport, tunnel.input, decryptor: const PassthroughDecryptor());
  }

  Future<_Outcome> _runAttempt(int gen) async {
    _setState(VodState.connecting);
    final attempt = _Attempt(this, gen);
    _attempt = attempt;
    try {
      return await attempt.run();
    } finally {
      if (identical(_attempt, attempt)) _attempt = null;
    }
  }

  /// `do pause` (`{"type":"request","params":{"method":"do","pause":"null"},"seq":N}`).
  Future<void> pause() async {
    await _control('pause');
    if (_state == VodState.playing) _setState(VodState.paused);
  }

  /// `do play`.
  Future<void> resume() async {
    await _control('play');
    if (_state == VodState.paused) _setState(VodState.playing);
  }

  Future<void> _control(String verb) async {
    final s = _attempt?.session;
    if (s == null || s.sessionId == null) return;
    try {
      await s.sendJson('{"type":"request","params":{"method":"do","$verb":"null"}}');
    } catch (_) {}
  }

  /// A fresh `get playback` at [utcSeconds] (relay: new slot). Also resumes a
  /// paused playback and restarts after the end of recordings.
  Future<void> seek(int utcSeconds) async {
    _resumeAt = utcSeconds;
    _lastPosition = utcSeconds;
    final attempt = _attempt;
    if (attempt != null && !_stopping) {
      attempt.interrupt(_End.seek);
      return;
    }
    // After the end of recordings or a failure: start again. The player
    // re-requests the bridge URL and receives this new stream.
    if (_loopRunning && !_stopping) return;
    if (_state == VodState.stopped || _state == VodState.failed || _state == VodState.idle) {
      final c = _newOut(startOnListen: false);
      _resumeAt = utcSeconds;
      _setState(VodState.connecting);
      _startLoop(_generation);
      // The controller buffers until the player attaches.
      if (c.isClosed) return;
    }
  }

  /// `do stop`, linger, close, release the lease.
  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;
    final attempt = _attempt;
    if (attempt != null) {
      attempt.interrupt(_End.stop);
      await attempt.finished;
    }
    _releaseLease();
    _setState(_state == VodState.failed ? VodState.failed : VodState.stopped);
    final out = _out;
    if (out != null && !out.isClosed) unawaited(out.close());
  }
}

class _Attempt {
  _Attempt(this.owner, this.gen);

  final VodSession owner;
  final int gen;
  MediaSession? session;
  Timer? _heartbeat;
  StreamSubscription<MultipartPart>? _sub;
  final Completer<_Outcome> _done = Completer<_Outcome>();
  final Completer<void> _cleaned = Completer<void>();
  final List<Uint8List> _early = [];
  bool _accepted = false;
  bool _mediaSeen = false;
  bool _finishedFlag = false;
  int _seq = 0;
  _End? _interrupt;

  Future<void> get finished => _cleaned.future;

  void interrupt(_End why) {
    _interrupt ??= why;
    _complete(_Outcome(why));
  }

  void _complete(_Outcome o) {
    if (!_done.isCompleted) _done.complete(o);
  }

  Future<_Outcome> run() async {
    _Outcome outcome;
    try {
      outcome = await _body();
    } catch (e) {
      outcome = _Outcome(owner._isFatal(e) ? _End.fatal : _End.closed, error: e);
    }
    await _cleanup();
    if (!_cleaned.isCompleted) _cleaned.complete();
    return outcome;
  }

  Future<_Outcome> _body() async {
    final s = await owner._open();
    session = s;
    if (_interrupt != null || owner._stopping || gen != owner._generation) {
      return _Outcome(_interrupt ?? _End.stop);
    }
    if (owner.relayAuth != null) {
      _heartbeat = Timer.periodic(owner.heartbeatInterval, (_) => s.sendRaw(s.heartbeatPart()));
    }
    _sub = s.parts.listen(_onPart, onError: (Object e) {
      _complete(_Outcome(owner._isFatal(e) ? _End.fatal : _End.closed, error: e, played: _mediaSeen));
    }, onDone: () {
      _complete(_Outcome(_finishedFlag ? _End.finished : _End.closed, played: _mediaSeen));
    });
    final start = owner._resumeAt < 1 ? 1 : owner._resumeAt;
    _seq = s.nextSeq();
    await s.sendJson(playbackRequestJson(start, owner.endUtc < start ? start : owner.endUtc, seq: _seq));
    return _done.future;
  }

  void _onPart(MultipartPart part) {
    if (_done.isCompleted) return;
    if (part.isJson) {
      _onJson(part);
      return;
    }
    if (!part.isVideo || part.body.isEmpty) return;
    if (!_accepted) {
      if (_early.length < VodSession._maxEarlyParts) _early.add(part.body);
      return;
    }
    _forward(part.body, part);
  }

  void _forward(Uint8List body, MultipartPart part) {
    final out = owner._out;
    if (out == null || out.isClosed) return;
    _mediaSeen = true;
    out.add(body);
    final seq = int.tryParse(part.header('X-Data-Sequence') ?? '');
    final s = session;
    if (seq != null && seq != 0 && seq % VodSession._ackEvery == 0 && s != null && s.sessionId != null) {
      s.sendRaw(s.ackPart(seq));
    }
  }

  void _onJson(MultipartPart part) {
    Map<String, dynamic>? msg;
    try {
      final v = jsonDecode(utf8.decode(part.body));
      if (v is Map<String, dynamic>) msg = v;
    } catch (_) {}
    if (msg == null) return;
    final type = msg['type'];
    if (type == 'response' && !_accepted && (msg['seq'] == _seq || msg['seq'] == null)) {
      final result = msg['result'] is Map ? msg['result'] as Map : const {};
      final code = result['error_code'] ?? 0;
      if (code is int && code != 0) {
        if (kStreamLimitCodes.contains(code)) {
          _complete(_Outcome(_End.fatal,
              error: StreamLimitException('stream limit reached: camera refused playback ($code)', errorCode: code)));
          return;
        }
        final start = owner._resumeAt;
        if (owner.clips.isNotEmpty && !owner.clips.any((c) => c.end > start + 1)) {
          _complete(const _Outcome(_End.finished));
          return;
        }
        _complete(_Outcome(_End.fatal,
            error: PlaybackRefusedException('camera refused the playback (error_code $code)', errorCode: code)));
        return;
      }
      _accepted = true;
      if (owner._state != VodState.paused) owner._setState(VodState.playing);
      for (final b in _early) {
        final out = owner._out;
        if (out == null || out.isClosed) break;
        _mediaSeen = true;
        out.add(b);
      }
      _early.clear();
      return;
    }
    if (type == 'notification') {
      final params = msg['params'] is Map ? msg['params'] as Map : const {};
      final event = params['event_type'];
      if (event == 'stream_status' && params['status'] == 'finished') {
        _finishedFlag = true;
        _complete(const _Outcome(_End.finished));
      } else if (event == 'disk_status' && params['status'] == 'offline') {
        _complete(const _Outcome(_End.fatal, error: SdCardOfflineException()));
      }
    } else if (type == 'error') {
      final code = msg['error_code'];
      if (code is int && kStreamLimitCodes.contains(code)) {
        _complete(_Outcome(_End.fatal, error: StreamLimitException('stream limit reached: camera error $code', errorCode: code)));
      } else {
        _complete(_Outcome(_End.closed, error: MediaException('camera error $code')));
      }
    }
  }

  Future<void> _cleanup() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    final s = session;
    final polite = s != null && _interrupt != null && s.sessionId != null;
    // Windows order: stop request, linger, close. Keep reading until the stop
    // is out: cancelling a (TLS) socket's input first may drop the stop.
    if (polite) {
      try {
        await s.sendJson(stopRequestJson(s.nextSeq()));
        await s.flush();
        await Future<void>.delayed(owner.stopLinger);
      } catch (_) {}
    }
    final sub = _sub;
    _sub = null;
    unawaited(sub?.cancel());
    if (s == null) return;
    unawaited(s.close().catchError((Object _) {}));
  }
}
