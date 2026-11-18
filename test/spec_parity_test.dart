// Gate 1: the merged port spec and the repository agree.
//
// * every spec item has at least one existing test file among its `tests`
//   entries, or is listed in [_testMap] / [_deferred] with a reason;
// * specs/android_tv_port_spec.json is up to date with the four lane files
//   (the logic of `python tools/merge_specs.py --check`);
// * every file named in a spec `target` exists, or is listed in [_targetMisses].
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _lanes = [
  'hybrid_control_spec.json',
  'media3_player_bridge_spec.json',
  'tv_ui_remote_spec.json',
  'tv_vod_onvif_spec.json',
];

/// Items whose `tests` entries name a file that was placed elsewhere; the
/// tests below exist and cover the item.
const Map<String, List<String>> _testMap = {
  'hc.cloud.online_state': ['test/unit/camera_router_test.dart'],
  'hc.cloud.terminal_uuid': ['test/unit/secure_store_test.dart'],
  'hc.local.media_digest_ref': ['test/unit/camera_backend_wiring_test.dart', 'test/integration/live_8800_test.dart'],
  'mb.relay.slot_request': ['test/media/relay_slot_test.dart'],
  // probeCodec (A-law / AAC / none) is what decides ExoPlayer support.
  'mb.audio.exo_support': ['test/media/ts_audio_tap_test.dart'],
};

/// Items with no test on purpose, with the decision that says why.
const Map<String, String> _deferred = {
  'vod.download.optional': 'spec decision: SD download skipped this phase (target is a future file)',
  'ev.onvif.discovery': 'spec decision: ONVIF discovery skipped this phase',
  'ev.onvif.ptz': 'spec decision: ONVIF PTZ skipped this phase',
};

/// Target files that do not exist, with the reason (never invent files).
const Map<String, String> _targetMisses = {
  'assets/tplink_roots.pem': 'the roots bundle is assets/tapo-cloud-roots.pem (same content, different name)',
  'lib/api/local_media.dart': 'the :8800 media auth lives in lib/media/local8800 (media lane), not in lib/api',
  'lib/screens/recordings_screen.dart': 'the recordings UI is lib/screens/vod_timeline_screen.dart (one screen for list and player)',
  'lib/screens/playback_screen.dart': 'player keys are handled by lib/screens/vod_timeline_screen.dart (no separate screen)',
};

Map<String, dynamic> _readJson(String path) => jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

/// The file part of a `tests` entry (`path.dart: description` or `path.dart`).
String? _testFile(String entry) {
  final m = RegExp(r'^\s*([\w./\-]+\.(?:dart|kt))\b').firstMatch(entry);
  return m?.group(1);
}

bool _targetExempt(String target) {
  final t = target.toLowerCase().trim();
  return t.startsWith('none') || t.startsWith('docs only') || t.contains('(future');
}

/// Repository files named in a `target` string; globs, `...` and bare
/// directories are not files and are skipped.
List<String> _targetFiles(String target) {
  final out = <String>[];
  for (final m in RegExp(r'[\w./\-]+\.(?:dart|kt|kts|xml|pem|gradle|json|yaml|properties)\b').allMatches(target)) {
    final f = m.group(0)!;
    if (f.contains('...') || f.contains('*') || !f.contains('/')) continue;
    out.add(f);
  }
  return out;
}

void main() {
  final spec = _readJson('specs/android_tv_port_spec.json');
  final items = (spec['items'] as List).cast<Map<String, dynamic>>();

  test('spec has items with unique ids and the fields the gate reads', () {
    expect(items, isNotEmpty);
    final ids = items.map((i) => i['id'] as String).toList();
    expect(ids.toSet().length, ids.length, reason: 'duplicate ids');
    for (final i in items) {
      expect(i['tests'], isA<List>(), reason: '${i['id']} has no tests list');
      expect(i['target'], isA<String>(), reason: '${i['id']} has no target');
    }
  });

  test('every spec item has an existing test file or an explicit mapping', () {
    final missing = <String>[];
    for (final i in items) {
      final id = i['id'] as String;
      if (_deferred.containsKey(id)) continue;
      final files = [
        for (final t in (i['tests'] as List).cast<String>()) ?_testFile(t),
        ...?_testMap[id],
      ];
      if (!files.any((f) => File(f).existsSync())) missing.add('$id: ${files.isEmpty ? 'no tests entry' : files.toSet().join(', ')}');
    }
    expect(missing, isEmpty, reason: 'items without an existing test file:\n${missing.join('\n')}');
  });

  test('the explicit maps are current: known ids, existing files, reasons, no redundancy', () {
    final ids = items.map((i) => i['id'] as String).toSet();
    final byId = {for (final i in items) i['id'] as String: i};
    for (final e in _testMap.entries) {
      expect(ids, contains(e.key), reason: '${e.key} is not a spec item any more');
      for (final f in e.value) {
        expect(File(f).existsSync(), isTrue, reason: '${e.key} maps to missing $f');
      }
      final own = [for (final t in (byId[e.key]!['tests'] as List).cast<String>()) ?_testFile(t)];
      expect(own.any((f) => File(f).existsSync()), isFalse, reason: '${e.key} has its own test now: drop the mapping');
    }
    for (final e in _deferred.entries) {
      expect(ids, contains(e.key), reason: '${e.key} is not a spec item any more');
      expect(e.value.trim(), isNotEmpty);
      final own = [for (final t in (byId[e.key]!['tests'] as List).cast<String>()) ?_testFile(t)];
      expect(own.any((f) => File(f).existsSync()), isFalse, reason: '${e.key} has a test now: drop the deferral');
    }
  });

  test('vod.playback.timeline_position is covered by its own files', () {
    final item = items.firstWhere((i) => i['id'] == 'vod.playback.timeline_position');
    final files = [for (final t in (item['tests'] as List).cast<String>()) ?_testFile(t)];
    expect(files, contains('test/api/vod_timeline_test.dart'));
    expect(File('test/api/vod_timeline_test.dart').existsSync(), isTrue);
    expect(File('lib/api/vod_timeline.dart').existsSync(), isTrue);
  });

  test('merged spec is up to date with the lane files (tools/merge_specs.py --check)', () {
    final merged = <Map<String, dynamic>>[];
    final lanes = <String, int>{};
    final seen = <String>{};
    for (final name in _lanes) {
      final lane = _readJson('specs/$name');
      final laneId = (lane['lane'] ?? name) as String;
      final laneItems = (lane['items'] as List).cast<Map<String, dynamic>>();
      lanes[laneId] = laneItems.length;
      for (final item in laneItems) {
        final id = item['id'] as String;
        expect(seen.add(id), isTrue, reason: 'duplicate id $id across lanes');
        merged.add({...item, 'lane': laneId});
      }
    }
    expect(items.map((i) => i['id']).toList(), merged.map((i) => i['id']).toList(),
        reason: 'ids/order differ: run python tools/merge_specs.py');
    expect(items.length, merged.length);
    for (var k = 0; k < merged.length; k++) {
      expect(jsonEncode(items[k]), jsonEncode(merged[k]), reason: 'item ${merged[k]['id']} differs from its lane file');
    }
    final mergedLanes = (spec['lanes'] as Map).cast<String, dynamic>();
    expect(mergedLanes.keys.toList(), lanes.keys.toList());
    for (final e in lanes.entries) {
      expect((mergedLanes[e.key] as Map)['items'], e.value);
    }
  });

  test('every spec target file exists or is mapped with a reason', () {
    final misses = <String>[];
    final found = <String>{};
    for (final i in items) {
      final target = i['target'] as String;
      if (_targetExempt(target)) continue;
      for (final f in _targetFiles(target)) {
        if (File(f).existsSync()) continue;
        found.add(f);
        if (!_targetMisses.containsKey(f)) misses.add('${i['id']}: $f');
      }
    }
    expect(misses, isEmpty, reason: 'target files that do not exist:\n${misses.join('\n')}');
    for (final e in _targetMisses.entries) {
      expect(e.value.trim(), isNotEmpty);
      expect(found, contains(e.key), reason: '${e.key} exists or is not a target any more: drop the mapping');
    }
  });
}
