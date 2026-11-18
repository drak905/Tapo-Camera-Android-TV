// In-test camera for the secure v3 / legacy MD5 login and the encrypted /ds
// channel. Written independently of lib/api/local_crypto.dart (package:crypto
// and pointycastle only). Never talks to a network.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tapo_tv/api/camera_transport.dart';

import 'helpers.dart';

enum FakeCameraMode {
  /// encrypt_type 3: -40413 challenge, digest, encrypted /ds.
  v3,

  /// Old firmware: step 1 answers -40210, then MD5 login, plain JSON.
  legacy,

  /// Newer firmware: step 1 answers -40211 (TPAP required).
  tpap,
}

class FakeV3Camera implements CameraChannel {
  FakeV3Camera({required this.secret, this.mode = FakeCameraMode.v3, this.nonce = '0123456789ABCDEF'});

  /// The password (or LAT) the camera knows.
  String secret;
  FakeCameraMode mode;
  final String nonce;

  bool locked = false;

  /// HTTP status for login posts (200 normally).
  int loginHttpStatus = 200;

  /// The next N /ds requests answer every item with -40401 (session expired).
  int invalidateNext = 0;

  /// The next N /ds requests fail with a socket error.
  int throwOnNext = 0;

  final List<String> loginBodies = [];
  final List<int> seqs = [];
  int stepOneCount = 0;
  int digestAttempts = 0;
  int loginSuccesses = 0;
  final List<Map<String, dynamic>> received = [];

  String _cnonce = '';
  String _stok = '';
  int startSeq = 1234;

  String get _firstHash =>
      sha256UpperRef(_cnonce + sha256UpperRef(secret) + nonce);

  Uint8List _key(String tag) => Uint8List.fromList(
      sha256Raw(utf8.encode('$tag$_cnonce$nonce$_firstHash')).sublist(0, 16));

  ChannelResponse _json(Object body, [int status = 200]) =>
      ChannelResponse(status, Uint8List.fromList(utf8.encode(jsonEncode(body))));

  @override
  Future<ChannelResponse> post(
    String path,
    List<int> body, {
    Map<String, String> headers = const {},
  }) async {
    final text = utf8.decode(body);
    if (path == '/') return _login(text);
    return _ds(path, text, headers);
  }

  ChannelResponse _login(String text) {
    loginBodies.add(text);
    if (loginHttpStatus != 200) return _json({}, loginHttpStatus);
    final params = (jsonDecode(text) as Map)['params'] as Map;
    if (locked) {
      return _json({
        'error_code': -40404,
        'result': {'data': {'sec_left': 300}},
      });
    }
    if (params['sub_method'] != null) return _json({'error_code': -40101});
    if (params['hashed'] == true) {
      if (mode == FakeCameraMode.legacy && params['password'] == md5UpperRef(secret)) {
        _stok = 'stok-legacy';
        loginSuccesses++;
        return _json({'error_code': 0, 'result': {'stok': _stok}});
      }
      return _json({'error_code': -40401});
    }
    if (params['digest_passwd'] == null) {
      stepOneCount++;
      switch (mode) {
        case FakeCameraMode.legacy:
          return _json({'error_code': -40210});
        case FakeCameraMode.tpap:
          return _json({'error_code': -40211});
        case FakeCameraMode.v3:
          _cnonce = '${params['cnonce']}';
          return _json({
            'error_code': -40413,
            'result': {
              'data': {
                'code': -40413,
                'encrypt_type': ['3'],
                'nonce': nonce,
                'device_confirm': '$_firstHash$nonce$_cnonce',
              },
            },
          });
      }
    }
    digestAttempts++;
    final expected = sha256UpperRef(sha256UpperRef(secret) + _cnonce + nonce) + _cnonce + nonce;
    if (params['digest_passwd'] != expected) return _json({'error_code': -40401});
    _stok = 'stok-v3-$loginSuccesses';
    loginSuccesses++;
    return _json({
      'error_code': 0,
      'result': {'stok': _stok, 'start_seq': startSeq},
    });
  }

  ChannelResponse _ds(String path, String text, Map<String, String> headers) {
    if (throwOnNext > 0) {
      throwOnNext--;
      throw const SocketException('connection reset');
    }
    if (mode == FakeCameraMode.legacy) {
      final inner = jsonDecode(text) as Map<String, dynamic>;
      received.add(inner);
      return _json(_answer(inner));
    }
    final seq = int.parse(headers['seq'] ?? '-1');
    seqs.add(seq);
    final tagPrefix = sha256UpperRef(sha256UpperRef(secret) + _cnonce);
    final expectedTag = sha256UpperRef('$tagPrefix$text$seq');
    if (headers['tapo_tag'] != expectedTag || path != '/stok=$_stok/ds') {
      return _json({'error_code': -40401});
    }
    final outer = jsonDecode(text) as Map<String, dynamic>;
    final b64 = ((outer['params'] as Map)['request']) as String;
    final inner = jsonDecode(utf8.decode(
      aesCbc(false, _key('lsk'), _key('ivb'), Uint8List.fromList(base64.decode(b64))),
    )) as Map<String, dynamic>;
    received.add(inner);
    final answer = _answer(inner);
    final enc = aesCbc(
      true,
      _key('lsk'),
      _key('ivb'),
      Uint8List.fromList(utf8.encode(jsonEncode(answer))),
    );
    return _json({
      'error_code': 0,
      'result': {'response': base64.encode(enc)},
    });
  }

  Map<String, dynamic> _answer(Map<String, dynamic> inner) {
    final expire = invalidateNext > 0;
    if (expire) invalidateNext--;
    final requests = ((inner['params'] as Map)['requests'] as List).cast<Map<String, dynamic>>();
    return {
      'error_code': 0,
      'result': {
        'responses': [
          for (final r in requests)
            {'method': r['method'], 'result': <String, dynamic>{}, 'error_code': expire ? -40401 : 0},
        ],
      },
    };
  }

  @override
  void close() {}
}

List<int> sha256Raw(List<int> data) => sha256Digest(data);
