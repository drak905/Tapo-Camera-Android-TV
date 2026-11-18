import 'dart:async';
import 'dart:typed_data';

import 'media_source.dart';

/// Placeholder, see test/media/http_ts_source_test.dart.
class HttpTsSource implements MediaSource {
  HttpTsSource(this.url);
  final Uri url;

  @override
  Stream<Uint8List> openTs() => throw UnimplementedError();
}
