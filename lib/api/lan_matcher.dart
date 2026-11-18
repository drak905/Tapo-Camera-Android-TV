// Cloud <-> LAN matching and TPAP hint. Spec: hc.discovery.matcher,
// hc.discovery.tpap_hint.

/// Normalises to `AA-BB-CC-DD-EE-FF`; strips `[\s:.-]`, upper-cases; returns
/// '' unless exactly 12 hex digits remain.
String normaliseMac(String raw) => throw UnimplementedError();

/// Lower-case MD5 hex of the UTF-8 [deviceId].
String deviceIdMd5(String deviceId) => throw UnimplementedError();

/// True when the TDP hints ask for TPAP: `tpap.pake` non-empty or `'4'` in
/// `encrypt_type` (a str, an int or a list of those).
bool tpapRequested(Map<String, dynamic>? tpap, [Object? encryptType]) =>
    throw UnimplementedError();

/// `'tpap'` when [tpapRequested] for the raw TDP result map
/// (`raw['tpap']`, `raw['encrypt_type']`), else `''` (probe v3 first).
String controlProtocolFromRaw(Map<String, dynamic> raw) => throw UnimplementedError();

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
Map<String, LanMatch> matchLan(List<CloudDeviceRef> cloud, List<LanDevice> lan) =>
    throw UnimplementedError();