import 'package:flutter/material.dart';

import '../state/camera_view_model.dart';

/// "Local" / "Cloud" / "Offline" chip (icon + text). Shown on home cards,
/// in the live top bar and in grid tile corners.
class RouteBadge extends StatelessWidget {
  const RouteBadge({super.key, required this.route, required this.online});
  final CameraRoute route;
  final bool online;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink(); // RED stub
}