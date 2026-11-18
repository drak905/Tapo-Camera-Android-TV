import 'package:flutter/material.dart';

import '../state/camera_view_model.dart';
import 'theme.dart';

/// "Local" / "Cloud" / "Offline" chip (icon + text). Shown on home cards,
/// in the live top bar and in grid tile corners.
class RouteBadge extends StatelessWidget {
  const RouteBadge({super.key, required this.route, required this.online, this.compact = false});
  final CameraRoute route;
  final bool online;

  /// Smaller chip for grid tile corners.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final (label, icon, color) = !online
        ? ('Offline', Icons.cloud_off_rounded, TopoColors.error)
        : route == CameraRoute.local
            ? ('Local', Icons.lan_rounded, TopoColors.success)
            : ('Cloud', Icons.cloud_queue_rounded, TopoColors.primaryPressed);
    final size = compact ? 14.0 : 16.0;
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 8, vertical: compact ? 2 : 3),
          decoration: BoxDecoration(
            color: TopoColors.surface,
            borderRadius: BorderRadius.circular(TopoRadius.sm),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: size + 2, color: color),
              SizedBox(width: compact ? 3 : 5),
              Text(label, style: TextStyle(color: color, fontSize: size, fontWeight: FontWeight.w700, height: 1.2)),
            ],
          ),
        ),
      ),
    );
  }
}
