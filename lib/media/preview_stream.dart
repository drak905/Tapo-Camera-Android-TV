/// The preview flow shared by the local :8800 and relay sources: open a
/// session, send the preview request, wait for its response, then forward
/// video parts as plain TS with flow-control acks, and stop politely.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'client_parts.dart';
import 'local8800/media_session.dart';
import 'media_errors.dart';
import 'multipart_reader.dart';
import 'stream_limiter.dart';

/// Error codes of a refused preview / playback request that mean "this camera
/// allows no further session". Fatal.
const Set<int> kStreamLimitCodes = {-52407, -52405, -52419, -52435};

/// Notifications after which the camera ends the stream on this connection.
const Set<String> kEndEvents = {'connection_closed', 'stream_finish', 'device_locked', 'internal_error'};

/// Runs one stream. Create with [PreviewStream.open]; the returned stream
/// starts the flow on listen and ends it (stop request, linger, close) on cancel.
class PreviewStream {
  PreviewStream._({
    required this.openSession,
    required this.requestBody,
    required this.limiter,
    required this.limiterKey,
    required this.startGate,
    required this.stopLinger,
    required this.ackEvery,
    this.onSession,
    this.onSessionEnd,
  });

  /// Opens the connection (digest handshake or relay slot + tunnel).
  final Future<MediaSession> Function() openSession;

  /// Builds the first JSON request for the sequence number the session hands out.
  final String Function(int seq) requestBody;
  final StreamLimiter? limiter;
  final String limiterKey;
  final Future<void>? startGate;
  final Duration stopLinger;
  final int ackEvery;

  /// Called once the session is open (relay: starts the heartbeat).
  final void Function(MediaSession session)? onSession;

  /// Called when the stream ends, before the socket closes.
  final void Function()? onSessionEnd;

  late final StreamController<Uint8List> _out;
  MediaSession? session;
  StreamLease? _lease;
  StreamSubscription<MultipartPart>? _sub;
  bool _cancelled = false;
  bool _finished = false;
  bool _accepted = false;
  int _seq = 0;
  final List<Uint8List> _early = [];
  Future<void>? _stopFuture;

  static Stream<Uint8List> open({
    required Future<MediaSession> Function() openSession,
    required String Function(int seq) requestBody,
    StreamLimiter? limiter,
    required String limiterKey,
    Future<void>? startGate,
    Duration stopLinger = const Duration(milliseconds: 150),
    int ackEvery = 25,
    void Function(MediaSession session)? onSession,
    void Function()? onSessionEnd,
    void Function(PreviewStream run)? onCreate,
  }) {
    final run = PreviewStream._(
      openSession: openSession,
      requestBody: requestBody,
      limiter: limiter,
      limiterKey: limiterKey,
      startGate: startGate,
      stopLinger: stopLinger,
      ackEvery: ackEvery,
      onSession: onSession,
      onSessionEnd: onSessionEnd,
    );
    onCreate?.call(run);
    run._out = StreamController<Uint8List>(
      onListen: run._start,
      onCancel: run._stop,
    );
    return run._out.stream;
  }

  Future<void> _start() async {
    try {
      if (startGate != null) await startGate;
      if (_cancelled) return;
      if (limiter != null) {
        _lease = await limiter!.acquire(limiterKey);
        if (_cancelled) {
          _releaseLease();
          return;
        }
      }
      final s = await openSession();
      if (_cancelled) {
        await s.close();
        _releaseLease();
        return;
      }
      session = s;
      onSession?.call(s);
      _sub = s.parts.listen(_onPart, onError: _fail, onDone: _onDone);
      _seq = s.nextSeq();
      await s.sendJson(requestBody(_seq));
    } catch (e) {
      await _fail(e);
    }
  }

  void _onPart(MultipartPart part) {
    if (_finished || _cancelled) return;
    if (part.isJson) {
      _onJson(part);
      return;
    }
    if (!part.isVideo || part.body.isEmpty) return;
    if (!_accepted) {
      if (_early.length < 8) _early.add(part.body);
      return;
    }
    _forward(part);
  }

  void _forward(MultipartPart part) {
    _out.add(part.body);
    final seq = int.tryParse(part.header('X-Data-Sequence') ?? '');
    final s = session;
    if (seq != null && seq != 0 && seq % ackEvery == 0 && s != null && s.sessionId != null) {
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
    if (!_accepted) {
      if (type == 'response' && (msg['seq'] == _seq || msg['seq'] == null)) {
        final result = msg['result'] is Map ? msg['result'] as Map : const {};
        final code = result['error_code'] ?? 0;
        if (code is int && code != 0) {
          if (kStreamLimitCodes.contains(code)) {
            _fail(StreamLimitException('stream limit reached: camera refused the request ($code)', errorCode: code));
          } else {
            _fail(StreamRefusedException('camera refused the stream request ($code)', errorCode: code));
          }
          return;
        }
        _accepted = true;
        for (final b in _early) {
          if (_finished) return;
          _out.add(b);
        }
        _early.clear();
        return;
      }
    }
    if (type == 'notification') {
      final params = msg['params'] is Map ? msg['params'] as Map : const {};
      final event = params['event_type'];
      if (kEndEvents.contains(event)) {
        _fail(MediaException('camera ended the stream ($event)'));
      }
    } else if (type == 'error') {
      final code = msg['error_code'];
      if (code is int && kStreamLimitCodes.contains(code)) {
        _fail(StreamLimitException('stream limit reached: camera error $code', errorCode: code));
      } else {
        _fail(MediaException('camera error $code'));
      }
    }
  }

  void _onDone() {
    if (_finished) return;
    if (!_accepted) {
      _fail(const MediaException('camera closed the media connection'));
    } else {
      _fail(null);
    }
  }

  /// Ends the stream; [error] null closes it normally.
  Future<void> _fail(Object? error) async {
    if (_finished) return;
    _finished = true;
    _early.clear();
    final sub = _sub;
    _sub = null;
    unawaited(sub?.cancel());
    onSessionEnd?.call();
    _releaseLease();
    final closing = session?.close();
    if (!_out.isClosed) {
      if (error != null) _out.addError(error);
      unawaited(_out.close());
    }
    await closing;
  }

  Future<void> _stop() => _stopFuture ??= _doStop();

  Future<void> _doStop() async {
    _cancelled = true;
    if (_finished) return;
    _finished = true;
    final sub = _sub;
    _sub = null;
    unawaited(sub?.cancel());
    onSessionEnd?.call();
    final s = session;
    if (s != null) {
      if (s.sessionId != null) {
        try {
          await s.sendJson(stopRequestJson(s.nextSeq()));
          await Future<void>.delayed(stopLinger);
        } catch (_) {}
      }
      _releaseLease();
      await s.close();
    }
    _releaseLease();
  }
  void _releaseLease() {
    _lease?.release();
    _lease = null;
  }
}
