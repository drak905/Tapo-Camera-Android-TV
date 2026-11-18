# Status

## Verified (2026-11-18)
| Gate | Check | Result |
|---|---|---|
| 1 | `test/spec_parity_test.dart`, `python tools/merge_specs.py --check` | every spec item has a test or a mapped reason; merged spec up to date |
| 2 | `python tools/test_summary.py` (Tier 1 unit, Tier 2 integration vs Dart mocks, Tier 3 TV widgets) | 1041 pass, 0 fail; Kotlin JUnit 13 pass |
| 3 | `flutter build apk --release`, demo `android-arm` and `android-x64` | built (55.7 MB universal, 16.4 MB arm demo, 20.3 MB x64 demo) |
| 4 | `scripts/run_adb_tv_soak.ps1` on the Android TV 36 x86_64 emulator, demo stream playing | 230 cycles in 28.5 min, 0 ANR, 0 FATAL, max PSS 162 MB (limit 220) |

## Not verified on real hardware
Everything below is tested only against the Dart mocks in `test/fixtures/`:
- Sign-in and MFA against the real TP-Link cloud from the TV.
- Local login (v3, TPAP, LAT) and :8800 video with real C200/C510W cameras.
- Relay live view and relay SD playback with real cameras.
- TDP discovery on a real TV box (broadcast assumes a /24 network plus 255.255.255.255).
- Capability names for night vision / siren / SD card (`capabilitiesFromComponents`).
- Hardware H.264 decoding and memory on a real (low-end) TV box.

## Not built yet
- Audio (G.711 A-law decode exists in `lib/media/audio/`, playback through AudioTrack is not wired).
- Two-way talk, clip download, ONVIF discovery and ONVIF PTZ (spec: deferred).
- RTSP playback with a camera account (URL builder only).
- Encrypted relay parts: key schedule unknown; the app reports the camera as unsupported.

## Spec text notes
- `mb.local.preview_flow` shows `seq` second in the preview JSON; Windows (and the code) put it last.
- Four spec target names are stale (mapped in `test/spec_parity_test.dart`): `assets/tplink_roots.pem`,
  `lib/api/local_media.dart`, `lib/screens/recordings_screen.dart`, `lib/screens/playback_screen.dart`.

## Build warnings
AGP 9 deprecations (`android.builtInKotlin`, `android.newDsl`, the `kotlin-android` plugin in
plugins, `Task.project` at execution time). No Kotlin warnings in our sources.
