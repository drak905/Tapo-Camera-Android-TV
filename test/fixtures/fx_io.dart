// Small async socket helpers shared by the TCP / TLS fixtures.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Buffered reader over a byte stream (a Socket or SecureSocket).
/// All reads return null once the peer closed and the buffer is exhausted.
class ByteReader {
  ByteReader(Stream<List<int>> stream) {
    _sub = stream.listen((d) {
      _buf = _buf.isEmpty
          ? Uint8List.fromList(d)
          : (Uint8List(_buf.length + d.length)
            ..setRange(0, _buf.length, _buf)
            ..setRange(_buf.length, _buf.length + d.length, d));
      _wake();
    }, onDone: () {
      eof = true;
      _wake();
    }, onError: (Object _) {
      eof = true;
      _wake();
    }, cancelOnError: true);
  }

  late final StreamSubscription<List<int>> _sub;
  Uint8List _buf = Uint8List(0);
  Completer<void>? _waiter;
  bool eof = false;

  int get buffered => _buf.length;

  void _wake() {
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<bool> _more() async {
    if (eof) return false;
    _waiter = Completer<void>();
    await _waiter!.future;
    return true;
  }

  Future<Uint8List?> readExact(int n) async {
    while (_buf.length < n) {
      if (!await _more() && _buf.length < n) return null;
    }
    final out = Uint8List.sublistView(_buf, 0, n);
    _buf = Uint8List.sublistView(_buf, n);
    return Uint8List.fromList(out);
  }

  /// A line without its CRLF (a bare LF also terminates). Latin-1 decoded.
  Future<String?> readLine({int maxLen = 65536}) async {
    var from = 0;
    while (true) {
      final i = _buf.indexOf(10, from);
      if (i >= 0) {
        var end = i;
        if (end > 0 && _buf[end - 1] == 13) end--;
        final line = latin1.decode(_buf.sublist(0, end));
        _buf = Uint8List.sublistView(_buf, i + 1);
        return line;
      }
      if (_buf.length > maxLen) return null;
      from = _buf.length;
      if (!await _more()) {
        if (!_buf.contains(10)) return null;
      }
    }
  }

  /// Header block up to the blank line, names lower-cased, in a map.
  Future<Map<String, String>?> readHeaders() async {
    final h = <String, String>{};
    while (true) {
      final ln = await readLine();
      if (ln == null) return null;
      if (ln.isEmpty) return h;
      final k = ln.indexOf(':');
      if (k > 0) h[ln.substring(0, k).trim().toLowerCase()] = ln.substring(k + 1).trim();
    }
  }

  Future<void> cancel() => _sub.cancel();
}

/// Polls [cond] every [every] until it is true; returns false on [timeout].
Future<bool> waitFor(bool Function() cond,
    {Duration timeout = const Duration(seconds: 5),
    Duration every = const Duration(milliseconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) return false;
    await Future<void>.delayed(every);
  }
  return true;
}

/// Closes a socket without throwing.
Future<void> quietClose(Socket s) async {
  try {
    await s.close();
  } catch (_) {
    s.destroy();
  }
}
