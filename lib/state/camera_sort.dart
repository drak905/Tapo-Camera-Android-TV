/// Camera sort order (Windows setting `camera_sort`).
library;

import 'package:unorm_dart/unorm_dart.dart' as unorm;

enum CameraSort {
  nameAsc('name_asc', 'Name A-Z'),
  nameDesc('name_desc', 'Name Z-A'),
  account('account', 'Account order');

  const CameraSort(this.storageValue, this.label);
  final String storageValue;
  final String label;

  /// Unknown or null falls back to [nameAsc].
  static CameraSort parse(String? value) =>
      CameraSort.values.firstWhere((s) => s.storageValue == value, orElse: () => CameraSort.nameAsc);
}

/// Lower-case, accent-free key used for comparing names.
String _foldKey(String s) {
  final decomposed = unorm.nfd(s.toLowerCase());
  final out = StringBuffer();
  for (final r in decomposed.runes) {
    if (r >= 0x300 && r <= 0x36F) continue;
    out.writeCharCode(r);
  }
  return out.toString();
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

/// Natural, case-insensitive compare: "Cam 2" < "Cam 10", accents next to
/// their base letter.
int naturalCompare(String a, String b) {
  final x = _foldKey(a);
  final y = _foldKey(b);
  var i = 0, j = 0;
  while (i < x.length && j < y.length) {
    final cx = x.codeUnitAt(i), cy = y.codeUnitAt(j);
    if (_isDigit(cx) && _isDigit(cy)) {
      var ei = i, ej = j;
      while (ei < x.length && _isDigit(x.codeUnitAt(ei))) {
        ei++;
      }
      while (ej < y.length && _isDigit(y.codeUnitAt(ej))) {
        ej++;
      }
      final nx = x.substring(i, ei).replaceFirst(RegExp(r'^0+(?=\d)'), '');
      final ny = y.substring(j, ej).replaceFirst(RegExp(r'^0+(?=\d)'), '');
      if (nx.length != ny.length) return nx.length < ny.length ? -1 : 1;
      final c = nx.compareTo(ny);
      if (c != 0) return c < 0 ? -1 : 1;
      i = ei;
      j = ej;
    } else {
      if (cx != cy) return cx < cy ? -1 : 1;
      i++;
      j++;
    }
  }
  if (x.length - i == y.length - j) return 0;
  return (x.length - i) < (y.length - j) ? -1 : 1;
}

/// Returns a sorted copy. Ties keep the incoming (account) order.
List<T> sortCameras<T>(List<T> items, CameraSort mode, String Function(T item) nameOf) {
  final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
  if (mode != CameraSort.account) {
    final sign = mode == CameraSort.nameDesc ? -1 : 1;
    indexed.sort((p, q) {
      final c = naturalCompare(nameOf(p.$2), nameOf(q.$2)) * sign;
      return c != 0 ? c : p.$1.compareTo(q.$1);
    });
  }
  return [for (final e in indexed) e.$2];
}
