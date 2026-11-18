# Autonomous Agent CLI Execution Plan: Porting Tapo Camera Windows App to Native Android TV via Multi-Subagent Parallelism & Strict TDD

## 1. Executive Summary & Cross-Platform Porting Strategy

This master execution plan instructs an autonomous Agent CLI (Claude Code, Kiro CLI, or Antigravity) running on a Windows x64 host to port the completed [Tapo-Camera-Windows (`drak905/Tapo-Camera-Windows`)](https://github.com/drak905/Tapo-Camera-Windows) desktop application into a production-grade **Android TV & Google TV application**, using [Topo TV (`abdulmominsakib/tapo-android-tv`)](https://github.com/abdulmominsakib/tapo-android-tv) as the reference 10-foot UI and TV player architecture.

While [Topo TV (`abdulmominsakib/tapo-android-tv/blob/main/README.md`)](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md) provides a well-designed Flutter 10-foot D-pad interface and a focusless native `ExoPlayer` (`androidx.media3`) view (`LivePlayer.kt`), it has four major architectural limitations documented in its repository:
- **Cloud-Only Dependency**: It relies exclusively on undocumented Tapo cloud relays and cannot connect directly to cameras on the local LAN via RTSP (`:554`), ONVIF (`:2020`), or Local HTTPS (`:443`).
- **No Audio or Two-Way Talk**: It strips audio tracks and lacks `pcm_alaw` (G.711 A-law) decoding or talkback support.
- **No SD Card Recordings, Snapshots, or Motion Alerts**: It lacks the 24-hour SD card VOD timeline, clip downloader, and real-time ONVIF motion toast overlays.
- **No Encrypted Camera Stream Support**: It fails on newer Tapo firmware that enforces local/relay stream encryption.

By combining the proven **Local LAN Protocol Triad & Core Engine** from [Tapo-Camera-Windows (`drak905/Tapo-Camera-Windows`)](https://github.com/drak905/Tapo-Camera-Windows) with the **10-Foot Remote UX & Native Media3 Surface Architecture** from [tapo-android-tv (`abdulmominsakib/tapo-android-tv`)](https://github.com/abdulmominsakib/tapo-android-tv), the Agent CLI will build a unified **Hybrid Local-First + Cloud-Fallback Android TV App** (`Tapo-Camera-Android-TV`).

| Architectural Dimension | Source Reference: `Tapo-Camera-Windows` | Reference TV Port: `tapo-android-tv` | Target Unified Android TV Architecture (`Tapo-Camera-Android-TV`) |
| :--- | :--- | :--- | :--- |
| **Connection & Control Plane** | Local HTTPS `:443` (`stok`, AES-CBC/GCM, `multipleRequest`) + ONVIF `:2020` ([Tapo-Camera-Windows](https://github.com/drak905/Tapo-Camera-Windows)). | Cloud-only HTTPS signed API (`lib/api/tapo_cloud.dart`) ([tapo-android-tv README](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md)). | **Dual-Engine Hybrid**: Zero-latency Local LAN (`:443` / `:554` / `:2020`) primary mode ([TP-Link RTSP/ONVIF Guide](https://www.tp-link.com/us/support/faq/2680/)) + Cloud Relay (`tapo_cloud.dart`) remote fallback. |
| **Video & Audio Pipeline** | RTSP `:554` (`/stream1`, `/stream2`, `/stream6`) + `pcm_alaw` audio ([Tapo-Camera-Windows](https://github.com/drak905/Tapo-Camera-Windows)). | Local loopback `RelayBridge` (`127.0.0.1`) feeding video-only MPEG-TS to `LivePlayer.kt` (`ExoPlayer`) ([tapo-android-tv README](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md)). | **Native Media3 ExoPlayer (`LivePlayer.kt`)**: Hardware `MediaCodec` H.264/H.265 + 8 kHz G.711 `pcm_alaw` audio bridge over RTSP `:554` and `127.0.0.1` loopback with per-launch secret token. |
| **10-Foot TV UI & Remote Control** | Desktop mouse/keyboard grid & PTZ overlay ([Tapo-Camera-Windows](https://github.com/drak905/Tapo-Camera-Windows)). | `960 × 540` overscan-safe grid, 3-unit focus ring, D-pad PTZ, `CH+/CH-`, `1–9` hotkeys, `1+5` / `2x2` / `3x3` grids ([tapo-android-tv README](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md)). | Preserves full D-pad/OK/Hold-OK/Menu/CH+/1–9 remote matrix + adds **D-Pad 24h SD Card VOD Timeline**, **IR Night Vision / Siren Quick Menu**, and **TV Picture-in-Picture (PiP) Motion Toasts**. |
| **Credential & Keystore Security** | Windows DPAPI Credential Vault ([Tapo-Camera-Windows](https://github.com/drak905/Tapo-Camera-Windows)). | Session token in private storage + bundled `assets/tapo-cloud-roots.pem` ([tapo-android-tv README](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md)). | **Android Keystore (`EncryptedSharedPreferences`)** for Local Camera Account & `stok`/cloud tokens + pinned TP-Link root CA & TOFU local camera cert fingerprints. |

## 2. Multi-Subagent Parallel Execution Topology (DAG Orchestration)

To maximize build speed on Windows, the Main Orchestrator Agent must never analyze repositories or implement Android TV subsystems sequentially in a single loop. Work is partitioned into **3 concurrent subagent waves** (4 parallel subagents per wave) isolated via **Git Worktrees** (`C:\Projects\TapoCameraAndroidTV\worktrees\<lane>`).

```
      [Main Orchestrator Agent: Step 0 Host Audit & Step 1 Public GitHub Repo Init]
        Auto-installs JDK 17, Flutter/FVM, Android SDK/NDK, ADB -> `gh repo create --public`
        Clones `drak905/Tapo-Camera-Windows` & `abdulmominsakib/tapo-android-tv` to `refs/`
                                             |
       +-------------------------------------+-------------------------------------+
       | WAVE 1: PARALLEL DUAL-REPO EXTRACTION & ARCHITECTURE MAPPING (4 Agents)   |
       v                         v                         v                       v
+-----------------+     +------------------+     +------------------+     +-----------------+
|Subagent-Audit-  |     |Subagent-Audit-   |     |Subagent-Audit-   |     |Subagent-Audit-  |
|Protocol         |     |MediaBridge       |     |TV-UI             |     |VOD-Events       |
|Extracts Local   |     |Maps Windows RTSP/|     |Extracts 960x540  |     |Maps Windows SD  |
|HTTPS :443, AES, |     |alaw pipeline to  |     |theme.dart, tv.dart|    |VOD & ONVIF :2020|
|stok & FFI/Dart  |     |RelayBridge +     |     |D-pad keymap &    |     |events to TV     |
|contracts        |     |LivePlayer.kt     |     |1+5/2x2/3x3 grids |     |remote timeline  |
+--------+--------+     +--------+---------+     +--------+---------+     +--------+--------+
         |                       |                        |                        |
         +-----------------------+-----------+------------+------------------------+
                                             |
               [SYNCHRONIZATION BARRIER 1: Unified TV Port Spec & Gate 1]
                Merges `specs/android_tv_port_spec.json` -> Pushes to GitHub
                                             |
       +-------------------------------------+-------------------------------------+
       | WAVE 2: PARALLEL TDD RED-PHASE & TV MOCK HARNESS (4 Isolated Worktrees)   |
       v                         v                         v                       v
+-----------------+     +------------------+     +------------------+     +-----------------+
|Subagent-TV-     |     |Subagent-TDD-     |     |Subagent-TDD-     |     |Subagent-TDD-    |
|Fixture          |     |HybridApi         |     |NativePlayer      |     |RemoteUI         |
|Ports Mock Tapo  |     |Writes FAILING    |     |Writes FAILING    |     |Writes FAILING   |
|Server (:8443/   |     |(Red) tests for   |     |(Red) tests for   |     |(Red) D-pad focus|
|8554/8020) + ADB |     |Local :443 + Cloud|     |127.0.0.1 bridge, |     |traversal, 960x  |
|reverse :8099 TS |     |failover & crypto |     |alaw audio &      |     |540 overscan &   |
|stream generator |     |                  |     |staggered start   |     |VOD timeline UI  |
+--------+--------+     +--------+---------+     +--------+---------+     +--------+--------+
         |                       |                        |                        |
         +-----------------------+-----------+------------+------------------------+
                                             |
                [SYNCHRONIZATION BARRIER 2: Verify All Tests Fail (Red)]
                                             |
       +-------------------------------------+-------------------------------------+
       | WAVE 3: PARALLEL TDD GREEN/REFACTOR IMPLEMENTATION (4 Worktrees)          |
       v                         v                         v                       v
+-----------------+     +------------------+     +------------------+     +-----------------+
|Subagent-Impl-   |     |Subagent-Impl-    |     |Subagent-Impl-    |     |Subagent-Impl-   |
|HybridClient     |     |Media3Player      |     |TVGridsAndRemote  |     |TVVodAndOverlay  |
|Implements Local |     |Implements Kotlin |     |Implements Home,  |     |Implements 24h   |
|HTTPS :443, ONVIF|     |LivePlayer.kt +   |     |1+5/2x2/3x3 Grids,|     |D-pad VOD player,|
|:2020 & Cloud    |     |RTSP/MPEG-TS +    |     |CH+/1-9 keys &    |     |NightVision/PTZ  |
|client + Keystore|     |G.711 audio decode|     |focus outline UI  |     |& Motion PiP OSD |
+--------+--------+     +--------+---------+     +--------+---------+     +--------+--------+
         |                       |                        |                        |
         +-----------------------+-----------+------------+------------------------+
                                             |
        [SYNCHRONIZATION BARRIER 3: Merge, Emulator/ADB Soak, APK Build & Push]
          Builds universal + `android-arm` APKs -> Passes Gates 2–4 -> GitHub Push
```

## 3. Phase 1: Check Current Status on This Computer & Auto-Provisioning

Before cloning any repository or spawning subagents, the Agent CLI must audit the Windows x64 environment and automatically install all missing Android TV, Flutter (`fvm`), Java, and media dependencies. As noted in the [tapo-android-tv Build Guide](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md), building the Android TV target requires **JDK 17**, **FVM (Flutter Version Management) with Flutter 3.47.2+**, the **Android SDK (`platform-tools`, `cmdline-tools`, `build-tools;34.0.0`, `platforms;android-34`)**, and **FFmpeg** for synthetic live MPEG-TS/RTSP stream testing.

### Step 3.1: Required Toolchain Matrix on Windows x64

| Tool / Component | Minimum / Pinned Version | Automated Installer Command | Role in Android TV Porting Pipeline |
| :--- | :--- | :--- | :--- |
| **`git` & `gh`** | Git `>=2.40`, GitHub CLI `>=2.50` | `winget install Git.Git GitHub.cli` | Clones reference repos, manages subagent `git worktree` lanes, and creates the public GitHub repo ([GitHub CLI Manual](https://cli.github.com/manual/gh_repo_create)). |
| **`java` / `javac` (JDK 17)** | OpenJDK `17.0.x` (`JAVA_HOME`) | `winget install Microsoft.OpenJDK.17` | Required by Gradle 8.x and Flutter Android TV builds ([tapo-android-tv Build Guide](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md)). |
| **`fvm` & `flutter`** | Flutter `3.47.2` (or latest stable) | `dart pub global activate fvm` / `fvm install 3.47.2` | Compiles Dart UI, manages `--dart-define=TOPO_DEMO`, and builds `android-arm` / `arm64` APKs ([tapo-android-tv Build Guide](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md)). |
| **Android SDK & `adb`** | API 24–34, `platform-tools`, TV Emulator | `winget install Google.PlatformTools` + `sdkmanager` | Compiles Kotlin `LivePlayer.kt` (`androidx.media3`), runs `adb reverse tcp:8099 tcp:8099`, and deploys APKs to Android TV ([tapo-android-tv Install Guide](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md)). |
| **`cargo` / `rustc` (Optional FFI)** | Stable + `cargo-ndk` | `winget install Rustlang.Rustup` | Compiles any shared Rust crypto/protocol crates from [Tapo-Camera-Windows](https://github.com/drak905/Tapo-Camera-Windows) to Android JNI targets if Rust FFI is used. |
| **`ffmpeg`** | `>= 6.1` | `winget install Gyan.FFmpeg` | Generates synthetic `testsrc2` MPEG-TS (`127.0.0.1:8099/live.ts`) and RTSP `:8554` + `pcm_alaw` test streams ([tapo-android-tv UI Test Mode](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md)). |

### Step 3.2: Self-Healing Host Audit & Auto-Installer Script (`scripts/check_and_install_tv_prereqs.ps1`)

The Agent CLI must write and execute the following PowerShell script as **Step 0** to check current computer status, install any missing toolchains silently, configure `JAVA_HOME` and `ANDROID_HOME`, accept Android SDK licenses, and write `artifacts/host_tv_status_report.json`:

```powershell
# Save as: C:\Projects\TapoCameraAndroidTV\scripts\check_and_install_tv_prereqs.ps1
$ErrorActionPreference = "Stop"
$WorkspaceRoot = "C:\Projects\TapoCameraAndroidTV"
New-Item -ItemType Directory -Force -Path "$WorkspaceRoot\artifacts" | Out-Null

function Refresh-SessionPath {
    $MachinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $UserPath    = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path    = "$MachinePath;$UserPath;$env:USERPROFILE\AppData\Local\Pub\Cache\bin;$env:LOCALAPPDATA\Android\Sdk\platform-tools;$env:LOCALAPPDATA\Android\Sdk\cmdline-tools\latest\bin"
}

function Ensure-WingetPackage {
    param([string]$CommandName, [string]$WingetId, [string]$FriendlyName)
    Refresh-SessionPath
    if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
        Write-Host "[AUTO-INSTALL] '$FriendlyName' ($CommandName) missing. Installing $WingetId via winget..."
        winget install --id $WingetId -e --silent --accept-source-agreements --accept-package-agreements
        Refresh-SessionPath
    }
    return ($null -ne (Get-Command $CommandName -ErrorAction SilentlyContinue))
}

# 1. Ensure Winget is available
if (-not (Get-Command "winget" -ErrorAction SilentlyContinue)) {
    Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
    Refresh-SessionPath
}

# 2. Check and auto-install Git, GitHub CLI, OpenJDK 17, FFmpeg, ADB Platform-Tools, and Commandline-Tools
$BaseTools = @(
    @{ Cmd = "git";    Id = "Git.Git";                   Name = "Git VCS" },
    @{ Cmd = "gh";     Id = "GitHub.cli";                Name = "GitHub CLI" },
    @{ Cmd = "javac";  Id = "Microsoft.OpenJDK.17";      Name = "OpenJDK 17" },
    @{ Cmd = "ffmpeg"; Id = "Gyan.FFmpeg";               Name = "FFmpeg" },
    @{ Cmd = "adb";    Id = "Google.PlatformTools";      Name = "Android Platform Tools (ADB)" }
)

$StatusReport = @{}
foreach ($t in $BaseTools) {
    $ok = Ensure-WingetPackage -CommandName $t.Cmd -WingetId $t.Id -FriendlyName $t.Name
    $StatusReport[$t.Cmd] = @{ installed = $ok; path = (Get-Command $t.Cmd -ErrorAction SilentlyContinue).Source }
}

# 3. Configure JAVA_HOME to OpenJDK 17
$JdkPath = Resolve-Path "$env:ProgramFiles\Microsoft\jdk-17*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($JdkPath) {
    $env:JAVA_HOME = $JdkPath.Path
    [System.Environment]::SetEnvironmentVariable("JAVA_HOME", $JdkPath.Path, "User")
    $env:Path = "$env:JAVA_HOME\bin;$env:Path"
}

# 4. Check and auto-install Android SDK Command-Line Tools & Required API Packages (API 34, Build-Tools 34.0.0)
$AndroidSdkRoot = "$env:LOCALAPPDATA\Android\Sdk"
$env:ANDROID_HOME = $AndroidSdkRoot
[System.Environment]::SetEnvironmentVariable("ANDROID_HOME", $AndroidSdkRoot, "User")
New-Item -ItemType Directory -Force -Path "$AndroidSdkRoot\cmdline-tools" | Out-Null

$SdkManager = "$AndroidSdkRoot\cmdline-tools\latest\bin\sdkmanager.bat"
if (-not (Test-Path $SdkManager)) {
    Write-Host "[AUTO-INSTALL] Downloading Android SDK Command-line Tools for Windows..."
    $CmdToolsZip = "$env:TEMP\commandlinetools-win.zip"
    Invoke-WebRequest -Uri "https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip" -OutFile $CmdToolsZip
    Expand-Archive -Path $CmdToolsZip -DestinationPath "$AndroidSdkRoot\cmdline-tools\temp" -Force
    Move-Item -Path "$AndroidSdkRoot\cmdline-tools\temp\cmdline-tools" -Destination "$AndroidSdkRoot\cmdline-tools\latest" -Force
    Remove-Item -Recurse -Force "$AndroidSdkRoot\cmdline-tools\temp", $CmdToolsZip -ErrorAction SilentlyContinue
}
Refresh-SessionPath

# Accept Android SDK licenses and install required Android TV build packages
Write-Host "[AUTO-CONFIG] Accepting Android SDK licenses and installing platform-tools, android-34, build-tools;34.0.0..."
1..10 | ForEach-Object { "y" } | & $SdkManager --licenses | Out-Null
& $SdkManager "platform-tools" "platforms;android-34" "build-tools;34.0.0"

# 5. Check and auto-install FVM & Flutter 3.47.2 (matching tapo-android-tv reference)
if (-not (Get-Command "fvm" -ErrorAction SilentlyContinue)) {
    Write-Host "[AUTO-INSTALL] Installing FVM (Flutter Version Management)..."
    winget install --id LeoFarias.FVM -e --silent --accept-source-agreements --accept-package-agreements
    Refresh-SessionPath
}
Set-Location $WorkspaceRoot
fvm install 3.47.2 --setup
fvm use 3.47.2 --force
$FlutterDoc = (fvm flutter doctor -v 2>&1 | Out-String)
$StatusReport["flutter_fvm"] = @{ installed = $true; doctor_summary = $FlutterDoc }

$StatusReport | ConvertTo-Json -Depth 4 | Out-File "$WorkspaceRoot\artifacts\host_tv_status_report.json" -Encoding utf8
Write-Host "[READY] Windows host is fully provisioned for Android TV development."
```

## 4. Phase 2: Public GitHub Repository Initialization, Credential Hygiene & Reference Cloning

Before writing any code or cloning the reference repositories into `refs/`, the Main Orchestrator Agent initializes the project root, installs strict credential/keystore guards, and creates the public GitHub repository.

### Step 4.1: Hardened `.gitignore` for Android TV, Keystores & Tapo Credentials

Write the following `.gitignore` at `C:\Projects\TapoCameraAndroidTV\.gitignore` to ensure signing keystores, local camera credentials, `stok` tokens, and reference repo clones are never committed to the public repository:

```gitignore
# =====================================================================
# 1. TAPO CREDENTIALS, SESSION TOKENS & LOCAL NETWORK CONFIGS (CRITICAL)
# =====================================================================
.env
.env.*
!.env.example
*secret*
*password*
*credential*
*stok*
tapo_session.json
camera_credentials.json
local_cameras.json
local_cameras.yaml
config.local.*
local.properties
!local.properties.example

# =====================================================================
# 2. ANDROID SIGNING KEYSTORES, CERTIFICATES & PRIVATE KEYS
# =====================================================================
*.jks
*.keystore
key.properties
*.pem
!assets/tapo-cloud-roots.pem
*.key
*.pfx
*.p12
*.der
google-services.json

# =====================================================================
# 3. REFERENCE REPO CLONES, SUBAGENT WORKTREES & BUILD OUTPUTS
# =====================================================================
refs/
worktrees/
.fvm/flutter_sdk
.dart_tool/
build/
android/.gradle/
android/captures/
android/app/debug/
android/app/profile/
android/app/release/
*.apk
*.aab
*.dex
*.so
*.log
artifacts/
```

Also create `.env.example` with safe placeholder values for local testing:

```ini
# Copy to .env (git-ignored) for local hardware / ADB reverse testing
TAPO_CAMERA_LAN_IP=192.168.1.XXX
TAPO_LOCAL_CAMERA_USER=your_local_camera_account_username
TAPO_LOCAL_CAMERA_PASS=your_local_camera_account_password
TAPO_CLOUD_EMAIL=your_tapo_cloud_email@example.com
TAPO_CLOUD_PASSWORD=your_tapo_cloud_password
ANDROID_TV_ADB_IP=192.168.1.YYY:5555
```

### Step 4.2: Automated Pre-Commit Secret, Keystore & APK Guard (`.git/hooks/pre-commit`)

Install an automated `pre-commit` hook immediately after `git init -b main` to block any accidental staging of Android signing keys (`*.jks`, `*.keystore`, `key.properties`), `.env` files, `stok=` tokens, or RTSP credentials:

```powershell
$WorkspaceRoot = "C:\Projects\TapoCameraAndroidTV"
Set-Location $WorkspaceRoot
git init -b main

$PreCommitHook = @'
#!/usr/bin/env sh
STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM)
if [ -z "$STAGED_FILES" ]; then exit 0; fi

# 1. Block Android keystores, .env files, APKs, and private keys (allow assets/tapo-cloud-roots.pem)
FORBIDDEN_FILES=$(echo "$STAGED_FILES" | grep -E '\.(jks|keystore|apk|aab|dex|so|pfx|p12|key)$|(^|/)key\.properties$|(^|/)local\.properties$|(^|/)\.env($|\.)' | grep -vE '\.example$')
if [ -n "$FORBIDDEN_FILES" ]; then
    echo "[SECURITY BLOCK] Attempted to commit forbidden keystore, binary, or credential file:"
    echo "$FORBIDDEN_FILES"
    exit 1
fi

# 2. Scan staged diffs for leaked RTSP credentials, stok tokens, or hardcoded passwords
LEAK_MATCH=$(git diff --cached -U0 | grep -E '^\+' | grep -vE '^\+\+\+|your_local_camera|your_tapo_cloud|camera_user:camera_password|\{user\}:\{pass\}|mock_pass|test_pass|TOPO_DEMO' | grep -iE '(rtsp://[^/:\s]+:[^@\s]+@[0-9]+\.[0-9]+|stok=[a-f0-9]{16,}|storePassword\s*=|keyPassword\s*=|TAPO_.*_PASS\s*=\s*[^\s]+)')
if [ -n "$LEAK_MATCH" ]; then
    echo "[SECURITY BLOCK] Potential credential, keystore password, or session token detected in staged diff!"
    echo "$LEAK_MATCH"
    exit 1
fi
exit 0
'@

$PreCommitHook | Out-File -FilePath "$WorkspaceRoot\.git\hooks\pre-commit" -Encoding ascii -Force
```

### Step 4.3: Public GitHub Repository Creation & Reference Repository Cloning

The Main Orchestrator creates the public GitHub repository via [`gh repo create`](https://cli.github.com/manual/gh_repo_create) and clones both source repositories into the ignored `refs/` directory for Wave 1 analysis:

```powershell
# 1. Ensure GitHub CLI is authenticated
gh auth status
if ($LASTEXITCODE -ne 0) {
    gh auth login --hostname github.com --git-protocol https --web
}

# 2. Commit initial scaffold and create public GitHub repository
git add .gitignore .env.example scripts/
git commit -m "chore(init): initialize Android TV workspace with keystore and credential guards"

$RepoName = "Tapo-Camera-Android-TV"
gh repo view $RepoName 2>$null
if ($LASTEXITCODE -ne 0) {
    gh repo create $RepoName --public --source=. --remote=origin `
      --description "Native Android TV & Google TV client for TP-Link Tapo cameras (Local RTSP/ONVIF/HTTPS + Cloud Relay)" `
      --push
} else {
    git push -u origin main
}

# 3. Clone completed Windows app and reference Android TV app into git-ignored ./refs/
New-Item -ItemType Directory -Force -Path "$WorkspaceRoot\refs" | Out-Null
git clone https://github.com/drak905/Tapo-Camera-Windows "$WorkspaceRoot\refs\Tapo-Camera-Windows"
git clone https://github.com/abdulmominsakib/tapo-android-tv "$WorkspaceRoot\refs\tapo-android-tv"
```

## 5. Phase 3 (Wave 1): Parallel Dual-Repository Audit & Porting Spec Extraction

The Main Orchestrator spawns **4 read-only subagents in parallel** to cross-examine `refs/Tapo-Camera-Windows` ([drak905/Tapo-Camera-Windows](https://github.com/drak905/Tapo-Camera-Windows)) and `refs/tapo-android-tv` ([abdulmominsakib/tapo-android-tv](https://github.com/abdulmominsakib/tapo-android-tv)).

| Subagent ID | Assigned Porting Domain | Files Audited Across `refs/Tapo-Camera-Windows` & `refs/tapo-android-tv` | Output Specification File |
| :--- | :--- | :--- | :--- |
| **`Subagent-Audit-Protocol`** | Local LAN HTTPS `:443` + Cloud API Unification | Windows `src/core/auth`, `src/core/control_client`, `specs/tapo_protocol_spec.json` vs. TV `lib/api/tapo_cloud.dart` & `assets/tapo-cloud-roots.pem` ([tapo-android-tv README](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md)). | `specs/hybrid_control_spec.json` |
| **`Subagent-Audit-MediaBridge`** | RTSP `:554` + Loopback `127.0.0.1` Bridge + `pcm_alaw` Audio | Windows `src/core/media_engine` (RTSP `/stream1`, `/stream2`, `/stream6`, G.711 `pcm_alaw`) vs. TV `lib/api/relay_bridge.dart` & `android/.../LivePlayer.kt` (`androidx.media3` ExoPlayer) ([tapo-android-tv README](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md)). | `specs/media3_player_bridge_spec.json` |
| **`Subagent-Audit-TV-UI`** | 10-Foot `960 × 540` Overscan Layout, Grids & Remote Keymap | TV `lib/ui/theme.dart`, `lib/ui/tv.dart`, `lib/ui/guide.dart`, `lib/state/grids.dart`, `lib/screens/*` vs. Windows multi-camera grid & PTZ preset controls ([tapo-android-tv README](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md)). | `specs/tv_ui_remote_spec.json` |
| **`Subagent-Audit-VOD-Events`** | SD Card 24h Timeline VOD & ONVIF `:2020` Motion Alerts | Windows `src/core/onvif_service` (`PullPointSubscription` on port `2020`) and SD VOD downloader (`searchVideoOfDay`, `search_video_with_utc`) mapped to TV D-pad controls ([TP-Link RTSP/ONVIF Guide](https://www.tp-link.com/us/support/faq/2680/)). | `specs/tv_vod_onvif_spec.json` |

### Synchronization Barrier 1: Unified Android TV Architecture Contract

The Main Orchestrator merges the 4 subagent specs into `specs/android_tv_port_spec.json` and commits it to GitHub, locking in the following design rules:
1. **Zero-Focus-Theft Native Video Surface**: Retain the core pattern from `LivePlayer.kt` in [tapo-android-tv](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md) where the native `androidx.media3` `ExoPlayer` `SurfaceView` is embedded with `focusable = false` and `focusableInTouchMode = false` so the Android TV remote D-pad is never trapped inside the video view.
2. **Staggered Home & Grid Stream Startup**: Preserve sequential preview connection startup (connecting cameras one at a time after displaying their cached last snapshot) AND enforce the hardware 2-stream limit per camera ([HomeAssistant-Tapo-Control FAQ](https://github.com/jurajnyiri/homeassistant-tapo-control)) so budget Android TV boxes (e.g., 2 GB RAM Amlogic/MediaTek SoCs) remain 60 FPS smooth.
3. **Dual-Transport `LivePlayer.kt` & `RelayBridge`**:
   - **Local LAN Fast-Path**: When the Android TV is on the same home subnet as the camera, `LivePlayer.kt` uses `androidx.media3:media3-exoplayer-rtsp` (`RtspMediaSource.Factory().setForceUseRtpTcp(true)`) directly against `rtsp://{user}:{pass}@{ip}:554/stream2` (for grids/previews) and `/stream1` or `/stream6` (for full-screen live view) ([TP-Link RTSP/ONVIF Guide](https://www.tp-link.com/us/support/faq/2680/)), decoding both H.264/H.265 video and 8 kHz `pcm_alaw` G.711 audio natively via Android `MediaCodec`.
   - **Cloud & Encrypted Relay Fallback**: When viewing cameras remotely or streaming encrypted CIPC/SD-card VOD segments, `lib/api/relay_bridge.dart` decrypts the AES-CBC/GCM blocks on `127.0.0.1` (authenticated with a random per-launch key) and demuxes video + G.711 audio to `LivePlayer.kt` ([tapo-android-tv Architecture](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md)).

## 6. Phase 4 (Waves 2 & 3): 4-Tier TDD Mechanism & Parallel Android TV Implementation

All Android TV code is developed under strict **Red-Green-Refactor TDD** across 4 isolated Git worktrees (`worktrees/lane-fixture`, `worktrees/lane-api`, `worktrees/lane-player`, `worktrees/lane-ui`).

### 6.1: The 4-Tier Android TV TDD & Stability Pyramid

```
                       /\
                      /  \     Tier 4: ADB Emulator / TV Hardware E2E & 30-Min Soak
                     /----\    (`adb reverse tcp:8099`, `--dart-define=TOPO_DEMO`, 0 ANRs)
                    /      \
                   /--------\   Tier 3: 10-Foot Widget, D-Pad Traversal & Overscan Golden Tests
                  /          \  (960x540 safe margins, CH+/1-9/Hold-OK keymap, focus ring visibility)
                 /------------\
                /              \ Tier 2: Stateful Mock Camera & Local Bridge Chaos Tests
               /----------------\ (LAN->Cloud failover, -40401 re-auth, staggered tile startup)
              /                  \
             /--------------------\ Tier 1: Protocol, Crypto & Audio Codec Unit Tests
            +----------------------+ (`fvm flutter test` + Kotlin JUnit: stok, AES, CIPC, pcm_alaw)
```

| TDD Tier | Target Android TV Failure Modes Prevented | Mandatory Automated Tests Written in Wave 2 (`Red` Phase) | Stability Acceptance Criteria (`Green` & `Refactor` Phase) |
| :--- | :--- | :--- | :--- |
| **Tier 1: Protocol, Crypto & Audio Unit Tests** (`fvm flutter test test/unit/`) | Broken `stok` AES-CBC/GCM cipher port from Windows, CIPC relay parser crashes, garbled G.711 `pcm_alaw` audio, lost grid configs. | Deterministic Dart & JUnit tests porting all golden crypto/DTO vectors from [Tapo-Camera-Windows](https://github.com/drak905/Tapo-Camera-Windows) plus the relay stream parser tests from [tapo-android-tv](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md). | 100% pass rate on `fvm flutter test`; 100% byte-for-byte parity with Windows AES-CBC/GCM and `multipleRequest` payloads; zero unhandled exceptions on corrupted CIPC chunks. |
| **Tier 2: Hybrid Failover & Chaos Integration Tests** (`test/integration/`) | TV app freeze when local camera IP changes or Wi-Fi drops, unauthorized access to `127.0.0.1` relay bridge, camera lockup from >2 streams (`-40404`). | Integration suite driven against `mock_tapo_server` (`:8443` HTTPS, `:8554` RTSP, `:8020` ONVIF + Mock Cloud CIPC) injecting: (a) local port `554`/`443` blackhole triggering automatic Cloud Relay fallback, (b) `-40401` expired `stok` renewal, and (c) unauthorized local request without the random per-launch bridge key ([tapo-android-tv Security](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md)). | Seamless failover from Local RTSP to Cloud Relay (or auto-reconnect) within `<2.5 seconds`; `403 Forbidden` on any `127.0.0.1` bridge request missing the per-launch secret; strict sequential tile connection queue. |
| **Tier 3: 10-Foot TV Widget & D-Pad Focus Golden Tests** (`test/widget_tv/`) | Invisible focus ring over bright video, D-pad trapped inside video player, broken `Hold OK` long-press or `CH+/CH-` / `1–9` shortcuts, text clipped by TV overscan. | Automated Flutter widget tests simulating `KeyDownEvent` / `KeyUpEvent` for `LogicalKeyboardKey.arrowUp/Down/Left/Right`, `select` (`OK`), long-press `select` (`Hold OK`), `escape`/`goBack` (`Back`), `info`/`contextMenu` (`Menu`), `channelUp`/`channelDown`, and `digit1`–`digit9` across all screens (`960 × 540` canvas) ([tapo-android-tv Remote Table](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md)). | 100% of interactive controls reachable via D-pad alone with zero dead ends; 3-unit dark blue focus outline + white inner edge verified via golden snapshot diffs; moving focus never triggers an action by itself. |
| **Tier 4: ADB Emulator / TV Soak & Hardware Decoder Tests** (`test/e2e_adb/`) | `MediaCodec` surface leak crashing the TV after switching grids 20 times, x86 emulator stall on hardware H.264 decode, ANR dialog on slow TV CPUs. | Automated PowerShell + ADB harness deploying `--dart-define=TOPO_DEMO=true --dart-define=TOPO_DEMO_STREAM=http://127.0.0.1:8099/live.ts` over `adb reverse tcp:8099 tcp:8099` ([tapo-android-tv UI Test Mode](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md)), cycling `2x2`, `1+5`, and `3x3` grids 100 times via `adb shell input keyevent`. | Zero ANRs or crashes in `adb logcat`; automatic software H.264 decoder fallback on Android TV emulators and hardware `MediaCodec` on physical TVs; total app memory `<220 MB` PSS after 30-minute soak. |

### 6.2: Wave 2 — Parallel TDD Red-Phase & TV Mock Harness Subagents

The Main Orchestrator creates 4 Git worktrees (`worktrees/lane-fixture`, `worktrees/lane-tdd-api`, `worktrees/lane-tdd-player`, `worktrees/lane-tdd-ui`) and launches **4 Wave 2 Subagents in parallel**:

1. **`Subagent-TV-Fixture` (`worktrees/lane-fixture`)**:
   - Ports the stateful `mock_tapo_server` from `refs/Tapo-Camera-Windows` (`:8443` Local HTTPS, `:8554` RTSP `/stream1` & `/stream2`, `:8020` ONVIF) and adds the **Live MPEG-TS Demo Streamer** (`http://127.0.0.1:8099/live.ts` using `ffmpeg -re -f lavfi -i testsrc2=size=1280x720:rate=15 -f lavfi -i sine=frequency=440:sample_rate=8000 -c:v libx264 -tune zerolatency -c:a pcm_alaw -f mpegts`) plus automated `adb reverse tcp:8099 tcp:8099`, `adb reverse tcp:8443 tcp:8443`, and `adb reverse tcp:8554 tcp:8554` scripts ([tapo-android-tv UI Test Mode](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md)).
2. **`Subagent-TDD-HybridApi` (`worktrees/lane-tdd-api`)**:
   - Authors failing (`Red`) unit and chaos integration tests (`test/unit/hybrid_client_test.dart`, `test/unit/vod_timeline_test.dart`) covering Local HTTPS `:443` (`stok`, `cnonce`/`snonce`, AES-CBC/GCM, `multipleRequest`), Cloud API (`tapo_cloud.dart` MFA & session reuse), ONVIF `:2020` discovery/events, and SD card 24-hour recording search (`searchVideoOfDay`).
3. **`Subagent-TDD-NativePlayer` (`worktrees/lane-tdd-player`)**:
   - Authors failing (`Red`) player bridge and audio tests (`test/unit/relay_bridge_audio_test.dart`, `android/app/src/test/.../LivePlayerTest.kt`) asserting per-launch random token authentication on `127.0.0.1`, G.711 `pcm_alaw` audio track demuxing, emulator software H.264 fallback vs. physical TV hardware decoding, and sequential 1-by-1 preview stream startup.
4. **`Subagent-TDD-RemoteUI` (`worktrees/lane-tdd-ui`)**:
   - Authors failing (`Red`) Flutter TV widget and D-pad traversal tests (`test/widget_tv/remote_navigation_test.dart`, `test/widget_tv/grid_layouts_test.dart`, `test/widget_tv/vod_dpad_scrubber_test.dart`) testing every remote control binding documented in [tapo-android-tv](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md) plus the new D-pad SD card timeline scrubber and Night Vision / Siren quick menu.

### 6.3: Wave 3 — Parallel TDD Green/Refactor Android TV Implementation Subagents

Once Synchronization Barrier 2 confirms all Wave 2 tests fail (`Red`), the Main Orchestrator dispatches **4 Wave 3 Implementation Subagents in parallel**:

1. **`Subagent-Impl-HybridClient` (`worktrees/lane-impl-api`)**:
   - Implements `lib/api/tapo_local_client.dart` (ported from `refs/Tapo-Camera-Windows`), `lib/api/tapo_onvif_client.dart` (port `2020`), `lib/api/tapo_cloud.dart` (adapted from `refs/tapo-android-tv` with `assets/tapo-cloud-roots.pem` TLS pinning), and `lib/api/hybrid_camera_controller.dart` (auto-selecting Local LAN RTSP/HTTPS when reachable and falling back to Cloud Relay when remote).
   - Stores session tokens and Local Camera Account credentials in Android Keystore via `flutter_secure_storage` (`EncryptedSharedPreferences`), never storing plaintext cloud passwords ([tapo-android-tv Privacy & Security](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md)).
2. **`Subagent-Impl-Media3Player` (`worktrees/lane-impl-player`)**:
   - Implements `lib/api/relay_bridge.dart` (loopback `127.0.0.1` server with per-launch random key, AES-CBC/GCM stream decryption for encrypted cameras, and MPEG-TS + G.711 `pcm_alaw` audio multiplexing) and `android/app/src/main/kotlin/.../LivePlayer.kt` (`androidx.media3` ExoPlayer supporting both direct low-latency `RtspMediaSource` on port `554` and loopback MPEG-TS, with `focusable = false`, automatic catch-up speed, per-tile audio mute/unmute, and emulator software H.264 detection) ([tapo-android-tv How It Works](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md)).
3. **`Subagent-Impl-TVGridsAndRemote` (`worktrees/lane-impl-ui`)**:
   - Implements the 10-foot Android TV interface (`lib/ui/theme.dart`, `lib/ui/tv.dart`, `lib/ui/guide.dart`, `lib/state/grids.dart`, `lib/screens/home_screen.dart`, `lib/screens/grid_view_screen.dart`, `lib/screens/grid_editor_screen.dart`):
     - `960 × 540` logical layout grid with overscan-safe margins and calm blue/white theme ([tapo-android-tv Design](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md)).
     - 3-unit dark blue focus outline with white inner contrast border over video tiles.
     - Built-in `All cameras`, `2 side by side`, `2 × 2`, `1 + 5`, and `3 × 3` multi-view grids, custom grid editor, and Home Screen pinned favourite grid.
     - Complete remote control mapping: `Arrows` (move outline / pan & tilt in live view), `OK` (select / show controls), `Hold OK` (quick actions: privacy mode, night vision, siren, reconnect, swap tile camera), `CH+ / CH-` & `1–9` (switch cameras/grids), and `Menu / Info` (interactive remote guide) ([tapo-android-tv Using the Remote](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md)).
     - Android TV Leanback launcher declaration (`android.intent.category.LEANBACK_LAUNCHER`, banner drawable, and `android:required="false"` for `android.hardware.touchscreen` in `AndroidManifest.xml`).
4. **`Subagent-Impl-TVVodAndOverlay` (`worktrees/lane-impl-vod`)**:
   - Ports the 24-hour SD Card Recording Calendar & Timeline player and ONVIF motion alert listener from [Tapo-Camera-Windows](https://github.com/drak905/Tapo-Camera-Windows) into a D-pad-friendly TV interface (`lib/screens/vod_timeline_screen.dart` & `lib/ui/motion_pip_toast.dart`):
     - Use `Left` / `Right` D-pad arrows to scrub across recorded SD card clips by timestamp, `Up` / `Down` to switch days on the calendar, and `OK` to play back video + decoded G.711 audio on the TV.
     - Renders non-intrusive Picture-in-Picture (PiP) overlay toasts in the top-right corner of the TV screen when ONVIF port `2020` detects motion or person events.

## 7. Phase 5: 4-Gate Closed-Loop Verification, APK Build & ADB Deployment

After merging all 4 Wave 3 worktrees at Synchronization Barrier 3, the Main Orchestrator executes the **4-Gate Verification Pipeline**:

| Verification Gate | Automated Command / Check | Pass Criteria | Self-Healing Remediation |
| :--- | :--- | :--- | :--- |
| **Gate 1: Dual-Repo Feature & Spec Parity** | `fvm flutter test test/spec_parity_test.dart` | 100% of Local LAN features from [Tapo-Camera-Windows](https://github.com/drak905/Tapo-Camera-Windows) and 100% of TV remote/grid features from [tapo-android-tv](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md) are mapped and verified in `specs/android_tv_port_spec.json`. | Re-audit missing methods in `refs/Tapo-Camera-Windows` or `refs/tapo-android-tv` and update DTO/keymap bindings. |
| **Gate 2: TDD Unit, Chaos & TV Widget Golden Suite** | `fvm flutter test` (Tier 1 + Tier 2 Chaos + Tier 3 TV Widget D-Pad tests) | 100% pass across AES-CBC/GCM crypto, Local-to-Cloud failover (`<2.5s`), G.711 `pcm_alaw` audio bridge, and D-pad focus traversal across all screens. | Isolate failing test in its subsystem worktree and iterate Red-Green-Refactor without modifying test assertions. |
| **Gate 3: Android TV APK Build (`release` + `android-arm`)** | `fvm flutter build apk --release` AND `fvm flutter build apk --release --target-platform android-arm --dart-define=TOPO_DEMO=true` | Generates both universal release APK (`arm64-v8a`, `armeabi-v7a`, `x86_64`) and 32-bit ARM emulator/demo APK (`build/app/outputs/flutter-apk/app-release.apk`) with zero Gradle/Kotlin warnings ([tapo-android-tv Build Guide](https://github.com/abdulmominsakib/tapo-android-tv/blob/main/README.md)). | Resolve Gradle/Kotlin `androidx.media3` or Android SDK API version mismatches; verify `LEANBACK_LAUNCHER` manifest declarations. |
| **Gate 4: ADB Emulator / TV Soak Test & Public GitHub Push** | `powershell ./scripts/run_adb_tv_soak.ps1 && git push origin main` | Installs APK via `adb install -r`, streams live video via `adb reverse tcp:8099 tcp:8099`, passes 100 remote key cycles (`DPAD_*`, `KEYCODE_CHANNEL_UP`, `KEYCODE_DPAD_CENTER`) with 0 ANRs, `<220 MB` PSS RAM, and pushes clean repo to GitHub. | Fix any `MediaCodec` surface release leaks in `LivePlayer.kt` (`onDispose`), purge any sensitive files blocked by `pre-commit`, and re-push. |

## 8. Phase 6: Master Agent CLI Prompt (Copy-Paste Execution Block)

Copy and paste the following master prompt directly into your Windows Agent CLI (Claude Code, Kiro CLI, or Antigravity) inside `C:\Projects\TapoCameraAndroidTV`:

```text
ROLE & OBJECTIVE:
You are the Lead Cross-Platform & Android TV Orchestrator Agent operating on Windows x64. Your objective is to port the completed Windows application (`https://github.com/drak905/Tapo-Camera-Windows`) to a native Android TV & Google TV application, using `https://github.com/abdulmominsakib/tapo-android-tv` (`Topo TV`) as the reference 10-foot UI and native Media3 player architecture.

STEP 0 — CHECK CURRENT STATUS ON THIS COMPUTER & AUTO-INSTALL MISSING TOOLS:
1. Create and execute `./scripts/check_and_install_tv_prereqs.ps1` to verify `git`, `gh`, `javac` (OpenJDK 17), `ffmpeg`, `adb` (`Google.PlatformTools`), Android SDK (`cmdline-tools`, `platforms;android-34`, `build-tools;34.0.0`), and `fvm` with Flutter `3.47.2`.
2. If any tool is missing, automatically download and install it via `winget`, `sdkmanager`, or `fvm install 3.47.2 --setup`, refresh `$env:Path`, `$env:JAVA_HOME`, and `$env:ANDROID_HOME` in the active PowerShell session, accept Android SDK licenses, and save `./artifacts/host_tv_status_report.json`.

STEP 1 — PUBLIC GITHUB REPOSITORY INIT, CREDENTIAL HYGIENE & REFERENCE CLONING:
1. Write a hardened `.gitignore` that strictly excludes:
   - Credentials & tokens: `.env`, `.env.*` (except `.env.example`), `*secret*`, `*password*`, `*stok*`, `tapo_session.json`, `camera_credentials.json`, `local_cameras.*`, `local.properties`.
   - Android signing keystores & certs: `*.jks`, `*.keystore`, `key.properties`, `*.pem` (except `assets/tapo-cloud-roots.pem`), `*.key`, `*.pfx`.
   - Reference clones, worktrees & build artifacts: `refs/`, `worktrees/`, `.fvm/flutter_sdk`, `build/`, `*.apk`, `*.aab`, `artifacts/`.
2. Install `.git/hooks/pre-commit` to block any commit containing keystores, `.env` files, `.apk` binaries, `stok=` tokens, `rtsp://user:pass@` strings, or hardcoded passwords.
3. Create `.env.example`, initialize Git (`git init -b main`), verify `gh auth status`, and create/push the public GitHub repository via `gh repo create Tapo-Camera-Android-TV --public --source=. --remote=origin --push`.
4. Clone `https://github.com/drak905/Tapo-Camera-Windows` into `./refs/Tapo-Camera-Windows` and `https://github.com/abdulmominsakib/tapo-android-tv` into `./refs/tapo-android-tv`.

MANDATORY MULTI-SUBAGENT PARALLELISM RULES:
1. NEVER analyze repositories or implement independent subsystems sequentially in your main loop. Always spawn 4 parallel subagents (`Task` / subagent workers) per wave across isolated Git worktrees (`git worktree add ./worktrees/<lane>`).
2. Wave 1 (Parallel Dual-Repo Audit): Spawn 4 read-only subagents concurrently:
   - `Subagent-Audit-Protocol`: Merge Windows Local HTTPS `:443` (`stok`, AES-CBC/GCM, `multipleRequest`) and TV Cloud API (`lib/api/tapo_cloud.dart`) into `./specs/hybrid_control_spec.json`.
   - `Subagent-Audit-MediaBridge`: Merge Windows RTSP `:554` (`/stream1`, `/stream2`, `/stream6`) + `pcm_alaw` audio with TV `lib/api/relay_bridge.dart` (`127.0.0.1` per-launch secret) & Kotlin `LivePlayer.kt` (`androidx.media3` ExoPlayer) into `./specs/media3_player_bridge_spec.json`.
   - `Subagent-Audit-TV-UI`: Extract the `960 × 540` overscan-safe layout, 3-unit blue/white focus outline, multi-view grids (`2 side by side`, `2x2`, `1+5`, `3x3`), and D-pad/OK/Hold-OK/Menu/CH+/1–9 remote bindings into `./specs/tv_ui_remote_spec.json`.
   - `Subagent-Audit-VOD-Events`: Map Windows 24h SD Card VOD timeline (`searchVideoOfDay`, MP4/TS playback) and ONVIF `:2020` `PullPointSubscription` motion events into `./specs/tv_vod_onvif_spec.json`.
3. Synchronize at Barrier 1, merge into `./specs/android_tv_port_spec.json`, and push `./specs/` to `origin/main`.

MANDATORY TEST-DRIVEN DEVELOPMENT (RED-GREEN-REFACTOR) & ANDROID TV STABILITY RULES:
1. ZERO PRODUCTION CODE BEFORE FAILING TESTS (WAVE 2 RED PHASE): Spawn 4 parallel subagents in isolated worktrees (`Subagent-TV-Fixture`, `Subagent-TDD-HybridApi`, `Subagent-TDD-NativePlayer`, `Subagent-TDD-RemoteUI`) to build the Mock Tapo + MPEG-TS Demo Server (`:8443` HTTPS, `:8554` RTSP, `:8020` ONVIF, `:8099` `live.ts` with `adb reverse`) and author failing tests across 4 tiers:
   - Tier 1 (Unit/Crypto/Audio): AES-CBC/GCM vectors, `stok` challenge-response, CIPC relay parser, and 8 kHz G.711 `pcm_alaw` audio frame decoding.
   - Tier 2 (Chaos & Hybrid Failover): Automatic Local RTSP `:554` to Cloud Relay failover (`<2.5s`), `-40401` token refresh, `-40404` 2-stream limit semaphore, per-launch `127.0.0.1` bridge key enforcement, and sequential 1-by-1 home preview startup.
   - Tier 3 (10-Foot TV Widget & D-Pad Golden Tests): Full D-pad focus traversal across `960 × 540` overscan-safe screens, verifying `LivePlayer.kt` never steals focus (`focusable=false`), `Hold OK` context actions, `CH+/CH-` & `1–9` shortcuts, and D-pad 24h SD VOD timeline scrubbing.
   - Tier 4 (ADB Emulator/TV Soak): `--dart-define=TOPO_DEMO=true --dart-define=TOPO_DEMO_STREAM=http://127.0.0.1:8099/live.ts` soak test cycling grids 100 times via `adb shell input keyevent` with `<220 MB` PSS RAM and 0 ANRs.
2. Verify at Barrier 2 that all Wave 2 tests fail (`Red`).
3. GREEN & REFACTOR PHASE (WAVE 3): Spawn 4 parallel implementation subagents (`Subagent-Impl-HybridClient`, `Subagent-Impl-Media3Player`, `Subagent-Impl-TVGridsAndRemote`, `Subagent-Impl-TVVodAndOverlay`) in isolated worktrees. Do not weaken or skip any Wave 2 test; implement clean production code until 100% of Tier 1–4 tests pass (`Green`).
4. Synchronize at Barrier 3, build both universal (`fvm flutter build apk --release`) and 32-bit ARM emulator (`--target-platform android-arm`) APKs, pass all 4 Verification Gates, and push the complete codebase to the public GitHub repository.

Begin immediately with Step 0 (Check Current Status on This Computer & Auto-Install), then execute Step 1 (Public GitHub Repo Init & Reference Cloning) and launch Wave 1.
```
