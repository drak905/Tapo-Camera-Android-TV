// Cloud <-> LAN matching and TPAP hint. Spec: hc.discovery.matcher,
// hc.discovery.tpap_hint.

import 'dart:convert';

import 'package:crypto/crypto.dart';

final _macSeparators = RegExp(r'[\s:.\-]');
final _hex12 = RegExp(r'^[0-9A-F]{12}$');

/// Normalises to `AA-BB-CC-DD-EE-FF`; strips `[\s:.-]`, upper-cases; returns
/// '' unless exactly 12 hex digits remain.
String normaliseMac(String raw) {
  final compact = raw.replaceAll(_macSeparators, '').toUpperCase();
  if (!_hex12.hasMatch(compact)) return '';
  return [for (var i = 0; i < 12; i += 2) compact.substring(i, i + 2)].join('-');
}

/// Lower-case MD5 hex of the UTF-8 [deviceId].
String deviceIdMd5(String deviceId) => md5.convert(utf8.encode(deviceId)).toString();

/// True when the TDP hints ask for TPAP: `tpap.pake` non-empty or `'4'` in
/// `encrypt_type` (a str, an int or a list of those).
bool tpapRequested(Map<String, dynamic>? tpap, [Object? encryptType]) {
  final pake = tpap?['pake'];
  if (pake is List && pake.isNotEmpty) return true;
  if (encryptType is List) return encryptType.any((e) => '$e' == '4');
  if (encryptType is String || encryptType is int) return '$encryptType' == '4';
  return false;
}

/// `'tpap'` when [tpapRequested] for the raw TDP result map
/// (`raw['tpap']`, `raw['encrypt_type']`), else `''` (probe v3 first).
String controlProtocolFromRaw(Map<String, dynamic> raw) {
  final tpap = raw['tpap'];
  return tpapRequested(tpap is Map<String, dynamic> ? tpap : null, raw['encrypt_type']) ? 'tpap' : '';
}

/// A camera found by TDP.
class LanDevice {
  const LanDevice({
    required this.ip,
    required this.mac,
    this.md5 = '',
    this.httpPort,
    this.raw = const {},
  });
  final String ip;
  final String mac;

  /// Lower-case md5 of the device id ('' when unknown).
  final String md5;

  /// null means the default 443.
  final int? httpPort;
  final Map<String, dynamic> raw;
}

/// A cloud device (device-list v2 entry).
class CloudDeviceRef {
  const CloudDeviceRef({required this.deviceId, this.mac = ''});
  final String deviceId;
  final String mac;
}

/// Local connection parameters of a matched camera.
class LanMatch {
  const LanMatch({
    required this.deviceId,
    required this.host,
    required this.httpsPort,
    required this.lanFound,
    required this.controlProtocol,
    required this.byMd5,
  });
  final String deviceId;
  final String host;
  final int httpsPort;
  final bool lanFound;
  final String controlProtocol;
  final bool byMd5;
}

/// Pass 1: md5(deviceId) (case-insensitive, first LAN device wins). Pass 2:
/// normalised MAC among the unused LAN devices. Each LAN device is used at
/// most once, md5 beats MAC, unmatched cloud devices are absent from the map
/// (keyed by deviceId).
Map<String, LanMatch> matchLan(List<CloudDeviceRef> cloud, List<LanDevice> lan) {
  final result = <String, LanMatch>{};
  final used = <int>{};
  LanMatch build(CloudDeviceRef c, LanDevice d, bool byMd5) => LanMatch(
        deviceId: c.deviceId,
        host: d.ip,
        httpsPort: (d.httpPort != null && d.httpPort! > 0 && d.httpPort! < 65536) ? d.httpPort! : 443,
        lanFound: true,
        controlProtocol: controlProtocolFromRaw(d.raw),
        byMd5: byMd5,
      );

  final byMd5 = <String, int>{};
  for (var i = 0; i < lan.length; i++) {
    final key = lan[i].md5.trim().toLowerCase();
    if (key.isNotEmpty) byMd5.putIfAbsent(key, () => i);
  }
  for (final c in cloud) {
    if (c.deviceId.isEmpty) continue;
    final idx = byMd5[deviceIdMd5(c.deviceId)];
    if (idx != null && !used.contains(idx)) {
      result[c.deviceId] = build(c, lan[idx], true);
      used.add(idx);
    }
  }
  final byMac = <String, int>{};
  for (var i = 0; i < lan.length; i++) {
    final mac = normaliseMac(lan[i].mac);
    if (mac.isNotEmpty && !used.contains(i)) byMac.putIfAbsent(mac, () => i);
  }
  for (final c in cloud) {
    if (result.containsKey(c.deviceId)) continue;
    final mac = normaliseMac(c.mac);
    final idx = mac.isEmpty ? null : byMac[mac];
    if (idx != null && !used.contains(idx)) {
      result[c.deviceId] = build(c, lan[idx], false);
      used.add(idx);
    }
  }
  return result;
}