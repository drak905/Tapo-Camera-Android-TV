/// Reads an HTTP response head from a transport without consuming bytes that
/// belong to the body or the tunnel after it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'media_errors.dart';

class HttpHead {
  const HttpHead(this.status, this.reason, this.headers);
  final int status;
  final String reason;

  /// Lower-case names.
  final Map<String, String> headers;

  int get contentLength => int.tryParse(headers['content-length'] ?? '') ?? 0;
}

class HeadReader {
  HeadReader(Stream<Uint8List> input, {this.maxHeadBytes = 16 * 1024}) {
    _sub = input.listen(_onData, onError: _onError, onDone: _onDone);
  }

  final int maxHeadBytes;
  late final StreamSubscription<Uint8List> _sub;
  Uint8List _buf = Uint8List(0);
  bool _done = false;
  Object? _error;
  Completer<void>? _wake;
  StreamController<Uint8List>? _rest;

  void _onData(Uint8List data) {
    final rest = _rest;
    if (rest != null) {
      if (!rest.isClosed) rest.add(data);
      return;
    }
    _buf = Uint8List.fromList([..._buf, ...data]);
    _notify();
  }

  void _onError(Object e, StackTrace s) {
    final rest = _rest;
    if (rest != null) {
      if (!rest.isClosed) rest.addError(e, s);
      return;
    }
    _error = e;
    _notify();
  }

  void _onDone() {
    _done = true;
    final rest = _rest;
    if (rest != null) {
      if (!rest.isClosed) rest.close();
      return;
    }
    _notify();
  }

  void _notify() {
    final w = _wake;
    _wake = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> _waitMore(Duration timeout) async {
    final w = _wake = Completer<void>();
    try {
      await w.future.timeout(timeout);
    } on TimeoutException {
      _wake = null;
      throw const MediaException('timed out waiting for the peer');
    }
  }

  static int _indexOfCrlfCrlf(Uint8List b) {
    for (var i = 0; i + 3 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) return i;
    }
    return -1;
  }

  /// Reads the status line and headers. The body is not read.
  Future<HttpHead> readHead({Duration timeout = const Duration(seconds: 10)}) async {
    while (true) {
      final end = _indexOfCrlfCrlf(_buf);
      if (end >= 0) {
        final text = latin1.decode(Uint8List.sublistView(_buf, 0, end));
        _buf = Uint8List.sublistView(_buf, end + 4);
        return _parse(text);
      }
      if (_buf.length > maxHeadBytes) throw const MediaException('response head too large');
      if (_error != null) throw MediaException('connection error: ${_error.runtimeType}');
      if (_done) throw const MediaException('connection closed by the peer');
      await _waitMore(timeout);
    }
  }

  /// Reads exactly [n] body bytes (n capped by the caller).
  Future<Uint8List> readBytes(int n, {Duration timeout = const Duration(seconds: 10)}) async {
    while (_buf.length < n) {
      if (_error != null || _done) break;
      await _waitMore(timeout);
    }
    final take = n < _buf.length ? n : _buf.length;
    final out = Uint8List.fromList(Uint8List.sublistView(_buf, 0, take));
    _buf = Uint8List.sublistView(_buf, take);
    return out;
  }

  /// Everything after what was read so far, as a single-subscription stream.
  /// Cancelling it cancels the transport subscription.
  Stream<Uint8List> takeRest() {
    final c = StreamController<Uint8List>(
      onPause: () => _sub.pause(),
      onResume: () => _sub.resume(),
      onCancel: () => _sub.cancel(),
    );
    _rest = c;
    if (_buf.isNotEmpty) c.add(_buf);
    _buf = Uint8List(0);
    if (_error != null) {
      c.addError(MediaException('connection error: ${_error.runtimeType}'));
    }
    if (_done) c.close();
    return c.stream;
  }

  Future<void> dispose() => _sub.cancel();

  static HttpHead _parse(String text) {
    final lines = text.split('\r\n');
    final status = lines.first.split(' ');
    if (status.length < 2 || !status[0].startsWith('HTTP/') || int.tryParse(status[1]) == null) {
      throw const MediaException('malformed HTTP status line');
    }
    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      final i = line.indexOf(':');
      if (i > 0) headers[line.substring(0, i).trim().toLowerCase()] = line.substring(i + 1).trim();
    }
    return HttpHead(int.parse(status[1]), status.skip(2).join(' '), headers);
  }
}
