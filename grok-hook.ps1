# Grok lifecycle hook -> the LaneHost that owns this Grok process.
# In a normal Grok terminal LANES_LANE_DIR is absent, so this user-level hook is deliberately inert.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

if (-not $env:LANES_LANE_DIR -or -not $env:LANES_MODULE) { exit 0 }
$hostExe = Join-Path $env:LANES_MODULE 'bin\LaneHost.exe'
if (-not (Test-Path -LiteralPath $hostExe)) { exit 0 }

& $hostExe hook $env:LANES_LANE_DIR
exit $LASTEXITCODE
