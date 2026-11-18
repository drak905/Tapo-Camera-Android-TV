import 'package:flutter/material.dart';

/// Opens the rename dialog; resolves to the new (NFC, trimmed) name, or null
/// when cancelled. [localOnly] = shared or manual camera: the name is only
/// used on this TV.
Future<String?> showRenameDialog(BuildContext context, {required String currentName, required bool localOnly}) =>
    showDialog<String>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => RenameDialog(currentName: currentName, localOnly: localOnly),
    );

class RenameDialog extends StatefulWidget {
  const RenameDialog({super.key, required this.currentName, required this.localOnly});
  final String currentName;
  final bool localOnly;

  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<RenameDialog> {
  @override
  Widget build(BuildContext context) => throw UnimplementedError('ui lane GREEN: RenameDialog');
}