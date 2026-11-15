# Collects everything needed to debug the trainer into trainer-report.txt (in this folder).
# Run after playing:  powershell -ExecutionPolicy Bypass -File report.ps1
param([string]$GameDir = "D:\SteamLibrary\steamapps\common\GunsDragonsPlaytest")

$win64 = Join-Path $GameDir "EX\Binaries\Win64"
$mod = Join-Path $win64 "ue4ss\Mods\GunsDragonsTrainer"
$log = Join-Path $win64 "ue4ss\UE4SS.log"
$out = Join-Path $PSScriptRoot "trainer-report.txt"

$sb = New-Object System.Text.StringBuilder
function Add([string]$s) { [void]$sb.AppendLine($s) }

Add "=== Trainer report $(Get-Date -Format s)"
Add "UE4SS installed: $(Test-Path (Join-Path $win64 'dwmapi.dll'))"
Add "Mod installed: $(Test-Path (Join-Path $mod 'Scripts\main.lua'))"
Add ""
Add "=== UE4SS.log (startup, trainer lines, errors)"
if (Test-Path $log) {
    $lines = Get-Content $log
    $lines | Select-Object -First 60 | ForEach-Object { Add $_ }
    Add "..."
    $lines | Where-Object { $_ -match "G&D Trainer|error|Error|fail|Failed|AOB|EngineTick|ProcessEvent|GunsDragonsTrainer" } |
        Select-Object -Last 150 | ForEach-Object { Add $_ }
} else { Add "(no UE4SS.log - UE4SS did not load; was the game started after installing?)" }
foreach ($f in "status.ini", "settings.ini", "pings.txt", "enemies.txt", "probe.txt") {
    Add ""
    Add "=== $f"
    $p = Join-Path $mod $f
    if (Test-Path $p) { Get-Content $p | ForEach-Object { Add $_ } } else { Add "(missing)" }
}
[IO.File]::WriteAllText($out, $sb.ToString())
Write-Host "Wrote $out"
# Newest crash dump, if the game crashed since the last report.
$dmp = Get-ChildItem (Join-Path $win64 "ue4ss") -Filter "crash_*.dmp" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
if ($dmp) { Add-Content $out "`r`n=== Newest crash dump: $($dmp.Name) ($($dmp.LastWriteTime))" }
