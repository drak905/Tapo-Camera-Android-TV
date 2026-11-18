import 'package:flutter/material.dart';

import '../main.dart';
import '../state/app_state.dart';
import '../state/camera_sort.dart';
import '../ui/guide.dart';
import '../ui/theme.dart';
import '../ui/tv.dart';

class SettingsPanel extends StatefulWidget {
  const SettingsPanel({super.key});

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  /// Number of cameras with a camera account (optional RTSP/ONVIF login).
  int _accounts = 0;

  @override
  void initState() {
    super.initState();
    _countAccounts();
  }

  Future<void> _countAccounts() async {
    final app = AppScope.read(context);
    var n = 0;
    for (final camera in app.cameras) {
      try {
        if (await app.cameraAccountUser(camera) != null) n++;
      } catch (_) {}
    }
    if (mounted) setState(() => _accounts = n);
  }

  Future<void> _chooseAccountCamera() async {
    final app = AppScope.read(context);
    final camera = await showTvDialog<Camera>(
      context,
      (context) => TvDialog(
        title: 'Camera account',
        message: 'Choose the camera this account belongs to.',
        children: [
          for (final (i, c) in app.sortedCameras.indexed) ...[
            TvTile(
              title: c.name,
              subtitle: c.model,
              icon: Icons.videocam_rounded,
              autofocus: i == 0,
              onSelect: () => Navigator.pop(context, c),
            ),
            const SizedBox(height: TopoSpace.md),
          ],
          TvButton(label: 'Cancel', style: TvButtonStyle.text, onPressed: () => Navigator.pop(context)),
        ],
      ),
    );
    if (camera == null || !mounted) return;
    final saved = await showTvDialog<bool>(context, (_) => _CameraAccountDialog(app: app, camera: camera));
    if (saved == true) {
      await _countAccounts();
      if (mounted) showToast(context, 'Camera account updated');
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    Widget value(String text) => Container(
          padding: const EdgeInsets.symmetric(horizontal: TopoSpace.md, vertical: 6),
          decoration: BoxDecoration(color: TopoColors.surface, borderRadius: BorderRadius.circular(TopoRadius.full)),
          child: Text(text, style: TopoText.label.copyWith(color: TopoColors.primaryPressed)),
        );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          // A short list: every tile is built, so focus search always finds it.
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(8),
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TvTile(
                title: 'Tapo account',
                subtitle: app.accountHint.isEmpty ? 'Signed in · ${app.regionHost}' : '${app.accountHint} · ${app.regionHost}',
                icon: Icons.person_rounded,
                autofocus: true,
              ),
              const SizedBox(height: TopoSpace.md),
              TvTile(
                title: 'Live previews on the camera list',
                subtitle: 'Turn off to save data on slower TVs',
                icon: Icons.videocam_rounded,
                // Changes only on OK, never on focus.
                trailing: ExcludeFocus(
                  child: Switch(
                    value: app.livePreviews,
                    activeThumbColor: TopoColors.onPrimary,
                    activeTrackColor: TopoColors.primaryAction,
                    onChanged: (v) => app.setLivePreviews(v),
                  ),
                ),
                onSelect: () => app.setLivePreviews(!app.livePreviews),
              ),
              const SizedBox(height: TopoSpace.md),
              TvTile(
                title: 'Pan & tilt step',
                subtitle: 'How far the camera moves per arrow press',
                icon: Icons.open_with_rounded,
                trailing: value('${app.ptzStep}°'),
                onSelect: () {
                  const steps = [5, 10, 20];
                  app.setPtzStep(steps[(steps.indexOf(app.ptzStep) + 1) % steps.length]);
                },
              ),
              const SizedBox(height: TopoSpace.md),
              TvTile(
                title: 'Camera sort',
                subtitle: 'Order of the camera list and the All cameras grid',
                icon: Icons.sort_rounded,
                trailing: value(app.cameraSort.label),
                onSelect: () {
                  const modes = CameraSort.values;
                  app.setCameraSort(modes[(modes.indexOf(app.cameraSort) + 1) % modes.length]);
                },
              ),
              const SizedBox(height: TopoSpace.md),
              TvTile(
                title: 'Max remote streams',
                subtitle: 'Cameras streamed through the cloud at the same time',
                icon: Icons.cloud_queue_rounded,
                trailing: value('${app.maxRemoteStreams}'),
                onSelect: () => app.setMaxRemoteStreams(app.maxRemoteStreams % 8 + 1),
              ),
              const SizedBox(height: TopoSpace.md),
              TvTile(
                title: 'Motion alerts',
                subtitle: 'Show a message when a camera detects motion',
                icon: Icons.notifications_rounded,
                trailing: value(app.motionNotifications ? 'On' : 'Off'),
                onSelect: () => app.setMotionNotifications(!app.motionNotifications),
              ),
              const SizedBox(height: TopoSpace.md),
              TvTile(
                title: 'Camera account',
                subtitle: _accounts == 0
                    ? 'Not set (optional)'
                    : _accounts == 1
                        ? 'Set for 1 camera'
                        : 'Set for $_accounts cameras',
                icon: Icons.key_rounded,
                trailing: const Icon(Icons.chevron_right_rounded, color: TopoColors.muted),
                onSelect: app.cameras.isEmpty ? null : _chooseAccountCamera,
              ),
              const SizedBox(height: TopoSpace.md),
              TvTile(
                title: 'Remember password on this TV',
                subtitle: 'Off by default. Kept in the TV secure storage, never in plain text',
                icon: Icons.lock_rounded,
                trailing: value(app.rememberPassword ? 'On' : 'Off'),
                onSelect: () => app.setRememberPassword(!app.rememberPassword),
              ),
              const SizedBox(height: TopoSpace.md),
              TvTile(
                title: 'Remote control guide',
                subtitle: 'See which buttons do what',
                icon: Icons.help_outline_rounded,
                trailing: const Icon(Icons.chevron_right_rounded, color: TopoColors.muted),
                onSelect: () => showRemoteGuide(context),
              ),
              const SizedBox(height: TopoSpace.md),
              TvTile(
                title: 'Sign out',
                subtitle: 'Removes the saved Tapo session from this TV',
                icon: Icons.logout_rounded,
                danger: true,
                onSelect: () async {
                  final ok = await confirmDialog(
                    context,
                    title: 'Sign out?',
                    message: 'You will need your Tapo password and a verification code to sign in again.',
                    confirmLabel: 'Sign out',
                    danger: true,
                  );
                  if (ok && context.mounted) await app.logout();
                },
              ),
            ],
            ),
          ),
        ),
        const SizedBox(width: TopoSpace.x3),
        SizedBox(
          width: 250,
          child: Container(
            padding: const EdgeInsets.all(TopoSpace.x2),
            decoration: BoxDecoration(
              gradient: featuredGradient,
              borderRadius: BorderRadius.circular(TopoRadius.lg),
              boxShadow: featuredShadow,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset('assets/topo.png', width: 56, height: 56, semanticLabel: 'Topo'),
                const SizedBox(height: TopoSpace.md),
                const Text('Topo TV 1.2.0', style: TopoText.label),
                const SizedBox(height: TopoSpace.xs),
                const Text(
                  'Android TV port of github.com/filirnd/topo. MIT licence. Not affiliated with TP-Link.',
                  style: TopoText.caption,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Username and password for one camera (optional RTSP/ONVIF account).
/// Save tests the login once; an empty pair removes the account.
class _CameraAccountDialog extends StatefulWidget {
  const _CameraAccountDialog({required this.app, required this.camera});
  final AppState app;
  final Camera camera;

  @override
  State<_CameraAccountDialog> createState() => _CameraAccountDialogState();
}

class _CameraAccountDialogState extends State<_CameraAccountDialog> {
  String _username = '';
  String _password = '';
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.app.cameraAccountUser(widget.camera).then((user) {
      if (mounted && user != null && _username.isEmpty) setState(() => _username = user);
    }).catchError((_) {});
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await widget.app.saveCameraAccount(widget.camera, _username.trim(), _password);
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop(true);
      } else {
        setState(() {
          _busy = false;
          _error = 'Could not sign in to the camera with this account.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return TvDialog(
      title: 'Camera account',
      message: '${widget.camera.name}. Used for the optional RTSP and ONVIF connection. '
          'Leave both fields empty to remove it.',
      children: [
        TvTextField(
          label: 'Username',
          value: _username,
          icon: Icons.person_rounded,
          autofocus: true,
          onChanged: (v) => setState(() => _username = v),
        ),
        const SizedBox(height: TopoSpace.md),
        TvTextField(
          label: 'Password',
          value: _password,
          icon: Icons.key_rounded,
          obscure: true,
          onChanged: (v) => setState(() => _password = v),
        ),
        if (_error != null) ...[
          const SizedBox(height: TopoSpace.md),
          Semantics(
            liveRegion: true,
            child: Text(_error!, style: TopoText.caption.copyWith(color: TopoColors.error)),
          ),
        ],
        const SizedBox(height: TopoSpace.x2),
        Row(
          children: [
            TvButton(
              label: 'Save',
              icon: Icons.check_rounded,
              style: TvButtonStyle.primary,
              busy: _busy,
              onPressed: _save,
            ),
            const SizedBox(width: TopoSpace.md),
            TvButton(label: 'Cancel', style: TvButtonStyle.text, onPressed: () => Navigator.of(context).pop(false)),
          ],
        ),
      ],
    );
  }
}
