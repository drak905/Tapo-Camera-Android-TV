# AGENTS.md: handover for coding agents

Read this first. Shared facts for every lane are in `docs/PORTING_BRIEF.md`;
lane ownership is in `docs/LANES.md`; the merged spec is
`specs/android_tv_port_spec.json` (decisions at the top win).

## What this is
Unofficial Android TV / Google TV client for TP-Link Tapo cameras (Flutter +
Kotlin media3). It ports the protocol work of the Windows app
(`drak905/Tapo-Camera-Windows`) onto the Topo TV 10-foot UI
(`abdulmominsakib/tapo-android-tv`, MIT).

- Same LAN: TDP discovery, local login (secure v3 / legacy MD5 / TPAP SPAKE2+,
  LAT aware) on :443, live and SD playback on :8800 (Digest, MD5/HKDF keys).
- Remote or shared: cloud passthrough for control, cloud relay for live and SD playback.
- Owned LAN cameras fall back to the relay when the local stream fails (`FailoverSource`, 2.5 s).
- Every byte source reaches ExoPlayer as plain MPEG-TS through `RelayBridge`
  (127.0.0.1, per-launch key). The native player refuses any other URL.

## Machine setup (Windows)
```powershell
powershell -ExecutionPolicy Bypass -File scripts/check_and_install_tv_prereqs.ps1
powershell -File scripts/install_hooks.ps1     # pre-commit secret/keystore guard
```
Flutter 3.47.2 lives in `C:\Projects\tools\flutter` (no fvm; `.fvmrc` pins the version).
Android SDK 36 in `%LOCALAPPDATA%\Android\Sdk`; JDK 17 or 21.

## Everyday commands
| Task | Command |
|---|---|
| All tests (about 5 min) | `python tools/test_summary.py` |
| One area | `python tools/test_summary.py test/media` |
| Kotlin unit tests | `cd android; .\gradlew.bat :app:testDebugUnitTest` |
| Spec merge check (Gate 1) | `python tools/merge_specs.py --check` and `test/spec_parity_test.dart` |
| Release APK (arm, arm64, x64) | `flutter build apk --release` |
| Demo APK for the emulator | `flutter build apk --release --target-platform android-x64 --dart-define=TOPO_DEMO=true --dart-define=TOPO_DEMO_STREAM=http://127.0.0.1:8099/live.ts` |
| Soak (Tier 4) | start the emulator (below), then `scripts/run_adb_tv_soak.ps1 -Apk <demo apk> -Cycles 100` |

Emulator: AVD `TapoTV_API36` (`system-images;android-36;android-tv;x86_64`).
Start it with `emulator -avd TapoTV_API36 -no-snapshot -no-audio -gpu host -grpc 8560`.
- `-gpu swiftshader_indirect` makes the emulator exit as soon as video decodes.
- `-grpc 8560` keeps the emulator's gRPC port off 8554 (used by `adb reverse`).
- 32-bit x86 TV images cannot run Flutter release builds (libflutter.so is ARM-only there).
- Processes started by an agent tool call die when the call returns: boot, test and
  screenshot in the same call.

## Rules
- Camera lockout: never loop logins; TPAP makes at most 2 attempts; the auth breaker
  blocks 120 s after a wrong password. Tests enforce this.
- Real devices: read-only or no-op actions only, without the owner's consent.
- No personal data in git (real IPs, names, e-mails, ids, tokens). The pre-commit hook
  blocks some patterns; never bypass it. Use `192.168.1.x` / `10.0.0.x`.
- TDD: failing tests first (`test(red):` commit), then code. Fix a provably wrong test
  only in a separate `test(fix):` commit with the reason.
- Fixtures under `test/fixtures/` are wire-level mocks: additive changes only, new
  behaviour behind an option.
- New files UTF-8 without BOM, LF. Some baseline files are still CRLF.
- AdGuard on the dev PC intercepts plain loopback HTTP; :8800 tests fall back to TLS.

## Known gaps
See `docs/STATUS.md`.
