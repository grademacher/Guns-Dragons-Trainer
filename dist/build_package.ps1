# Builds the shareable zip: dist\GunsDragonsTrainer_v<version>.zip
#   powershell -ExecutionPolicy Bypass -File dist\build_package.ps1
# Contents: INSTALL_INSTRUCTIONS.txt + Win64\ (clean UE4SS v4.0.0 from vendor\, this game's UE4SS config, the trainer).
# Never includes personal files (settings.ini, logs, crash dumps, diagnostics).
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot
$version = (Select-String -Path (Join-Path $root "GunsDragonsTrainer\Scripts\main.lua") -Pattern '^local VERSION = "([^"]+)"').Matches[0].Groups[1].Value
$name = "GunsDragonsTrainer_v$version"
$stage = Join-Path $PSScriptRoot "staging\$name"
$zipOut = Join-Path $PSScriptRoot "$name.zip"

if (Test-Path (Join-Path $PSScriptRoot "staging")) { Remove-Item (Join-Path $PSScriptRoot "staging") -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null
$win64 = Join-Path $stage "Win64"

# 1. Clean UE4SS v4.0.0 (as downloaded).
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $root "vendor\UE4SS_v4.0.0.zip"), $win64)

# 2. This game's UE4SS config.
$ue = Join-Path $win64 "ue4ss"
Copy-Item (Join-Path $root "ue4ss-config\MemberVariableLayout.ini") $ue -Force
$ini = Join-Path $ue "UE4SS-settings.ini"
$text = [IO.File]::ReadAllText($ini)
$text = $text -replace "(?m)^EnableHotReloadSystem\s*=\s*0", "EnableHotReloadSystem = 1" `
              -replace "(?m)^EnableAutoReloadingLuaMods\s*=\s*0", "EnableAutoReloadingLuaMods = 1"
[IO.File]::WriteAllText($ini, $text)
$modsTxt = Join-Path $ue "Mods\mods.txt"
$lines = Get-Content $modsTxt
$out = @(); $added = $false
foreach ($l in $lines) {
    if (-not $added -and $l -match "^; Built-in keybinds") { $out += "GunsDragonsTrainer : 1"; $out += ""; $added = $true }
    $out += $l
}
if (-not $added) { $out += "GunsDragonsTrainer : 1" }
Set-Content -Path $modsTxt -Value $out -Encoding ascii

# 3. The trainer.
$src = Join-Path $root "GunsDragonsTrainer"
$dst = Join-Path $ue "Mods\GunsDragonsTrainer"
New-Item -ItemType Directory -Force (Join-Path $dst "Scripts"), (Join-Path $dst "icons") | Out-Null
Copy-Item (Join-Path $src "enabled.txt"), (Join-Path $src "TrainerGUI.exe") $dst -Force
Copy-Item (Join-Path $src "Scripts\*.lua") (Join-Path $dst "Scripts") -Force
Copy-Item (Join-Path $src "icons\*.png") (Join-Path $dst "icons") -Force

# 4. Instructions.
Copy-Item (Join-Path $PSScriptRoot "INSTALL_INSTRUCTIONS.txt") $stage -Force

# 5. Zip.
if (Test-Path $zipOut) { Remove-Item $zipOut -Force }
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipOut, [IO.Compression.CompressionLevel]::Optimal, $true)
Remove-Item (Join-Path $PSScriptRoot "staging") -Recurse -Force
Write-Host "Built $zipOut"
