<#
.SYNOPSIS
  Tier 4 soak test on a real Android TV box / emulator: grid cycling with the D-pad,
  crash / ANR watch, memory ceiling.

.DESCRIPTION
  1. finds adb and one device (clear message + exit 2 when there is none),
  2. installs the APK (unless -SkipInstall),
  3. starts scripts/demo_stream.ps1 (127.0.0.1:8099) and scripts/adb_reverse.ps1,
  4. launches the app and cycles the grids -Cycles times with
     adb shell input keyevent DPAD_* / CHANNEL_UP / DPAD_CENTER,
  5. every -SampleEvery cycles samples PSS (dumpsys meminfo), at the end scans logcat
     for ANR / FATAL EXCEPTION / process death,
  6. writes artifacts/soak_report.json.
  Exit codes: 0 pass, 1 soak failed (crash, ANR, PSS over limit), 2 no device / missing tool,
  3 setup error (install, launch).

.PARAMETER Apk          APK to install (default build/app/outputs/flutter-apk/app-debug.apk).
.PARAMETER Serial       adb serial (required with several devices).
.PARAMETER Cycles       Grid cycles (default 100).
.PARAMETER PssLimitMb   Fail when the app PSS exceeds this (default 220).
.PARAMETER SkipInstall  Use the app already on the device.
.PARAMETER NoStream     Do not start demo_stream.ps1 (use an already running source).
.PARAMETER Report       Report path (default artifacts/soak_report.json).
#>
[CmdletBinding()]
param(
    [string]$Apk = '',
    [string]$Serial = '',
    [string]$Package = 'io.github.drak905.tapo_tv',
    [int]$Cycles = 100,
    [int]$PssLimitMb = 220,
    [int]$SampleEvery = 10,
    [int]$CycleDelayMs = 700,
    [switch]$SkipInstall,
    [switch]$NoStream,
    [string]$Report = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Apk) { $Apk = Join-Path $root 'build\app\outputs\flutter-apk\app-debug.apk' }
if (-not $Report) { $Report = Join-Path $root 'artifacts\soak_report.json' }

$result = [ordered]@{
    status       = 'error'
    package      = $Package
    serial       = $Serial
    cycles       = $Cycles
    cycles_done  = 0
    pss_limit_mb = $PssLimitMb
    pss_samples_mb = @()
    pss_max_mb   = 0
    anr          = 0
    fatal        = 0
    process_died = $false
    failures     = @()
    started_utc  = (Get-Date).ToUniversalTime().ToString('o')
    finished_utc = ''
}

function Save-Report {
    $result.finished_utc = (Get-Date).ToUniversalTime().ToString('o')
    $dir = Split-Path -Parent $Report
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $json = ($result | ConvertTo-Json -Depth 5) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($Report, $json + "`n", (New-Object Text.UTF8Encoding $false))
    Write-Host "report: $Report"
}

function Finish([int]$code, [string]$status, [string]$why = '') {
    $result.status = $status
    if ($why) { $result.failures += $why; Write-Host "FAIL: $why" -ForegroundColor Red }
    Save-Report
    if ($script:streamProc -and -not $script:streamProc.HasExited) { try { $script:streamProc.Kill() } catch { } }
    exit $code
}

function Find-Adb {
    $c = Get-Command adb -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($r in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA 'Android\Sdk'))) {
        if ($r) {
            $p = Join-Path $r 'platform-tools\adb.exe'
            if (Test-Path $p) { return $p }
        }
    }
    return $null
}

$script:streamProc = $null
$adb = Find-Adb
if (-not $adb) {
    Write-Host 'adb not found. Install Android platform-tools or set ANDROID_HOME.' -ForegroundColor Red
    Finish 2 'skipped_no_adb' 'adb not found'
}

$serials = @(& $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\tdevice$' } |
    ForEach-Object { ($_ -split '\t')[0] })
if ($serials.Count -eq 0) {
    Write-Host 'No Android device or emulator connected. Attach a TV box ("adb connect <ip>:5555") or start an emulator, then rerun.' -ForegroundColor Red
    Finish 2 'skipped_no_device' 'no adb device connected'
}
if (-not $Serial) {
    if ($serials.Count -gt 1) {
        Finish 2 'skipped_no_device' "several devices attached ($($serials -join ', ')); pass -Serial"
    }
    $Serial = $serials[0]
}
$result.serial = $Serial
function Adb { & $adb -s $Serial @args }

# ---- install ------------------------------------------------------------------------
if (-not $SkipInstall) {
    if (-not (Test-Path $Apk)) { Finish 3 'error' "APK not found: $Apk (run flutter build apk --debug)" }
    Write-Host "installing $Apk"
    $out = Adb install -r -t $Apk 2>&1
    if ($LASTEXITCODE -ne 0 -or ($out -join ' ') -notmatch 'Success') {
        Finish 3 'error' "adb install failed: $($out -join ' ')"
    }
}

# ---- demo stream + reverse ------------------------------------------------------------
if (-not $NoStream) {
    $ps = (Get-Command powershell -ErrorAction SilentlyContinue).Source
    $script:streamProc = Start-Process -FilePath $ps -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'demo_stream.ps1'))
    $ok = $false
    for ($i = 0; $i -lt 30 -and -not $script:streamProc.HasExited; $i++) {
        try {
            $c = New-Object Net.Sockets.TcpClient
            $c.Connect('127.0.0.1', 8099)
            $c.Close(); $ok = $true; break
        } catch { Start-Sleep -Milliseconds 300 }
    }
    if (-not $ok) { Finish 3 'error' 'demo stream did not start on 127.0.0.1:8099 (is ffmpeg installed?)' }
}
& (Join-Path $PSScriptRoot 'adb_reverse.ps1') -Serial $Serial
if ($LASTEXITCODE -ne 0) { Finish 3 'error' 'adb reverse failed' }

# ---- launch ---------------------------------------------------------------------------
Adb logcat -c | Out-Null
Adb shell am force-stop $Package | Out-Null
$launch = Adb shell monkey -p $Package -c android.intent.category.LEANBACK_LAUNCHER 1 2>&1
if (($launch -join ' ') -match 'No activities found') {
    $launch = Adb shell monkey -p $Package -c android.intent.category.LAUNCHER 1 2>&1
}
if (($launch -join ' ') -match 'No activities found|Error') { Finish 3 'error' "cannot launch $Package" }
Start-Sleep -Seconds 5

function Get-PssMb {
    $txt = (Adb shell dumpsys meminfo $Package) -join "`n"
    if ($txt -match 'TOTAL PSS:\s+(\d+)') { return [math]::Round([int]$Matches[1] / 1024, 1) }
    if ($txt -match '(?m)^\s*TOTAL\s+(\d+)') { return [math]::Round([int]$Matches[1] / 1024, 1) }
    return -1
}
function Test-Alive { (Adb shell pidof $Package) -match '\d+' }

# DPAD_RIGHT=22 DPAD_DOWN=20 DPAD_CENTER=23 DPAD_LEFT=21 DPAD_UP=19 CHANNEL_UP=166 BACK=4
$keys = @('KEYCODE_DPAD_RIGHT', 'KEYCODE_DPAD_DOWN', 'KEYCODE_DPAD_CENTER', 'KEYCODE_CHANNEL_UP',
    'KEYCODE_DPAD_LEFT', 'KEYCODE_DPAD_UP', 'KEYCODE_DPAD_CENTER', 'KEYCODE_BACK')

for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
    foreach ($k in $keys) {
        Adb shell input keyevent $k | Out-Null
        Start-Sleep -Milliseconds 120
    }
    Start-Sleep -Milliseconds $CycleDelayMs
    $result.cycles_done = $cycle
    if (-not (Test-Alive)) {
        $result.process_died = $true
        Finish 1 'failed' "app process died during cycle $cycle"
    }
    if ($cycle % $SampleEvery -eq 0 -or $cycle -eq $Cycles) {
        $pss = Get-PssMb
        $result.pss_samples_mb += $pss
        if ($pss -gt $result.pss_max_mb) { $result.pss_max_mb = $pss }
        Write-Host ("cycle {0}/{1}  PSS {2} MB" -f $cycle, $Cycles, $pss)
        if ($pss -gt $PssLimitMb) { $result.failures += "PSS $pss MB over limit $PssLimitMb MB at cycle $cycle" }
    }
}

# ---- logcat scan ------------------------------------------------------------------------
$log = (Adb logcat -d -v brief) -join "`n"
$result.anr = ([regex]::Matches($log, "ANR in $([regex]::Escape($Package))")).Count
$result.fatal = ([regex]::Matches($log, 'FATAL EXCEPTION')).Count
if ($log -match "Process $([regex]::Escape($Package)) .* has died") { $result.process_died = $true }
if ($result.anr -gt 0) { $result.failures += "$($result.anr) ANR(s) in logcat" }
if ($result.fatal -gt 0) { $result.failures += "$($result.fatal) FATAL EXCEPTION(s) in logcat" }
if ($result.process_died) { $result.failures += 'app process died (logcat)' }
if ($result.pss_max_mb -le 0) { $result.failures += 'could not read PSS from dumpsys meminfo' }

if ($result.failures.Count -gt 0) {
    $result.failures | ForEach-Object { Write-Host "FAIL: $_" -ForegroundColor Red }
    Finish 1 'failed'
}
Write-Host ("PASS: {0} cycles, max PSS {1} MB" -f $Cycles, $result.pss_max_mb) -ForegroundColor Green
Finish 0 'passed'
