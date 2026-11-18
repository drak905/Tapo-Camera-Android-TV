# Lane ownership (Waves 2 and 3)

Spec: `specs/android_tv_port_spec.json` (decisions at the top win over lane files).
A lane edits ONLY the paths it owns. Anything else: write the need in the lane's
final report and the orchestrator resolves it at the barrier.

| Lane | Owns (lib + android) | Owns (tests/scripts) | Spec items |
|---|---|---|---|
| api | `lib/api/` except `relay_bridge.dart`, `vod_session.dart`; `lib/state/secure_store.dart`, `lib/state/camera_names.dart` | `test/unit/` except UI-owned files; `test/api/` except VOD playback files | `hc.*`, `vod.search.*`, `vod.transport.routing`, `ev.*` |
| player | `lib/media/**`, `lib/player/**`, `lib/api/relay_bridge.dart`, `lib/api/vod_session.dart`, `android/app/src/main/kotlin/**`, `android/app/src/test/**`, `android/app/build.gradle.kts`, `android/app/src/main/res/xml/network_security_config.xml` | `test/media/**`, `test/player/**`, `test/relay_bridge_test.dart`, `test/stream_queue_test.dart`, `test/api/vod_{session,relay,transport,controls,end}_test.dart` | `mb.*`, `vod.playback.*` |
| ui | `lib/ui/**`, `lib/screens/**`, `lib/state/` except api-owned files, `lib/main.dart`, `android/app/src/main/AndroidManifest.xml`, `android/app/src/main/res/` except xml | `test/widget_tv/**`, `test/screens/**`, `test/ui/**`, `test/unit/{app_state,app_state_grids,grids,camera_sort,manifest}_test.dart` | `ui.*`, `vod.ui.*` |
| fixture | `test/fixtures/**`, `scripts/demo_stream.ps1`, `scripts/adb_reverse.ps1`, `scripts/run_adb_tv_soak.ps1` | `test/fixtures_selftest/**`, `test/e2e_adb/**` | wire-level mocks for all lanes, Tier 4 |

Shared rules:
- `pubspec.yaml`: do not edit. Ask in the report for a new package.
- Name clashes in the spec are settled as: one recordings screen
  `lib/screens/vod_timeline_screen.dart`; motion toast `lib/ui/motion_pip_toast.dart`;
  relay slot request + tunnel live in `lib/media/relay/` (player), using the cloud
  token, CIPC URL and signed POST exposed by `lib/api/tapo_cloud.dart` (api).
- Cross-lane types the UI needs (camera model with `role`, `online`, route) are
  defined by the api lane in `lib/api/camera_router.dart`; the UI wires them into
  `lib/state/app_state.dart`.
