// ui.grid.layouts + ui.grid.storage_format (model part)
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/state/grids.dart';

void main() {
  test('slots per layout are 2, 4, 6, 9', () {
    expect(GridLayout.two.slots, 2);
    expect(GridLayout.quad.slots, 4);
    expect(GridLayout.onePlusFive.slots, 6);
    expect(GridLayout.nine.slots, 9);
  });

  test('fitting(1..9) mapping', () {
    expect([for (var n = 1; n <= 9; n++) GridLayout.fitting(n)], [
      GridLayout.two,
      GridLayout.two,
      GridLayout.quad,
      GridLayout.quad,
      GridLayout.onePlusFive,
      GridLayout.onePlusFive,
      GridLayout.nine,
      GridLayout.nine,
      GridLayout.nine,
    ]);
  });

  test('byName(null/unknown) is quad', () {
    expect(GridLayout.byName(null), GridLayout.quad);
    expect(GridLayout.byName('nope'), GridLayout.quad);
    expect(GridLayout.byName('nine'), GridLayout.nine);
  });

  test('onePlusFive has a 2x2 big tile first on a 3x3 canvas', () {
    expect(GridLayout.onePlusFive.cols, 3);
    expect(GridLayout.onePlusFive.rows, 3);
    expect(GridLayout.onePlusFive.tiles.first.width, 2);
    expect(GridLayout.onePlusFive.tiles.first.height, 2);
  });

  test('toJson/fromJson roundtrip keeps layout name and slots', () {
    final g = GridPreset(id: 'g1', name: 'Downstairs', layout: GridLayout.onePlusFive, slots: ['a', null, 'c', 'd', null, 'f']);
    final json = g.toJson();
    expect(json['layout'], 'onePlusFive');
    expect(json['slots'], ['a', null, 'c', 'd', null, 'f']);
    final back = GridPreset.fromJson(json);
    expect(back.id, 'g1');
    expect(back.name, 'Downstairs');
    expect(back.layout, GridLayout.onePlusFive);
    expect(back.slots, g.slots);
  });

  test('fromJson pads a short slot list and trims a long one', () {
    final short = GridPreset.fromJson({'id': 'x', 'name': 'n', 'layout': 'quad', 'slots': ['a']});
    expect(short.slots, ['a', null, null, null]);
    final long = GridPreset.fromJson({'id': 'x', 'name': 'n', 'layout': 'two', 'slots': ['a', 'b', 'c', 'd']});
    expect(long.slots, ['a', 'b']);
  });

  test('the All cameras id is auto and never editable', () {
    final g = GridPreset(id: GridPreset.allCamerasId, name: 'All cameras', layout: GridLayout.two, slots: ['a']);
    expect(g.isAuto, isTrue);
    expect(GridPreset.allCamerasId, 'all');
  });

  test('cameraCount counts non-empty slots', () {
    final g = GridPreset(id: 'g', name: 'g', layout: GridLayout.quad, slots: ['a', null, 'b']);
    expect(g.cameraCount, 2);
  });
}