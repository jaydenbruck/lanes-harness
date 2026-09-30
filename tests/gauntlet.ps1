# gauntlet.ps1 — the Lanes Harness survival tests plus real-CLI witnesses.
# Run: pwsh -NoProfile -File tests\gauntlet.ps1 [-SkipReal] [-SkipGrok] [-Only 1,4] [-Evidence C:\path\evidence.md]
# -SkipReal skips the tests that start real claude / grok sessions (they cost a few cents of API usage).
# Runs against a throwaway LANES_HOME under %TEMP% unless LANES_HOME is already set.
# Every test prints PASS/FAIL with the numbers it measured; the evidence file keeps them.
[CmdletBinding()]
param([switch]$SkipReal, [switch]$SkipGrok, [string]$Only = '', [string]$Evidence = '', [string]$RealModel = 'haiku', [string]$GrokModel = 'grok-4.5', [string]$GrokEffort = 'low', [int]$FloodMB = 100)
# -Only takes a comma list ("2,4,6"): pwsh -File hands a comma list over as ONE string, so parse it here.
$OnlyList = @(); if ($Only) { $OnlyList = @($Only -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ }) }
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Scratch = Join-Path ([IO.Path]::GetTempPath()) 'lanes-gauntlet'; New-Item -ItemType Directory -Force $Scratch, (Join-Path $Scratch 't1') | Out-Null
if (-not $env:LANES_HOME) { $env:LANES_HOME = Join-Path $Scratch 'home' }
Import-Module (Join-Path $here '..\Lanes.psm1') -Force -DisableNameChecking
$env:LANES_HEAD = 'gauntlet'
$Root = Get-LanesRoot; $Heads = Get-LaneHeadsRoot; $Exe = Join-Path $here '..\bin\LaneHost.exe' | Resolve-Path | ForEach-Object Path
$EvidenceFile = $Evidence
if (-not $EvidenceFile) { $EvidenceFile = Join-Path $Scratch ("gauntlet-" + (Get-Date).ToString('yyyyMMdd-HHmmss') + ".md") }
$results = New-Object System.Collections.Generic.List[object]
$Q = Join-Path $Heads 'gauntlet\events.jsonl'

function Log([string]$s) { Write-Host $s; Add-Content -LiteralPath $EvidenceFile -Value $s }
function Result([int]$n, [string]$name, [bool]$pass, [string]$evidence) {
    $results.Add([pscustomobject]@{ n = $n; test = $name; pass = $pass; evidence = $evidence })
    Log ("{0} T{1} {2} — {3}" -f ($(if ($pass) { 'PASS' } else { 'FAIL' }), $n, $name, $evidence))
}
function Cleanup([string[]]$names) {
    foreach ($n in $names) {
        try { $st = Get-LaneState $n; if ($st -and $st.alive) { Stop-Lane $n -Hard -Force | Out-Null } } catch { }
        $d = Join-Path $Root $n; if (Test-Path $d) { for ($i = 0; $i -lt 5; $i++) { try { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 300 } } }
    }
}
function QueueRows([string]$lane = '') {
    if (-not (Test-Path $Q)) { return @() }
    $rows = Get-Content -LiteralPath $Q | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable }
    if ($lane) { $rows = $rows | Where-Object { $_.lane -eq $lane } }
    return @($rows)
}
function WaitState([string]$name, [string[]]$states, [int]$sec = 30) {
    $dl = (Get-Date).AddSeconds($sec)
    while ((Get-Date) -lt $dl) { $st = Get-LaneState $name; if ($st -and $st.state -in $states) { return $st }; Start-Sleep -Milliseconds 250 }
    return (Get-LaneState $name)
}
function WaitEvent([string]$name, [string]$state, [int]$sec = 30, [string]$why = '') {
    $dl = (Get-Date).AddSeconds($sec)
    while ((Get-Date) -lt $dl) {
        $r = QueueRows $name | Where-Object { $_.state -eq $state -and (-not $why -or $_.why -eq $why) } | Select-Object -Last 1
        if ($r) { return $r }; Start-Sleep -Milliseconds 250
    }
    return $null
}
function Mem([int]$hostPid) { try { $p = Get-Process -Id $hostPid; return [pscustomobject]@{ ws = [math]::Round($p.WorkingSet64 / 1MB, 1); priv = [math]::Round($p.PrivateMemorySize64 / 1MB, 1); cpu = [math]::Round($p.TotalProcessorTime.TotalSeconds, 2) } } catch { return $null } }
function ReadShared([string]$path) {
    $fs = [IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try { $ms = [IO.MemoryStream]::new(); $fs.CopyTo($ms); return $ms.ToArray() } finally { $fs.Dispose() }
}
function HashShared([string]$path) { $sha = [Security.Cryptography.SHA256]::Create(); try { return [BitConverter]::ToString($sha.ComputeHash((ReadShared $path))).Replace('-', '') } finally { $sha.Dispose() } }
# A fresh folder shows the CLI's trust dialog. Pick the 'trust' option whichever row is highlighted.
function AcceptTrust([string]$name) { if ((Read-Lane $name -Tail 12) -match '❯\s*No, exit') { Send-Lane $name -Key down,enter } else { Send-Lane $name -Key enter } }
function Run([int]$n) { return ($OnlyList.Count -eq 0 -or $OnlyList -contains $n) }

Log "# Lanes Harness gauntlet — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') — pwsh $($PSVersionTable.PSVersion) — $env:COMPUTERNAME"
Log "exe $Exe  root $Root  heads $Heads  queue $Q"
# start from a clean gauntlet queue and no leftover g- lanes
if (Test-Path $Q) { Remove-Item $Q -Force }; Remove-Item (Join-Path $Heads 'gauntlet\events.cursor') -Force -ErrorAction SilentlyContinue
Cleanup @(Get-ChildItem $Root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'g-*' } | ForEach-Object Name)

# ---------------------------------------------------------------------------------------------------
# T1 · 100 MB flood — nothing lost, supervisor memory flat
# ---------------------------------------------------------------------------------------------------
if (Run 1) {
    $flood = Join-Path $Scratch "flood-$FloodMB.txt"
    $lines = $FloodMB * 10000   # 100-byte lines
    if (-not (Test-Path $flood) -or (Get-Item $flood).Length -lt ($lines * 100)) {
        Log "T1: generating $flood ($lines lines of 100 bytes)"
        $fs = [IO.File]::Create($flood); $sw = [IO.StreamWriter]::new($fs, [Text.UTF8Encoding]::new($false), 1MB)
        $pad = 'x' * 89   # 'L' + 8 digits + ' ' + 89 x + LF = 100 bytes per line
        for ($i = 1; $i -le $lines; $i++) { $sw.Write('L'); $sw.Write($i.ToString('D8')); $sw.Write(' '); $sw.Write($pad); $sw.Write("`n") }
        $sw.Dispose()
    }
    $name = 'g-flood'
    $st = Start-Lane -Name $name -Kind other -Command ('cmd.exe /c type ' + $flood) -Cwd $Scratch -Hidden
    $m0 = Mem $st.hostPid; $peak = 0.0; $t0 = Get-Date
    while ($true) {
        $m = Mem $st.hostPid; if ($m) { if ($m.priv -gt $peak) { $peak = $m.priv } }
        $st = Get-LaneState $name
        if (-not $st.alive -or $st.state -in @('finished', 'died')) { break }
        if (((Get-Date) - $t0).TotalSeconds -gt 900) { break }
        Start-Sleep -Milliseconds 500
    }
    $secs = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    $log = Join-Path $Root $name 'console.log'
    $logLen = (Get-Item $log).Length
    # count the numbered lines present in the raw log (no VT stripping needed: the 9-char marker is never split by wrapping at 160 cols)
    $rx = [regex]::new('L(\d{8})', 'Compiled')   # no trailing space: a ConPTY frame boundary may split the line with a cursor sequence
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    $fsr = [IO.FileStream]::new($log, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete); $sr = [IO.StreamReader]::new($fsr, [Text.UTF8Encoding]::new($false), $false, 1MB)
    $carry = ''; $buf = [char[]]::new(1MB)
    while (($r = $sr.Read($buf, 0, $buf.Length)) -gt 0) {
        $chunk = $carry + [string]::new($buf, 0, $r)
        foreach ($mm in $rx.Matches($chunk)) { [void]$seen.Add([int]$mm.Groups[1].Value) }
        $carry = if ($chunk.Length -gt 16) { $chunk.Substring($chunk.Length - 16) } else { $chunk }
    }
    $sr.Dispose()
    $missing = $lines - $seen.Count
    $pass = ($missing -eq 0) -and ($peak -lt 64) -and (($peak - $m0.priv) -lt 16) -and ($st.state -eq 'finished')
    Result 1 "100 MB flood" $pass "lines expected $lines, distinct seen $($seen.Count), missing $missing; log $([math]::Round($logLen/1MB,1)) MB in $secs s ($([math]::Round($logLen/1MB/$secs,1)) MB/s); host private bytes start $($m0.priv) MB, peak $peak MB; final state $($st.state)/$($st.why)"
    Cleanup @($name)
}

# ---------------------------------------------------------------------------------------------------
# T2 · yes/no question — NEEDS-INPUT within seconds, head answers, session continues
# ---------------------------------------------------------------------------------------------------
if (Run 2) {
    $name = 'g-yesno'
    $cmd = 'pwsh -NoLogo -NoProfile -Command "$a = Read-Host ''Delete the old builds? (y/n)''; Write-Host (''answer='' + $a); exit 0"'
    $t0 = Get-Date
    $st = Start-Lane -Name $name -Kind other -Command $cmd -Cwd $Scratch -Hidden
    $ev = WaitEvent $name 'needs-input' 20
    $detect = if ($ev) { [math]::Round(((ConvertTo-Utc $ev.ts) - $t0.ToUniversalTime()).TotalSeconds, 1) } else { -1 }
    Send-Lane $name 'y'
    $fin = WaitEvent $name 'finished' 20
    $tail = Read-Lane $name -Tail 6
    $pass = ($null -ne $ev) -and ($detect -le 10) -and ($null -ne $fin) -and ($tail -match 'answer=y')
    Result 2 "yes/no question (generic CLI)" $pass "needs-input after $detect s, label '$($ev.label)'; answered 'y'; finished=$($null -ne $fin); tail has answer=y: $($tail -match 'answer=y')"
    Cleanup @($name)
    if (-not $SkipReal) {
        $name = 'g-ask'
        $t0 = Get-Date
        $st = Start-Lane -Name $name -Kind claude -Model $RealModel -Cwd (Join-Path $Scratch 't1') -Hidden -Prompt "Use the AskUserQuestion tool to ask me one question: 'Which plan?' with options 'Plan A' and 'Plan B'. After I answer, reply with exactly: you chose <my answer>."
        $trust = WaitEvent $name 'needs-input' 25 'prompt'
        if ($trust -and $trust.label -match 'trust') { AcceptTrust $name }
        $ev = WaitEvent $name 'needs-input' 90 'question'
        $detect = if ($ev) { [math]::Round(((ConvertTo-Utc $ev.ts) - $t0.ToUniversalTime()).TotalSeconds, 1) } else { -1 }
        if ($ev) { Send-Lane $name -Key down; Start-Sleep -Milliseconds 400; Send-Lane $name -Key enter }
        $done = $null; $dl = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $dl) { $done = QueueRows $name | Where-Object { $_.state -eq 'needs-input' -and $_.why -eq 'turn-complete' -and $_.label -match 'Plan B' } | Select-Object -Last 1; if ($done) { break }; Start-Sleep -Milliseconds 500 }
        $pass = ($null -ne $ev) -and ($ev.label -match 'Which plan') -and ($null -ne $done)
        Result 2 "AskUserQuestion on real claude ($RealModel)" $pass "question event after $detect s: '$($ev.label)'; answered down+enter; lane replied '$($done.label)'"
        Stop-Lane $name -Force | Out-Null; Cleanup @($name)
    }
}

# ---------------------------------------------------------------------------------------------------
# T3 · dies mid-turn — DIED fires, restart resumes with context
# ---------------------------------------------------------------------------------------------------
if (Run 3 -and -not $SkipReal) {
    $name = 'g-die'
    $st = Start-Lane -Name $name -Kind claude -Model $RealModel -Cwd (Join-Path $Scratch 't1') -Hidden -Prompt "We are setting up a small project. Its codename is MANGO-88; I will refer to it by that name later. Reply with exactly: noted."
    $trust = WaitEvent $name 'needs-input' 25 'prompt'; if ($trust -and $trust.label -match 'trust') { AcceptTrust $name }
    $first = WaitEvent $name 'needs-input' 90 'turn-complete'
    Send-Lane $name "Run the shell command 'ping -n 20 127.0.0.1' and then reply with exactly: ping done."
    Start-Sleep 7
    $st = Get-LaneState $name; $pidBefore = $st.pid; $sidBefore = $st.sessionId
    Stop-Process -Id $st.pid -Force      # the crash
    $died = WaitEvent $name 'died' 20
    $st2 = Restart-Lane $name
    $resumed = $null; $dl = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $dl) { $resumed = QueueRows $name | Where-Object { $_.state -eq 'needs-input' -and $_.why -eq 'turn-complete' -and (ConvertTo-Utc $_.ts) -gt (ConvertTo-Utc $died.ts) } | Select-Object -Last 1; if ($resumed) { break }; Start-Sleep -Milliseconds 500 }
    Send-Lane $name "Quick check before we continue: what is the codename of the project I mentioned at the start? Reply with the codename only."
    $answer = $null; $dl = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $dl) { $answer = QueueRows $name | Where-Object { $_.state -eq 'needs-input' -and $_.why -eq 'turn-complete' -and $_.label -match 'MANGO-88' } | Select-Object -Last 1; if ($answer) { break }; Start-Sleep -Milliseconds 500 }
    $logHasBoth = (Select-String -LiteralPath (Join-Path $Root $name 'console.log') -Pattern 'LANE g-die START' -AllMatches).Matches.Count
    $pass = ($null -ne $died) -and ($died.exit -ne 0) -and ($st2.sessionId -eq $sidBefore) -and ($st2.pid -ne $pidBefore) -and ($null -ne $answer) -and ($logHasBoth -ge 2)
    Result 3 "dies mid-turn, restart resumes with context ($RealModel)" $pass "DIED event: $($null -ne $died) (exit $($died.exit), why $($died.why)); restart pid $pidBefore -> $($st2.pid), resume session $($st2.sessionId -eq $sidBefore); recalled code word: $($null -ne $answer) ('$($answer.label)'); generations in one transcript: $logHasBoth"
    Stop-Lane $name -Force | Out-Null; Cleanup @($name)
}

# ---------------------------------------------------------------------------------------------------
# T4 · ten sessions finishing in the same second — ten rows, in order, labels only
# ---------------------------------------------------------------------------------------------------
if (Run 4) {
    $names = 1..10 | ForEach-Object { "g-ten-$_" }
    $T = (Get-Date).AddSeconds(25).ToString('yyyy-MM-ddTHH:mm:ss.fff')
    foreach ($n in $names) {
        $cmd = "pwsh -NoLogo -NoProfile -Command `"while ((Get-Date) -lt [datetime]'$T') { Start-Sleep -Milliseconds 20 }; Write-Host ('finished-' + '$n')`""
        Start-Lane -Name $n -Kind other -Command $cmd -Cwd $Scratch -Hidden | Out-Null
    }
    $cursorBefore = 0
    $cf = Join-Path $Heads 'gauntlet\events.cursor'; if (Test-Path $cf) { $cursorBefore = [long](Get-Content $cf -Raw).Trim() }
    # drain everything pending so the next drain is exactly this test's rows
    Get-LaneEvent -Drain | Out-Null
    $dl = (Get-Date).AddSeconds(60); $fin = @()
    while ((Get-Date) -lt $dl) { $fin = @(QueueRows | Where-Object { $_.state -eq 'finished' -and $_.lane -like 'g-ten-*' }); if ($fin.Count -ge 10) { break }; Start-Sleep -Milliseconds 250 }
    $ts = $fin | ForEach-Object { ConvertTo-Utc $_.ts }
    $spread = if ($ts.Count -ge 2) { [math]::Round((($ts | Measure-Object -Maximum).Maximum - ($ts | Measure-Object -Minimum).Minimum).TotalMilliseconds) } else { -1 }
    $ordered = $true; for ($i = 1; $i -lt $ts.Count; $i++) { if ($ts[$i] -lt $ts[$i - 1]) { $ordered = $false } }
    $drained = @(Get-LaneEvent -Drain)
    $drainChars = ($drained | Measure-Object -Property Length -Sum).Sum
    $noVt = -not (($drained -join "`n") -match "`e")
    $distinct = ($fin | ForEach-Object lane | Sort-Object -Unique).Count
    $pass = ($fin.Count -eq 10) -and ($distinct -eq 10) -and ($spread -ge 0) -and ($spread -le 1000) -and $ordered -and ($drained.Count -eq 10) -and $noVt -and ($drainChars -lt 10 * 400)
    Result 4 "ten lanes finishing within the same second" $pass "finished rows $($fin.Count) (distinct lanes $distinct), spread $spread ms, file order = time order: $ordered; drain returned $($drained.Count) label lines, $drainChars chars total, no escape codes: $noVt"
    Cleanup $names
}

# ---------------------------------------------------------------------------------------------------
# T5 · supervisor killed and restarted — sessions reattached, registry never lies
# ---------------------------------------------------------------------------------------------------
if (Run 5) {
    $names = 1..3 | ForEach-Object { "g-sup-$_" }
    foreach ($n in $names) { Start-Lane -Name $n -Kind other -Command 'pwsh -NoLogo -NoProfile' -Cwd $Scratch -Hidden | Out-Null }
    $port = 7399
    $sv = Start-LaneViewer -Port $port
    Start-Sleep 2
    $before = Invoke-RestMethod "http://127.0.0.1:$port/api/lanes"
    $aliveBefore = @($before | Where-Object { $_.name -like 'g-sup-*' -and $_.alive }).Count
    # kill the supervisor (viewer/WS server) — the lanes must not notice
    Stop-Process -Id $sv.pid -Force; Start-Sleep 1
    $pidsAfterKill = $names | ForEach-Object { (Get-LaneState $_).pid }
    $stillAlive = @($names | ForEach-Object { Get-LaneState $_ } | Where-Object { $_.alive }).Count
    # restart it; reattach; drive a lane through the restarted supervisor
    $sv2 = Start-LaneViewer -Port $port; Start-Sleep 2
    $after = Invoke-RestMethod "http://127.0.0.1:$port/api/lanes"
    $aliveAfter = @($after | Where-Object { $_.name -like 'g-sup-*' -and $_.alive }).Count
    Invoke-RestMethod -Method Post "http://127.0.0.1:$port/api/send/g-sup-1" -Body ([Text.Encoding]::UTF8.GetBytes("'after-restart-ok'`r")) -ContentType 'application/octet-stream' | Out-Null
    Start-Sleep 2
    $tail = Read-Lane 'g-sup-1' -Tail 5
    # now kill a HOST (the thing that really owns a PTY): the registry must say died/host-lost, exactly one event
    $victim = Get-LaneState 'g-sup-3'; Stop-Process -Id $victim.hostPid -Force; Start-Sleep 1
    $v1 = Get-LaneState 'g-sup-3'; Start-Sleep 1; $v2 = Get-LaneState 'g-sup-3'
    $lostRows = @(QueueRows 'g-sup-3' | Where-Object { $_.state -eq 'died' -and $_.why -eq 'host-lost' }).Count
    $after2 = Invoke-RestMethod "http://127.0.0.1:$port/api/lanes"; $v3 = $after2 | Where-Object { $_.name -eq 'g-sup-3' }
    Stop-Process -Id $sv2.pid -Force
    $pass = ($aliveBefore -eq 3) -and ($stillAlive -eq 3) -and ($aliveAfter -eq 3) -and ($tail -match 'after-restart-ok') -and ($v1.state -eq 'died') -and ($v1.why -eq 'host-lost') -and ($lostRows -eq 1) -and ($v3.state -eq 'died') -and (-not $v3.alive)
    Result 5 "supervisor killed and restarted" $pass "alive via API before $aliveBefore; after killing the supervisor $stillAlive of 3 lanes alive (pids $($pidsAfterKill -join ',')); after restart API sees $aliveAfter alive, typed through it: $($tail -match 'after-restart-ok'); killed a host: registry says $($v1.state)/$($v1.why), host-lost events $lostRows (exactly one), API says $($v3.state) alive=$($v3.alive)"
    Cleanup $names
}

# ---------------------------------------------------------------------------------------------------
# T6 · the user types while the head is mid-send — both arrive, in order, nothing interleaves mid-line
# ---------------------------------------------------------------------------------------------------
if (Run 6) {
    $name = 'g-type'; $typer = 'g-typer'
    Start-Lane -Name $name -Kind other -Command ('"' + $Exe + '" echo') -Cwd $Scratch -Hidden | Out-Null
    Start-Sleep 1
    # the user's tab: an attach client in its own lane, fed one keystroke at a time
    Start-Lane -Name $typer -Kind other -Command ('"' + $Exe + '" attach ' + $name) -Cwd $Scratch -Hidden -Cols 160 -Rows 45 | Out-Null
    Start-Sleep 2
    $userText = 'USER-abcdefghijklmnopqrstuvwxyz-0123456789-END'
    $headLine = 'HEAD-' + ('h' * 400) + '-END'
    $job = Start-ThreadJob -ScriptBlock {
        param($mod, $typer, $text)
        Import-Module $mod -DisableNameChecking
        foreach ($ch in $text.ToCharArray()) { Send-Lane $typer -Raw ([string]$ch); Start-Sleep -Milliseconds 15 }
    } -ArgumentList (Join-Path $here '..\Lanes.psm1'), $typer, $userText
    Start-Sleep -Milliseconds 200
    for ($k = 0; $k -lt 5; $k++) { Send-Lane $name "$headLine$k"; Start-Sleep -Milliseconds 60 }
    $job | Wait-Job | Out-Null; Remove-Job $job; Start-Sleep 1
    $raw = Read-Lane $name -Raw -Bytes 1MB
    $headIntact = 0; for ($k = 0; $k -lt 5; $k++) { if ($raw.Contains("$headLine$k`r")) { $headIntact++ } }
    # every user char present, in order (the head's lines may sit between them, never inside a head line)
    $pos = -1; $inOrder = $true
    foreach ($ch in $userText.ToCharArray()) { $p = $raw.IndexOf($ch, $pos + 1); if ($p -lt 0) { $inOrder = $false; break }; $pos = $p }
    $rest = $raw; for ($k = 0; $k -lt 5; $k++) { $rest = $rest.Replace("$headLine$k" + [string][char]13, '') }
    $userContig = $rest.Contains($userText)   # with the head's lines removed, the user's keystrokes read back as one run
    $pass = ($headIntact -eq 5) -and $inOrder -and $userContig
    Result 6 "user types while the head sends" $pass "5 head lines of $($headLine.Length) chars arrived contiguous: $headIntact/5; all $($userText.Length) user keystrokes present in order: $inOrder; user text contiguous once the head lines are removed: $userContig"
    Cleanup @($typer, $name)
}

# ---------------------------------------------------------------------------------------------------
# T7 · lane name reused after a crash — no corruption, old transcript preserved
# ---------------------------------------------------------------------------------------------------
if (Run 7) {
    $name = 'g-reuse'
    Start-Lane -Name $name -Kind other -Command 'pwsh -NoLogo -NoProfile' -Cwd $Scratch -Hidden | Out-Null
    Start-Sleep 2; Send-Lane $name "'generation-one-marker'"; Start-Sleep 1
    $st1 = Get-LaneState $name; $log1 = Join-Path $Root $name 'console.log'
    $bytes1 = ReadShared $log1; $hash1 = HashShared $log1
    Stop-Process -Id $st1.hostPid -Force; Start-Sleep 1     # crash the host
    $crashed = Get-LaneState $name
    $st2 = Start-Lane -Name $name -Kind other -Command 'pwsh -NoLogo -NoProfile' -Cwd $Scratch -Hidden
    Start-Sleep 2; Send-Lane $name "'generation-two-marker'"; Start-Sleep 1
    $hist = Get-ChildItem (Join-Path $Root $name 'history') -Directory | Select-Object -First 1
    $oldLog = Join-Path $hist.FullName 'console.log'
    $hashOld = HashShared $oldLog
    $newRaw = Read-Lane $name -Raw
    $pass = ($crashed.state -eq 'died') -and ($hashOld -eq $hash1) -and ($newRaw -notmatch 'generation-one-marker') -and ($newRaw -match 'generation-two-marker') -and ($st2.alive) -and ($st2.hostPid -ne $st1.hostPid)
    Result 7 "lane name reused after a crash" $pass "after the crash the registry said $($crashed.state)/$($crashed.why); old transcript moved to history\$($hist.Name) byte-identical: $($hashOld -eq $hash1) ($($bytes1.Length) bytes); new transcript fresh (no old marker, has new marker): $(($newRaw -notmatch 'generation-one-marker') -and ($newRaw -match 'generation-two-marker')); new host pid $($st2.hostPid)"
    Cleanup @($name)
}

# ---------------------------------------------------------------------------------------------------
# T8 · PowerShell 7.6.3 and Windows Terminal as installed — no WSL, no admin; a real tab opens
# ---------------------------------------------------------------------------------------------------
if (Run 8) {
    $psv = $PSVersionTable.PSVersion
    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $name = 'g-tab'
    Start-Lane -Name $name -Kind other -Command 'pwsh -NoLogo -NoProfile' -Cwd $Scratch -Hidden | Out-Null
    Start-Sleep 1
    $v0 = (Get-LaneState $name).viewers
    Open-LaneTab -Name $name
    $dl = (Get-Date).AddSeconds(15); $v1 = 0
    while ((Get-Date) -lt $dl) { $v1 = (Get-LaneState $name).viewers; if ($v1 -gt $v0) { break }; Start-Sleep -Milliseconds 300 }
    $attachProc = @(Get-CimInstance Win32_Process -Filter "Name='LaneHost.exe'" | Where-Object { $_.CommandLine -match "attach $name" }).Count
    # closing the tab must not kill the lane: end the attach client, the lane stays
    Get-CimInstance Win32_Process -Filter "Name='LaneHost.exe'" | Where-Object { $_.CommandLine -match "attach $name" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Start-Sleep 1
    $still = (Get-LaneState $name).alive
    $pass = ($psv.Major -eq 7 -and $psv.Minor -eq 6) -and ($null -ne $wt) -and (-not $isAdmin) -and ($v1 -gt $v0) -and ($attachProc -ge 1) -and $still
    Result 8 "pwsh 7.6 + Windows Terminal as installed, no WSL, no admin" $pass "pwsh $psv; wt.exe $($wt.Source); elevated: $isAdmin; tab attached (viewers $v0 -> $v1, attach processes $attachProc); lane alive after the tab closed: $still"
    Cleanup @($name)
}

# ---------------------------------------------------------------------------------------------------
# T9 · a head drains 50 mixed events — labels only; any lane's full log still reachable
# ---------------------------------------------------------------------------------------------------
if (Run 9) {
    $names = 1..25 | ForEach-Object { "g-fifty-$_" }
    Get-LaneEvent -Drain | Out-Null
    foreach ($n in $names) {
        $cmd = 'pwsh -NoLogo -NoProfile -Command "$a = Read-Host ''Continue ' + $n + '? (y/n)''; 1..40 | ForEach-Object { Write-Host (''line '' + $_ + '' of ' + $n + ' '' + (''z'' * 120)) }; Write-Host ''bye ' + $n + '''"'
        Start-Lane -Name $n -Kind other -Command $cmd -Cwd $Scratch -Hidden | Out-Null
    }
    $dl = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $dl) { $ni = @(QueueRows | Where-Object { $_.state -eq 'needs-input' -and $_.lane -like 'g-fifty-*' } | ForEach-Object lane | Sort-Object -Unique).Count; if ($ni -ge 25) { break }; Start-Sleep -Milliseconds 300 }
    foreach ($n in $names) { Send-Lane $n 'y' }
    $dl = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $dl) { $fi = @(QueueRows | Where-Object { $_.state -eq 'finished' -and $_.lane -like 'g-fifty-*' }).Count; if ($fi -ge 25) { break }; Start-Sleep -Milliseconds 300 }
    $drained = @(Get-LaneEvent -Drain -Max 1000)
    $chars = ($drained | Measure-Object -Property Length -Sum).Sum
    $logBytes = ($names | ForEach-Object { (Get-Item (Join-Path $Root $_ 'console.log')).Length } | Measure-Object -Sum).Sum
    $noVt = -not (($drained -join "`n") -match "`e")
    $maxLine = ($drained | Measure-Object -Property Length -Maximum).Maximum
    $reach = Read-Lane 'g-fifty-13' -Tail 3
    $niLanes = @(QueueRows | Where-Object { $_.state -eq 'needs-input' -and $_.lane -like 'g-fifty-*' } | ForEach-Object lane | Sort-Object -Unique).Count
    $fiLanes = @(QueueRows | Where-Object { $_.state -eq 'finished' -and $_.lane -like 'g-fifty-*' } | ForEach-Object lane | Sort-Object -Unique).Count
    $pass = ($drained.Count -eq 50) -and ($niLanes -eq 25) -and ($fiLanes -eq 25) -and $noVt -and ($chars -lt 50 * 400) -and ($reach -match 'bye g-fifty-13')
    Result 9 "head drains 50 mixed events, labels only" $pass "drained $($drained.Count) rows ($niLanes lanes needs-input + $fiLanes lanes finished), $chars chars total (max line $maxLine) against $([math]::Round($logBytes/1KB)) KB of transcripts; no escape codes: $noVt; explicit reach into lane 13's log worked: $($reach -match 'bye g-fifty-13')"
    Cleanup $names
}

# ---------------------------------------------------------------------------------------------------
# S · the fifth state: STALLED (no output for N) then FINISHED
# ---------------------------------------------------------------------------------------------------
if (Run 10) {
    $name = 'g-stall'
    Start-Lane -Name $name -Kind other -Command 'cmd.exe /c "ping -n 20 127.0.0.1 > nul & echo awake"' -Cwd $Scratch -Hidden -StallSeconds 8 | Out-Null
    $stalled = WaitEvent $name 'stalled' 30
    $fin = WaitEvent $name 'finished' 40
    $inOrder10 = ($null -ne $stalled) -and ($null -ne $fin) -and ((ConvertTo-Utc $stalled.ts) -lt (ConvertTo-Utc $fin.ts))
    $awake = ((Read-Lane $name -Tail 5) -match 'awake')
    $pass = ($null -ne $stalled) -and ($stalled.why -eq 'no-output-8s') -and ($null -ne $fin) -and $inOrder10 -and $awake
    Result 10 "STALLED fires on silence, FINISHED after" $pass "stalled event: $($null -ne $stalled) ($($stalled.why)); finished after it: $inOrder10; 'awake' printed after the stall: $awake"
    Cleanup @($name)
}

# ---------------------------------------------------------------------------------------------------
# M · per-session overhead at idle (100 lanes) — what a lane costs when it does nothing
# ---------------------------------------------------------------------------------------------------
if (Run 11) {
    $names = 1..100 | ForEach-Object { "g-idle-$_" }
    $t0 = Get-Date
    foreach ($n in $names) { Start-Lane -Name $n -Kind other -Command 'cmd.exe /k' -Cwd $Scratch -Hidden | Out-Null }
    $launchSecs = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    Start-Sleep 10
    $hosts = @($names | ForEach-Object { $st = Get-LaneState $_; if ($st -and $st.hostPid) { Get-Process -Id $st.hostPid -ErrorAction SilentlyContinue } } | Where-Object { $_ })
    $cpu0 = ($hosts | ForEach-Object { $_.TotalProcessorTime.TotalSeconds } | Measure-Object -Sum).Sum
    Start-Sleep 30
    $hosts = @($names | ForEach-Object { $st = Get-LaneState $_; if ($st -and $st.hostPid) { Get-Process -Id $st.hostPid -ErrorAction SilentlyContinue } } | Where-Object { $_ })
    $cpu1 = ($hosts | ForEach-Object { $_.TotalProcessorTime.TotalSeconds } | Measure-Object -Sum).Sum
    $ws = ($hosts | ForEach-Object { $_.WorkingSet64 } | Measure-Object -Average -Sum)
    $priv = ($hosts | ForEach-Object { $_.PrivateMemorySize64 } | Measure-Object -Average -Sum)
    $conhosts = @(Get-CimInstance Win32_Process -Filter "Name='conhost.exe' OR Name='OpenConsole.exe'" | Where-Object { $_.CreationDate -gt $t0 })
    $chPriv = ($conhosts | ForEach-Object { $_.PrivatePageCount } | Measure-Object -Sum).Sum
    $t1 = Get-Date; $list = @(Get-Lane); $listSecs = [math]::Round(((Get-Date) - $t1).TotalSeconds, 2)
    $aliveCount = @($list | Where-Object { $_.name -like 'g-idle-*' -and $_.alive }).Count
    Log ("MEASURE idle: 100 lanes launched in $launchSecs s; $aliveCount alive; host private bytes avg {0:N1} MB (sum {1:N0} MB), working set avg {2:N1} MB; host CPU over 30 s idle: {3:N3} s total across 100 hosts ({4:N4} s each); conhost private sum {5:N0} MB for {6} conhosts; Get-Lane over 100 lanes took $listSecs s" -f ($priv.Average/1MB), ($priv.Sum/1MB), ($ws.Average/1MB), ($cpu1-$cpu0), (($cpu1-$cpu0)/100), ($chPriv/1MB), $conhosts.Count)
    Result 11 "100 idle lanes: per-session overhead measured" ($aliveCount -eq 100) ("avg host private {0:N1} MB, CPU {1:N4} s/30 s per host, conhost {2:N1} MB each" -f ($priv.Average/1MB), (($cpu1-$cpu0)/100), ($(if ($conhosts.Count) { $chPriv/1MB/$conhosts.Count } else { 0 })))
    Cleanup $names
}

# ---------------------------------------------------------------------------------------------------
# H · heads: two maximum; a head drives its own lanes and may only type into another head's inbox
# ---------------------------------------------------------------------------------------------------
if (Run 12) {
    $hf = Join-Path $Heads 'heads.json'; $bak = $null
    if (Test-Path $hf) { $bak = Get-Content $hf -Raw; Remove-Item $hf -Force }
    $env:LANES_HEAD = 'user'
    Start-Lane -Name 'g-head-a' -Kind other -Command 'pwsh -NoLogo -NoProfile' -Cwd $Scratch -Hidden -IsHead | Out-Null
    Start-Lane -Name 'g-head-b' -Kind other -Command 'pwsh -NoLogo -NoProfile' -Cwd $Scratch -Hidden -IsHead | Out-Null
    $third = $null; try { Start-Lane -Name 'g-head-c' -Kind other -Command 'pwsh -NoLogo -NoProfile' -Cwd $Scratch -Hidden -IsHead | Out-Null } catch { $third = "$_" }
    # head a launches a worker; head b tries to drive it, and to message head a's inbox
    $env:LANES_HEAD = 'g-head-a'
    Start-Lane -Name 'g-worker-a' -Kind other -Command 'pwsh -NoLogo -NoProfile' -Cwd $Scratch -Hidden | Out-Null
    $wa = Get-LaneState 'g-worker-a'
    $env:LANES_HEAD = 'g-head-b'
    $refused = $null; try { Send-Lane 'g-worker-a' "'b-drove-a-worker'" } catch { $refused = "$_" }
    $inbox = $null; try { Send-Lane 'g-head-a' "'hello from b'" } catch { $inbox = "$_" }
    Start-Sleep 2
    $aTail = Read-Lane 'g-head-a' -Tail 3
    $env:LANES_HEAD = 'gauntlet'
    $heads = @(Get-LaneHead)
    $pass = ($null -ne $third) -and ($third -match 'LANES_MAX_HEADS') -and ($wa.head -eq 'g-head-a') -and ($null -ne $refused) -and ($null -eq $inbox) -and ($aTail -match 'hello from b') -and ($heads.Count -eq 2)
    Result 12 "two heads max; a head drives only its own lanes, messages the other's inbox" $pass "third head refused: $($null -ne $third); worker owned by g-head-a: $($wa.head -eq 'g-head-a'); head b driving a's worker refused: $($null -ne $refused); head b -> head a inbox delivered: $($aTail -match 'hello from b'); registered heads: $($heads.name -join ',')"
    Cleanup @('g-worker-a', 'g-head-a', 'g-head-b', 'g-head-c')
    if ($bak) { Set-Content -LiteralPath $hf -Value $bak -NoNewline } else { Remove-Item $hf -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------------------------------
# Q · two consumers of one head's queue each see every event exactly once (the verifier's finding)
# ---------------------------------------------------------------------------------------------------
if (Run 13) {
    $names = 1..4 | ForEach-Object { "g-q-$_" }
    Get-LaneEvent -Drain -As 'q-alpha' | Out-Null; Get-LaneEvent -Drain -As 'q-beta' | Out-Null
    foreach ($n in $names) { Start-Lane -Name $n -Kind other -Command "cmd.exe /c echo done-$n" -Cwd $Scratch -Hidden | Out-Null }
    $dl = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $dl) { $fi = @(QueueRows | Where-Object { $_.state -eq 'finished' -and $_.lane -like 'g-q-*' }).Count; if ($fi -ge 4) { break }; Start-Sleep -Milliseconds 250 }
    $a1 = @(Get-LaneEvent -Drain -As 'q-alpha' | Where-Object { $_ -match 'g-q-' })
    $b1 = @(Get-LaneEvent -Drain -As 'q-beta'  | Where-Object { $_ -match 'g-q-' })
    $a2 = @(Get-LaneEvent -Drain -As 'q-alpha' | Where-Object { $_ -match 'g-q-' })
    $b2 = @(Get-LaneEvent -Drain -As 'q-beta'  | Where-Object { $_ -match 'g-q-' })
    $pass = ($a1.Count -eq 4) -and ($b1.Count -eq 4) -and ($a2.Count -eq 0) -and ($b2.Count -eq 0)
    Result 13 "two consumers of one queue each see every event once" $pass "alpha first drain $($a1.Count), beta first drain $($b1.Count) (both 4 = nobody blinded the other); second drains $($a2.Count)/$($b2.Count) (exactly once each)"
    Cleanup $names
}

# ---------------------------------------------------------------------------------------------------
# G · real Grok Build: launch/read/send/kill/events
# ---------------------------------------------------------------------------------------------------
if (Run 14 -and -not $SkipReal -and -not $SkipGrok) {
    $name = 'g-grok-real'; $work = Join-Path $Scratch 'grok-real'; New-Item -ItemType Directory -Force $work | Out-Null
    $witness = Join-Path $work 'grok-lane-witness.txt'; Remove-Item -LiteralPath $witness -Force -ErrorAction SilentlyContinue
    $st = Start-Lane -Name $name -Kind grok -Model $GrokModel -ExtraArgs @('--reasoning-effort', $GrokEffort) -Cwd $work -Hidden -StallMinutes 3 -Prompt 'Create grok-lane-witness.txt containing exactly GROK_GAUNTLET, then reply with exactly GROK_FIRST_DONE.'
    $first = WaitEvent $name 'needs-input' 90 'turn-complete'
    $fileFirst = if (Test-Path -LiteralPath $witness) { [IO.File]::ReadAllText($witness).Trim() } else { '' }
    $readFirst = @(Read-Lane $name -Messages 1) -join "`n"

    if ($first) { Send-Lane $name 'Read grok-lane-witness.txt. If it contains exactly GROK_GAUNTLET, reply with exactly GROK_SECOND_DONE.' }
    $dl = (Get-Date).AddSeconds(90); $turns = @()
    while ((Get-Date) -lt $dl) {
        $turns = @(QueueRows $name | Where-Object { $_.state -eq 'needs-input' -and $_.why -eq 'turn-complete' })
        if ($turns.Count -ge 2) { break }
        Start-Sleep -Milliseconds 500
    }
    $lastTurn = if ($turns.Count) { $turns[-1] } else { $null }
    $readSecond = @(Read-Lane $name -Messages 1) -join "`n"
    $hooks = @(Read-Lane $name -Events -Tail 20)
    $launch = Read-JsonFile (Join-Path (Get-LanesRoot) $name 'launch.json')
    $killed = Stop-Lane $name -Hard -Force
    $dead = WaitEvent $name 'died' 20
    $pass = $true `
        -and ($st.kind -eq 'grok') -and ($st.sessionId -match '^[0-9a-f-]{36}$') `
        -and ($first.label -eq 'GROK_FIRST_DONE') -and ($fileFirst -eq 'GROK_GAUNTLET') -and ($readFirst -eq 'GROK_FIRST_DONE') `
        -and ($turns.Count -ge 2) -and ($lastTurn.label -eq 'GROK_SECOND_DONE') -and ($readSecond -eq 'GROK_SECOND_DONE') `
        -and (($hooks -join "`n") -match '"hookEventName":"stop"') -and ($killed.state -eq 'died') -and ($null -ne $dead) -and ($dead.kind -eq 'grok')
    Result 14 "real Grok Build lane: launch/read/send/kill/events" $pass "kind=$($st.kind), model=$GrokModel/$GrokEffort, session=$($st.sessionId); first event='$($first.label)', file='$fileFirst', read='$readFirst'; second events=$($turns.Count), event='$($lastTurn.label)', read='$readSecond'; stop hook=$((($hooks -join "`n") -match '"hookEventName":"stop"')); kill=$($killed.state)/$($killed.why), died event=$($null -ne $dead)"
    Cleanup @($name)
}

Log ""
Log "| # | test | result | evidence |"
Log "|---|------|--------|----------|"
foreach ($r in $results) { Log ("| {0} | {1} | {2} | {3} |" -f $r.n, $r.test, $(if ($r.pass) { 'PASS' } else { '**FAIL**' }), ($r.evidence -replace '\|', '/')) }
$failed = @($results | Where-Object { -not $_.pass }).Count
Log ""
Log "$($results.Count) tests, $failed failed. Evidence: $EvidenceFile"
exit $failed
