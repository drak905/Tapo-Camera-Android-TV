import 'package:flutter/material.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../state/camera_names.dart' show cameraNameMaxBytes;
import '../ui/theme.dart';
import '../ui/tv.dart';

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
  late String _value = widget.currentName;

  /// The normalised name when valid, else null (with [_error] set).
  String? _valid;
  String? _error;

  @override
  void initState() {
    super.initState();
    _validate();
  }

  void _validate() {
    final raw = _value;
    if (raw.contains(RegExp(r'[\r\n\t]'))) {
      _valid = null;
      _error = 'The name cannot contain line breaks or tabs.';
      return;
    }
    // Same rules as `normalizeCameraName` (api lane), kept here so the dialog
    // shows its messages without depending on that implementation.
    final name = unorm.nfc(raw).trim();
    _valid = null;
    if (name.isEmpty) {
      _error = 'Enter a name.';
    } else if (name.runes.any((r) => r < 0x20 || (r >= 0x7F && r < 0xA0))) {
      _error = 'The name cannot contain control characters.';
    } else if (_byteLength(name) > cameraNameMaxBytes) {
      _error = 'The name is too long (${_byteLength(name)} of $cameraNameMaxBytes bytes). '
          'Letters with accents count as 2-3 bytes.';
    } else {
      _valid = name;
      _error = null;
    }
  }

  static int _byteLength(String s) => s.runes.fold<int>(0, (n, r) => n + (r < 0x80 ? 1 : r < 0x800 ? 2 : r < 0x10000 ? 3 : 4));

  bool get _changed => _valid != null && _valid != widget.currentName;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: TopoColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(TopoRadius.xl)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(TopoSpace.x3),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Rename camera', style: TopoText.headline),
              const SizedBox(height: TopoSpace.sm),
              Text(
                widget.localOnly
                    ? 'This name is only used on this TV. The camera keeps its own name.'
                    : 'The name is saved on the camera, so it also shows in the Tapo app.',
                style: TopoText.body.copyWith(color: TopoColors.muted),
              ),
              const SizedBox(height: TopoSpace.x2),
              TvTextField(
                label: 'Camera name',
                value: _value,
                autofocus: true,
                onChanged: (v) => setState(() {
                  _value = v;
                  _validate();
                }),
              ),
              if (_error != null) ...[
                const SizedBox(height: TopoSpace.sm),
                Semantics(
                  liveRegion: true,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.error_outline_rounded, size: 20, color: TopoColors.error),
                      const SizedBox(width: TopoSpace.sm),
                      Expanded(child: Text(_error!, style: TopoText.caption.copyWith(color: TopoColors.error))),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: TopoSpace.x2),
              Row(
                children: [
                  TvButton(
                    label: 'Save',
                    icon: Icons.check_rounded,
                    style: TvButtonStyle.primary,
                    onPressed: _changed ? () => Navigator.of(context).pop(_valid) : null,
                  ),
                  const SizedBox(width: TopoSpace.md),
                  TvButton(label: 'Cancel', style: TvButtonStyle.text, onPressed: () => Navigator.of(context).pop()),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
