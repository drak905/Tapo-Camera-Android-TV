/// Stateful multipart reader shared by the local :8800 and relay sources.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'media_errors.dart';

/// One part: headers (latin-1) and exactly Content-Length body bytes.
class MultipartPart {
  const MultipartPart(this.headers, this.body);

  /// Header names as sent; look up with [header] (case-insensitive).
  final Map<String, String> headers;
  final Uint8List body;

  String? header(String name) {
    final lower = name.toLowerCase();
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == lower) return e.value;
    }
    return null;
  }

  /// Content-Type without parameters, lower case (null when absent).
  String? get contentType {
    final v = header('Content-Type');
    if (v == null) return null;
    return v.split(';').first.trim().toLowerCase();
  }

  /// `video/mp2t`.
  bool get isVideo => contentType == 'video/mp2t';
  bool get isJson => (contentType ?? '').contains('json');
  bool get isAudio => (contentType ?? '').startsWith('audio/');
}

enum _State { seekDelimiter, headers, body }

/// Parses the device stream: lines are skipped until one equals the delimiter
/// `--` + `--device-stream-boundary--`; then headers up to CRLFCRLF (cap
/// 64 KiB), a numeric Content-Length (max part 16 MiB) and exactly that many
/// body bytes. Blank, junk and closing lines between parts are ignored.
class MultipartReader {
  MultipartReader({
    this.delimiter = '----device-stream-boundary--',
    this.maxPartBytes = 16 * 1024 * 1024,
    this.maxHeaderBytes = 64 * 1024,
  });

  final String delimiter;
  final int maxPartBytes;
  final int maxHeaderBytes;

  Uint8List _buf = Uint8List(4096);
  int _start = 0;
  int _end = 0;
  _State _state = _State.seekDelimiter;
  Map<String, String> _headers = {};
  int _bodyLength = 0;

  /// Feeds raw bytes (any chunking) and returns the parts completed by them.
  /// Throws [MultipartFormatException] for a missing, negative or oversized
  /// Content-Length.
  List<MultipartPart> add(List<int> chunk) {
    _append(chunk);
    final out = <MultipartPart>[];
    while (true) {
      if (_state == _State.seekDelimiter) {
        if (!_seekDelimiter()) break;
        _state = _State.headers;
      }
      if (_state == _State.headers) {
        if (!_readHeaders()) break;
        _state = _State.body;
      }
      if (_state == _State.body) {
        if (_end - _start < _bodyLength) break;
        final body = Uint8List.fromList(Uint8List.sublistView(_buf, _start, _start + _bodyLength));
        _start += _bodyLength;
        out.add(MultipartPart(_headers, body));
        _headers = {};
        _state = _State.seekDelimiter;
      }
    }
    return out;
  }

  /// Same as [add] for a byte stream.
  Stream<MultipartPart> bind(Stream<List<int>> input) async* {
    await for (final chunk in input) {
      for (final p in add(chunk)) {
        yield p;
      }
    }
  }

  void _append(List<int> chunk) {
    if (_start > 0 && _start == _end) {
      _start = 0;
      _end = 0;
    }
    final needed = _end + chunk.length;
    if (needed > _buf.length) {
      final live = _end - _start;
      final size = live + chunk.length;
      if (_start > 0 && size <= _buf.length) {
        _buf.setRange(0, live, _buf, _start);
      } else {
        var cap = _buf.length;
        while (cap < size) {
          cap *= 2;
        }
        final next = Uint8List(cap);
        next.setRange(0, live, _buf, _start);
        _buf = next;
      }
      _start = 0;
      _end = live;
    }
    _buf.setRange(_end, _end + chunk.length, chunk);
    _end += chunk.length;
  }

  bool _seekDelimiter() {
    while (true) {
      var nl = -1;
      for (var i = _start; i < _end; i++) {
        if (_buf[i] == 10) {
          nl = i;
          break;
        }
      }
      if (nl < 0) {
        // Drop an endless junk line instead of buffering it.
        if (_end - _start > maxHeaderBytes) _start = _end;
        return false;
      }
      var lineEnd = nl;
      if (lineEnd > _start && _buf[lineEnd - 1] == 13) lineEnd--;
      final line = latin1.decode(Uint8List.sublistView(_buf, _start, lineEnd));
      _start = nl + 1;
      if (line == delimiter) return true;
    }
  }

  bool _readHeaders() {
    var term = -1;
    for (var i = _start; i + 1 < _end; i++) {
      if (_buf[i] == 13 && _buf[i + 1] == 10) {
        // Empty header block: the line right after the delimiter is blank.
        if (i == _start) {
          term = i;
          break;
        }
        if (i + 3 < _end + 0 && _buf[i + 2] == 13 && _buf[i + 3] == 10) {
          term = i;
          break;
        }
      }
    }
    if (term < 0) {
      if (_end - _start > maxHeaderBytes) {
        throw const MultipartFormatException('multipart header block too large');
      }
      return false;
    }
    final blockEnd = term == _start ? _start : term;
    final text = latin1.decode(Uint8List.sublistView(_buf, _start, blockEnd));
    _start = term == _start ? term + 2 : term + 4;
    if (text.length > maxHeaderBytes) {
      throw const MultipartFormatException('multipart header block too large');
    }
    final headers = <String, String>{};
    for (final line in text.split('\r\n')) {
      if (line.isEmpty) continue;
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      headers[line.substring(0, colon).trim()] = line.substring(colon + 1).trim();
    }
    String? cl;
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == 'content-length') cl = e.value;
    }
    if (cl == null) {
      throw const MultipartFormatException('multipart part without Content-Length');
    }
    final n = int.tryParse(cl);
    if (n == null || n < 0) {
      throw MultipartFormatException('invalid Content-Length');
    }
    if (n > maxPartBytes) {
      throw MultipartFormatException('part larger than $maxPartBytes bytes');
    }
    _headers = headers;
    _bodyLength = n;
    return true;
  }
}

/// Only the bodies of `video/mp2t` parts; JSON control parts and audio are
/// never emitted as video.
Stream<Uint8List> videoBytes(Stream<MultipartPart> parts) async* {
  await for (final p in parts) {
    if (p.isVideo) yield p.body;
  }
}
