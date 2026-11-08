$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$env:LANES_HOME = Join-Path ([IO.Path]::GetTempPath()) ('lanes-notifications-' + [guid]::NewGuid().ToString('N'))
$env:LANES_HEAD = 'test-head'
Remove-Item Env:LANES_LANE -ErrorAction SilentlyContinue
Import-Module (Join-Path $repo 'Lanes.psm1') -Force -DisableNameChecking
$python = (Get-Command python).Source
$fake = Join-Path $PSScriptRoot 'fake-inbox-agent.py'
function Assert($value, $message) { if (-not $value) { throw $message }; "PASS $message" }
function Wait-Until([scriptblock]$check, [int]$seconds = 15) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) { if (& $check) { return }; Start-Sleep -Milliseconds 100 }
    throw 'timed out waiting for condition'
}
function Hook($name, $payload) {
    Append-Line (Join-Path (Get-LanesRoot) $name 'hooks.jsonl') ($payload | ConvertTo-Json -Compress -Depth 6)
}
function Received($name) {
    $path = Join-Path (Get-LanesRoot) $name 'received.jsonl'
    if (-not (Test-Path $path)) { return '' }
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = [IO.StreamReader]::new($stream)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}
try {
    $p = Start-Lane parent -Kind other -Command ('"' + $python + '" "' + $fake + '"') -Hidden
    $env:LANES_LANE = 'parent'
    $c = Start-Lane child -Kind other -Command 'cmd.exe /c echo done' -Hidden -Permissions default
    $launch = Read-JsonFile (Join-Path (Get-LanesRoot) 'child\launch.json')
    Assert ($launch.parentLane -eq 'parent') 'actual parent recorded without is-head'
    Wait-Until { (Get-LaneState child).state -eq 'finished' }
    Start-Sleep -Seconds 2
    Assert (-not (Received parent)) 'busy parent is not interrupted'
    Hook parent @{ hook_event_name = 'PermissionRequest'; tool_name = 'Bash'; tool_input = @{ command = 'example' } }
    Wait-Until { (Get-LaneState parent).why -eq 'permission' }
    Start-Sleep -Seconds 2
    Assert (-not (Received parent)) 'notification does not answer permission dialog'
    Hook parent @{ hook_event_name = 'UserPromptSubmit' }
    Hook parent @{ hook_event_name = 'Stop'; last_assistant_message = 'Ready for next instruction' }
    Wait-Until { (Received parent) -match 'child finished' }
    $capture = [IO.File]::Open((Join-Path (Get-LanesRoot) 'parent\received.jsonl'), [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    try { Assert ((Received parent) -match 'child finished') 'capture reader permits an active writer' }
    finally { $capture.Dispose() }
    Assert ((Received parent) -match '\\u001b\[200~') 'notification uses bracketed paste'
    $env:LANES_LANE = $null
    & (Join-Path $repo 'lane.ps1') send parent 'Run the command' '--example' 'value'
    Wait-Until { (Received parent) -match 'Run the command --example value' }
    & (Join-Path $repo 'lane.ps1') send parent '--' '--force' 'is literal'
    Wait-Until { (Received parent) -match '--force is literal' }
    Assert $true 'message flags stay literal, including explicit separator'
    $env:LANES_LANE = 'sibling'; $env:LANES_HEAD = 'test-head'
    Assert ((Get-CurrentConsumer) -eq 'sibling') 'siblings have independent event cursors'
    $env:LANES_LANE = $null
    Hook parent @{ hook_event_name = 'Stop'; last_assistant_message = 'Ready before draft' }
    Wait-Until { (Get-LaneState parent).why -eq 'turn-complete' }
    Send-Lane parent 'unfinished draft' -Raw
    $r = Restart-Lane child
    Hook parent @{ hook_event_name = 'Stop'; last_assistant_message = 'Finished while draft exists' }
    $before = Received parent
    Start-Sleep -Seconds 5
    Assert ((Received parent) -eq $before) 'raw draft defers notification'
    Send-Lane parent -Key enter
    Wait-Until { (Received parent) -match 'unfinished draft' }
    $before = Received parent
    Start-Sleep -Seconds 5
    Assert ((Received parent) -eq $before) 'raw Enter starts a busy turn without stale completion'
    Hook parent @{ hook_event_name = 'Stop'; last_assistant_message = 'New turn finished' }
    Wait-Until { (Received parent).Length -gt $before.Length }
    $before = Received parent
    Stop-Lane parent -Hard | Out-Null
    Restart-Lane parent | Out-Null
    Hook parent @{ hook_event_name = 'Stop'; last_assistant_message = 'Resumed parent' }
    Wait-Until { (Get-LaneState parent).why -eq 'turn-complete' }
    Start-Sleep -Seconds 2
    Assert ((Received parent) -eq $before) 'parent restart preserves delivery cursor without replay'
    $r = Restart-Lane child
    $launch2 = Read-JsonFile (Join-Path (Get-LanesRoot) 'child\launch.json')
    Assert ($launch2.parentInbox -eq $launch.parentInbox -and $launch2.permissions -eq 'default') 'restart preserves parent generation and permission mode'
    Stop-Lane parent -Hard | Out-Null
    Remove-Item -LiteralPath (Join-Path (Get-LanesRoot) 'parent\received.jsonl')
    $new = Start-Lane parent -Kind other -Command ('"' + $python + '" "' + $fake + '"') -Hidden
    Hook parent @{ hook_event_name = 'Stop'; last_assistant_message = 'New generation' }
    Wait-Until { (Get-LaneState parent).why -eq 'turn-complete' }
    Start-Sleep -Seconds 2
    Assert (-not (Received parent)) 'reused parent name does not receive stale notifications'
    $stats = Get-LaneUsage
    Assert ($stats.launches -eq 6 -and $stats.restarts -eq 3) 'usage counts launches and restarts'
    'All notification checks passed'
} finally {
    $env:LANES_LANE = $null
    foreach ($n in 'parent', 'child') { try { Stop-Lane $n -Hard -Force | Out-Null } catch { } }
    "Evidence retained in $env:LANES_HOME"
}
