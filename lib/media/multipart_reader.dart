/// Stateful multipart reader shared by the local :8800 and relay sources.
library;

import 'dart:typed_data';

/// One part: headers (latin-1) and exactly Content-Length body bytes.
class MultipartPart {
  const MultipartPart(this.headers, this.body);

  /// Header names as sent; look up with [header] (case-insensitive).
  final Map<String, String> headers;
  final Uint8List body;

  String? header(String name) => throw UnimplementedError();

  /// Content-Type without parameters, lower case (null when absent).
  String? get contentType => throw UnimplementedError();

  /// `video/mp2t`.
  bool get isVideo => throw UnimplementedError();
  bool get isJson => throw UnimplementedError();
  bool get isAudio => throw UnimplementedError();
}

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

  /// Feeds raw bytes (any chunking) and returns the parts completed by them.
  /// Throws [MultipartFormatException] for a missing, negative or oversized
  /// Content-Length.
  List<MultipartPart> add(List<int> chunk) => throw UnimplementedError();

  /// Same as [add] for a byte stream.
  Stream<MultipartPart> bind(Stream<List<int>> input) => throw UnimplementedError();
}

/// Only the bodies of `video/mp2t` parts; JSON control parts and audio are
/// never emitted as video.
Stream<Uint8List> videoBytes(Stream<MultipartPart> parts) => throw UnimplementedError();
