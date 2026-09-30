# Builds LaneHost.exe with the in-box .NET Framework 4.8 C# compiler. No SDK, no admin.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw "csc.exe not found at $csc" }
New-Item -ItemType Directory -Force "$here\bin" | Out-Null
$out = "$here\bin\LaneHost.exe"
$tmp = "$here\bin\LaneHost.build.exe"
& $csc /nologo /optimize+ /target:exe /platform:x64 /out:$tmp /nowarn:0168,0219,0414,0649,1998 `
    /r:System.dll /r:System.Core.dll /r:System.Net.dll /r:Microsoft.CSharp.dll `
    "$here\src\LaneHost.cs"
if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE)" }
# A running host keeps its image locked, but Windows lets a running image be renamed: move the old one aside.
if (Test-Path $out) {
    try { Remove-Item $out -Force -ErrorAction Stop }
    catch {
        New-Item -ItemType Directory -Force "$here\bin\old" | Out-Null
        Move-Item $out "$here\bin\old\LaneHost.$((Get-Date).ToString('yyyyMMdd-HHmmss')).exe" -Force
    }
}
Move-Item $tmp $out -Force
Get-ChildItem "$here\bin\old" -Filter *.exe -ErrorAction SilentlyContinue | ForEach-Object { try { Remove-Item $_.FullName -Force -ErrorAction Stop } catch { } }
# Force the .NET Framework runtime to 4.8 and modern path handling.
@"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <startup><supportedRuntime version="v4.0" sku=".NETFramework,Version=v4.8"/></startup>
  <runtime>
    <gcServer enabled="false"/>
    <gcConcurrent enabled="false"/>
    <AppContextSwitchOverrides value="Switch.System.IO.UseLegacyPathHandling=false;Switch.System.IO.BlockLongPaths=false"/>
  </runtime>
</configuration>
"@ | Set-Content -Encoding UTF8 "$out.config"
Write-Host "built $out ($((Get-Item $out).Length) bytes)"
