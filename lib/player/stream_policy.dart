/// View-driven streaming policy: SD (VGA) for grid tiles, HD fullscreen.
library;

enum StreamQuality { vga, hd }

/// One planned live stream.
class StreamPlan {
  const StreamPlan(this.quality);
  final StreamQuality quality;

  /// Preview `resolutions` value: `VGA` or `HD`.
  String get resolution => quality == StreamQuality.hd ? 'HD' : 'VGA';
}

/// Streams for a view, in slot order: camera id to plan.
///
/// [visibleSlots] are the slots of the current page (id or null), [known] the
/// known camera ids, [fullscreen] the camera shown alone (ignored unless it
/// is in a visible slot). Grid: every visible camera streams VGA. Fullscreen:
/// only that camera, HD. Empty slots, unknown ids and repeated ids never
/// stream. [maxVisibleTiles] caps the grid plan (default 4, 2x2).
Map<String, StreamPlan> planStreams(
  List<String?> visibleSlots, {
  required Set<String> known,
  String? fullscreen,
  int maxVisibleTiles = 4,
}) {
  final plan = <String, StreamPlan>{};
  if (fullscreen != null && known.contains(fullscreen) && visibleSlots.contains(fullscreen)) {
    plan[fullscreen] = const StreamPlan(StreamQuality.hd);
    return plan;
  }
  for (final id in visibleSlots) {
    if (id == null || !known.contains(id) || plan.containsKey(id)) continue;
    if (plan.length >= maxVisibleTiles) break;
    plan[id] = const StreamPlan(StreamQuality.vga);
  }
  return plan;
}
