# Draws the trainer's minimap icons (64x64 PNG) in the style of the game's own minimap badges:
# dark outline, colored ring, dark slate center, glyph in the ring color.
#   powershell -ExecutionPolicy Bypass -File icons\make_icons.ps1
# Output goes to GunsDragonsTrainer\icons (install.ps1 copies that folder into the mod).
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$out = Join-Path $PSScriptRoot "..\GunsDragonsTrainer\icons"
New-Item -ItemType Directory -Force $out | Out-Null

function C([int]$r, [int]$g, [int]$b, [int]$a = 255) { [System.Drawing.Color]::FromArgb($a, $r, $g, $b) }

function New-Badge([System.Drawing.Color]$ring) {
    $bmp = New-Object System.Drawing.Bitmap 64, 64, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $outline = New-Object System.Drawing.SolidBrush (C 12 15 20 235)
    $g.FillEllipse($outline, 1, 1, 62, 62)
    $ringBrush = New-Object System.Drawing.SolidBrush $ring
    $g.FillEllipse($ringBrush, 3, 3, 58, 58)
    # Dark center with a slight top highlight, like the game's badges.
    $center = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.Rectangle 8, 8, 48, 48), (C 52 62 78), (C 26 31 40), 90
    $g.FillEllipse($center, 8, 8, 48, 48)
    return @{ Bmp = $bmp; G = $g }
}

function Save-Badge($b, [string]$name) {
    $b.G.Dispose()
    $b.Bmp.Save((Join-Path $out $name), [System.Drawing.Imaging.ImageFormat]::Png)
    $b.Bmp.Dispose()
    Write-Host "wrote $name"
}

function Draw-Chest($g, [System.Drawing.Color]$col) {
    $br = New-Object System.Drawing.SolidBrush $col
    $dark = New-Object System.Drawing.SolidBrush (C 26 31 40)
    $g.FillRectangle($br, 18, 26, 28, 18)          # body
    $g.FillPie($br, 18, 17, 28, 18, 180, 180)      # rounded lid
    $g.FillRectangle($dark, 18, 29, 28, 2)         # lid seam
    $g.FillRectangle($dark, 29, 30, 6, 7)          # lock plate
    $g.FillRectangle($br, 31, 32, 2, 3)            # keyhole
}

# Resource chest: gold
$b = New-Badge (C 232 176 48); Draw-Chest $b.G (C 240 190 70); Save-Badge $b "chest.png"

# Secret room chest: magenta, chest with a small star above
$b = New-Badge (C 214 72 180); Draw-Chest $b.G (C 232 110 200)
$star = New-Object System.Drawing.SolidBrush (C 255 230 120)
$pts = @()
for ($i = 0; $i -lt 10; $i++) {
    $a = -[Math]::PI / 2 + $i * [Math]::PI / 5
    $r = if ($i % 2 -eq 0) { 7 } else { 3 }
    $pts += New-Object System.Drawing.PointF ([single](32 + $r * [Math]::Cos($a))), ([single](13 + $r * [Math]::Sin($a)))
}
$b.G.FillPolygon($star, $pts); Save-Badge $b "secret_chest.png"

# Artifact box: orange, box with a gem
$b = New-Badge (C 236 120 40)
$col = New-Object System.Drawing.SolidBrush (C 245 150 70)
$b.G.FillRectangle($col, 19, 24, 26, 20)
$dark = New-Object System.Drawing.SolidBrush (C 26 31 40)
$b.G.FillRectangle($dark, 19, 30, 26, 2)
$gem = New-Object System.Drawing.SolidBrush (C 140 220 255)
$b.G.FillPolygon($gem, @((New-Object System.Drawing.PointF 32, 14), (New-Object System.Drawing.PointF 38, 20), (New-Object System.Drawing.PointF 32, 27), (New-Object System.Drawing.PointF 26, 20)))
Save-Badge $b "artifact_box.png"

# Clay launcher: green, target
$b = New-Badge (C 90 200 80)
$pen = New-Object System.Drawing.Pen (C 120 225 100), 4
$b.G.DrawEllipse($pen, 19, 19, 26, 26)
$dot = New-Object System.Drawing.SolidBrush (C 120 225 100)
$b.G.FillEllipse($dot, 28, 28, 8, 8)
$thin = New-Object System.Drawing.Pen (C 120 225 100), 3
$b.G.DrawLine($thin, 32, 12, 32, 20); $b.G.DrawLine($thin, 32, 44, 32, 52)
$b.G.DrawLine($thin, 12, 32, 20, 32); $b.G.DrawLine($thin, 44, 32, 52, 32)
Save-Badge $b "clay_launcher.png"

# Secret wall: red, cracked bricks
$b = New-Badge (C 214 64 52)
$brick = New-Object System.Drawing.SolidBrush (C 232 96 80)
foreach ($row in @(@(18, 0), @(27, 6), @(36, 0))) {
    $y = $row[0]; $off = $row[1]
    for ($x = 15 + $off - 12; $x -lt 49; $x += 12) {
        $x0 = [Math]::Max(15, $x); $x1 = [Math]::Min(49, $x + 10)
        if ($x1 - $x0 -gt 2) { $b.G.FillRectangle($brick, $x0, $y, $x1 - $x0, 7) }
    }
}
$crack = New-Object System.Drawing.Pen (C 20 22 28), 3
$b.G.DrawLines($crack, @((New-Object System.Drawing.PointF 36, 15), (New-Object System.Drawing.PointF 30, 25), (New-Object System.Drawing.PointF 36, 33), (New-Object System.Drawing.PointF 29, 46)))
Save-Badge $b "secret_wall.png"

# Dynamic event (grave): teal, tombstone with a cross
$b = New-Badge (C 60 190 200)
$stone = New-Object System.Drawing.SolidBrush (C 110 220 228)
$b.G.FillPie($stone, 21, 14, 22, 20, 180, 180)    # rounded top
$b.G.FillRectangle($stone, 21, 23, 22, 21)         # body
$b.G.FillRectangle($stone, 17, 43, 30, 5)          # base
$dark = New-Object System.Drawing.SolidBrush (C 26 31 40)
$b.G.FillRectangle($dark, 30, 20, 4, 16)           # cross
$b.G.FillRectangle($dark, 25, 25, 14, 4)
Save-Badge $b "event_grave.png"

# Loot dot (magnet items on the minimap): small bright gold dot with a dark rim, drawn at ~9 px.
$bmp = New-Object System.Drawing.Bitmap 32, 32, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.Clear([System.Drawing.Color]::Transparent)
$g.FillEllipse((New-Object System.Drawing.SolidBrush (C 12 15 20 235)), 1, 1, 30, 30)
$g.FillEllipse((New-Object System.Drawing.SolidBrush (C 255 214 90)), 5, 5, 22, 22)
$g.FillEllipse((New-Object System.Drawing.SolidBrush (C 255 246 200)), 10, 8, 8, 7)
$g.Dispose()
$bmp.Save((Join-Path $out "loot_dot.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Host "wrote loot_dot.png"
