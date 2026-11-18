/// Camera sort order (Windows setting `camera_sort`).
library;

enum CameraSort {
  nameAsc('name_asc', 'Name A-Z'),
  nameDesc('name_desc', 'Name Z-A'),
  account('account', 'Account order');

  const CameraSort(this.storageValue, this.label);
  final String storageValue;
  final String label;

  /// Unknown or null falls back to [nameAsc].
  static CameraSort parse(String? value) => throw UnimplementedError('ui lane GREEN: CameraSort.parse');
}

/// Natural, case-insensitive compare: "Cam 2" < "Cam 10", accents next to
/// their base letter.
int naturalCompare(String a, String b) => throw UnimplementedError('ui lane GREEN: naturalCompare');

/// Returns a sorted copy. Ties keep the incoming (account) order.
List<T> sortCameras<T>(List<T> items, CameraSort mode, String Function(T item) nameOf) =>
    throw UnimplementedError('ui lane GREEN: sortCameras');