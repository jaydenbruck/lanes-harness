# Lanes.psm1 — the PowerShell 7 control surface of Lanes Harness.
#
# Every lane is a real CLI process (claude / codex / grok / cursor / anything) inside a ConPTY owned by one tiny
# LaneHost.exe. This module launches hosts, reads their logs, types into them, kills and restarts
# them, and drains the per-head event queue. It holds no state of its own: the registry is the set of
# <LANES_HOME>\lanes\<name>\state.json files plus _registry.jsonl, the queues are <LANES_HOME>\heads\<head>\events.jsonl.
# LANES_HOME defaults to %LOCALAPPDATA%\lanes.
#
# Verbs (also reachable as `lane <verb>` through lane.ps1):
#   Start-Lane (launch) · Get-Lane (list) · Read-Lane (read) · Send-Lane (send) · Stop-Lane (kill)
#   Restart-Lane (restart) · Get-LaneEvent (events) · Open-LaneTab (tab) · Start-LaneViewer (serve)
#   Register-LaneHead (head) · Get-LaneHead (heads) · Wait-LaneEvent (wait)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$script:ModuleDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Exe       = Join-Path $script:ModuleDir 'bin\LaneHost.exe'
$script:LanesHome = if ($env:LANES_HOME) { $env:LANES_HOME } else { Join-Path $env:LOCALAPPDATA 'lanes' }
$script:Root      = if ($env:LANES_ROOT) { $env:LANES_ROOT } else { Join-Path $script:LanesHome 'lanes' }
$script:HeadsRoot = if ($env:LANES_HEADS_ROOT) { $env:LANES_HEADS_ROOT } else { Join-Path $script:LanesHome 'heads' }
$script:MaxHeads  = if ($env:LANES_MAX_HEADS) { [int]$env:LANES_MAX_HEADS } else { 2 }
$script:Utf8      = [System.Text.UTF8Encoding]::new($false)

function Get-LanesHome { $script:LanesHome }
function Get-LanesRoot { $script:Root }
function Get-LaneHeadsRoot { $script:HeadsRoot }

# ---------------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------------
function Get-CurrentHead {
    if ($env:LANES_HEAD) { return $env:LANES_HEAD }
    return 'user'
}

function Get-CurrentConsumer {
    # Who is draining. A registered head is its own consumer; any other lane-hosted session (a verifier, a helper
    # launched without --is-head) is identified by its lane name; the human at their own terminal is 'user'.
    # Two sessions that share a head identity therefore still keep separate cursors: each sees every event once,
    # and neither can mark the other's unseen rows as seen.
    if ($env:LANES_CONSUMER) { return $env:LANES_CONSUMER }
    if ($env:LANES_HEAD -and $env:LANES_HEAD -ne 'user') { return $env:LANES_HEAD }
    if ($env:LANES_LANE) { return $env:LANES_LANE }
    return 'user'
}

function Get-CursorPath([string]$Head, [string]$Consumer) {
    if (-not $Consumer -or $Consumer -eq $Head -or $Consumer -eq 'user') { return (Join-Path $script:HeadsRoot $Head 'events.cursor') }
    return (Join-Path $script:HeadsRoot $Head ("events." + ($Consumer -replace '[^A-Za-z0-9._-]', '_') + ".cursor"))
}

function Test-LaneName([string]$Name) {
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw "lane name '$Name' must be 1-64 chars of [A-Za-z0-9._-]" }
}

function Get-LaneDir([string]$Name) { Test-LaneName $Name; Join-Path $script:Root $Name }   # every caller validated in one place

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    # the host replaces state.json atomically; a read can still race the replace, so retry briefly
    for ($i = 0; $i -lt 5; $i++) {
        try { return ([IO.File]::ReadAllText($Path, $script:Utf8) | ConvertFrom-Json -AsHashtable) }
        catch { Start-Sleep -Milliseconds 40 }
    }
    return $null
}

function Write-JsonFile([string]$Path, $Obj) {
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, ($Obj | ConvertTo-Json -Depth 8 -Compress), $script:Utf8)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function ConvertTo-Utc($v) {
    # ConvertFrom-Json already turns ISO strings into DateTime; strings still arrive from other paths.
    if ($null -eq $v -or $v -eq '') { return $null }
    if ($v -is [DateTime]) { if ($v.Kind -eq 'Unspecified') { return [DateTime]::SpecifyKind($v, 'Utc') } else { return $v.ToUniversalTime() } }
    return [DateTime]::Parse([string]$v, $null, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

function Test-HostAlive($State) {
    if (-not $State -or -not $State.ContainsKey('hostPid')) { return $false }
    try {
        $p = Get-Process -Id ([int]$State.hostPid) -ErrorAction Stop
        if ($State.ContainsKey('hostStart') -and $State.hostStart) {
            $t = ConvertTo-Utc $State.hostStart
            return ([math]::Abs(($p.StartTime.ToUniversalTime() - $t).TotalSeconds) -lt 2)
        }
        return $true
    } catch { return $false }
}

function Append-Line([string]$Path, [string]$Line) {
    # Same discipline as the host: a named mutex per file, one append, flushed.
    $dir = Split-Path -Parent $Path; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $mname = 'lanes-events-' + ($Path.ToLowerInvariant() -replace '[\\:/]', '_')
    $m = [System.Threading.Mutex]::new($false, $mname)
    $got = $false
    try { $got = $m.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    try {
        $fs = [IO.FileStream]::new($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        try { $b = $script:Utf8.GetBytes($Line + "`n"); $fs.Write($b, 0, $b.Length); $fs.Flush($true) } finally { $fs.Dispose() }
    } finally { if ($got) { $m.ReleaseMutex() }; $m.Dispose() }
}

# Pipe client: one frame out, optional one frame back.
function Send-LaneFrame {
    param([string]$Name, [char]$Type, [byte[]]$Payload = @(), [switch]$WantReply, [int]$TimeoutMs = 3000)
    $cli = [System.IO.Pipes.NamedPipeClientStream]::new('.', "lanes-$Name", [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
    try {
        $cli.Connect($TimeoutMs)
        $len = $Payload.Length
        $hdr = [byte[]]@([byte][char]$Type, ($len -band 0xFF), (($len -shr 8) -band 0xFF), (($len -shr 16) -band 0xFF), (($len -shr 24) -band 0xFF))
        $cli.Write($hdr, 0, 5); if ($len -gt 0) { $cli.Write($Payload, 0, $len) }; $cli.Flush()
        if ($WantReply) {
            $h = [byte[]]::new(5); $got = 0
            while ($got -lt 5) { $n = $cli.Read($h, $got, 5 - $got); if ($n -le 0) { throw "pipe closed" }; $got += $n }
            $rl = [int]$h[1] -bor ([int]$h[2] -shl 8) -bor ([int]$h[3] -shl 16) -bor ([int]$h[4] -shl 24)
            $pl = [byte[]]::new($rl); $got = 0
            while ($got -lt $rl) { $n = $cli.Read($pl, $got, $rl - $got); if ($n -le 0) { break }; $got += $n }
            return @{ Type = [char]$h[0]; Payload = $pl }
        }
        # give the server a moment to consume before the pipe closes under it
        Start-Sleep -Milliseconds 30
    } finally { $cli.Dispose() }
}

function Get-LaneState([string]$Name) {
    $st = Read-JsonFile (Join-Path (Get-LaneDir $Name) 'state.json')
    if ($null -eq $st) { return $null }
    $alive = Test-HostAlive $st
    $st['alive'] = $alive
    if (-not $alive -and $st.state -in @('running', 'needs-input', 'stalled', 'starting')) {
        # The host is gone without an exit row: the registry must not keep saying "running".
        $st['state'] = 'died'; $st['why'] = 'host-lost'
        $marker = Join-Path (Get-LaneDir $Name) 'host-lost.emitted'
        $claimed = $false
        try { $fsm = [IO.File]::Open($marker, [IO.FileMode]::CreateNew); $fsm.Dispose(); $claimed = $true } catch { }   # exclusive create: one emitter, ever
        if ($claimed) {
            try {
                $st['label'] = 'host process vanished (supervisor or host killed); transcript preserved'
                Write-JsonFile (Join-Path (Get-LaneDir $Name) 'state.json') $st
                $row = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); head = $st.head; lane = $Name; state = 'died'; why = 'host-lost'
                    label = $st.label; from = $st.episodeStart; to = $st.bytes; pid = $st.pid; exit = $null; kind = $st.kind; model = $st.model; cwd = $st.cwd; hostPid = $st.hostPid; n = 0 }
                Append-Line (Join-Path $script:HeadsRoot $st.head 'events.jsonl') ($row | ConvertTo-Json -Compress)
            } catch { }
        }
    }
    return $st
}

function Assert-LaneDriveable([string]$Name, $State, [switch]$Force) {
    # A lane belongs to exactly one head. Another head may only type into a head lane (its inbox).
    $me = Get-CurrentHead
    if ($Force -or $me -eq 'user') { return }
    if ($State.head -eq $me) { return }
    $isHeadLane = $false
    try { $isHeadLane = [bool]($State.meta -and $State.meta.isHead) } catch { }
    if ($isHeadLane) { return }
    throw "lane '$Name' belongs to head '$($State.head)'; '$me' may not drive it (it may only `lane send` to a head's inbox)"
}

# ---------------------------------------------------------------------------------------------------
# heads
# ---------------------------------------------------------------------------------------------------
function Get-LaneHead {
    $f = Join-Path $script:HeadsRoot 'heads.json'
    $h = Read-JsonFile $f
    if ($null -eq $h) { return @() }
    return @($h.heads)
}

function Register-LaneHead {
    param([Parameter(Mandatory)][string]$Name, [string]$Lane = '', [switch]$Force)
    Test-LaneName $Name
    if ($Name -eq 'user') { throw "'user' is the implicit owner of head lanes (the human), not a head" }
    New-Item -ItemType Directory -Force $script:HeadsRoot | Out-Null
    $f = Join-Path $script:HeadsRoot 'heads.json'
    $m = [System.Threading.Mutex]::new($false, 'lanes-heads'); $got = $false
    try { $got = $m.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    try {
        $h = Read-JsonFile $f; if ($null -eq $h) { $h = @{ heads = @() } }
        $list = @($h.heads)
        $existing = $list | Where-Object { $_.name -eq $Name }
        if ($existing) {
            if ($Lane) { $existing.lane = $Lane; $existing.updated = (Get-Date).ToUniversalTime().ToString('o') }
            Write-JsonFile $f @{ heads = $list }
            return $existing
        }
        # At most LANES_MAX_HEADS heads (default 2). A dead head's seat can be reclaimed with -Force.
        $live = @()
        foreach ($x in $list) {
            $alive = $false
            if ($x.lane) { $st = Read-JsonFile (Join-Path (Get-LaneDir $x.lane) 'state.json'); if ($st) { $alive = Test-HostAlive $st } }
            if ($alive -or -not $Force) { $live += $x }
        }
        if ($live.Count -ge $script:MaxHeads) {
            throw "$($live.Count) heads already registered ($($live.name -join ', ')); LANES_MAX_HEADS is $($script:MaxHeads). Use -Force to replace a dead one."
        }
        $entry = [ordered]@{ name = $Name; lane = $Lane; created = (Get-Date).ToUniversalTime().ToString('o'); updated = (Get-Date).ToUniversalTime().ToString('o') }
        $live += $entry
        Write-JsonFile $f @{ heads = $live }
        New-Item -ItemType Directory -Force (Join-Path $script:HeadsRoot $Name) | Out-Null
        return $entry
    } finally { if ($got) { $m.ReleaseMutex() }; $m.Dispose() }
}

# ---------------------------------------------------------------------------------------------------
# launch
# ---------------------------------------------------------------------------------------------------
function New-ClaudeHookSettings([string]$LaneDir) {
    $cmd = '"' + $script:Exe + '" hook "' + $LaneDir + '"'
    $hook = @{ type = 'command'; command = $cmd; timeout = 20 }
    $plain = @(@{ hooks = @($hook) })
    $settings = @{
        hooks = @{
            SessionStart      = $plain
            UserPromptSubmit  = $plain
            Stop              = $plain
            Notification      = $plain
            PermissionRequest = $plain
            SessionEnd        = $plain
            PreToolUse        = @(@{ matcher = 'AskUserQuestion'; hooks = @($hook) })
            PostToolUse       = @(@{ matcher = 'AskUserQuestion'; hooks = @($hook) })
        }
    }
    $p = Join-Path $LaneDir 'claude-settings.json'
    [IO.File]::WriteAllText($p, ($settings | ConvertTo-Json -Depth 6), $script:Utf8)
    return $p
}

function Get-TomlSection([string]$Text, [string]$Name) {
    $m = [regex]::Match($Text, "(?ms)^\[" + [regex]::Escape($Name) + "\]\s*\r?\n(?<body>.*?)(?=^\[|\z)")
    if ($m.Success) { return $m.Groups['body'].Value }
    return ''
}

function Test-LanesStrictPrivacy { return ($env:LANES_STRICT_PRIVACY -match '^(1|true|yes|on)$') }

function Assert-GrokDataSharingOptOut {
    # Opt-in (LANES_STRICT_PRIVACY=1): refuse to launch Grok unless the account has opted out of coding-data
    # retention and local telemetry is pinned off. The coding-data choice is an account setting cached by the
    # authenticated CLI, not a telemetry guess. Local telemetry is a separate surface and must also be pinned off.
    $home = Join-Path $env:USERPROFILE '.grok'
    $authPath = Join-Path $home 'auth.json'
    $configPath = Join-Path $home 'config.toml'
    if (-not (Test-Path -LiteralPath $authPath)) { throw "Grok is not logged in: $authPath is absent" }
    if (-not (Test-Path -LiteralPath $configPath)) { throw "Grok privacy config is absent: $configPath" }

    try { $auth = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json -AsHashtable } catch { throw "cannot read Grok account settings from $authPath`: $_" }
    $stack = [System.Collections.Generic.Stack[object]]::new(); $stack.Push($auth)
    $optOut = @()
    while ($stack.Count) {
        $node = $stack.Pop()
        if ($node -is [System.Collections.IDictionary]) {
            foreach ($key in $node.Keys) {
                $value = $node[$key]
                if ([string]$key -eq 'coding_data_retention_opt_out') { $optOut += [bool]$value }
                if ($value -is [System.Collections.IDictionary] -or ($value -is [System.Collections.IEnumerable] -and $value -isnot [string])) { $stack.Push($value) }
            }
        } elseif ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
            foreach ($value in $node) { if ($null -ne $value) { $stack.Push($value) } }
        }
    }
    if ($optOut.Count -eq 0 -or $optOut -contains $false) { throw 'Grok account setting coding_data_retention_opt_out is not proven true; open Grok Settings > Data sharing, opt out, then retry' }

    $config = [IO.File]::ReadAllText($configPath)
    $features = Get-TomlSection $config 'features'
    $telemetry = Get-TomlSection $config 'telemetry'
    $pins = [ordered]@{
        'features.telemetry' = ($features -match '(?m)^\s*telemetry\s*=\s*false\s*(?:#.*)?$')
        'features.feedback' = ($features -match '(?m)^\s*feedback\s*=\s*false\s*(?:#.*)?$')
        'telemetry.mixpanel_enabled' = ($telemetry -match '(?m)^\s*mixpanel_enabled\s*=\s*false\s*(?:#.*)?$')
        'telemetry.trace_upload' = ($telemetry -match '(?m)^\s*trace_upload\s*=\s*false\s*(?:#.*)?$')
    }
    $missing = @($pins.Keys | Where-Object { -not $pins[$_] })
    if ($missing.Count) { throw "Grok local privacy pins are missing or not false: $($missing -join ', ') in $configPath" }
    foreach ($name in 'GROK_TELEMETRY_ENABLED','GROK_FEEDBACK_ENABLED','GROK_TELEMETRY_MIXPANEL_ENABLED','GROK_TELEMETRY_TRACE_UPLOAD') {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value -and $value -notmatch '^(0|false|off|no)$') { throw "Grok privacy pin is overridden by $name" }
    }
    return [pscustomobject]@{ accountOptOut = $true; telemetry = $false; feedback = $false; mixpanel = $false; traceUpload = $false; authPath = $authPath; configPath = $configPath }
}

function Install-GrokLaneHooks {
    # Grok reads user config only, so this adds a marked block to ~/.grok/config.toml. The hook is inert
    # outside a lane because grok-hook.ps1 requires LANES_LANE_DIR/LANES_MODULE; inside a lane it gives
    # LaneHost the same lifecycle evidence used by Claude and Codex. The block is replaced atomically.
    $configPath = Join-Path $env:USERPROFILE '.grok\config.toml'
    $hookPath = Join-Path $script:ModuleDir 'grok-hook.ps1'
    if (-not (Test-Path -LiteralPath $hookPath)) { throw "Grok lane hook is missing: $hookPath" }
    $command = 'pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $hookPath + '"'
    if ($command.Contains("'")) { throw "Grok hook path cannot contain an apostrophe: $hookPath" }
    $tables = foreach ($event in 'SessionStart','UserPromptSubmit','Stop','SessionEnd') {
        "[[hooks.$event]]`r`n  [[hooks.$event.hooks]]`r`n  type = `"command`"`r`n  command = '$command'`r`n  timeout = 20"
    }
    $block = "# BEGIN LANES HARNESS GROK HOOKS`r`n" + ($tables -join "`r`n`r`n") + "`r`n# END LANES HARNESS GROK HOOKS"
    $mutex = [System.Threading.Mutex]::new($false, 'lanes-grok-config')
    $got = $false
    try {
        try { $got = $mutex.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
        $text = [IO.File]::ReadAllText($configPath)
        $pattern = '(?ms)^# BEGIN LANES HARNESS GROK HOOKS\r?\n.*?^# END LANES HARNESS GROK HOOKS\s*'
        $next = if ([regex]::IsMatch($text, $pattern)) { [regex]::Replace($text, $pattern, $block + "`r`n") } else { $text.TrimEnd() + "`r`n`r`n" + $block + "`r`n" }
        if ($next -cne $text) {
            $tmp = "$configPath.lanes-harness.tmp"
            [IO.File]::WriteAllText($tmp, $next, $script:Utf8)
            Move-Item -LiteralPath $tmp -Destination $configPath -Force
        }
    } finally { if ($got) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
    return $hookPath
}

function Get-CodexEffortArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_-]*$')][string]$Effort)
    return @('-c', "model_reasoning_effort=$Effort")
}

function Read-LaneEffortFromLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [long]$From = 0, [int]$MaxBytes = 4194304)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $fs = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $start = [math]::Min([math]::Max([long]0, $From), $fs.Length)
        if ($fs.Length - $start -gt $MaxBytes) { $start = $fs.Length - $MaxBytes }
        $null = $fs.Seek($start, [IO.SeekOrigin]::Begin)
        $buf = [byte[]]::new($fs.Length - $start)
        $got = 0
        while ($got -lt $buf.Length) {
            $read = $fs.Read($buf, $got, $buf.Length - $got)
            if ($read -le 0) { break }
            $got += $read
        }
    } finally { $fs.Dispose() }
    if ($got -eq 0) { return '' }
    $text = $script:Utf8.GetString($buf, 0, $got)
    $text = [regex]::Replace($text, "`e\[[0-9;?<=>!]*[ -/]*[@-~]", '')
    $text = [regex]::Replace($text, "`e\][^`a`e]*(`a|`e\\)?", '')
    $text = [regex]::Replace($text, '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', ' ')
    # Codex renders the effort in two status-bar forms: the startup card ends in
    # "/model to change", and the footer separates the working directory with a middle dot.
    # Requiring one of those delimiters keeps prompt text from impersonating a readback.
    $matches = [regex]::Matches($text, '(?i)gpt[\w.\-]*\s+(none|minimal|low|medium|high|xhigh|max|ultra)\b(?=\s*(?:/model\b|·))')
    if ($matches.Count -eq 0) { return '' }
    return $matches[$matches.Count - 1].Groups[1].Value.ToLowerInvariant()
}

function Wait-LaneEffortReadback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Expected,
        [long]$From = 0,
        [int]$TimeoutSeconds = 30
    )
    $path = Join-Path (Get-LaneDir $Name) 'console.log'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $actual = Read-LaneEffortFromLog -Path $path -From $From
        if ($actual) {
            return [pscustomobject]@{ requested = $Expected; actual = $actual; status = $(if ($actual -eq $Expected) { 'OK' } else { 'DRIFT' }) }
        }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    return [pscustomobject]@{ requested = $Expected; actual = 'UNKNOWN'; status = 'CANNOT-SEE' }
}

function Format-LaneEffortReadback {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Readback)
    if ($Readback.status -eq 'OK') { return "OK effort requested=$($Readback.requested) actual=$($Readback.actual)" }
    if ($Readback.status -eq 'DRIFT') { return "DRIFT effort requested=$($Readback.requested) actual=$($Readback.actual)" }
    return "CANNOT-SEE effort requested=$($Readback.requested) actual=UNKNOWN"
}

function Get-LaneEffortReadbackTimeout {
    [CmdletBinding()]
    param([string]$ResumeSession = '')
    if ($ResumeSession) { return 120 }
    return 30
}

function Get-LaneRestartEffort {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Launch)
    if (($Launch.PSObject.Properties.Name -contains 'effort') -and $Launch.effort) { return [string]$Launch.effort }
    return 'high'
}

function Start-Lane {
    <#
    .SYNOPSIS  Launch a real CLI session in its own pseudoconsole, owned by the current head.
    .EXAMPLE   Start-Lane -Name api -Kind claude -Model opus -Cwd C:\src\myapp -Brief briefs\api.md
    .EXAMPLE   Start-Lane -Name sec -Kind codex -Cwd C:\src\myapp -Prompt "Audit the auth module."
    .EXAMPLE   Start-Lane -Name build -Kind grok -Cwd C:\src\myapp -Prompt "Fix the failing build."
    .EXAMPLE   Start-Lane -Name ui -Kind cursor -Cwd C:\src\myapp -Prompt "Polish the settings page."
    .EXAMPLE   Start-Lane -Name shell -Command 'pwsh -NoLogo' -Cwd C:\src\myapp
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('claude', 'codex', 'grok', 'cursor', 'other')][string]$Kind = 'claude',
        [string]$Model = '',
        [string]$Cwd = (Get-Location).Path,
        [string]$Brief = '',            # path to the brief; the first prompt tells the session to read it
        [string]$Prompt = '',           # literal first prompt (appended after the brief line if both)
        [string]$Command = '',          # explicit command line for -Kind other (or to override a built-in kind)
        [string[]]$ExtraArgs = @(),
        [ValidatePattern('^[a-z][a-z0-9_-]*$')][string]$Effort = 'high',
        [string]$Head = '',             # owner; defaults to the current head ($env:LANES_HEAD or 'user')
        [switch]$IsHead,                # this lane IS a head agent: registers it (LANES_MAX_HEADS, default 2), sets LANES_HEAD inside it
        [switch]$Visible, [switch]$Hidden,
        [int]$Cols = 160, [int]$Rows = 45,
        [int]$StallMinutes = 10,
        [int]$StallSeconds = 0,         # overrides -StallMinutes when > 0 (tests)
        [string]$ResumeSession = '',    # claude: --resume <id>; codex: resume <id>
        [string]$RestartOf = '', [int]$RestartCount = 0,
        [switch]$KeepLog,               # append to the existing console.log (restart) instead of rotating it
        [switch]$Force                  # replace a dead head seat
    )
    Test-LaneName $Name
    if (-not (Test-Path -LiteralPath $script:Exe)) { throw "LaneHost.exe not built: run $script:ModuleDir\build.ps1" }
    if (-not (Test-Path -LiteralPath $Cwd -PathType Container)) { throw "cwd '$Cwd' does not exist" }
    $Cwd = (Resolve-Path -LiteralPath $Cwd).Path
    if (-not $Head) { $Head = Get-CurrentHead }
    if ($IsHead) {
        # The human launches head agents; the head lane is owned by 'user' and registered.
        $null = Register-LaneHead -Name $Name -Lane $Name -Force:$Force
        $Head = 'user'
    }
    $laneDir = Get-LaneDir $Name
    New-Item -ItemType Directory -Force $script:Root, $script:HeadsRoot, (Join-Path $script:HeadsRoot $Head) | Out-Null

    # Name reuse: alive -> refuse; dead -> preserve the old generation, never overwrite a transcript.
    if (Test-Path -LiteralPath $laneDir) {
        $old = Read-JsonFile (Join-Path $laneDir 'state.json')
        if ($old -and (Test-HostAlive $old)) { throw "lane '$Name' is alive (host pid $($old.hostPid), state $($old.state)); kill it first or pick another name" }
        if (-not $KeepLog) {
            $stamp = if ($old -and $old.started) { (ConvertTo-Utc $old.started).ToString('yyyyMMdd-HHmmss') } else { (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') }
            $hist = Join-Path $laneDir "history\$stamp"
            New-Item -ItemType Directory -Force $hist | Out-Null
            foreach ($f in 'console.log', 'state.json', 'hooks.jsonl', 'launch.json', 'claude-settings.json', 'host-lost.emitted') {
                $src = Join-Path $laneDir $f
                if (Test-Path -LiteralPath $src) { Move-Item -LiteralPath $src -Destination (Join-Path $hist $f) -Force }
            }
        } else {
            foreach ($f in 'host-lost.emitted', 'hooks.jsonl') { $src = Join-Path $laneDir $f; if (Test-Path -LiteralPath $src) { Remove-Item -LiteralPath $src -Force } }
        }
    }
    New-Item -ItemType Directory -Force $laneDir | Out-Null
    $effortReadOffset = 0
    $consolePath = Join-Path $laneDir 'console.log'
    if (Test-Path -LiteralPath $consolePath -PathType Leaf) { $effortReadOffset = (Get-Item -LiteralPath $consolePath).Length }

    # Build the command line.
    $sessionId = ''
    $parts = @()
    $firstPrompt = ''
    if ($Brief) {
        $bp = (Resolve-Path -LiteralPath $Brief -ErrorAction SilentlyContinue)
        $bpath = if ($bp) { $bp.Path } else { $Brief }
        $firstPrompt = "Read $bpath. It is your brief. Carry it out completely."
    }
    if ($Prompt) { $firstPrompt = if ($firstPrompt) { "$firstPrompt`n`n$Prompt" } else { $Prompt } }

    if ($Command) {
        $cmdline = (@($Command) + @($ExtraArgs | ForEach-Object { ConvertTo-ArgString $_ })) -join ' '
        if ($firstPrompt) { $cmdline += ' ' + (ConvertTo-ArgString $firstPrompt) }
    }
    elseif ($Kind -eq 'claude') {
        $settings = New-ClaudeHookSettings $laneDir
        $parts = @((Resolve-LaneExe 'claude'), '--dangerously-skip-permissions')
        if ($Model) { $parts += @('--model', $Model) }
        if ($ResumeSession) { $parts += @('--resume', $ResumeSession); $sessionId = $ResumeSession }
        else { $sessionId = [guid]::NewGuid().ToString(); $parts += @('--session-id', $sessionId) }
        $parts += @('--settings', $settings)
        $parts += $ExtraArgs
        if ($firstPrompt) { $parts += $firstPrompt }
        $cmdline = ($parts | ForEach-Object { ConvertTo-ArgString $_ }) -join ' '
    }
    elseif ($Kind -eq 'codex') {
        $notify = "notify=['" + $script:Exe + "','hook','" + $laneDir + "']"
        $codex = Resolve-LaneExe 'codex'
        if ($ResumeSession) { $parts = @($codex, 'resume', $ResumeSession) } else { $parts = @($codex) }
        $parts += @('--yolo')
        if ($Model) { $parts += @('-m', $Model) }
        $parts += @('-c', $notify, '-C', $Cwd)
        $parts += $ExtraArgs
        $parts += Get-CodexEffortArguments -Effort $Effort
        if ($firstPrompt) { $parts += $firstPrompt }
        $cmdline = ($parts | ForEach-Object { ConvertTo-ArgString $_ }) -join ' '
        $sessionId = $ResumeSession
    }
    elseif ($Kind -eq 'grok') {
        if (Test-LanesStrictPrivacy) { $null = Assert-GrokDataSharingOptOut }
        $null = Install-GrokLaneHooks
        $parts = @((Resolve-LaneExe 'grok'), '--no-alt-screen', '--permission-mode', 'bypassPermissions')
        if ($Model) { $parts += @('--model', $Model) }
        if ($ResumeSession) { $parts += @('--resume', $ResumeSession); $sessionId = $ResumeSession }
        else { $sessionId = [guid]::NewGuid().ToString(); $parts += @('--session-id', $sessionId) }
        $parts += $ExtraArgs
        if ($firstPrompt) { $parts += $firstPrompt }
        $cmdline = ($parts | ForEach-Object { ConvertTo-ArgString $_ }) -join ' '
    }
    elseif ($Kind -eq 'cursor') {
        if (Test-LanesStrictPrivacy) { Assert-CursorModelIsZeroRetention $Model }
        # Cursor ships cursor-agent.cmd -> Windows PowerShell 5.1 -> cursor-agent.ps1 -> node.
        # Three process layers before the agent, and a ConPTY lane wants the leaf: the same
        # reason Resolve-LaneExe already skips the codex .cmd shim. Resolve-CursorAgent
        # returns the node.exe and the index.js of the newest installed version.
        $ca = Resolve-CursorAgent
        # --force is Cursor's own 'run everything' (its --yolo alias); it is the peer of
        # claude's --dangerously-skip-permissions and grok's bypassPermissions, which every
        # other kind here already passes. --trust answers the workspace-trust prompt that
        # would otherwise block a headless lane on its first turn forever.
        $parts = @($ca.Node, $ca.Entry, '--force', '--trust', '--workspace', $Cwd)
        if ($Model) { $parts += @('--model', $Model) }
        # Cursor mints its own chat id. Unlike claude and grok there is no --session-id to
        # pre-seed, so a fresh lane has no id until Cursor makes one; resuming is by the id
        # Cursor itself returned. Recording an invented guid here would be a claim the tool
        # never made.
        if ($ResumeSession) { $parts += @('--resume', $ResumeSession); $sessionId = $ResumeSession }
        else { $sessionId = '' }
        $parts += $ExtraArgs
        if ($firstPrompt) { $parts += $firstPrompt }
        $cmdline = ($parts | ForEach-Object { ConvertTo-ArgString $_ }) -join ' '
    }
    else { throw "-Kind other needs -Command" }

    $meta = [ordered]@{ isHead = [bool]$IsHead; visible = $null; launchedBy = Get-CurrentHead; launcherPid = $PID }
    $showTab = if ($Visible) { $true } elseif ($Hidden) { $false } else { (@(Get-Lane | Where-Object { $_.alive }).Count -lt 10) }
    $meta.visible = $showTab

    $launch = [ordered]@{
        name = $Name; head = $Head; kind = $Kind; model = $Model; effort = $(if ($Kind -eq 'codex') { $Effort } else { '' }); actualEffort = ''; effortStatus = ''; effortReadbackAt = ''; cwd = $Cwd; brief = $Brief; prompt = $firstPrompt; cmd = $cmdline
        sessionId = $sessionId; cols = $Cols; rows = $Rows; stallMinutes = $StallMinutes; isHead = [bool]$IsHead; visible = $showTab
        restartOf = $RestartOf; restartCount = $RestartCount; launchedBy = (Get-CurrentHead); launcherPid = $PID
        strictPrivacy = [bool](Test-LanesStrictPrivacy)
        launchedAt = (Get-Date).ToUniversalTime().ToString('o'); exe = $script:Exe
    }
    Write-JsonFile (Join-Path $laneDir 'launch.json') $launch
    Append-Line (Join-Path $script:Root '_registry.jsonl') ($launch | ConvertTo-Json -Compress -Depth 4)   # every launch is recorded

    # Spawn the host. Hidden console, no redirection: the host neutralises its std handles before spawning the lane.
    $hostArgs = @('run', '--name', $Name, '--dir', $laneDir, '--cwd', $Cwd, '--cols', $Cols, '--rows', $Rows, '--head', $Head, '--kind', $Kind,
        '--model', $Model, '--brief', $Brief, '--session', $sessionId, '--stall-min', $StallMinutes) + $(if ($StallSeconds -gt 0) { @('--stall-sec', $StallSeconds) } else { @() }) + @(
        '--meta-json', ($meta | ConvertTo-Json -Compress), '--restart-of', $RestartOf, '--restart-count', $RestartCount,
        '--events', (Join-Path $script:HeadsRoot $Head 'events.jsonl'), '--cmdline', $cmdline)
    # Spawn through ShellExecuteEx (Start-Process without redirection): bInheritHandles is FALSE there, so the host
    # inherits no pipe from whoever launched it. A head launches lanes from a tool whose stdout is a pipe; one
    # inherited write end, anywhere in the lane's process tree, would keep that tool call open until the lane died.
    # (.NET's Process.Start always inherits handles, so the environment is staged on this process for the spawn.)
    # A lane is a first-class session, not a child of whoever launched it. A head agent is itself a Claude session,
    # and Claude Code marks its children (CLAUDE_CODE_CHILD_SESSION etc.): inherited, the lane would stop saving its
    # transcript, and --resume would have nothing to resume. Scrub every launcher marker for the spawn.
    $saved = @{}
    $scrub = [Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -match '^(CLAUDE_CODE_CHILD_SESSION|CLAUDE_CODE_ENTRYPOINT|CLAUDE_CODE_SESSION_ID|CLAUDE_PID|CLAUDECODE|CLAUDE_CODE_MAX_OUTPUT_TOKENS|CODEX_THREAD_ID|CODEX_SANDBOX.*|CODEX_CI)$' }
    $shimDir = Join-Path $script:LanesHome 'bin'
    if (-not (Test-Path (Join-Path $shimDir 'lane.cmd'))) { New-Item -ItemType Directory -Force $shimDir | Out-Null; Set-Content -LiteralPath (Join-Path $shimDir 'lane.cmd') -Value ('@echo off' + "`r`n" + 'pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File "' + (Join-Path $script:ModuleDir 'lane.ps1') + '" %*') -NoNewline -Encoding ascii }
    $lanePath = if (($env:Path -split ';') -contains $shimDir) { $env:Path } else { "$shimDir;$env:Path" }   # `lane` is on every lane's PATH, whatever the launcher's was
    $set = @{ CLAUDE_CODE_FORCE_SESSION_PERSISTENCE = '1'; Path = $lanePath; LANES_HEAD = $(if ($IsHead) { $Name } else { $Head }); LANES_LANE = $Name; LANES_LANE_DIR = $laneDir
              LANES_ROOT = $script:Root; LANES_HEADS_ROOT = $script:HeadsRoot; LANES_MODULE = $script:ModuleDir }
    foreach ($k in @($scrub) + @($set.Keys)) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
    try {
        foreach ($k in $scrub) { [Environment]::SetEnvironmentVariable($k, $null) }
        foreach ($k in $set.Keys) { [Environment]::SetEnvironmentVariable($k, $set[$k]) }
        $argString = ($hostArgs | ForEach-Object { ConvertTo-ArgString ([string]$_) }) -join ' '
        $proc = Start-Process -FilePath $script:Exe -ArgumentList $argString -WorkingDirectory $Cwd -WindowStyle Hidden -PassThru
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }

    # Wait for the state file: the host writes it right after the spawn.
    $sp = Join-Path $laneDir 'state.json'
    $deadline = (Get-Date).AddSeconds(15)
    $st = $null
    while ((Get-Date) -lt $deadline) {
        $st = Read-JsonFile $sp
        if ($st -and $st.state -ne 'starting' -and [int]$st.hostPid -eq $proc.Id) { break }
        if ($proc.HasExited) { break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $st) { throw "lane '$Name': host did not report a state within 15 s (host exit code $($proc.ExitCode))" }
    if ($st.state -eq 'died' -and $st.why -eq 'spawn-failed') { throw "lane '$Name': spawn failed: $($st.label)" }

    if ($showTab) { try { Open-LaneTab -Name $Name } catch { Write-Warning "could not open a Windows Terminal tab: $_" } }
    $st = Get-LaneState $Name
    if ($Kind -eq 'codex') {
        $readbackTimeout = Get-LaneEffortReadbackTimeout -ResumeSession $ResumeSession
        $readback = Wait-LaneEffortReadback -Name $Name -Expected $Effort -From $effortReadOffset -TimeoutSeconds $readbackTimeout
        $launch.actualEffort = $readback.actual
        $launch.effortStatus = $readback.status
        $launch.effortReadbackAt = (Get-Date).ToUniversalTime().ToString('o')
        Write-JsonFile (Join-Path $laneDir 'launch.json') $launch
        $st | Add-Member -NotePropertyName requestedEffort -NotePropertyValue $readback.requested -Force
        $st | Add-Member -NotePropertyName actualEffort -NotePropertyValue $readback.actual -Force
        $st | Add-Member -NotePropertyName effortStatus -NotePropertyValue $readback.status -Force
    }
    return $st
}

function Assert-CursorModelIsZeroRetention([string]$Model) {
    <#
      .SYNOPSIS  Refuse to launch a cursor lane on a model outside Cursor's ZDR agreements.
      .DESCRIPTION
        Opt-in: only called when LANES_STRICT_PRIVACY=1.

        Cursor's own docs: Privacy Mode stops code being used for training, but
        "some models also require data retention with their provider and fall
        outside Cursor's ZDR agreements". The server marks those in
        `--list-models` with a literal "(NO ZDR)" suffix.

        This asks the SERVER every launch rather than carrying a hardcoded list,
        because the set changes and a stale allowlist would silently authorise a
        model that lost its agreement.
    #>
    if (-not $Model) { return }   # no model named: Cursor's account default applies
    $ca = Resolve-CursorAgent
    $listing = & $ca.Node $ca.Entry --list-models 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "cursor: cannot read the model list, so ZDR cannot be verified - refusing to launch. Run 'cursor-agent login'."
    }
    $line = $listing | Where-Object { $_ -match "^\s*$([regex]::Escape($Model))\s+-" } | Select-Object -First 1
    if (-not $line) {
        throw "cursor: '$Model' is not a model this account is offered; refusing rather than guessing."
    }
    if ($line -match '\(NO ZDR\)') {
        throw "cursor: '$Model' is OUTSIDE Cursor's zero-data-retention agreements (server says: $($line.Trim())). LANES_STRICT_PRIVACY is on, so this lane is refused. Pick a model with no NO ZDR marker."
    }
}

function Resolve-CursorAgent {
    <#
      .SYNOPSIS  The node.exe and index.js of the newest installed Cursor CLI.
      .DESCRIPTION
        The installer puts wrappers at %LOCALAPPDATA%\cursor-agent and the real payload under
        versions\<stamp>\. cursor-agent.ps1 itself picks a version and runs
        `node.exe index.js`; this does the same thing without the cmd.exe and
        Windows-PowerShell hops in between.

        NOTE the name: `agent` can resolve to another tool's agent.exe (Grok ships one), so the
        wrapper of that name is NOT the one to reach for. Nothing here goes through PATH.
    #>
    $root = Join-Path $env:LOCALAPPDATA 'cursor-agent'
    $versions = Join-Path $root 'versions'
    if (-not (Test-Path -LiteralPath $versions)) {
        throw "cursor-agent is not installed (no $versions). Install: irm 'https://cursor.com/install?win32=true' | iex"
    }
    $pick = Get-ChildItem -LiteralPath $versions -Directory |
        Sort-Object LastWriteTime -Descending |
        Where-Object { (Test-Path (Join-Path $_.FullName 'node.exe')) -and (Test-Path (Join-Path $_.FullName 'index.js')) } |
        Select-Object -First 1
    if (-not $pick) { throw "no usable cursor-agent version under $versions (need node.exe and index.js)" }
    return [pscustomobject]@{
        Node    = (Join-Path $pick.FullName 'node.exe')
        Entry   = (Join-Path $pick.FullName 'index.js')
        Version = $pick.Name
    }
}

function Resolve-LaneExe([string]$Kind) {
    if ($Kind -eq 'cursor') { return (Resolve-CursorAgent).Node }
    if ($Kind -eq 'claude') {
        $c = Get-Command claude.exe -ErrorAction SilentlyContinue
        if (-not $c) { $c = Get-Command claude -ErrorAction SilentlyContinue }
        if (-not $c) { throw 'claude is not on PATH' }
        return $c.Source
    }
    if ($Kind -eq 'codex') {
        # the npm shim is a .cmd that picks the newest native codex.exe; do the same and skip cmd.exe
        $bin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
        if (Test-Path $bin) {
            $cand = Get-ChildItem -LiteralPath $bin -Directory | Sort-Object LastWriteTime -Descending | ForEach-Object { Join-Path $_.FullName 'codex.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
            if (-not $cand -and (Test-Path (Join-Path $bin 'codex.exe'))) { $cand = Join-Path $bin 'codex.exe' }
            if ($cand) { return $cand }
        }
        $c = Get-Command codex.exe -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
        throw 'codex.exe not found (looked under %LOCALAPPDATA%\OpenAI\Codex\bin and on PATH)'
    }
    if ($Kind -eq 'grok') {
        $installed = Join-Path $env:USERPROFILE '.grok\bin\grok.exe'
        if (Test-Path -LiteralPath $installed) { return $installed }
        $c = Get-Command grok.exe -ErrorAction SilentlyContinue
        if (-not $c) { $c = Get-Command grok -ErrorAction SilentlyContinue }
        if ($c) { return $c.Source }
        throw "grok.exe not found (looked at $installed and on PATH)"
    }
    throw "unknown kind $Kind"
}

function ConvertTo-ArgString([string]$s) {
    # Windows CommandLineToArgvW quoting.
    if ($s.Length -gt 0 -and $s -notmatch '[\s"]') { return $s }
    $sb = [System.Text.StringBuilder]::new('"'); $bs = 0
    foreach ($c in $s.ToCharArray()) {
        if ($c -eq '\') { $bs++; continue }
        if ($c -eq '"') { [void]$sb.Append('\', $bs * 2 + 1).Append('"'); $bs = 0; continue }
        if ($bs -gt 0) { [void]$sb.Append('\', $bs); $bs = 0 }
        [void]$sb.Append($c)
    }
    if ($bs -gt 0) { [void]$sb.Append('\', $bs * 2) }
    [void]$sb.Append('"'); return $sb.ToString()
}

# ---------------------------------------------------------------------------------------------------
# list / read
# ---------------------------------------------------------------------------------------------------
function Get-Lane {
    [CmdletBinding()]
    param([string]$Name = '', [switch]$All, [string]$Head = '')
    if ($Name) { return (Get-LaneState $Name) }
    if (-not (Test-Path $script:Root)) { return @() }
    $rows = @()
    foreach ($d in Get-ChildItem -LiteralPath $script:Root -Directory) {
        if ($d.Name.StartsWith('_')) { continue }
        $st = Get-LaneState $d.Name
        if ($null -eq $st) { continue }
        if ($Head -and $st.head -ne $Head) { continue }
        if (-not $All -and $st.state -in @('finished', 'died') -and -not $st.alive) {
            # finished lanes older than a day fall out of the default list
            try { if (((Get-Date).ToUniversalTime() - (ConvertTo-Utc $st.updated)).TotalHours -gt 24) { continue } } catch { }
        }
        $rows += $st
    }
    return $rows
}

function Format-LaneTable {
    param([Parameter(ValueFromPipeline)]$Lanes)
    begin { $acc = @() } process { $acc += $Lanes } end {
        $now = (Get-Date).ToUniversalTime()
        $acc | Sort-Object { $_.started } | ForEach-Object {
            $age = ''; $lo = ''
            try { $age = [int]($now - (ConvertTo-Utc $_.started)).TotalMinutes; $age = "${age}m" } catch { }
            try { $lo = [int]($now - (ConvertTo-Utc $_.lastOutputAt)).TotalSeconds; $lo = "${lo}s" } catch { }
            [pscustomobject]@{ lane = $_.name; head = $_.head; state = $_.state; why = $_.why; kind = $_.kind; model = $_.model; pid = $_.pid; age = $age; quiet = $lo; kb = [int]($_.bytes / 1024)
                label = (($_.label -replace '\s+', ' ')) | ForEach-Object { if ($_.Length -gt 70) { $_.Substring(0, 69) + '…' } else { $_ } } }
        } | Format-Table -AutoSize -Wrap:$false | Out-String -Width 220
    }
}

function ConvertFrom-Vt([string]$s) {
    # strip CSI / OSC / DCS / 2-char escapes, control chars; resolve \r overwrites per line
    $s = [regex]::Replace($s, "`e\[(\d*)C", { param($m) $n = 1; if ($m.Groups[1].Value) { $n = [math]::Min(1000, [int]$m.Groups[1].Value) }; ' ' * $n })
    $s = [regex]::Replace($s, "`e\[[0-9;?<=>!]*[ -/]*[@-~]", '')
    $s = [regex]::Replace($s, "`e\][^`a`e]*(`a|`e\\)?", '')
    $s = [regex]::Replace($s, "`e[P^_][^`e]*(`e\\)?", '')
    $s = [regex]::Replace($s, "`e[()*+#][0-9A-Za-z]", '')
    $s = [regex]::Replace($s, "`e.", '')
    $s = [regex]::Replace($s, "[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", '')
    $lines = ($s -replace "`r`n", "`n") -split "`n"
    $out = foreach ($l in $lines) { $r = $l.LastIndexOf("`r"); if ($r -ge 0) { $l = $l.Substring($r + 1) }; $l.TrimEnd() }
    return ($out -join "`n")
}

function Read-GrokAssistantMessages([string]$TranscriptPath) {
    $messages = @()
    foreach ($line in [IO.File]::ReadLines($TranscriptPath)) {
        try { $o = $line | ConvertFrom-Json -AsHashtable } catch { continue }
        $u = $o.params.update
        if ($u -and $u.sessionUpdate -eq 'agent_message_chunk' -and $u.content.type -eq 'text' -and $u.content.text) { $messages += [string]$u.content.text }
    }
    return $messages
}

function Read-Lane {
    <#
    .SYNOPSIS  Read a lane's transcript: the last N screen lines (VT stripped), a byte range, or raw bytes.
    .EXAMPLE   Read-Lane api -Tail 50
    .EXAMPLE   Read-Lane api -From 120000 -To 130000
    .EXAMPLE   Read-Lane api -Messages 3        # claude/grok: last assistant messages from the session transcript
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Name, [int]$Tail = 40, [long]$From = -1, [long]$To = -1, [switch]$Raw, [int]$Messages = 0, [long]$Bytes = 262144, [switch]$Events)
    $dir = Get-LaneDir $Name
    $log = Join-Path $dir 'console.log'
    $st = Get-LaneState $Name
    if ($Messages -gt 0) {
        $tp = if ($st) { $st.transcript } else { '' }
        if (-not $tp -or -not (Test-Path -LiteralPath $tp)) { throw "lane '$Name' has no known structured transcript" }
        if ($st.kind -eq 'grok') { return @(Read-GrokAssistantMessages $tp | Select-Object -Last $Messages) }
        $msgs = @()
        foreach ($line in [IO.File]::ReadAllLines($tp)) {
            if ($line -notmatch '"type":"assistant"') { continue }
            try { $o = $line | ConvertFrom-Json -AsHashtable } catch { continue }
            $txt = @(); foreach ($c in @($o.message.content)) { if ($c -is [hashtable] -and $c.type -eq 'text') { $txt += $c.text } }
            if ($txt.Count) { $msgs += ($txt -join "`n") }
        }
        return ($msgs | Select-Object -Last $Messages)
    }
    if ($Events) {
        $hp = Join-Path $dir 'hooks.jsonl'
        if (Test-Path -LiteralPath $hp) { return (Get-Content -LiteralPath $hp -Tail $Tail) } else { return @() }
    }
    # Grok's TUI repaints a dense inline screen. Its authenticated session transcript is the honest,
    # structured read surface; --raw and byte ranges still expose the exact PTY record when requested.
    if ($st -and $st.kind -eq 'grok' -and -not $Raw -and $From -lt 0 -and $st.transcript -and (Test-Path -LiteralPath $st.transcript)) {
        return @(Read-GrokAssistantMessages $st.transcript | Select-Object -Last $Tail)
    }
    if (-not (Test-Path -LiteralPath $log)) { throw "no transcript at $log" }
    $fs = [IO.FileStream]::new($log, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        $len = $fs.Length
        if ($From -ge 0) { $start = [math]::Min($From, $len); $end = if ($To -ge 0) { [math]::Min($To, $len) } else { $len } }
        else { $end = $len; $start = [math]::Max(0, $len - $Bytes) }
        $n = [int]($end - $start); $buf = [byte[]]::new($n); $fs.Seek($start, 'Begin') | Out-Null
        $got = 0; while ($got -lt $n) { $r = $fs.Read($buf, $got, $n - $got); if ($r -le 0) { break }; $got += $r }
    } finally { $fs.Dispose() }
    if ($Raw) { return [System.Text.Encoding]::UTF8.GetString($buf, 0, $got) }
    $text = ConvertFrom-Vt ([System.Text.Encoding]::UTF8.GetString($buf, 0, $got))
    $lines = $text -split "`n"
    if ($From -ge 0) { return ($lines -join "`n") }
    # last $Tail non-empty lines, collapsing immediate repeats (ink redraws)
    $res = New-Object System.Collections.Generic.List[string]; $prev = $null
    for ($i = $lines.Count - 1; $i -ge 0 -and $res.Count -lt $Tail; $i--) {
        $l = $lines[$i].Trim(); if (-not $l) { continue }; if ($l -eq $prev) { continue }; $prev = $l; $res.Insert(0, $lines[$i])
    }
    return ($res -join "`n")
}

# ---------------------------------------------------------------------------------------------------
# send / kill / restart
# ---------------------------------------------------------------------------------------------------
$script:Keys = @{
    enter = "`r"; esc = "`e"; tab = "`t"; 'shift-tab' = "`e[Z"; up = "`e[A"; down = "`e[B"; right = "`e[C"; left = "`e[D"
    'ctrl-c' = [string][char]3; 'ctrl-d' = [string][char]4; 'ctrl-z' = [string][char]26; 'ctrl-l' = [string][char]12; 'ctrl-u' = [string][char]21
    space = ' '; backspace = [string][char]127; home = "`e[H"; end = "`e[F"; pgup = "`e[5~"; pgdn = "`e[6~"; y = 'y'; n = 'n'
}

function Send-Lane {
    <#
    .SYNOPSIS  Type into a lane. Default: the text as one message followed by Enter (atomic, bracketed when the CLI wants it).
    .EXAMPLE   Send-Lane api "Yes, continue with the second option."
    .EXAMPLE   Send-Lane api -Key enter          # answer a highlighted choice
    .EXAMPLE   Send-Lane api -Key down,down,enter
    .EXAMPLE   Send-Lane api -Raw "2"            # bare keystrokes, no Enter
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Name, [Parameter(Position = 1, ValueFromRemainingArguments)][string[]]$Text, [string[]]$Key, [switch]$Raw, [switch]$NoEnter, [switch]$Force, [string]$File = '')
    $st = Get-LaneState $Name
    if ($null -eq $st) { throw "no lane '$Name'" }
    if (-not $st.alive) { throw "lane '$Name' is not alive (state $($st.state) $($st.why))" }
    Assert-LaneDriveable $Name $st -Force:$Force
    if ($Key) {
        $seq = ($Key | ForEach-Object { $k = $_.ToLowerInvariant(); if ($script:Keys.ContainsKey($k)) { $script:Keys[$k] } else { throw "unknown key '$_' (known: $($script:Keys.Keys -join ', '))" } }) -join ''
        Send-LaneFrame -Name $Name -Type 'I' -Payload $script:Utf8.GetBytes($seq)
        return
    }
    $msg = if ($File) { [IO.File]::ReadAllText($File) } else { ($Text -join ' ') }
    if ($Raw) { Send-LaneFrame -Name $Name -Type 'I' -Payload $script:Utf8.GetBytes($msg); return }
    $msg = $msg -replace "`r`n", "`n"
    if (-not $NoEnter) { $msg += "`r" }
    Send-LaneFrame -Name $Name -Type 'P' -Payload $script:Utf8.GetBytes($msg)
}

function Stop-Lane {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Name, [switch]$Hard, [switch]$Force, [int]$WaitSeconds = 20)
    $st = Get-LaneState $Name
    if ($null -eq $st) { throw "no lane '$Name'" }
    if (-not $st.alive) { return $st }
    Assert-LaneDriveable $Name $st -Force:$Force
    try { Send-LaneFrame -Name $Name -Type 'K' -Payload $script:Utf8.GetBytes($(if ($Hard) { 'hard' } else { 'soft' })) }
    catch { Stop-Process -Id $st.hostPid -Force -ErrorAction SilentlyContinue }   # the host owns the PTY; killing it ends the tree
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) { $st = Get-LaneState $Name; if (-not $st.alive) { break }; Start-Sleep -Milliseconds 200 }
    if ($st.alive) { Stop-Process -Id $st.hostPid -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 300; $st = Get-LaneState $Name }
    return $st
}

function Restart-Lane {
    <#
    .SYNOPSIS  Relaunch a lane with its transcript as context: claude/codex/grok resume their session, same cwd/model/head.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Name, [string]$Prompt = '', [switch]$Force, [switch]$Fresh)
    $pausedPath = Join-Path $script:LanesHome 'paused-lanes.txt'
    if (-not $Force -and (Test-Path -LiteralPath $pausedPath)) {
        $paused = @(Get-Content -LiteralPath $pausedPath | ForEach-Object {
            ($_ -split '#', 2)[0].Trim()
        } | Where-Object { $_ })
        if ($paused -contains $Name) {
            throw "lane '$Name' is intentionally parked in $pausedPath; remove it there or use -Force to restart"
        }
    }
    $dir = Get-LaneDir $Name
    $launch = Read-JsonFile (Join-Path $dir 'launch.json')
    if ($null -eq $launch) { throw "lane '$Name' has no launch record" }
    $st = Get-LaneState $Name
    if ($st -and $st.alive) { $null = Stop-Lane $Name -Force:$Force }
    $sid = if ($st -and $st.sessionId) { $st.sessionId } else { $launch.sessionId }
    $resume = if ($Fresh) { '' } else { $sid }
    $p = $Prompt
    if (-not $p) {
        $p = if ($launch.kind -eq 'claude' -and $resume) { 'You were restarted after an interruption; your previous context is above. Continue exactly where you left off.' }
             elseif ($launch.kind -eq 'codex' -and $resume) { 'You were restarted after an interruption; continue exactly where you left off.' }
             elseif ($launch.kind -eq 'grok' -and $resume) { 'You were restarted after an interruption; continue exactly where you left off.' }
             else { $launch.prompt }
    }
    $recordedEffort = Get-LaneRestartEffort -Launch $launch
    $args = @{ Name = $Name; Kind = $launch.kind; Model = $launch.model; Effort = $recordedEffort; Cwd = $launch.cwd; Head = $launch.head; Brief = $launch.brief; Prompt = $p
        Cols = $launch.cols; Rows = $launch.rows; StallMinutes = $launch.stallMinutes; ResumeSession = $resume
        RestartOf = $(if ($launch.restartOf) { $launch.restartOf } else { $Name }); RestartCount = ([int]$launch.restartCount + 1); KeepLog = $true; Force = $Force }
    if ($launch.kind -eq 'other') { $args.Command = $launch.cmd; $args.Prompt = '' }
    if ($launch.isHead) { $args.IsHead = $true }
    if ($launch.visible) { $args.Visible = $true } else { $args.Hidden = $true }
    # A codex lane learns its thread id from the first turn-ended notify. If it died before that, there is
    # nothing to resume: relaunch it on its original prompt, and say so in the event label via the prompt.
    if ($launch.kind -eq 'codex' -and -not $resume -and -not $Fresh -and -not $Prompt) {
        $args.Prompt = $launch.prompt
    }
    return (Start-Lane @args)
}

# ---------------------------------------------------------------------------------------------------
# events: the per-head queue. Labels only; the full log is an explicit reach.
# ---------------------------------------------------------------------------------------------------
function Get-LaneEvent {
    <#
    .SYNOPSIS  Read the current head's event queue. -Drain marks what you have now seen; without it the same rows come back.
    .EXAMPLE   lane events --drain
    .EXAMPLE   Get-LaneEvent -Peek -Max 20
    #>
    [CmdletBinding()]
    param([switch]$Drain, [switch]$Peek, [int]$Max = 200, [string]$Head = '', [switch]$AsObject, [int]$LabelChars = 240, [switch]$All, [string]$As = '')
    if (-not $Head) { $Head = Get-CurrentHead }
    $qf = Join-Path $script:HeadsRoot $Head 'events.jsonl'
    if (-not $As) { $As = Get-CurrentConsumer }
    $cf = Get-CursorPath $Head $As
    if (-not (Test-Path -LiteralPath $qf)) { if ($AsObject) { return @() } else { return "(no events for head '$Head'; consumer '$As')" } }
    # repair host-lost lanes first, so the queue is truthful
    $null = Get-Lane -Head $Head
    $cursor = 0
    if (-not $All) {
        if (Test-Path -LiteralPath $cf) { $cursor = [long](Get-Content -LiteralPath $cf -Raw).Trim() }
        elseif ($As -ne 'user' -and $As -ne $Head) {
            # a consumer that has never drained starts now: history before it existed is not owed to it (--all reads it)
            $cursor = (Get-Item -LiteralPath $qf).Length
            New-Item -ItemType Directory -Force (Split-Path $cf) | Out-Null; Set-Content -LiteralPath $cf -Value ([string]$cursor) -NoNewline
        }
    }
    $fs = [IO.FileStream]::new($qf, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $len = $fs.Length
        if ($cursor -gt $len) { $cursor = 0 }   # the queue was truncated/rotated; start over
        $fs.Seek($cursor, 'Begin') | Out-Null
        $buf = [byte[]]::new($len - $cursor); $got = 0
        while ($got -lt $buf.Length) { $r = $fs.Read($buf, $got, $buf.Length - $got); if ($r -le 0) { break }; $got += $r }
    } finally { $fs.Dispose() }
    $text = $script:Utf8.GetString($buf, 0, $got)
    $lastNl = $text.LastIndexOf("`n")
    if ($lastNl -lt 0) { if ($AsObject) { return @() } else { return "(no new events for head '$Head'; consumer '$As', cursor $cursor of $len bytes)" } }
    $complete = $text.Substring(0, $lastNl + 1)
    $rows = @(); $consumed = 0; $count = 0
    $split = $complete -split "`n"
    for ($k = 0; $k -lt $split.Count - 1; $k++) {      # the last element is the empty tail after the final newline
        if ($count -ge $Max) { break }
        $line = $split[$k]
        $consumed += $script:Utf8.GetByteCount($line) + 1
        $l = $line.Trim(); if (-not $l) { continue }
        try { $rows += ($l | ConvertFrom-Json -AsHashtable); $count++ } catch { }
    }
    $out = @()
    $i = 0
    foreach ($r in $rows) {
        $i++
        $lbl = [string]$r.label; if ($lbl.Length -gt $LabelChars) { $lbl = $lbl.Substring(0, $LabelChars - 1) + '…' }
        $stateU = ([string]$r.state).ToUpperInvariant()
        $ts = try { (ConvertTo-Utc $r.ts).ToLocalTime().ToString('HH:mm:ss') } catch { "$($r.ts)" }
        $exitS = if ($null -ne $r.exit) { " exit=$($r.exit)" } else { '' }
        $line = "[$ts] $($r.lane)  $stateU($($r.why))$exitS  $lbl  (log $($r.from)..$($r.to))"
        if ($AsObject) { $r['text'] = $line; $out += $r } else { $out += $line }
    }
    if ($Drain -and -not $Peek) {
        # Only now, after the labels exist for the caller, is the cursor advanced: nothing is "seen" before it is shown.
        New-Item -ItemType Directory -Force (Split-Path $cf) | Out-Null
        Set-Content -LiteralPath $cf -Value ([string]($cursor + $consumed)) -NoNewline
    }
    return $out
}

function Wait-LaneEvent {
    <#
    .SYNOPSIS  Block until the head's queue has at least one unseen event (or the timeout). Event-driven, no busy loop.
    #>
    [CmdletBinding()]
    param([int]$TimeoutSec = 600, [string]$Head = '', [switch]$Drain, [string]$As = '')
    if (-not $Head) { $Head = Get-CurrentHead }
    $qf = Join-Path $script:HeadsRoot $Head 'events.jsonl'
    if (-not $As) { $As = Get-CurrentConsumer }
    $cf = Get-CursorPath $Head $As
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $len = if (Test-Path -LiteralPath $qf) { (Get-Item -LiteralPath $qf).Length } else { 0 }
        $cur = if (Test-Path -LiteralPath $cf) { [long](Get-Content -LiteralPath $cf -Raw).Trim() } else { 0 }
        if ($len -gt $cur) { return (Get-LaneEvent -Head $Head -Drain:$Drain -As $As) }
        # also catch host-lost lanes (they emit through Get-Lane)
        $null = Get-Lane -Head $Head
        Start-Sleep -Seconds 1
    }
    return @()
}

# ---------------------------------------------------------------------------------------------------
# tabs / viewer
# ---------------------------------------------------------------------------------------------------
function Open-LaneTab {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Name, [switch]$NewWindow, [switch]$SplitPane)
    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    if (-not $wt) { throw 'wt.exe (Windows Terminal) not found on PATH' }
    $window = if ($NewWindow) { 'new' } else { '0' }
    $verb = if ($SplitPane) { 'split-pane' } else { 'new-tab' }
    # call operator, not Start-Process: Start-Process joins an ArgumentList without quoting and wt.exe then sees
    # "lane" and "<name>" as two arguments, which is how T8 first failed
    & $wt.Source -w $window $verb --title "lane $Name" --suppressApplicationTitle -- $script:Exe attach $Name | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "wt.exe returned $LASTEXITCODE" }
}

function Start-LaneViewer {
    [CmdletBinding()]
    param([int]$Port = 7342, [switch]$Open, [switch]$Foreground)
    $www = Join-Path $script:ModuleDir 'viewer'
    $args = @('serve', '--root', $script:Root, '--heads', $script:HeadsRoot, '--www', $www, '--port', $Port)
    if ($Foreground) { & $script:Exe @args; return }
    $p = Start-Process -FilePath $script:Exe -ArgumentList (($args | ForEach-Object { ConvertTo-ArgString ([string]$_) }) -join ' ') -WindowStyle Hidden -PassThru
    Set-Content -LiteralPath (Join-Path $script:Root '_viewer.pid') -Value $p.Id
    if ($Open) { Start-Process "http://127.0.0.1:$Port/" }
    return [pscustomobject]@{ pid = $p.Id; url = "http://127.0.0.1:$Port/" }
}

Set-Alias -Name lane-launch -Value Start-Lane
Export-ModuleMember -Function Get-LanesHome, Test-LanesStrictPrivacy, ConvertTo-Utc, Get-CurrentConsumer, Get-CursorPath, Resolve-CursorAgent, Assert-CursorModelIsZeroRetention, Start-Lane, Get-Lane, Read-Lane, Send-Lane, Stop-Lane, Restart-Lane, Get-LaneEvent, Wait-LaneEvent, Open-LaneTab, Start-LaneViewer, Register-LaneHead, Get-LaneHead, Format-LaneTable, Get-LaneState, Get-CurrentHead, ConvertFrom-Vt, Send-LaneFrame, Get-LanesRoot, Get-LaneHeadsRoot, ConvertTo-ArgString, Append-Line, Read-JsonFile, Test-HostAlive, Assert-GrokDataSharingOptOut, Install-GrokLaneHooks, Get-CodexEffortArguments, Read-LaneEffortFromLog, Wait-LaneEffortReadback, Format-LaneEffortReadback, Get-LaneEffortReadbackTimeout, Get-LaneRestartEffort
