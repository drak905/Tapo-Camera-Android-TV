<#
.SYNOPSIS
  Forwards the host's fixture ports to an Android TV device / emulator with adb reverse.

.DESCRIPTION
  After this, the app on the device reaches the host services as 127.0.0.1:<port>:
    8099  demo MPEG-TS stream   (scripts/demo_stream.ps1)
    8443  mock camera / cloud   (a dev server wrapping test/fixtures, optional)
    8554  RTSP test source      (optional)
  Exit codes: 0 ok, 2 adb missing, 3 no device / ambiguous device.

.PARAMETER Serial  adb serial (needed when more than one device is attached).
.PARAMETER Ports   Ports to forward (default 8099, 8443, 8554).
.PARAMETER Remove  Remove the reverse mappings instead.
#>
[CmdletBinding()]
param(
    [string]$Serial = '',
    [int[]]$Ports = @(8099, 8443, 8554),
    [switch]$Remove
)
$ErrorActionPreference = 'Stop'

function Find-Adb {
    $c = Get-Command adb -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    foreach ($root in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA 'Android\Sdk'))) {
        if ($root) {
            $p = Join-Path $root 'platform-tools\adb.exe'
            if (Test-Path $p) { return $p }
        }
    }
    return $null
}

$adb = Find-Adb
if (-not $adb) {
    Write-Error 'adb not found. Install Android platform-tools or set ANDROID_HOME.'
    exit 2
}

$lines = & $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\tdevice$' }
$serials = @($lines | ForEach-Object { ($_ -split '\t')[0] })
if ($serials.Count -eq 0) {
    Write-Error 'No Android device or emulator connected (adb devices is empty). Connect a TV box ("adb connect <ip>:5555") or start an emulator.'
    exit 3
}
if (-not $Serial) {
    if ($serials.Count -gt 1) {
        Write-Error "More than one device attached ($($serials -join ', ')). Pass -Serial."
        exit 3
    }
    $Serial = $serials[0]
}

$failed = @()
foreach ($p in $Ports) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    if ($Remove) {
        & $adb -s $Serial reverse --remove "tcp:$p" 2>&1 | Out-Null
        Write-Host "removed reverse tcp:$p"
    } else {
        $out = & $adb -s $Serial reverse "tcp:$p" "tcp:$p" 2>&1 | ForEach-Object { "$_" }
        if ($LASTEXITCODE -ne 0) {
            $failed += $p
            Write-Host "reverse tcp:$p failed: $($out -join ' ')" -ForegroundColor Yellow
        } else {
            Write-Host "reverse tcp:$p -> host 127.0.0.1:$p ($Serial)"
        }
    }
    $ErrorActionPreference = $old
}
# Only the demo stream port is required; 8443/8554 are optional dev services.
if ($failed -contains 8099) { exit 3 }
exit 0
