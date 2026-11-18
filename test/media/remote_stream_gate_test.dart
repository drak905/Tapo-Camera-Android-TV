// mb.limits.remote_gate (max remote streams 1..8, default 4)
import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/media/remote_stream_gate.dart';

void main() {
  test('default capacity is 4', () {
    expect(RemoteStreamGate().capacity, 4);
    expect(kDefaultMaxRemoteStreams, 4);
  });

  test('evicts oldest when over capacity', () {
    final g = RemoteStreamGate(capacity: 2);
    final evicted = <String>[];
    expect(g.acquire('a', () => evicted.add('a')), isTrue);
    expect(g.acquire('b', () => evicted.add('b')), isTrue);
    expect(g.acquire('c', () => evicted.add('c')), isFalse, reason: 'full without preempt');
    expect(g.acquire('c', () => evicted.add('c'), preempt: true), isTrue);
    expect(evicted, ['a']);
    expect(g.holders(), ['b', 'c']);
    expect(g.holds('a'), isFalse);
  });

  test('acquire twice for a holder keeps its slot and first callback', () {
    final g = RemoteStreamGate(capacity: 1);
    var evicted = 0;
    expect(g.acquire('a', () => evicted++), isTrue);
    expect(g.acquire('a', () => evicted += 10), isTrue);
    g.acquire('b', () {}, preempt: true);
    expect(evicted, 1);
  });

  test('reserved keys exceed capacity and are not evicted', () {
    final g = RemoteStreamGate(capacity: 1);
    final evicted = <String>[];
    g.reserve(['v1', 'v2']);
    expect(g.acquire('v1', () => evicted.add('v1')), isTrue);
    expect(g.acquire('v2', () => evicted.add('v2')), isTrue);
    expect(g.holders(), ['v1', 'v2'], reason: 'reserved holders exceed capacity 1');
    expect(g.acquire('x', () => evicted.add('x'), preempt: true), isFalse, reason: 'no non-reserved victim');
    expect(evicted, isEmpty);
    expect(g.reserved(), {'v1', 'v2'});
  });

  test('non reserved holder is the victim, reserved one survives', () {
    final g = RemoteStreamGate(capacity: 2);
    final evicted = <String>[];
    g.reserve(['a']);
    g.acquire('a', () => evicted.add('a'));
    g.acquire('b', () => evicted.add('b'));
    expect(g.acquire('c', () => evicted.add('c'), preempt: true), isTrue);
    expect(evicted, ['b']);
    expect(g.holders(), ['a', 'c']);
  });

  test('release frees the slot', () {
    final g = RemoteStreamGate(capacity: 1);
    g.acquire('a', () {});
    g.release('a');
    g.release('a');
    expect(g.acquire('b', () {}), isTrue);
  });

  test('invalid capacity falls back to 4', () {
    for (final bad in [null, 0, -1, 9, 16, 4.5, '4', true]) {
      expect(validMaxRemoteStreams(bad), 4, reason: '$bad');
    }
  });

  test('valid capacity 1..8 is kept', () {
    for (var n = 1; n <= 8; n++) {
      expect(validMaxRemoteStreams(n), n);
    }
  });

  test('setCapacity rejects values outside 1..8', () {
    final g = RemoteStreamGate();
    expect(() => g.setCapacity(0), throwsArgumentError);
    expect(() => g.setCapacity(9), throwsArgumentError);
    g.setCapacity(8);
    expect(g.capacity, 8);
  });
}
