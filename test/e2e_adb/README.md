# Tier 4: on-device soak (adb)

Tiers 1-3 run in `flutter test` on the host with the wire-level mocks in
`test/fixtures/`. **Tier 4** is the only tier that needs an Android TV box or an
Android TV emulator. It checks what host tests cannot: real decoder, memory
pressure, D-pad focus, ANR / crash behaviour over a long run.

## What runs

| Script | Job |
|---|---|
| `scripts/demo_stream.ps1` | Serves a synthetic MPEG-TS (testsrc2 1280x720 @ 15 fps + 440 Hz sine, 8 kHz G.711 A-law) at `http://127.0.0.1:8099/live.ts`, bound to loopback only. Needs `ffmpeg` on `PATH`. |
| `scripts/adb_reverse.ps1` | `adb reverse` for 8099 (stream), 8443 (mock camera / cloud) and 8554 (RTSP) so the device sees the host services as `127.0.0.1:<port>`. |
| `scripts/run_adb_tv_soak.ps1` | Installs the APK, starts the stream, launches the app, sends 100 grid cycles of `DPAD_*` / `CHANNEL_UP` / `DPAD_CENTER` key events, samples PSS, scans logcat, writes `artifacts/soak_report.json`. |

No real camera, no cloud account and no personal data are involved. The device
only talks to `127.0.0.1` through the `adb reverse` tunnel.

## Run it

```powershell
flutter build apk --debug
powershell -File scripts/run_adb_tv_soak.ps1                 # one device attached
powershell -File scripts/run_adb_tv_soak.ps1 -Serial 192.168.1.50:5555 -Cycles 200
powershell -File scripts/run_adb_tv_soak.ps1 -SkipInstall -NoStream   # reuse app and a running stream
```

To point the app at the demo stream, add a source whose URL is
`http://127.0.0.1:8099/live.ts` (the loopback `RelayBridge` accepts it as plain
MPEG-TS). Pair the box first with `adb connect <ip>:5555` if it is on the network.

## Pass criteria

All of these must hold, otherwise the script exits `1`:

* the app process is alive after every cycle;
* no `ANR in <package>` and no `FATAL EXCEPTION` in `logcat -d`;
* app PSS from `dumpsys meminfo <package>` stays below **220 MB** (`-PssLimitMb`),
  sampled every 10 cycles and after the last one.

## Exit codes and report

| Code | Meaning |
|---|---|
| 0 | soak passed |
| 1 | soak failed (crash, ANR, PSS over the limit) |
| 2 | no adb, or no / several devices: nothing was tested. The report has `status: skipped_no_device` |
| 3 | setup error: APK missing, install failed, stream or launch failed |

`artifacts/soak_report.json` (git-ignored) holds `status`, `cycles_done`,
`pss_samples_mb`, `pss_max_mb`, `anr`, `fatal`, `process_died`, `failures`, and
UTC timestamps. CI must treat exit code 2 as "not run", never as a pass.

## Notes

* Keys are sent with `adb shell input keyevent`, so they exercise the same
  `KeyEvent` path as a remote. They do not replace the widget tests in
  `test/widget_tv/`, which cover focus logic deterministically.
* PSS includes the Flutter engine and the native ExoPlayer buffers, which is the
  number that matters on a 1 to 2 GB TV box.
* A security product that inspects HTTP on the host (for example AdGuard) can
  reject the :8800 multipart traffic of the host-side mocks with a 400 page. The
  self-tests detect this and switch the :8800 mock to TLS; see `useTls` in
  `test/fixtures/mock_media8800.dart`.
