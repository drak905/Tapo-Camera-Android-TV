# Tapo TV (Tapo-Camera-Android-TV)

Unofficial Android TV / Google TV client for TP-Link Tapo cameras.
Work in progress: this repository is being built by following
`AGENTS.md` and the porting plan.

It combines two projects:

| Part | Comes from |
|---|---|
| 10-foot UI, D-pad remote, grids, cloud relay player | [Topo TV](https://github.com/abdulmominsakib/tapo-android-tv) (MIT) |
| Local LAN protocol (TDP discovery, TPAP/secure login, :8800 media, SD playback), relay VOD, cloud passthrough | [Tapo-Camera-Windows](https://github.com/drak905/Tapo-Camera-Windows) |

## Build

Requirements: Flutter 3.47.2 (`.fvmrc`), Android SDK 36, JDK 17 or 21.
`scripts/check_and_install_tv_prereqs.ps1` installs them on Windows.

```powershell
flutter pub get
flutter test
flutter build apk --release
```

Unofficial and not affiliated with TP-Link. See [LICENSE](LICENSE).
