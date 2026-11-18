// ui.grid.storage_format: AppState persistence (existing) and the new cleaning rule
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tapo_tv/state/app_state.dart';
import 'package:tapo_tv/state/grids.dart';

Future<(AppState, SharedPreferences)> _boot(Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  final app = AppState();
  await app.init();
  return (app, await SharedPreferences.getInstance());
}

Camera _cam(String id) => Camera({'deviceId': id, 'alias': id});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('corrupt grids pref yields an empty list', () async {
    final (app, _) = await _boot({'grids': '{not json'});
    expect(app.savedGrids, isEmpty);
    expect(app.activeGridId, GridPreset.allCamerasId);
  });

  test('saveGrid stores the documented JSON under "grids" with a g<ms> id', () async {
    final (app, prefs) = await _boot({});
    final saved = await app.saveGrid(GridPreset(id: '', name: 'Porch', layout: GridLayout.two, slots: ['a', 'b']));
    expect(saved.id, matches(RegExp(r'^g\d{10,}$')));
    final list = jsonDecode(prefs.getString('grids')!) as List;
    expect(list.single, {'id': saved.id, 'name': 'Porch', 'layout': 'two', 'slots': ['a', 'b']});
  });

  test('saving an existing id replaces it and keeps the id', () async {
    final (app, _) = await _boot({});
    final first = await app.saveGrid(GridPreset(id: '', name: 'One', layout: GridLayout.two, slots: ['a']));
    await app.saveGrid(first.copyWith(name: 'Renamed'));
    expect(app.savedGrids, hasLength(1));
    expect(app.savedGrids.single.name, 'Renamed');
    expect(app.savedGrids.single.id, first.id);
  });

  test('active_grid and favorite_grid keys hold the ids', () async {
    final (app, prefs) = await _boot({});
    final g = await app.saveGrid(GridPreset(id: '', name: 'G', layout: GridLayout.two, slots: ['a']));
    await app.setActiveGrid(g.id);
    await app.setFavoriteGrid(g.id);
    expect(prefs.getString('active_grid'), g.id);
    expect(prefs.getString('favorite_grid'), g.id);
    await app.setFavoriteGrid(null);
    expect(prefs.getString('favorite_grid'), isNull);
  });

  test('deleteGrid resets active and favorite', () async {
    final (app, prefs) = await _boot({});
    final g = await app.saveGrid(GridPreset(id: '', name: 'G', layout: GridLayout.two, slots: ['a']));
    await app.setActiveGrid(g.id);
    await app.setFavoriteGrid(g.id);
    await app.deleteGrid(g.id);
    expect(app.savedGrids, isEmpty);
    expect(app.activeGridId, GridPreset.allCamerasId);
    expect(app.favoriteGridId, isNull);
    expect(prefs.getString('favorite_grid'), isNull);
    expect(prefs.getString('active_grid'), 'all');
  });

  test('All cameras is built from the cameras in account order and never stored', () async {
    final (app, prefs) = await _boot({});
    app.cameras = [_cam('a'), _cam('b'), _cam('c')];
    final all = app.allCamerasGrid;
    expect(all.layout, GridLayout.quad);
    expect(all.slots.take(3), ['a', 'b', 'c']);
    expect(all.isAuto, isTrue);
    expect(prefs.getString('grids'), isNull);
    expect(app.grids.first.id, 'all');
  });

  test('NEW: unknown and duplicate camera ids in a saved grid become empty slots', () async {
    final (app, _) = await _boot({
      'grids': jsonEncode([
        {'id': 'g1', 'name': 'G', 'layout': 'quad', 'slots': ['a', 'gone', 'a', 'b']},
      ]),
    });
    app.cameras = [_cam('a'), _cam('b')];
    app.cleanGridSlots();
    expect(app.savedGrids.single.slots, ['a', null, null, 'b']);
  });

  test('NEW: cameras added later are not added to saved grids', () async {
    final (app, _) = await _boot({
      'grids': jsonEncode([
        {'id': 'g1', 'name': 'G', 'layout': 'quad', 'slots': ['a', null, null, null]},
      ]),
    });
    app.cameras = [_cam('a'), _cam('b'), _cam('c')];
    app.cleanGridSlots();
    expect(app.savedGrids.single.slots, ['a', null, null, null]);
  });
}