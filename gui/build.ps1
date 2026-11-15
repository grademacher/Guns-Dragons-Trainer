# Builds TrainerGUI.exe into the mod folder using the C# compiler that ships with .NET Framework 4.
$ErrorActionPreference = "Stop"
$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw "csc.exe not found at $csc" }
$out = Join-Path $PSScriptRoot "..\GunsDragonsTrainer\TrainerGUI.exe"
& $csc /nologo /target:winexe /optimize+ /out:$out `
    /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll `
    (Join-Path $PSScriptRoot "TrainerGUI.cs")
if ($LASTEXITCODE -ne 0) { throw "Build failed" }
Write-Host "Built $out"
