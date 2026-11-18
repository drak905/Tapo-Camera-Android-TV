# Tapo TV (Tapo-Camera-Android-TV)

Unofficial Android TV / Google TV client for TP-Link Tapo cameras. You only need the remote.

| Part | Comes from |
|---|---|
| 10-foot UI, D-pad remote, multi-view grids, ExoPlayer view | [Topo TV](https://github.com/abdulmominsakib/tapo-android-tv) (MIT) |
| Local LAN protocol (TDP discovery, TPAP / secure login, :8800 video, SD playback), relay VOD, cloud passthrough | [Tapo-Camera-Windows](https://github.com/drak905/Tapo-Camera-Windows) |

## Features
- Sign in with your TP-Link ID (with MFA). Cameras appear with their cloud names.
- Cameras on the same network are found and streamed directly; if that fails, the
  app falls back to the TP-Link cloud relay. Remote and shared cameras use the relay.
- Live previews, full-screen live view, grids (2 side by side, 2 x 2, 1 + 5, 3 x 3, all cameras).
- Pan and tilt, privacy mode, night vision, siren, rename (local name for shared cameras).
- SD card recordings on a 24 h timeline, 1x to 8x.
- Motion notes in the top-right corner.

## Using the remote
| Where | Key | What it does |
|---|---|---|
| Everywhere | Arrows / OK / Back | Move, select, go back |
| | Menu / Info | Remote guide |
| Cameras | OK | Watch live |
| | Hold OK | Quick actions: privacy, night vision, siren, rename, reconnect |
| | 1-9 | Open camera 1 to 9 |
| Grid | OK / Hold OK | Tile full screen / put another camera in the tile |
| | CH+ / CH- | Next / previous grid |
| Live view | Arrows | Pan and tilt |
| | OK | Controls (incl. Recordings) |
| Recordings | Left / Right | Move on the timeline |
| | Up / Down | Other day |
| | OK | Play; while playing: pause and speed |

## Build
Requirements: Flutter 3.47.2 (`.fvmrc`), Android SDK 36, JDK 17 or 21.
`scripts/check_and_install_tv_prereqs.ps1` installs them on Windows.

```powershell
flutter pub get
python tools/test_summary.py
flutter build apk --release
```

Install on the TV: `adb connect <tv-ip>:5555`, then `adb install -r build/app/outputs/flutter-apk/app-release.apk`.

Developer notes: [AGENTS.md](AGENTS.md). What is verified: [docs/STATUS.md](docs/STATUS.md).

## Privacy
- The cloud password is not stored unless you turn on "Remember password on this TV"
  (Android Keystore). Tokens are in Keystore-backed storage.
- TLS checks stay on; local cameras are pinned on first use.
- Video stays on the TV: the local bridge listens on 127.0.0.1 with a random per-launch key.

Unofficial and not affiliated with TP-Link. See [LICENSE](LICENSE).
