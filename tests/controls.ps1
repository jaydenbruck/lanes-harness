$ErrorActionPreference = 'Stop'
$env:LANES_HOME = Join-Path ([IO.Path]::GetTempPath()) ('lanes-controls-' + [guid]::NewGuid().ToString('N'))
Remove-Item Env:LANES_LANE -ErrorAction SilentlyContinue
$module = Import-Module (Join-Path $PSScriptRoot '..\Lanes.psm1') -Force -DisableNameChecking -PassThru
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
"Evidence retained in $env:LANES_HOME"
