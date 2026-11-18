# Checks and installs the Android TV toolchain on Windows x64.
# Idempotent: safe to run again. Writes artifacts/host_tv_status_report.json.
# Flutter is pinned by .fvmrc (3.47.2). FVM is not in winget, so this script
# installs that Flutter tag straight from git into $ToolsRoot\flutter.
$ErrorActionPreference = "Stop"
$WorkspaceRoot  = Split-Path -Parent $PSScriptRoot
$ToolsRoot      = "C:\Projects\tools"
$FlutterVersion = "3.47.2"
$FlutterRoot    = "$ToolsRoot\flutter"
$AndroidSdk     = "$env:LOCALAPPDATA\Android\Sdk"
New-Item -ItemType Directory -Force -Path "$WorkspaceRoot\artifacts", $ToolsRoot | Out-Null

function Refresh-SessionPath {
    $m = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $u = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$m;$u;$FlutterRoot\bin;$AndroidSdk\platform-tools;$AndroidSdk\cmdline-tools\latest\bin"
}

function Add-UserPath([string]$dir) {
    $u = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not (($u -split ';') -contains $dir)) {
        [Environment]::SetEnvironmentVariable("Path", "$u;$dir", "User")
    }
}

function Ensure-Winget([string]$Cmd, [string]$Id) {
    Refresh-SessionPath
    if (-not (Get-Command $Cmd -ErrorAction SilentlyContinue)) {
        Write-Host "[INSTALL] $Id"
        winget install --id $Id -e --silent --accept-source-agreements --accept-package-agreements | Out-Null
        Refresh-SessionPath
    }
}

Ensure-Winget git    Git.Git
Ensure-Winget gh     GitHub.cli
Ensure-Winget ffmpeg Gyan.FFmpeg

# JDK 17+ (the app targets Java 17 bytecode; Gradle 8 runs on JDK 17 or 21).
# Prefer 17, accept 21 so no admin (UAC) install is needed when 21 is present.
$Jdk17 = Resolve-Path "$env:ProgramFiles\Microsoft\jdk-17*", "$env:ProgramFiles\Microsoft\jdk-21*" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $Jdk17) {
    Write-Host "[INSTALL] Microsoft.OpenJDK.17"
    winget install --id Microsoft.OpenJDK.17 -e --silent --accept-source-agreements --accept-package-agreements | Out-Null
    $Jdk17 = Resolve-Path "$env:ProgramFiles\Microsoft\jdk-17*" | Select-Object -First 1
}
$env:JAVA_HOME = $Jdk17.Path
[Environment]::SetEnvironmentVariable("JAVA_HOME", $env:JAVA_HOME, "User")

# Android SDK command-line tools + packages
$env:ANDROID_HOME = $AndroidSdk
[Environment]::SetEnvironmentVariable("ANDROID_HOME", $AndroidSdk, "User")
$SdkManager = "$AndroidSdk\cmdline-tools\latest\bin\sdkmanager.bat"
if (-not (Test-Path $SdkManager)) {
    Write-Host "[INSTALL] Android cmdline-tools"
    New-Item -ItemType Directory -Force -Path "$AndroidSdk\cmdline-tools" | Out-Null
    $zip = "$env:TEMP\commandlinetools-win.zip"
    Invoke-WebRequest -Uri "https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip" -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath "$AndroidSdk\cmdline-tools\temp" -Force
    Move-Item "$AndroidSdk\cmdline-tools\temp\cmdline-tools" "$AndroidSdk\cmdline-tools\latest"
    Remove-Item -Recurse -Force "$AndroidSdk\cmdline-tools\temp", $zip
}
Refresh-SessionPath
# PowerShell pipes do not reach sdkmanager's prompt; a file redirected via cmd does.
$yes = "$env:TEMP\sdk_yes.txt"
[IO.File]::WriteAllText($yes, ("y`r`n" * 50))
cmd /c "`"$SdkManager`" --sdk_root=`"$AndroidSdk`" --licenses < `"$yes`"" | Out-Null
cmd /c "`"$SdkManager`" --sdk_root=`"$AndroidSdk`" platform-tools platforms;android-34 platforms;android-36 build-tools;34.0.0 build-tools;36.0.0" | Out-Null
Add-UserPath "$AndroidSdk\platform-tools"

# Flutter pinned tag
if (-not (Test-Path "$FlutterRoot\bin\flutter.bat")) {
    Write-Host "[INSTALL] Flutter $FlutterVersion"
    git clone -q --depth 1 -b $FlutterVersion https://github.com/flutter/flutter.git $FlutterRoot
}
Add-UserPath "$FlutterRoot\bin"
Refresh-SessionPath
& "$FlutterRoot\bin\flutter.bat" config --no-analytics | Out-Null
& "$FlutterRoot\bin\flutter.bat" config --android-sdk $AndroidSdk | Out-Null
cmd /c "`"$FlutterRoot\bin\flutter.bat`" doctor --android-licenses < `"$yes`"" 2>&1 | Out-Null
$doctor = (& "$FlutterRoot\bin\flutter.bat" doctor -v 2>&1 | Out-String)

$report = [ordered]@{}
foreach ($c in "git","gh","javac","ffmpeg","adb","flutter","dart") {
    $g = Get-Command $c -ErrorAction SilentlyContinue
    $report[$c] = @{ installed = [bool]$g; path = $(if ($g) { $g.Source } else { $null }) }
}
$report["JAVA_HOME"] = $env:JAVA_HOME
$report["ANDROID_HOME"] = $AndroidSdk
$report["flutter_doctor"] = $doctor
$json = $report | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText("$WorkspaceRoot\artifacts\host_tv_status_report.json", $json, (New-Object Text.UTF8Encoding $false))
Write-Host $doctor
Write-Host "[READY] host provisioned"
