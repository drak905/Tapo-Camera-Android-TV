import 'dart:async';

import 'package:flutter/material.dart';

import '../state/camera_actions.dart';
import 'theme.dart';

/// Shows a transient card at top 27 / right 48 for motion events:
/// "`<camera name>`: Motion at HH:MM:SS". Only active events of known cameras,
/// only when notifications are on, at most one per camera per [minInterval].
/// Never takes focus.
class MotionToastHost extends StatefulWidget {
  const MotionToastHost({
    super.key,
    required this.events,
    required this.cameraName,
    required this.notificationsEnabled,
    required this.child,
    this.now,
    this.minInterval = const Duration(seconds: 10),
  });

  final Stream<MotionEvent> events;

  /// Name of a known camera, or null for an unknown id.
  final String? Function(String cameraId) cameraName;
  final bool Function() notificationsEnabled;
  final Widget child;

  /// Clock seam (local time). Defaults to DateTime.now.
  final DateTime Function()? now;
  final Duration minInterval;

  @override
  State<MotionToastHost> createState() => _MotionToastHostState();
}

class _MotionToastHostState extends State<MotionToastHost> {
  static const _showFor = Duration(milliseconds: 3200);
  static const _maxQueued = 3;

  StreamSubscription<MotionEvent>? _sub;
  final _lastShown = <String, DateTime>{};
  final _queue = <String>[];
  String? _current;
  bool _visible = false;
  Timer? _timer;

  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _sub = widget.events.listen(_onEvent);
  }

  @override
  void didUpdateWidget(MotionToastHost old) {
    super.didUpdateWidget(old);
    if (!identical(old.events, widget.events)) {
      _sub?.cancel();
      _sub = widget.events.listen(_onEvent);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  void _onEvent(MotionEvent e) {
    if (!e.active || !widget.notificationsEnabled()) return;
    final name = widget.cameraName(e.cameraId);
    if (name == null) return;
    final now = _now();
    final last = _lastShown[e.cameraId];
    if (last != null && now.difference(last) < widget.minInterval) return;
    _lastShown[e.cameraId] = now;
    String two(int v) => v.toString().padLeft(2, '0');
    final message = '$name: Motion at ${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
    if (_current == null) {
      _show(message);
    } else if (_queue.length < _maxQueued) {
      _queue.add(message);
    }
  }

  void _show(String message) {
    setState(() {
      _current = message;
      _visible = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _current == message) setState(() => _visible = true);
    });
    _timer?.cancel();
    _timer = Timer(_showFor, () {
      if (!mounted) return;
      setState(() => _visible = false);
      final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      _timer = Timer(reduce ? Duration.zero : TopoMotion.navigation, _next);
    });
  }

  void _next() {
    if (!mounted) return;
    if (_queue.isNotEmpty) {
      _show(_queue.removeAt(0));
    } else {
      setState(() => _current = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = _current;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (message != null)
          Positioned(
            top: 27,
            right: 48,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _visible ? 1 : 0,
                duration: reduce ? Duration.zero : TopoMotion.navigation,
                child: Material(
                  type: MaterialType.transparency,
                  child: Semantics(
                    liveRegion: true,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 440),
                      padding: const EdgeInsets.symmetric(horizontal: TopoSpace.xl, vertical: TopoSpace.md),
                      decoration: BoxDecoration(
                        color: TopoColors.surface,
                        borderRadius: BorderRadius.circular(TopoRadius.lg),
                        boxShadow: const [BoxShadow(color: Color(0x2910486E), blurRadius: 20, offset: Offset(0, 6))],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.directions_run_rounded, color: TopoColors.primaryAction),
                          const SizedBox(width: TopoSpace.md),
                          Flexible(child: Text(message, style: TopoText.body.copyWith(color: TopoColors.primaryPressed, height: 1.3))),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
