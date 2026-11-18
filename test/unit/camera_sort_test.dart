// ui.camera.sort_order (pure logic, new)
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/state/camera_sort.dart';

List<String> _sorted(List<String> names, CameraSort mode) => sortCameras<String>(names, mode, (n) => n);

void main() {
  test('Cam 2 sorts before Cam 10 (natural order)', () {
    expect(_sorted(['Cam 10', 'Cam 2', 'Cam 1'], CameraSort.nameAsc), ['Cam 1', 'Cam 2', 'Cam 10']);
    expect(naturalCompare('Cam 2', 'Cam 10'), lessThan(0));
  });

  test('compare is case-insensitive', () {
    expect(naturalCompare('garden', 'Garage'), greaterThan(0));
    expect(naturalCompare('ALPHA', 'alpha'), 0);
  });

  test('accents sort next to their base letter', () {
    expect(_sorted(['Zebra', 'Éclair', 'Eagle', 'Fox'], CameraSort.nameAsc), ['Eagle', 'Éclair', 'Fox', 'Zebra']);
  });

  test('Z-A reverses the order', () {
    expect(_sorted(['b', 'a', 'c'], CameraSort.nameDesc), ['c', 'b', 'a']);
  });

  test('account order keeps the incoming order', () {
    expect(_sorted(['b', 'a', 'c'], CameraSort.account), ['b', 'a', 'c']);
  });

  test('ties keep account order', () {
    final items = [('Cam', 1), ('cam', 2), ('Cam', 3)];
    final asc = sortCameras<(String, int)>(items, CameraSort.nameAsc, (e) => e.$1);
    expect(asc.map((e) => e.$2), [1, 2, 3]);
    final desc = sortCameras<(String, int)>(items, CameraSort.nameDesc, (e) => e.$1);
    expect(desc.map((e) => e.$2), [1, 2, 3]);
  });

  test('sorting returns a copy and leaves the input alone', () {
    final input = ['b', 'a'];
    final out = _sorted(input, CameraSort.nameAsc);
    expect(input, ['b', 'a']);
    expect(identical(out, input), isFalse);
  });

  test('unknown or null mode falls back to name_asc', () {
    expect(CameraSort.parse(null), CameraSort.nameAsc);
    expect(CameraSort.parse('banana'), CameraSort.nameAsc);
    expect(CameraSort.parse('name_desc'), CameraSort.nameDesc);
    expect(CameraSort.parse('account'), CameraSort.account);
  });

  test('storage values and labels', () {
    expect(CameraSort.values.map((s) => s.storageValue), ['name_asc', 'name_desc', 'account']);
    expect(CameraSort.values.map((s) => s.label), ['Name A-Z', 'Name Z-A', 'Account order']);
  });
}