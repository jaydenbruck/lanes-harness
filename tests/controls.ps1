$ErrorActionPreference = 'Stop'
$env:LANES_HOME = Join-Path ([IO.Path]::GetTempPath()) ('lanes-controls-' + [guid]::NewGuid().ToString('N'))
Remove-Item Env:LANES_LANE -ErrorAction SilentlyContinue
$module = Import-Module (Join-Path $PSScriptRoot '..\Lanes.psm1') -Force -DisableNameChecking -PassThru
$stats = Get-LaneUsage
if ($stats.launches -ne 0 -or $stats.uniqueNames -ne 0) { throw 'empty stats failed' }
'PASS empty history'
& $module {
    # Capture generated launches without running providers or modifying their global config.
    function script:Resolve-LaneExe { 'provider.exe' }
    function script:Resolve-CursorAgent { @{ Node = 'node.exe'; Entry = 'cursor.js' } }
    function script:Install-GrokLaneHooks { }
    function script:Test-LanesStrictPrivacy { $false }
    function script:Start-Process { throw 'captured' }
}
foreach ($kind in 'claude', 'codex', 'grok', 'cursor') {
    foreach ($mode in 'bypass', 'default') {
        $name = "$kind-$mode"
        try { Start-Lane $name -Kind $kind -Permissions $mode -Hidden | Out-Null; throw 'spawn was not intercepted' }
        catch { if ($_ -notmatch 'captured') { throw } }
        $launch = Read-JsonFile (Join-Path (Get-LanesRoot) $name 'launch.json')
        $hasBypass = $launch.cmd -match '--dangerously-skip-permissions|--yolo|bypassPermissions|--force|--trust'
        if ($hasBypass -ne ($mode -eq 'bypass') -or $launch.permissions -ne $mode) { throw "$kind/$mode flags wrong" }
        "PASS $kind/$mode permission flags and recorded mode"
    }
}
$legacy = Read-JsonFile (Join-Path (Get-LanesRoot) 'claude-bypass\launch.json')
foreach ($key in 'parentLane', 'parentInbox', 'inbox', 'permissions', 'extraArgs') { $legacy.Remove($key) }
$legacy.name = 'legacy'
$legacyDir = Join-Path (Get-LanesRoot) 'legacy'
New-Item -ItemType Directory -Force $legacyDir | Out-Null
$legacy | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $legacyDir 'launch.json')
try { Restart-Lane legacy -Force | Out-Null; throw 'not intercepted' }
catch { if ($_ -notmatch 'captured') { throw } }
'PASS legacy launch records restart with defaults'
$parentDir = Join-Path (Get-LanesRoot) 'old-parent'
New-Item -ItemType Directory -Force $parentDir | Out-Null
@{ name = 'old-parent'; head = (Get-CurrentHead); hostPid = $PID; state = 'running'; meta = @{ isHead = $false } } |
    ConvertTo-Json | Set-Content (Join-Path $parentDir 'state.json')
try { Start-Lane child -Kind claude -ParentLane old-parent -Hidden | Out-Null; throw 'not intercepted' }
catch { if ($_ -notmatch 'captured') { throw } }
'PASS older parent uses event-only fallback'
$headDir = Join-Path (Get-LaneHeadsRoot) (Get-CurrentHead)
New-Item -ItemType Directory -Force $headDir | Out-Null
Append-Line (Join-Path $headDir 'events.jsonl') (@{ ts = (Get-Date).ToUniversalTime().ToString('o'); head = (Get-CurrentHead); lane = 'child'; state = 'finished'; why = 'exit-0'; label = 'done'; exit = 0; from = 0; to = 1 } | ConvertTo-Json -Compress)
$env:LANES_LANE = 'helper'
$rows = @(Get-LaneEvent -Drain -AsObject)
if ($rows.Count -ne 1) { throw 'first consumer read skipped completed child event' }
'PASS first consumer read retains completed child event'
$env:LANES_LANE = $null
"Evidence retained in $env:LANES_HOME"
