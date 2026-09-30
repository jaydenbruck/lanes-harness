# install.ps1 — builds LaneHost.exe, puts `lane` on your PATH, and prints the line to paste into your agent.
# Run from the repo folder:  pwsh -NoProfile -File install.ps1 [-NoPath]
# No admin needed. Re-running is safe: it rebuilds and rewrites the shim.
[CmdletBinding()]
param([switch]$NoPath)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($PSVersionTable.PSVersion.Major -lt 7) { throw "Lanes Harness needs PowerShell 7+ (pwsh). Install it: winget install Microsoft.PowerShell" }
if (-not $IsWindows) { throw 'Lanes Harness runs on Windows 10 1809+ / Windows 11 (it uses ConPTY).' }

& (Join-Path $here 'build.ps1')

$home_ = if ($env:LANES_HOME) { $env:LANES_HOME } else { Join-Path $env:LOCALAPPDATA 'lanes' }
$bin = Join-Path $home_ 'bin'
New-Item -ItemType Directory -Force $bin | Out-Null
$shim = Join-Path $bin 'lane.cmd'
Set-Content -LiteralPath $shim -Value ('@echo off' + "`r`n" + 'pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File "' + (Join-Path $here 'lane.ps1') + '" %*') -NoNewline -Encoding ascii
Write-Host "shim  $shim"

if (-not $NoPath) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -notcontains $bin) {
        [Environment]::SetEnvironmentVariable('Path', ($(if ($userPath) { "$userPath;$bin" } else { $bin })), 'User')
        Write-Host "added $bin to your user PATH (open a new terminal to pick it up)"
    } else { Write-Host "PATH  $bin already on your user PATH" }
}

$found = foreach ($c in 'claude', 'codex', 'grok') { if (Get-Command $c -ErrorAction SilentlyContinue) { $c } }
if (Test-Path (Join-Path $env:LOCALAPPDATA 'cursor-agent\versions')) { $found += 'cursor' }
Write-Host ("agents found: " + $(if ($found) { $found -join ', ' } else { 'none yet (install at least one of claude, codex, grok, cursor-agent)' }))
if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) { Write-Host 'note: Windows Terminal (wt.exe) not found; `lane tab` needs it, everything else works without it.' }

$guide = Join-Path $here 'HEAD.md'
Write-Host ''
Write-Host 'Paste this into your agent (Claude Code, Codex, Grok, Cursor) to make it a head:'
Write-Host ''
Write-Host "  You can run other coding agents as background workers. Read $guide and follow it: use the ``lane`` command to launch, watch and answer worker lanes."
Write-Host ''
