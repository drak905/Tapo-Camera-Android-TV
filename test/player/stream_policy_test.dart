// mb.policy.codec_budget: SD (VGA) for tiles, HD fullscreen.
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/player/stream_policy.dart';

void main() {
  const known = {'a', 'b', 'c', 'd', 'e', 'f'};

  test('grid plans vga per visible camera', () {
    final plan = planStreams(['a', 'b', null, 'c'], known: known);
    expect(plan.keys.toList(), ['a', 'b', 'c']);
    expect(plan.values.every((p) => p.quality == StreamQuality.vga), isTrue);
    expect(plan['a']!.resolution, 'VGA');
  });

  test('fullscreen plans only that camera hd', () {
    final plan = planStreams(['a', 'b', 'c', 'd'], known: known, fullscreen: 'b');
    expect(plan.keys.toList(), ['b']);
    expect(plan['b']!.quality, StreamQuality.hd);
    expect(plan['b']!.resolution, 'HD');
  });

  test('fullscreen camera outside the visible slots is ignored', () {
    final plan = planStreams(['a', 'b'], known: known, fullscreen: 'e');
    expect(plan.keys.toList(), ['a', 'b']);
  });

  test('repeated and unknown ids never stream', () {
    final plan = planStreams(['a', 'a', 'zzz', null, 'b'], known: known);
    expect(plan.keys.toList(), ['a', 'b']);
  });

  test('at most 4 visible tiles stream by default (grid up to 2x2 codec budget)', () {
    final plan = planStreams(['a', 'b', 'c', 'd', 'e', 'f'], known: known);
    expect(plan.keys.toList(), ['a', 'b', 'c', 'd']);
  });

  test('maxVisibleTiles can be raised after a codec capacity probe', () {
    final plan = planStreams(['a', 'b', 'c', 'd', 'e', 'f'], known: known, maxVisibleTiles: 9);
    expect(plan, hasLength(6));
  });
}
