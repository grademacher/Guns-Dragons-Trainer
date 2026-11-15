# Guns & Dragons Trainer

A [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod with a companion window (`TrainerGUI.exe`) for the Guns and Dragons Playtest (online co-op, Unreal Engine 5.7).

| Cheat | Works when you... | How |
|---|---|---|
| Infinite health | host or play solo | Refills `Health` to `MaxHealth` every frame and sets your `FinalReceivedDamageRatio` stat to -1 (no damage taken). |
| Infinite ammo | host or play solo | Refills your weapons' magazines and sets `UseAmmoOnFire` to 0. |
| Infinite armor | host or play solo | Tops `Shield` up to `MaxShield`. |
| Loot magnet | host or play solo | Pulls pickups within the radius to you and widens your pickup range. Per-player drops are left alone. |
| No spread | host; best effort when joined | Zeroes your spread stats and your weapon's spread multipliers. They are restored when you turn it off. |
| Fire rate multiplier | host; best effort when joined | Multiplies your `FireRateRatio` stat and bow draw speed (`ChargeSpeedRate`, `ChargeDoneTime`). Buffs still stack on top. |
| No dash cooldown | host; best effort when joined | Cooldown ~0 and dash charges kept full. |
| Reload speed multiplier | host; best effort when joined | Multiplies your `ReloadSpeedRatio` stat. |
| Movement speed multiplier | host; best effort when joined | Multiplies your walk speed. Sprint and other speed changes are multiplied too. When joined, the host may pull you back. |
| Explosive gear priority | host **or** join | Aims at an enemy's explosive part (goblin barrel, grenadier grenade) before its weak spot, but only when the part is on the side facing you. |
| Aim over shields | host **or** join | If the line to the weak spot or head crosses a carried or forward shield, it aims at the next point that's clear, or raises the aim until it clears the shield's top edge. |
| Highlight loot chests | host **or** join | Outlines unopened resource chests, artifact boxes and secret room reward chests. |
| Highlight secret walls | host **or** join | Outlines cracked secret walls (`B_SecretBreakableWall_C`). |
| Protectors first | host **or** join | When an enemy is protected by a tethered lifeline imp or bound by a Goblin Shaman Elite's Soul Binding, the aim goes to the protector until it dies. |
| Ignore ducking mushrooms | host **or** join | Spore colony mushrooms are skipped while burrowed (damage blocked) and targeted again when they pop up. |
| Lead moving targets | host **or** join | Leads moving targets (flying clays) and compensates for bullet drop, using your weapon's bullet speed and gravity. |
| Aim assist | host **or** join | While the hold key is down, it locks onto the hostile enemy closest to your crosshair. It aims at the game's weak spot, then the game's own auto-aim point, then the head, then the top of the body along the enemy's own up axis (wall-mounted enemies). Friendly summons such as Thorn Blooms are skipped. A locked target stays locked for 1.5 s if it hides behind a shield. |
| Supplies | host **or** join | The flying "clay" bubbles launched from bone, tomb and barrel piles. Aim assist can target them: it stays on each clay until your weapon fires once (read from the game's own shot timer, so any fire button and any weapon works), then moves to the next, and only comes back to clays it has already shot when none are left. Clays are outlined along with the piles and pickups. |
| Minimap icons (experimental, off by default) | host **or** join | Draws the trainer's own badges (`icons\*.png`, made by `icons\make_icons.ps1` in the style of the game's icons) on the minimap for highlighted resource chests, artifact boxes, secret room chests, clay launchers and secret walls. Also shows objects the game hides (unexplored rooms) or has no icon for. Uses a fixed set of 24 images on the minimap: the nearest objects are shown, and far ones are pinned to the edge. |
| Ping (F8) | host **or** join | Logs whatever is under your crosshair to `pings.txt`: the class, its parent classes and distance, and for enemies their team and aim points. It changes nothing in game. Used to check new enemies and objects. |

**Only this PC's player is affected.**
- The mod picks the one player controller that `IsLocalController()`.
- Stats, ammo and weapons are only changed on objects owned by that controller, its pawn or its player state.
- Teammates' stats, ammo and aim are never touched. The tests check this.

Health, armor, ammo and the loot magnet are tracked by the host's game, so they do nothing when you join someone else's session. The window tells you when that's the case.

**UE 5.7 crash note:** this game needs `ue4ss-config\MemberVariableLayout.ini`, which `install.ps1` copies, or UE4SS crashes on launch. Never pass gameplay-tag containers to game functions from Lua: UE4SS v4.0.0 crashes the game. That caused the first infinite-health crash.

## The window

`TrainerGUI.exe` opens automatically when the game starts and closes when the game exits.

- Press **Insert** (you can change this key) to show or hide it. The key isn't blocked in other apps.
- Every change is saved immediately to `settings.ini` and remembered on the next launch. The mod re-reads the file 4 times a second, so changes apply live.
- The top line shows whether the mod is connected and whether you're Solo, Hosting or Joined. While aim assist is locked on, it also shows the current target.
- The game must run in **borderless/windowed** mode for the window to appear over it.

You can also start `TrainerGUI.exe` by hand before the game, from `...\EX\Binaries\Win64\ue4ss\Mods\GunsDragonsTrainer\`.

## Install / update

UE4SS v4.0.0 and the mod are already installed in `D:\SteamLibrary\steamapps\common\GunsDragonsPlaytest\EX\Binaries\Win64`.

To reinstall after changing code:

```
powershell -ExecutionPolicy Bypass -File gui\build.ps1
powershell -ExecutionPolicy Bypass -File install.ps1
```

While the game is running, an update installed by `install.ps1` reloads the trainer automatically. You can also press **Ctrl+R** in-game to reload all UE4SS mods. The trainer saves the game's original stat values to `runtime_state.txt`, so a reload restores them instead of multiplying them again.

`install.ps1 -UE4SSZip <zip>` also installs or updates UE4SS. Your `settings.ini` is never overwritten.

To uninstall, delete `dwmapi.dll` and the `ue4ss` folder from `EX\Binaries\Win64`.

## First run checklist

1. Launch the game. The trainer window should appear, showing "Connected to game".
2. Load into a level (solo or hosting). The mod writes `probe.txt` with the real attribute names in this build. It also writes `enemies.txt`, with one line per enemy type showing its team and every aim point the game offers.
3. Quit, then run:
   ```
   powershell -ExecutionPolicy Bypass -File report.ps1
   ```
   This creates `trainer-report.txt` with the UE4SS log, status, settings, marked supplies, enemies and probe. If anything misbehaves, that file has what's needed to fix it.

## Development

- `GunsDragonsTrainer/Scripts/main.lua`: the game glue (UE4SS API calls)
- `gdt_settings.lua` / `gdt_aim.lua`: pure logic (settings parsing, aim math, target choice)
- `config.lua`: game-specific names (tags, attributes, head sockets) and timings
- `gui/TrainerGUI.cs`: the window. It builds with the .NET Framework `csc.exe` built into Windows (`gui\build.ps1`).
- `tests/run_tests.lua`: runs the real `main.lua` against a fake UE4SS/game world. It covers host, client, solo, teammate isolation, toggles, persistence and aim selection.
  ```
  lua tests\run_tests.lua
  luac -p GunsDragonsTrainer\Scripts\*.lua
  ```
  Lua 5.4 is installed at `%LOCALAPPDATA%\Programs\Lua\bin`.
