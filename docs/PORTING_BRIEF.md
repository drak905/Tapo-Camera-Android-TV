# Porting brief (shared by every agent lane)

Workspace: `C:\Projects\TapoCameraAndroidTV` (git repo, public on GitHub as
`drak905/Tapo-Camera-Android-TV`). Plan: `docs/porting_plan.md`.

## Sources (git-ignored, read-only)
- `refs/Tapo-Camera-Windows` – the finished Windows app (Python). Read its
  `AGENTS.md` first. Protocol facts: `specs/*_spec.json`, code under
  `src/tapo_desktop/core` and `src/tapo_desktop/services`, tests under `tests/`.
- `refs/tapo-android-tv` – Topo TV (MIT), already imported as the baseline of
  this repo (`lib/`, `android/`, `test/`). Do not edit `refs/`.

## Toolchain
- Flutter 3.47.2: `C:\Projects\tools\flutter\bin\flutter.bat` (prepend
  `C:\Projects\tools\flutter\bin` to PATH). No fvm; plain `flutter`.
- Android SDK: `%LOCALAPPDATA%\Android\Sdk` (API 34 + 36). JAVA_HOME = JDK 21.
- Tests: `flutter test` (Dart). Kotlin unit tests: `android\gradlew.bat -p android testDebugUnitTest`.

## Architecture decisions (override the plan where they differ)
The plan assumes the local path is RTSP :554 + ONVIF :2020. Real hardware
(Windows `AGENTS.md` section 5) says otherwise. The target mirrors the Windows app:

| Camera situation | Control | Live video | SD playback |
|---|---|---|---|
| Same LAN, owned | local HTTPS :443 (secure v3 / legacy MD5 / **TPAP SPAKE2+**, LAT mode) | :8800 media (Digest, MD5 or **HKDF** keys) | :8800 |
| Remote or shared | cloud passthrough (`services-sync`) | cloud relay (`cloudType: 2`) | relay VOD |
| Camera account configured (optional) | ONVIF :2020 (PTZ, PullPoint motion) | RTSP :554 `/stream1` `/stream2` | – |

- Discovery: TDP UDP 20002 broadcast (RSA-OAEP + AES `encrypt_info`), matched to cloud devices by md5(deviceId) or MAC.
- Shared cameras (thing `role` 1) are never logged in locally.
- Online state = IoT thing `status == 1`, or found on the LAN.
- Audio (G.711 A-law, 8 kHz) and encrypted relay parts are new work on TV.
- Native player stays `androidx.media3` ExoPlayer, embedded focus-less (`LivePlayer.kt`).
  Every byte source (local :8800, relay, VOD) is fed to it as plain MPEG-TS
  through the loopback `RelayBridge` (127.0.0.1, random per-launch key).
- Secrets: Android Keystore (`flutter_secure_storage`); never store the cloud password.

## Safety rules (from Windows AGENTS.md, keep them)
- Camera lockout: never loop logins; TPAP max 2 attempts; auth breaker 120 s.
- Never move/toggle/format/reboot a real camera. No real hardware in tests.
- No personal data in git: no real IPs (use `192.168.1.x`/`10.0.0.x`), names, e-mails, ids, tokens.
- TDD: failing tests first, then code. Never weaken a test to make it pass.
- Files UTF-8 without BOM, LF endings.
- Spec items cite the Windows source as `file:line` and the Windows spec id `[spec:<id>]`.
