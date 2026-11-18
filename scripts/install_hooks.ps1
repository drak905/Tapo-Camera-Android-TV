# Installs the credential/keystore guard as .git/hooks/pre-commit (LF, no BOM).
$root = Split-Path -Parent $PSScriptRoot
$hooks = (git -C $root rev-parse --git-common-dir)
if (-not [IO.Path]::IsPathRooted($hooks)) { $hooks = Join-Path $root $hooks }
$src = [IO.File]::ReadAllText("$root\scripts\pre-commit") -replace "`r`n", "`n"
New-Item -ItemType Directory -Force -Path "$hooks\hooks" | Out-Null
[IO.File]::WriteAllText("$hooks\hooks\pre-commit", $src, (New-Object Text.UTF8Encoding $false))
Write-Host "pre-commit hook installed in $hooks\hooks"
