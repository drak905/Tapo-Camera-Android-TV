import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart' show AppScope;
import '../state/app_state.dart';
import '../state/camera_actions.dart';
import '../state/camera_view_model.dart';
import '../ui/day_timeline.dart';
import '../ui/theme.dart';
import '../ui/tv.dart';

/// Builds the video surface of a running playback (tests inject a fake).
typedef PlaybackVideoBuilder = Widget Function(BuildContext context, PlaybackControl control);

String _two(int v) => v.toString().padLeft(2, '0');

String _hms(DateTime utc) {
  final t = utc.toLocal();
  return '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
}

String _dayKey(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

/// SD-card recordings of one camera: 24 h timeline (Left/Right scrub, Up =
/// later day, Down = earlier day, OK plays) and the playback view (OK shows
/// controls with speed chips, Back returns to the timeline, then pops).
class VodTimelineScreen extends StatefulWidget {
  const VodTimelineScreen({super.key, required this.camera, this.actions, this.videoBuilder, this.now});
  final Camera camera;

  /// Defaults to AppState.actions.
  final CameraActions? actions;
  final PlaybackVideoBuilder? videoBuilder;

  /// Clock seam (local time). Defaults to DateTime.now.
  final DateTime Function()? now;

  @override
  State<VodTimelineScreen> createState() => _VodTimelineScreenState();
}

class _VodTimelineScreenState extends State<VodTimelineScreen> {
  static const _speeds = [1, 2, 4, 8];

  final _node = FocusNode(debugLabel: 'recordings');
  final _pauseNode = FocusNode(debugLabel: 'recordings-pause');
  final _reloadNode = FocusNode(debugLabel: 'recordings-reload');
  final _list = ScrollController();

  late DateTime _day; // local calendar day (midnight)
  late ({DateTime start, DateTime end}) _range; // UTC instants
  List<RecordingClip> _clips = const [];
  bool _loading = false;
  String? _error;
  int _loadSeq = 0;
  late DateTime _cursor; // UTC
  int _repeats = 0;

  PlaybackControl? _player;
  bool _opening = false;
  bool _controls = false;
  bool _overlay = false;

  DateTime _now() => (widget.now ?? DateTime.now)();
  CameraActions? get _actions => widget.actions ?? AppScope.read(context).actions;
  bool get _hasSd => widget.camera.capabilities.contains(CameraCapability.sdCard);
  bool get _playing => _player != null;

  @override
  void initState() {
    super.initState();
    final n = _now();
    _setDay(DateTime(n.year, n.month, n.day));
    _cursor = _range.start;
    if (_hasSd) _load();
  }

  @override
  void dispose() {
    final p = _player;
    _player = null;
    if (p != null) {
      p.state.removeListener(_onPlayerState);
      unawaited(p.stop());
    }
    _node.dispose();
    _pauseNode.dispose();
    _reloadNode.dispose();
    _list.dispose();
    super.dispose();
  }

  void _setDay(DateTime day) {
    _day = day;
    final r = localDayRange(day);
    _range = (start: r.start.toUtc(), end: r.end.toUtc());
  }

  // ------------------------------------------------------------ loading --

  Future<void> _load() async {
    final seq = ++_loadSeq;
    final actions = _actions;
    setState(() {
      _loading = true;
      _error = null;
      _clips = const [];
      _cursor = _range.start;
    });
    try {
      if (actions == null) throw const CameraActionException('recordings are not available');
      final clips = [...await actions.listClips(widget.camera.deviceId, _range.start, _range.end)]
        ..sort((a, b) => a.start.compareTo(b.start));
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _loading = false;
        _clips = clips;
        _cursor = clips.isEmpty ? _range.start : clips.first.start;
      });
      _focusScreen();
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _loading = false;
        _error = e is CameraActionException ? e.message : e.toString();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _error != null) _reloadNode.requestFocus();
      });
    }
  }

  void _focusScreen() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _node.requestFocus();
    });
  }

  void _changeDay(int delta) {
    final next = DateTime(_day.year, _day.month, _day.day + delta);
    final n = _now();
    final tomorrow = DateTime(n.year, n.month, n.day + 1);
    if (next.isAfter(tomorrow)) return;
    _setDay(next);
    _load();
  }

  // ------------------------------------------------------------ timeline --

  DateTime _clamp(DateTime t) => t.isBefore(_range.start) ? _range.start : (t.isAfter(_range.end) ? _range.end : t);

  void _scrub(int sign, KeyEvent e) {
    final Duration step;
    if (e is KeyRepeatEvent) {
      _repeats++;
      step = Duration(minutes: _repeats <= 3 ? 5 : 15);
    } else {
      _repeats = 0;
      step = const Duration(minutes: 1);
    }
    setState(() => _cursor = _clamp(_cursor.add(step * sign)));
    _syncList();
  }

  void _jumpClip(bool next) {
    DateTime? target;
    if (next) {
      for (final c in _clips) {
        if (c.start.isAfter(_cursor)) {
          target = c.start;
          break;
        }
      }
    } else {
      for (final c in _clips.reversed) {
        if (c.start.isBefore(_cursor)) {
          target = c.start;
          break;
        }
      }
    }
    if (target == null) return;
    setState(() => _cursor = target!);
    _syncList();
  }

  void _syncList() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_list.hasClients) return;
      final i = _clips.indexWhere((c) => _cursor.isBefore(c.end) && !_cursor.isBefore(c.start));
      if (i < 0) return;
      final target = (i * _rowHeight).clamp(0.0, _list.position.maxScrollExtent);
      final visibleTop = _list.offset, visibleBottom = _list.offset + _list.position.viewportDimension;
      if (i * _rowHeight < visibleTop || (i + 1) * _rowHeight > visibleBottom) _list.jumpTo(target);
    });
  }

  static const _rowHeight = 40.0;

  // ------------------------------------------------------------ playback --

  Future<void> _play() async {
    if (_opening || _playing || _clips.isEmpty) return;
    final snapped = snapToClips(_cursor, _clips);
    final lastEnd = _clips.map((c) => c.end).reduce((a, b) => a.isAfter(b) ? a : b);
    if (!snapped.isBefore(lastEnd)) return;
    final actions = _actions;
    if (actions == null) return;
    _opening = true;
    try {
      final p = await actions.openPlayback(widget.camera.deviceId, snapped, _range.end);
      if (!mounted) {
        unawaited(p.stop());
        return;
      }
      p.state.addListener(_onPlayerState);
      setState(() {
        _player = p;
        _cursor = snapped;
        _controls = false;
        _overlay = false;
      });
      _focusScreen();
    } catch (e) {
      if (mounted) showToast(context, 'Could not play: ${e is CameraActionException ? e.message : e}', error: true);
    } finally {
      _opening = false;
    }
  }

  void _onPlayerState() {
    final p = _player;
    if (p != null && p.state.value.ended) _leavePlayback();
  }

  void _leavePlayback() {
    final p = _player;
    if (p == null) return;
    _player = null;
    p.state.removeListener(_onPlayerState);
    final position = p.state.value.position;
    unawaited(p.stop());
    if (!mounted) return;
    setState(() {
      _controls = false;
      _overlay = false;
      _cursor = _clamp(position);
    });
    _focusScreen();
    _syncList();
  }

  void _showControls() {
    setState(() {
      _controls = true;
      _overlay = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controls) _pauseNode.requestFocus();
    });
  }

  void _hideControls() {
    setState(() => _controls = false);
    _focusScreen();
  }

  void _togglePause() {
    final p = _player;
    if (p == null) return;
    unawaited(p.state.value.paused ? p.resume() : p.pause());
  }

  void _seekBy(Duration delta) {
    final p = _player;
    if (p == null) return;
    final position = p.state.value.position;
    var target = snapToClips(_clamp(position.add(delta)), _clips);
    if (delta.isNegative && target.isAfter(position)) {
      // Seeking back into a gap: land near the end of the previous clip.
      RecordingClip? prev;
      for (final c in _clips) {
        if (!c.end.isAfter(position)) prev = c;
      }
      if (prev == null) return;
      final back = prev.end.subtract(const Duration(seconds: 10));
      target = back.isBefore(prev.start) ? prev.start : back;
    }
    unawaited(p.seekTo(target));
  }

  void _seekClip(bool next) {
    final p = _player;
    if (p == null) return;
    final position = p.state.value.position;
    DateTime? target;
    if (next) {
      for (final c in _clips) {
        if (c.start.isAfter(position)) {
          target = c.start;
          break;
        }
      }
    } else {
      final limit = position.subtract(const Duration(seconds: 2));
      for (final c in _clips.reversed) {
        if (c.start.isBefore(limit)) {
          target = c.start;
          break;
        }
      }
    }
    if (target != null) unawaited(p.seekTo(target));
  }

  // --------------------------------------------------------------- keys --

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final k = e.logicalKey;
    final down = e is KeyDownEvent, repeat = e is KeyRepeatEvent, up = e is KeyUpEvent;
    if (_playing) return _onPlayingKey(k, e, down, repeat, up);
    if (_loading && !_hasSd) return KeyEventResult.ignored;
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
      if (_error != null) return KeyEventResult.ignored; // let focus move
      if (!up) _scrub(k == LogicalKeyboardKey.arrowRight ? 1 : -1, e);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      if (down) _changeDay(k == LogicalKeyboardKey.arrowUp ? 1 : -1);
      return KeyEventResult.handled;
    }
    if (selectKeys.contains(k)) {
      if (down) unawaited(_play());
      return KeyEventResult.handled;
    }
    if (_isNext(k) || _isPrev(k)) {
      if (down) _jumpClip(_isNext(k));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  bool _isNext(LogicalKeyboardKey k) => k == LogicalKeyboardKey.channelUp || k == LogicalKeyboardKey.mediaTrackNext;
  bool _isPrev(LogicalKeyboardKey k) => k == LogicalKeyboardKey.channelDown || k == LogicalKeyboardKey.mediaTrackPrevious;

  KeyEventResult _onPlayingKey(LogicalKeyboardKey k, KeyEvent e, bool down, bool repeat, bool up) {
    if (k == LogicalKeyboardKey.mediaPlayPause || k == LogicalKeyboardKey.mediaPlay || k == LogicalKeyboardKey.mediaPause) {
      if (down) _togglePause();
      return KeyEventResult.handled;
    }
    if (_isNext(k) || _isPrev(k)) {
      if (down) _seekClip(_isNext(k));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaFastForward || k == LogicalKeyboardKey.mediaRewind) {
      if (down || repeat) _seekBy(Duration(seconds: k == LogicalKeyboardKey.mediaFastForward ? 10 : -10));
      return KeyEventResult.handled;
    }
    if (_controls) return KeyEventResult.ignored; // the focused control and D-pad traversal handle it
    if (selectKeys.contains(k)) {
      if (down) _showControls();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
      if (down || repeat) _seekBy(Duration(seconds: k == LogicalKeyboardKey.arrowRight ? 10 : -10));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.arrowUp) {
      if (down) setState(() => _overlay = k == LogicalKeyboardKey.arrowDown);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onBack() {
    if (_controls) {
      _hideControls();
    } else if (_overlay) {
      setState(() => _overlay = false);
    } else {
      _leavePlayback();
    }
  }

  // -------------------------------------------------------------- build --

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_playing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Focus(
        focusNode: _node,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          backgroundColor: _playing ? Colors.black : TopoColors.neutral,
          body: _playing ? _buildPlaying(context) : _buildTimeline(context),
        ),
      ),
    );
  }

  Widget _header({required DateTime cursor}) {
    final atEnd = !cursor.isBefore(_range.end);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(_dayKey(_day), key: const ValueKey('timeline-day-label'), style: TopoText.title),
        const Spacer(),
        Text(atEnd ? '24:00:00' : _hms(cursor), key: const ValueKey('timeline-cursor-label'), style: TopoText.display),
      ],
    );
  }

  Widget _buildTimeline(BuildContext context) {
    Widget body;
    if (!_hasSd) {
      body = _message(Icons.sd_card_alert_outlined, 'No SD card');
    } else if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Could not load recordings: $_error', style: TopoText.body, textAlign: TextAlign.center),
            const SizedBox(height: TopoSpace.x2),
            TvButton(label: 'Reload', icon: Icons.refresh_rounded, style: TvButtonStyle.primary, focusNode: _reloadNode, onPressed: _load),
          ],
        ),
      );
    } else if (_clips.isEmpty) {
      body = _message(Icons.videocam_off_outlined, 'No recordings on this day');
    } else {
      body = _clipList();
    }
    return Padding(
      padding: tvSafePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.camera.name, style: TopoText.headline, maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: TopoSpace.sm),
          _header(cursor: _cursor),
          const SizedBox(height: TopoSpace.md),
          DayTimeline(day: _range, clips: _clips, cursor: _cursor),
          const SizedBox(height: TopoSpace.lg),
          Expanded(child: body),
          const SizedBox(height: TopoSpace.sm),
          const HintBar([
            (KeyCap('OK'), 'Play'),
            (KeyCap('\u25C0 \u25B6'), 'Scrub'),
            (KeyCap('\u25B2 \u25BC'), 'Day'),
            (KeyCap('CH'), 'Next clip'),
            (KeyCap('Back'), 'Close'),
          ]),
        ],
      ),
    );
  }

  Widget _message(IconData icon, String text) => Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: TopoColors.muted, size: 32),
            const SizedBox(width: TopoSpace.md),
            Text(text, style: TopoText.title.copyWith(color: TopoColors.muted)),
          ],
        ),
      );

  Widget _clipList() {
    return ListView.builder(
      controller: _list,
      itemExtent: _rowHeight,
      itemCount: _clips.length,
      itemBuilder: (context, i) {
        final c = _clips[i];
        final current = !_cursor.isBefore(c.start) && _cursor.isBefore(c.end);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: TopoSpace.lg),
          decoration: BoxDecoration(
            color: current ? TopoColors.surfaceSelected : Colors.transparent,
            borderRadius: BorderRadius.circular(TopoRadius.sm),
          ),
          child: Row(
            children: [
              Container(width: 14, height: 14, decoration: BoxDecoration(color: eventTypeColor(c.eventType), shape: BoxShape.circle)),
              const SizedBox(width: TopoSpace.md),
              Text('${_hms(c.start)} - ${_hms(c.end)}', style: TopoText.body),
              const SizedBox(width: TopoSpace.x2),
              Text(eventTypeName(c.eventType), style: TopoText.caption),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPlaying(BuildContext context) {
    final p = _player!;
    final video = widget.videoBuilder?.call(context, p) ?? const ColoredBox(color: Colors.black);
    return Stack(
      fit: StackFit.expand,
      children: [
        video,
        Positioned(
          top: 27,
          left: 48,
          child: ValueListenableBuilder<PlaybackState>(
            valueListenable: p.state,
            builder: (_, s, _) => Container(
              padding: const EdgeInsets.symmetric(horizontal: TopoSpace.md, vertical: TopoSpace.xs),
              decoration: BoxDecoration(color: const Color(0xAA101820), borderRadius: BorderRadius.circular(TopoRadius.sm)),
              child: Text(
                _hms(s.position),
                key: const ValueKey('playback-time'),
                style: TopoText.label.copyWith(color: TopoColors.onMedia),
              ),
            ),
          ),
        ),
        if (_overlay)
          Positioned(
            left: 48,
            right: 48,
            bottom: 27,
            child: ValueListenableBuilder<PlaybackState>(
              valueListenable: p.state,
              builder: (_, s, _) {
                final pos = _clamp(s.position);
                return Container(
                  padding: const EdgeInsets.all(TopoSpace.lg),
                  decoration: BoxDecoration(color: const Color(0xE6FFFFFF), borderRadius: BorderRadius.circular(TopoRadius.lg)),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _header(cursor: pos),
                      const SizedBox(height: TopoSpace.sm),
                      DayTimeline(day: _range, clips: _clips, cursor: pos),
                    ],
                  ),
                );
              },
            ),
          ),
        if (_controls)
          Positioned(
            left: 48,
            right: 48,
            bottom: 27,
            child: ValueListenableBuilder<PlaybackState>(
              valueListenable: p.state,
              builder: (_, s, _) => Container(
                padding: const EdgeInsets.symmetric(horizontal: TopoSpace.x2, vertical: TopoSpace.lg),
                decoration: BoxDecoration(color: const Color(0xCC101820), borderRadius: BorderRadius.circular(TopoRadius.lg)),
                child: Row(
                  children: [
                    TvButton(
                      label: s.paused ? 'Play' : 'Pause',
                      icon: s.paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                      style: TvButtonStyle.primary,
                      onMedia: true,
                      focusNode: _pauseNode,
                      onPressed: _togglePause,
                    ),
                    const SizedBox(width: TopoSpace.x2),
                    for (final speed in _speeds) ...[
                      TvChip(label: '${speed}x', selected: s.speed == speed, onMedia: true, onSelect: () => unawaited(p.setSpeed(speed))),
                      const SizedBox(width: TopoSpace.md),
                    ],
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
