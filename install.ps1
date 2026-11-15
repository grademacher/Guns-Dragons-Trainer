# Installs the trainer (and optionally UE4SS) into Guns & Dragons.
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -UE4SSZip path\to\UE4SS_v4.0.0.zip
# Your settings.ini in the installed mod folder is never overwritten.
param(
    [string]$GameDir = "D:\SteamLibrary\steamapps\common\GunsDragonsPlaytest",
    [string]$UE4SSZip = ""
)
$ErrorActionPreference = "Stop"

$win64 = Join-Path $GameDir "EX\Binaries\Win64"
if (-not (Test-Path (Join-Path $win64 "EXGameSteam-Win64-Shipping.exe"))) {
    throw "Game exe not found under $win64. Pass -GameDir."
}

if ($UE4SSZip) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path $UE4SSZip))
    try {
        foreach ($e in $zip.Entries) {
            if ($e.FullName.EndsWith("/")) { continue }
            $dest = Join-Path $win64 ($e.FullName -replace "/", "\")
            # Keep an existing UE4SS config and mod list.
            if ((Test-Path $dest) -and ($e.Name -in @("UE4SS-settings.ini", "mods.txt"))) { continue }
            New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
        }
    } finally { $zip.Dispose() }
    Write-Host "UE4SS extracted to $win64"
}

$mods = Join-Path $win64 "ue4ss\Mods"
if (-not (Test-Path $mods)) { throw "UE4SS not found ($mods). Run again with -UE4SSZip." }

# Game-specific UE4SS config. This build is UE 5.7 with class/property layouts that differ from UE4SS's
# template; without this file UE4SS crashes at "Locating KismetStringLibrary CDO...".
Copy-Item (Join-Path $PSScriptRoot "ue4ss-config\MemberVariableLayout.ini") (Join-Path $win64 "ue4ss") -Force

# Reload the trainer without restarting the game: Ctrl+R, and automatically whenever this script
# updates the mod's Scripts folder. Takes effect the next time the game starts.
$ue4ssIni = Join-Path $win64 "ue4ss\UE4SS-settings.ini"
if (Test-Path $ue4ssIni) {
    $ini = Get-Content $ue4ssIni -Raw
    $new = $ini -replace "(?m)^EnableHotReloadSystem\s*=\s*0", "EnableHotReloadSystem = 1" `
                -replace "(?m)^EnableAutoReloadingLuaMods\s*=\s*0", "EnableAutoReloadingLuaMods = 1"
    if ($new -ne $ini) { [IO.File]::WriteAllText($ue4ssIni, $new) }
}

# Re-enable UE4SS if it was switched off by renaming its loader.
$off = Join-Path $win64 "dwmapi.dll.disabled"
if ((Test-Path $off) -and -not (Test-Path (Join-Path $win64 "dwmapi.dll"))) { Rename-Item $off "dwmapi.dll" }

$src = Join-Path $PSScriptRoot "GunsDragonsTrainer"
$dest = Join-Path $mods "GunsDragonsTrainer"
New-Item -ItemType Directory -Force (Join-Path $dest "Scripts") | Out-Null

# A running trainer window locks its exe. Windows still allows renaming it, so the open window keeps
# working and the new exe is used next time the game starts.
$exe = Join-Path $dest "TrainerGUI.exe"
# Old copies from earlier updates; ones still running stay locked and are skipped.
Get-ChildItem $dest -Filter "TrainerGUI.old*.exe" -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
if (Test-Path $exe) {
    $locked = $false
    try { $fs = [IO.File]::Open($exe, 'Open', 'ReadWrite', 'None'); $fs.Close() } catch { $locked = $true }
    if ($locked) { Rename-Item $exe ("TrainerGUI.old." + [DateTime]::Now.Ticks + ".exe") }
}
Copy-Item (Join-Path $src "enabled.txt") $dest -Force
Copy-Item (Join-Path $src "TrainerGUI.exe") $dest -Force
Copy-Item (Join-Path $src "Scripts\*.lua") (Join-Path $dest "Scripts") -Force
# Minimap icons drawn by the trainer (loaded as textures at runtime).
New-Item -ItemType Directory -Force (Join-Path $dest "icons") | Out-Null
Copy-Item (Join-Path $src "icons\*.png") (Join-Path $dest "icons") -Force

# Register in mods.txt (above the built-in Keybinds line, as UE4SS asks).
$modsTxt = Join-Path $mods "mods.txt"
if (Test-Path $modsTxt) {
    $lines = Get-Content $modsTxt
    if (-not ($lines | Where-Object { $_ -match "^\s*GunsDragonsTrainer\s*:" })) {
        $out = @(); $added = $false
        foreach ($l in $lines) {
            if (-not $added -and $l -match "^; Built-in keybinds") { $out += "GunsDragonsTrainer : 1"; $out += ""; $added = $true }
            $out += $l
        }
        if (-not $added) { $out += "GunsDragonsTrainer : 1" }
        Set-Content -Path $modsTxt -Value $out -Encoding ascii
    }
}

Write-Host "Trainer installed to $dest"
