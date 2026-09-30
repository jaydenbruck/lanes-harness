# lane.ps1 — the `lane` command line. Thin: parses `--flag value` and positionals, calls the module.
#
#   lane launch --name api --kind claude|codex|grok|cursor|other --model opus --effort high --cwd C:\src\myapp --brief briefs\api.md [--visible|--hidden] [--is-head]
#   lane list [--all] [--head h] [--json]
#   lane read <name> [--tail 50] [--from A --to B] [--raw] [--messages 3] [--events]
#   lane send <name> <text...> | --key enter | --key down,down,enter | --raw "2" | --file path | --no-enter
#   lane kill <name> [--hard]
#   lane restart <name> [--prompt "..."] [--fresh]
#   lane events [--drain] [--peek] [--max 200] [--head h] [--json] [--label-chars 240] [--as consumer]
#   lane wait [--timeout 600] [--drain]
#   lane tab <name> [--new-window] [--split-pane]
#   lane serve [--port 7342] [--open]
#   lane head <name> [--lane l]     lane heads
#   lane status <name>              (state.json)
[CmdletBinding()]
param([Parameter(Position = 0)][string]$Verb = 'help', [Parameter(Position = 1, ValueFromRemainingArguments)][string[]]$Rest)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Lanes.psm1') -Force -DisableNameChecking

function Parse-Args([string[]]$a, [string[]]$positional, [string[]]$switches) {
    $named = @{}; $pos = @(); $i = 0
    while ($i -lt $a.Count) {
        $t = $a[$i]
        if ($t -like '--*') {
            $k = ($t.Substring(2) -split '-' | ForEach-Object { if ($_) { $_.Substring(0, 1).ToUpper() + $_.Substring(1) } }) -join ''
            if ($switches -contains $k -or $i + 1 -ge $a.Count -or ($a[$i + 1] -like '--*' -and $switches -contains $k)) { $named[$k] = $true; $i++; continue }
            $named[$k] = $a[$i + 1]; $i += 2; continue
        }
        $pos += $t; $i++
    }
    for ($j = 0; $j -lt [math]::Min($pos.Count, $positional.Count); $j++) { $named[$positional[$j]] = $pos[$j] }
    if ($pos.Count -gt $positional.Count) { $named['_rest'] = $pos[$positional.Count..($pos.Count - 1)] }
    return $named
}

switch ($Verb) {
    'launch' {
        $p = Parse-Args $Rest @('Name') @('Visible', 'Hidden', 'IsHead', 'KeepLog', 'Force')
        if ($p.ContainsKey('ExtraArgs')) { $p.ExtraArgs = @($p.ExtraArgs -split ' ') }
        if ($p.ContainsKey('_rest')) { $p.Remove('_rest') }
        $st = Start-Lane @p
        "launched $($st.name)  head=$($st.head) state=$($st.state) pid=$($st.pid) host=$($st.hostPid) cwd=$($st.cwd)"
        if ($st.kind -eq 'codex') {
            $readback = [pscustomobject]@{ requested = $st.requestedEffort; actual = $st.actualEffort; status = $st.effortStatus }
            Format-LaneEffortReadback $readback
            if ($st.effortStatus -eq 'DRIFT') { exit 1 }
            if ($st.effortStatus -eq 'CANNOT-SEE') { exit 3 }
        }
        "log  $(Join-Path (Get-LanesRoot) $st.name 'console.log')"
    }
    'list' {
        $p = Parse-Args $Rest @() @('All', 'Json')
        $json = $p.Remove('Json'); $lanes = @(Get-Lane @p)
        if ($json) { $lanes | ConvertTo-Json -Depth 6 } elseif ($lanes.Count -eq 0) { '(no lanes)' } else { $lanes | Format-LaneTable }
    }
    'ls' { & $PSCommandPath list @Rest }
    'read' {
        $p = Parse-Args $Rest @('Name') @('Raw', 'Events')
        if ($p.ContainsKey('_rest')) { $p.Remove('_rest') }
        Read-Lane @p
    }
    'send' {
        $p = Parse-Args $Rest @('Name') @('Raw', 'NoEnter', 'Force')
        if ($p.ContainsKey('Key')) { $p.Key = @($p.Key -split ',') }
        if ($p.ContainsKey('_rest')) { $p.Text = $p._rest; $p.Remove('_rest') }
        Send-Lane @p
        "sent to $($p.Name)"
    }
    'kill' {
        $p = Parse-Args $Rest @('Name') @('Hard', 'Force')
        $st = Stop-Lane @p
        "$($st.name): $($st.state) ($($st.why))"
    }
    'restart' {
        $p = Parse-Args $Rest @('Name') @('Force', 'Fresh')
        $st = Restart-Lane @p
        "restarted $($st.name)  state=$($st.state) pid=$($st.pid) host=$($st.hostPid) resume=$($st.sessionId)"
        if ($st.kind -eq 'codex') {
            $readback = [pscustomobject]@{ requested = $st.requestedEffort; actual = $st.actualEffort; status = $st.effortStatus }
            Format-LaneEffortReadback $readback
            if ($st.effortStatus -eq 'DRIFT') { exit 1 }
            if ($st.effortStatus -eq 'CANNOT-SEE') { exit 3 }
        }
    }
    'events' {
        $p = Parse-Args $Rest @() @('Drain', 'Peek', 'Json', 'All')
        $json = $p.Remove('Json'); if ($json) { $p.AsObject = $true }
        $ev = Get-LaneEvent @p
        if ($json) { $ev | ConvertTo-Json -Depth 4 } else { $ev }
    }
    'wait' {
        $p = Parse-Args $Rest @() @('Drain')
        if ($p.ContainsKey('Timeout')) { $p.TimeoutSec = [int]$p.Timeout; $p.Remove('Timeout') }
        Wait-LaneEvent @p
    }
    'tab' {
        $p = Parse-Args $Rest @('Name') @('NewWindow', 'SplitPane')
        Open-LaneTab @p; "tab opened for $($p.Name)"
    }
    'serve' {
        $p = Parse-Args $Rest @() @('Open', 'Foreground')
        Start-LaneViewer @p
    }
    'head' {
        $p = Parse-Args $Rest @('Name') @('Force')
        Register-LaneHead @p | ConvertTo-Json -Compress
    }
    'heads' { Get-LaneHead | ConvertTo-Json -Compress }
    'status' {
        $p = Parse-Args $Rest @('Name') @()
        Get-LaneState $p.Name | ConvertTo-Json -Depth 6
    }
    'whoami' { "head: $(Get-CurrentHead)  consumer: $(Get-CurrentConsumer)  lane: $env:LANES_LANE  home: $(Get-LanesHome)  root: $(Get-LanesRoot)" }
    default {
        @'
lane — Lanes Harness: run Claude Code, Codex, Grok and Cursor agents as headless lanes

  lane launch --name N --kind claude|codex|grok|cursor|other [--model M] [--effort LEVEL] [--cwd DIR] [--brief PATH] [--prompt TEXT] [--command CMD]
              Codex effort defaults to high; launch reads the actual status bar back.
              [--visible|--hidden] [--is-head] [--head OWNER] [--stall-minutes 10] [--cols 160 --rows 45]
  lane list [--all] [--head H] [--json]          lane status N
  lane read N [--tail 40] [--from A --to B] [--raw] [--messages 3] [--events]
  lane send N TEXT...      lane send N --key enter|esc|up|down|tab|ctrl-c|y|n   lane send N --raw "2"   lane send N --file PATH
  lane kill N [--hard]     lane restart N [--prompt TEXT] [--fresh]
  lane events [--drain] [--peek] [--max 200] [--json] [--as CONSUMER]     lane wait [--timeout 600] [--drain] [--as CONSUMER]
  lane tab N [--new-window|--split-pane]     lane serve [--port 7342] [--open]
  lane head N              lane heads        lane whoami
'@
    }
}
