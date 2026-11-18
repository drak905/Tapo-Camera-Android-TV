<#
.SYNOPSIS
  Serves a synthetic MPEG-TS live stream on http://127.0.0.1:8099/live.ts (loopback only).

.DESCRIPTION
  ffmpeg generates testsrc2 1280x720@15 H.264 plus a 440 Hz sine, 8 kHz mono G.711 A-law
  (pcm_alaw), muxed as MPEG-TS and fanned out to every connected HTTP client (late joiners
  start mid-stream, which is fine for TS). The listener is bound to 127.0.0.1 only; use
  scripts/adb_reverse.ps1 so an Android TV device or emulator reaches it as 127.0.0.1:8099.
  No camera, cloud or personal data is involved.

.PARAMETER Port      TCP port (default 8099).
.PARAMETER Seconds   Stop after N seconds (0 = run until Ctrl+C).
.PARAMETER Ffmpeg    Path to ffmpeg (default: PATH).
.EXAMPLE
  powershell -File scripts/demo_stream.ps1
  curl.exe -s http://127.0.0.1:8099/live.ts --max-time 3 -o NUL
#>
[CmdletBinding()]
param(
    [int]$Port = 8099,
    [int]$Seconds = 0,
    [string]$Ffmpeg = 'ffmpeg'
)
$ErrorActionPreference = 'Stop'

$ff = Get-Command $Ffmpeg -ErrorAction SilentlyContinue
if (-not $ff) {
    Write-Error "ffmpeg not found. Install it (winget install Gyan.FFmpeg) or pass -Ffmpeg <path>."
    exit 2
}

$ffArgs = @(
    '-hide_banner', '-loglevel', 'error', '-nostdin',
    '-re', '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=15',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=8000',
    '-c:v', 'libx264', '-preset', 'ultrafast', '-tune', 'zerolatency',
    '-profile:v', 'baseline', '-pix_fmt', 'yuv420p', '-b:v', '1500k', '-g', '15',
    '-c:a', 'pcm_alaw', '-ar', '8000', '-ac', '1',
    '-muxdelay', '0', '-f', 'mpegts', 'pipe:1'
)

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $ff.Source
$psi.Arguments = ($ffArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
$psi.RedirectStandardOutput = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$proc = [System.Diagnostics.Process]::Start($psi)

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")   # loopback only, never 0.0.0.0
try { $listener.Start() } catch {
    $proc.Kill()
    Write-Error "Cannot listen on 127.0.0.1:$Port ($($_.Exception.Message)). Is another demo_stream running?"
    exit 3
}
Write-Host "demo stream: http://127.0.0.1:$Port/live.ts (1280x720@15 + A-law 8 kHz). Ctrl+C to stop."

$clients = New-Object System.Collections.ArrayList
$pending = $listener.GetContextAsync()
$buf = New-Object byte[] (188 * 56)
$stdout = $proc.StandardOutput.BaseStream
$deadline = if ($Seconds -gt 0) { (Get-Date).AddSeconds($Seconds) } else { [datetime]::MaxValue }
try {
    while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
        if ($pending.IsCompleted) {
            $ctx = $pending.Result
            $pending = $listener.GetContextAsync()
            if ($ctx.Request.Url.AbsolutePath -eq '/live.ts') {
                $ctx.Response.ContentType = 'video/mp2t'
                $ctx.Response.SendChunked = $true
                [void]$clients.Add($ctx.Response)
            } else {
                $ctx.Response.StatusCode = 404
                $ctx.Response.Close()
            }
        }
        $n = $stdout.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        for ($i = $clients.Count - 1; $i -ge 0; $i--) {
            try {
                $clients[$i].OutputStream.Write($buf, 0, $n)
                $clients[$i].OutputStream.Flush()
            } catch {
                try { $clients[$i].Abort() } catch { }
                $clients.RemoveAt($i)
            }
        }
    }
} finally {
    foreach ($c in $clients) { try { $c.Abort() } catch { } }
    $listener.Stop()
    if (-not $proc.HasExited) { $proc.Kill() }
}
