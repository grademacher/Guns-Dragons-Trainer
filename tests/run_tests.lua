-- Offline tests: pure modules + main.lua running against a fake UE4SS / game object model.
-- Run from the repo root:  lua tests\run_tests.lua

local SEP = package.config:sub(1, 1)
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
local SCRIPTS = ROOT .. SEP .. "GunsDragonsTrainer" .. SEP .. "Scripts"
package.path = SCRIPTS .. SEP .. "?.lua;" .. package.path

local Settings = require("gdt_settings")
local Aim = require("gdt_aim")

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("PASS  " .. name)
    else
        failed = failed + 1
        print("FAIL  " .. name .. "\n      " .. tostring(err))
    end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function near(a, b, tol, msg)
    if type(a) ~= "number" or math.abs(a - b) > (tol or 1e-6) then
        error((msg or "") .. " expected ~" .. tostring(b) .. ", got " .. tostring(a), 2)
    end
end
local function truthy(v, msg) if not v then error(msg or "expected truthy", 2) end end

---------------------------------------------------------------------------
-- gdt_settings
---------------------------------------------------------------------------

test("settings: defaults when file empty", function()
    local s = Settings.fromIni("")
    eq(s.infiniteHealth, false); eq(s.aimFov, 10); eq(s.aimMode, "hold"); eq(s.aimHoldKey, "RightMouseButton")
end)

test("settings: parses, coerces and clamps", function()
    local s = Settings.fromIni("infiniteHealth=1\r\naimAssist = true\naimFov=500\naimSmoothing=abc\naimMode=ALWAYS\n; comment\nguiX=12\n")
    eq(s.infiniteHealth, true); eq(s.aimAssist, true)
    eq(s.aimFov, 90, "clamped fov"); eq(s.aimSmoothing, 100, "bad number -> default"); eq(s.aimMode, "always")
end)

test("settings: round trip", function()
    local s = Settings.defaults()
    s.infiniteAmmo = true; s.aimFov = 25; s.aimHoldKey = "LeftShift"
    local back = Settings.fromIni(Settings.toIni(s))
    for k, v in pairs(s) do eq(back[k], v, k) end
end)

test("settings: invalid enum/bool fall back to default", function()
    local s = Settings.fromIni("aimMode=sometimes\ninfiniteArmor=maybe\n")
    eq(s.aimMode, "hold"); eq(s.infiniteArmor, false)
end)

---------------------------------------------------------------------------
-- gdt_aim
---------------------------------------------------------------------------

test("aim: rotation/direction are inverses", function()
    for _, r in ipairs({ { 0, 0 }, { 30, 45 }, { -20, 170 }, { 10, -120 }, { 80, 3 } }) do
        local x, y, z = Aim.rotToDir(r[1], r[2])
        local p, yw = Aim.dirToRot(x, y, z)
        near(p, r[1], 1e-9); near(Aim.normAxis(yw - r[2]), 0, 1e-9)
    end
end)

test("aim: normAxis wraps", function()
    near(Aim.normAxis(190), -170); near(Aim.normAxis(-190), 170); near(Aim.normAxis(360), 0); near(Aim.normAxis(540), 180)
end)

local cam0, rot0 = { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0 }

test("aim: picks candidate closest to crosshair, not closest in distance", function()
    local c = {
        { id = "nearButWide", point = { X = 200, Y = 100, Z = 0 } },   -- ~26.6 deg
        { id = "farButCentered", point = { X = 3000, Y = 50, Z = 0 } }, -- ~0.95 deg
    }
    local best = Aim.pickTarget(cam0, rot0, c, 30, 10000)
    eq(best.id, "farButCentered")
end)

test("aim: respects fov radius and distance", function()
    local c = { { id = "a", point = { X = 1000, Y = 200, Z = 0 } } } -- ~11.3 deg
    eq(Aim.pickTarget(cam0, rot0, c, 10, 10000), nil, "outside 10 deg")
    eq(Aim.pickTarget(cam0, rot0, c, 12, 10000).id, "a", "inside 12 deg")
    eq(Aim.pickTarget(cam0, rot0, c, 12, 500), nil, "beyond max distance")
    eq(Aim.pickTarget(cam0, rot0, { { point = { X = -1000, Y = 0, Z = 0 } } }, 90, 10000), nil, "behind camera")
end)

test("aim: visibility check falls through to next best", function()
    local c = {
        { id = "hidden", point = { X = 1000, Y = 0, Z = 0 } },
        { id = "visible", point = { X = 1000, Y = 60, Z = 0 } },
    }
    local best = Aim.pickTarget(cam0, rot0, c, 10, 10000, function(x) return x.id ~= "hidden" end)
    eq(best.id, "visible")
end)

test("aim: snap rotation points exactly at target", function()
    local cam = { X = 10, Y = -20, Z = 150 }
    local pt = { X = 900, Y = 400, Z = 300 }
    local p, y = Aim.aimRotation(cam, pt, { Pitch = 350, Yaw = 200 }, { Pitch = -10, Yaw = -160 }, 1)
    local dx, dy, dz = Aim.rotToDir(p, y)
    local vx, vy, vz = pt.X - cam.X, pt.Y - cam.Y, pt.Z - cam.Z
    local len = math.sqrt(vx * vx + vy * vy + vz * vz)
    near(dx * vx / len + dy * vy / len + dz * vz / len, 1, 1e-9)
end)

test("aim: camera offset from control rotation is compensated", function()
    -- Camera is pitched 2 deg above control rotation (e.g. recoil): result must leave the camera on target.
    local p = Aim.aimRotation(cam0, { X = 1000, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0 }, { Pitch = 2, Yaw = 0 }, 1)
    near(p, -2, 1e-9)
end)

test("aim: smoothing moves part of the way and takes the short way round", function()
    local p, y = Aim.aimRotation(cam0, { X = -1000, Y = -10, Z = 0 }, { Pitch = 0, Yaw = 170 }, { Pitch = 0, Yaw = 170 }, 0.5)
    -- target yaw is ~ -179.4; shortest path from 170 is +10.6 deg -> halfway ~175.3
    near(y, 175.29, 0.05)
end)

---------------------------------------------------------------------------
-- main.lua against a fake UE4SS
---------------------------------------------------------------------------

local function tmpDir()
    local base = os.getenv("TEMP") or os.getenv("TMP") or "."
    local dir = base .. SEP .. "gdt_test_" .. tostring(os.time()) .. "_" .. tostring(math.random(1, 1e9))
    os.execute('mkdir "' .. dir .. SEP .. 'Scripts" >nul 2>nul')
    return dir
end

local function writeFile(p, s) local f = assert(io.open(p, "wb")); f:write(s); f:close() end
local function readFile(p) local f = io.open(p, "rb"); if not f then return nil end; local s = f:read("a"); f:close(); return s end

-- Builds a fake world and returns it plus a function that runs main.lua inside it.
local function makeWorld(opts)
    opts = opts or {}
    local W = { registry = {}, nextAddr = 1000, tagged = {}, untagged = {}, setRot = nil, loops = {}, log = {}, staticObjects = {} }
    local fnames = {}
    local function FN(s)
        if not fnames[s] then fnames[s] = { name = s, ToString = function() return s end } end
        return fnames[s]
    end

    local base = {}
    base.__index = base
    function base:IsValid() return not self._dead end
    function base:GetAddress() return self._addr end
    function base:GetOuter() return self._outer end
    local function classObj(names, i, props)
        if not names[i] then return nil end
        return {
            GetFName = function() return FN(names[i]) end,
            GetFullName = function() return "Class /Script/EXGame." .. names[i] end,
            ForEachProperty = function(_, fn)
                if i == 1 then
                    for _, n in ipairs(props or {}) do
                        fn({ GetFName = function() return FN(n) end,
                             GetClass = function() return { GetFName = function() return FN("ObjectProperty") end } end })
                    end
                end
            end,
            ForEachFunction = function() end,
            GetSuperStruct = function() return classObj(names, i + 1, props) end,
            IsValid = function() return true end,
        }
    end
    function base:GetClass()
        local names = { self._class }
        for _, n in ipairs(self._supers or {}) do names[#names + 1] = n end
        return classObj(names, 1, self._props)
    end
    function base:IsA() return self._primitive == true end

    local function obj(cls, isa, fields)
        fields = fields or {}
        fields._class = cls
        W.nextAddr = W.nextAddr + 8
        fields._addr = W.nextAddr
        local o = setmetatable(fields, base)
        for _, c in ipairs(isa) do
            W.registry[c] = W.registry[c] or {}
            table.insert(W.registry[c], o)
        end
        return o
    end
    W.obj = obj

    local function attr(v) return { BaseValue = v, CurrentValue = v } end
    W.attr = attr

    -- Player: controller, player state, pawn, attribute sets, an inventory item.
    local function player(isLocal, name)
        local p = {}
        p.ps = obj("EXPlayerState", { "PlayerState" })
        p.pawn = obj("B_Hero_C", { "EXPlayerCharacter", "EXCharacter", "Pawn" }, {
            K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end,
        })
        p.pc = obj("EXPlayerController", { "PlayerController" }, {
            Pawn = p.pawn, PlayerState = p.ps,
            IsLocalController = function() return isLocal end,
            IsInputKeyDown = function(_, key) return (W.keysDown or {})[key.KeyName.name] == true end,
            PlayerCameraManager = obj("PlayerCameraManager", {}, {
                GetCameraLocation = function() return W.cam or { X = 0, Y = 0, Z = 0 } end,
                GetCameraRotation = function() return W.camRot or { Pitch = 0, Yaw = 0, Roll = 0 } end,
            }),
            GetControlRotation = function() return W.ctrlRot or { Pitch = 0, Yaw = 0, Roll = 0 } end,
            SetControlRotation = function(self, r)
                if isLocal then W.setRot = r else W.remoteSetRot = r end
            end,
            LineOfSightTo = function(_, actor) return not actor.blocked end,
        })
        p.health = obj("EXHealthSet", { "EXHealthSet" }, {
            _outer = p.ps, Health = attr(20), MaxHealth = attr(100), Shield = attr(5), MaxShield = attr(50),
        })
        p.shield = p.health
        p.stats = obj("EXRogueLiteAttributeSet", { "EXRogueLiteAttributeSet" }, {
            _outer = p.ps,
            FinalReceivedDamageRatio = attr(0), UseAmmoOnFire = attr(1), DashCoolTime = attr(5),
            RemainDashCount = attr(0), MaxDashCount = attr(2), FireRateRatio = { BaseValue = 1, CurrentValue = 1.04 },
            AdditionalBulletSpreadAngle = attr(0), AdditionalSpreadMinMaxRatio = attr(1), ItemDetectionRange = attr(500),
        })
        p.spread = obj("SpreadData", {}, { SpreadAngleMultiplier_Aiming = 0.5, SpreadAngleMultiplier_Moving = 1.5 })
        p.weapon = obj("EXRangedWeaponInstance", { "EXRangedWeaponInstance" }, {
            _outer = p.pawn, ammo = 4, SpreadData = p.spread,
            GetMagazineSize = function() return 12 end,
            GetCurrentMagazineAmmo = function(self) return self.ammo end,
            AddCurrentMagazineAmmo = function(self, n) self.ammo = self.ammo + n end,
        })
        p.energy = obj("EXEnergyMagazineAttributeSet", { "EXEnergyMagazineAttributeSet" }, { _outer = p.ps, Energy = attr(1), MaxEnergy = attr(30) })
        local stacks = { ["EX.ShooterGame.Weapon.MagazineAmmo"] = 3, ["EX.ShooterGame.Weapon.MagazineSize"] = 30 }
        p.stacks = stacks
        p.item = obj("EXInventoryItemInstance", { "EXInventoryItemInstance" }, {
            _outer = p.pc,
            GetStatTagStackCount = function(_, tag) return stacks[tag.TagName.name] or 0 end,
            AddStatTagStack = function(_, tag, n)
                if not opts.clientRejectsWrites or W.role ~= "client" then
                    stacks[tag.TagName.name] = (stacks[tag.TagName.name] or 0) + n
                end
            end,
        })
        return p
    end
    W.me = player(true, "me")
    if opts.withTeammate ~= false then W.mate = player(false, "mate") end

    local function enemy(cls, loc, o)
        o = o or {}
        local mesh = {
            IsValid = function() return true end,
            DoesSocketExist = function(_, n) return n.name == "head" end,
            GetSocketLocation = function() return { X = loc.X, Y = loc.Y, Z = loc.Z + 70 } end,
            GetAllSocketNames = function() return { ForEach = function() end } end,
        }
        local e = obj(cls, { "EXCharacter", "Pawn", "Actor" }, {
            _supers = o.supers, team = o.team or 2,
            K2_GetActorLocation = function() return loc end,
            GetActorUpVector = function() return o.up or { X = 0, Y = 0, Z = 1 } end,
            GetAutoAimLocation = o.auto and function() return o.auto end or nil,
            Mesh = o.noHead and { IsValid = function() return true end, DoesSocketExist = function() return false end } or mesh,
            blocked = o.blocked,
            GetHealthComponent = function()
                return {
                    IsValid = function() return true end,
                    IsDeadOrDying = function() return o.dead == true end,
                    GetHealth = function() return o.dead and 0 or 100 end,
                }
            end,
            GetWeakSpotBodyInstanceLocation = function(self, idx)
                if idx ~= 0 then error("expected index 0") end
                return o.weakSpot or { X = 0, Y = 0, Z = 0 }
            end,
        })
        return e
    end
    W.enemy = enemy

    local cdos = {
        ["/Script/Engine.Default__KismetSystemLibrary"] = {
            IsValid = function() return true end,
            IsStandalone = function() return W.role == "solo" end,
            IsServer = function() return W.role == "solo" or W.role == "host" end,
            -- Line trace against W.blockers ({ box = oriented box, owner = actor }); W.traces counts calls.
            LineTraceSingle = function(_, ctx, a, b, channel, complex, ignore, debug, hit)
                W.traces = (W.traces or 0) + 1
                for _, bl in ipairs(W.blockers or {}) do
                    if Aim.segmentHitsBox(a, b, bl.box, 0) then
                        hit.bBlockingHit = true
                        hit.Location = { X = bl.box.center.X, Y = bl.box.center.Y, Z = bl.box.center.Z }
                        hit.Component = { GetOwner = function() return bl.owner end }
                        return true
                    end
                end
                hit.bBlockingHit = false
                return false
            end,
        },
        ["/Script/EXGame.Default__EXTeamStatics"] = {
            IsValid = function() return true end,
            GetAttitudeBetween = function(_, a, b) return b.team or 2 end,
        },
        ["/Script/Engine.PrimitiveComponent"] = { IsValid = function() return true end },
    }

    W.role = opts.role or "host"

    -- keepDir = true simulates a trainer reload: same mod folder, same running game.
    function W.load(settingsText, keepDir)
        local dir = keepDir and W.dir or tmpDir()
        W.dir = dir
        W.loops = {}
        if settingsText then writeFile(dir .. SEP .. "settings.ini", settingsText) end
        local env = setmetatable({}, { __index = _G })
        env.print = function(s) table.insert(W.log, s) end
        env.FName = FN
        env.FindAllOf = function(c)
            local out = {}
            for _, o in ipairs(W.registry[c] or {}) do if not o._dead then out[#out + 1] = o end end
            if #out == 0 then return nil end
            return out
        end
        env.FindFirstOf = function(c) local l = env.FindAllOf(c); return l and l[1] or nil end
        env.StaticFindObject = function(p) return cdos[p] or W.staticObjects[p] end
        env.StaticConstructObject = function(...) return W.construct(...) end
        if W.wrapHandles then W.wrapHandles(env) end
        env.LoopInGameThreadAfterFrames = function(_, fn) table.insert(W.loops, { kind = "frames", fn = fn }); return #W.loops end
        env.LoopInGameThreadWithDelay = function(ms, fn) table.insert(W.loops, { kind = "delay", ms = ms, fn = fn }); return #W.loops end
        env.LoopAsync = function() error("should not fall back to LoopAsync") end
        env.ExecuteInGameThread = function(fn) fn() end
        W.clock = 0
        env.os = setmetatable({ execute = function(c) W.executed = c end, clock = function() return W.clock end }, { __index = os })
        env.require = require
        local src = assert(readFile(SCRIPTS .. SEP .. "main.lua"))
        local chunk = assert(load(src, "@" .. dir .. SEP .. "Scripts" .. SEP .. "main.lua", "t", env))
        chunk()
        W.aimLoop = W.loops[1].fn
        W.refillLoop = W.loops[2].fn
        W.ioLoop = W.loops[3].fn
    end

    function W.tick(n)
        for _ = 1, (n or 1) do
            W.ioLoop(); W.refillLoop(); W.aimLoop()
        end
    end

    function W.status()
        local t = {}
        for k, v in (readFile(W.dir .. SEP .. "status.ini") or ""):gmatch("([^=\n]+)=([^\n]*)") do t[k] = v end
        return t
    end

    return W
end

local ALL_ON = "infiniteHealth=1\ninfiniteAmmo=1\ninfiniteArmor=1\naimAssist=1\naimFov=10\naimMode=hold\naimHoldKey=RightMouseButton\n"

test("main: keeps headroom under Lua's 200-locals limit (UE4SS adds its own when loading)", function()
    -- v3.9.0 compiled here but failed to load in the game at ~200 top-level locals. Require 25 spare.
    local src = assert(readFile(SCRIPTS .. SEP .. "main.lua"))
    local pad = {}
    for i = 1, 25 do pad[#pad + 1] = "local _pad" .. i .. " = " .. i end
    local fn, err = load(table.concat(pad, "\n") .. "\n" .. src, "=main.lua(padded)", "t")
    truthy(fn, err)
end)

test("main: registers per-frame aim loop and game-thread loops", function()
    local W = makeWorld()
    W.load(ALL_ON)
    eq(#W.loops, 3); eq(W.loops[1].kind, "frames"); eq(W.loops[2].kind, "delay"); eq(W.loops[3].kind, "delay")
end)

test("health/armor: refilled through the game's attribute setter so the HUD updates; teammate untouched", function()
    local W = makeWorld({ role = "host" })
    local calls = {}
    local function asc(p, who)
        return W.obj("EXAbilitySystemComponent", { "EXAbilitySystemComponent" }, {
            GetOwner = function() return p.ps end,
            SetAttributeBaseValueByName = function(_, setName, attr, v)
                calls[#calls + 1] = { who = who, set = setName, attr = attr.name, v = v }
                p.health[attr.name].BaseValue = v; p.health[attr.name].CurrentValue = v
            end })
    end
    asc(W.me, "me"); asc(W.mate, "mate")
    W.load(ALL_ON)
    W.tick(2)
    eq(W.me.health.Health.CurrentValue, 100); eq(W.me.health.Shield.CurrentValue, 50)
    eq(W.mate.health.Health.CurrentValue, 20, "teammate untouched")
    local n = 0
    for _, c in ipairs(calls) do
        eq(c.who, "me")
        eq(c.set, "EXHealthSet")
        n = n + 1
    end
    truthy(n >= 2, "health and shield set through the game")
    -- Full and announced: no more calls every frame.
    local before = #calls
    W.tick(5)
    eq(#calls, before, "no calls while full")
    -- Damage taken somehow: refilled through the setter again.
    W.me.health.Health.CurrentValue = 40
    W.tick(1)
    eq(calls[#calls].attr, "Health"); eq(calls[#calls].v, 100)
end)

test("health: already full in memory -> HUD is nudged once (value changes, then back to full)", function()
    local W = makeWorld({ role = "host" })
    W.me.health.Health = W.attr(100)
    local seen = {}
    W.obj("EXAbilitySystemComponent", { "EXAbilitySystemComponent" }, {
        GetOwner = function() return W.me.ps end,
        SetAttributeBaseValueByName = function(_, setName, attr, v)
            if attr.name == "Health" then seen[#seen + 1] = v end
            W.me.health[attr.name].CurrentValue = v
        end })
    W.load(ALL_ON)
    W.tick(4)
    eq(#seen, 2, "nudge + full")
    truthy(seen[1] < 100); eq(seen[2], 100)
end)

test("revives: count kept (through the game's setter), used counter held, teammate untouched", function()
    local W = makeWorld({ role = "host" })
    W.me.stats.NumResurrectCount = { BaseValue = 0, CurrentValue = 2 }   -- 2 from bonuses
    W.mate.stats.NumResurrectCount = { BaseValue = 0, CurrentValue = 2 }
    W.me.ps.ResurrectionCount = 0
    local calls = {}
    W.obj("EXAbilitySystemComponent", { "EXAbilitySystemComponent" }, {
        GetOwner = function() return W.me.ps end,
        SetAttributeBaseValueByName = function(_, setName, attr, v)
            calls[#calls + 1] = { set = setName, attr = attr.name, v = v }
            local a = W.me.stats[attr.name]
            a.CurrentValue = a.CurrentValue + (v - a.BaseValue); a.BaseValue = v
        end })
    W.load("infiniteRevives=1\n")
    W.tick(2)
    eq(#calls, 0, "nothing to do while the count is full")
    -- A revive is used: the game drops the count and bumps the used counter.
    W.me.stats.NumResurrectCount.BaseValue = -1; W.me.stats.NumResurrectCount.CurrentValue = 1
    W.me.ps.ResurrectionCount = 1
    W.mate.stats.NumResurrectCount.CurrentValue = 1
    W.tick(1)
    eq(W.me.stats.NumResurrectCount.CurrentValue, 2, "count back")
    eq(calls[1].set, "EXRogueLiteAttributeSet"); eq(calls[1].attr, "NumResurrectCount"); eq(calls[1].v, 0)
    eq(W.me.ps.ResurrectionCount, 0, "used counter held")
    eq(W.mate.stats.NumResurrectCount.CurrentValue, 1, "teammate untouched")
    -- Switched off: the game's numbers are left alone again.
    W.load("infiniteRevives=0\n", true)
    W.me.stats.NumResurrectCount.CurrentValue = 1
    W.tick(2)
    eq(W.me.stats.NumResurrectCount.CurrentValue, 1)
end)

test("revives: none to start with -> at least one is kept available", function()
    local W = makeWorld({ role = "host" })
    W.me.stats.NumResurrectCount = { BaseValue = 0, CurrentValue = 0 }
    W.load("infiniteRevives=1\n")
    W.tick(2)
    eq(W.me.stats.NumResurrectCount.CurrentValue, 1)
end)

test("main: host -> refills only this PC's health/armor/ammo, teammate untouched", function()
    local W = makeWorld({ role = "host" })
    W.load(ALL_ON)
    W.tick(2)
    eq(W.me.health.Health.CurrentValue, 100, "my health"); eq(W.me.health.Health.BaseValue, 100)
    eq(W.me.shield.Shield.CurrentValue, 50, "my shield")
    eq(W.me.energy.Energy.CurrentValue, 30, "my energy")
    eq(W.me.stacks["EX.ShooterGame.Weapon.MagazineAmmo"], 30, "my magazine")
    eq(W.mate.health.Health.CurrentValue, 20, "mate health untouched")
    eq(W.mate.shield.Shield.CurrentValue, 5, "mate shield untouched")
    eq(W.mate.energy.Energy.CurrentValue, 1, "mate energy untouched")
    eq(W.mate.stacks["EX.ShooterGame.Weapon.MagazineAmmo"], 3, "mate magazine untouched")
    eq(W.me.weapon.ammo, 12, "my weapon magazine")
    eq(W.mate.weapon.ammo, 4, "mate weapon untouched")
    eq(W.me.stats.FinalReceivedDamageRatio.CurrentValue, -1, "damage taken scaled to zero")
    eq(W.mate.stats.FinalReceivedDamageRatio.CurrentValue, 0, "mate damage untouched")
    eq(W.me.stats.UseAmmoOnFire.CurrentValue, 0); eq(W.mate.stats.UseAmmoOnFire.CurrentValue, 1)
    eq(W.me.pawn.bCanBeDamaged, false); eq(W.mate.pawn.bCanBeDamaged, nil)
    eq(W.status().role, "host")
end)

test("main: client -> health/armor/ammo left alone, status explains why", function()
    local W = makeWorld({ role = "client" })
    W.load(ALL_ON)
    W.tick(2)
    eq(W.me.health.Health.CurrentValue, 20); eq(W.me.stacks["EX.ShooterGame.Weapon.MagazineAmmo"], 3)
    eq(W.me.stats.FinalReceivedDamageRatio.CurrentValue, 0, "no host-only stat changes")
    eq(W.me.weapon.ammo, 4)
    local st = W.status()
    eq(st.role, "client"); truthy(st.notice:find("host"), "notice mentions host")
end)

test("main: solo works like host", function()
    local W = makeWorld({ role = "solo", withTeammate = false })
    W.load(ALL_ON)
    W.tick(2) -- status is written at the start of a tick, so the role shows up one tick later
    eq(W.me.health.Health.CurrentValue, 100); eq(W.status().role, "solo")
end)

test("main: toggles off -> nothing changes, cheat stats restored when turned off", function()
    local W = makeWorld({ role = "host" })
    W.load(ALL_ON)
    W.tick()
    eq(W.me.stats.FinalReceivedDamageRatio.CurrentValue, -1)
    writeFile(W.dir .. SEP .. "settings.ini", "infiniteHealth=0\ninfiniteAmmo=0\ninfiniteArmor=0\naimAssist=0\n")
    W.me.health.Health = W.attr(10); W.me.shield.Shield = W.attr(1); W.me.stacks["EX.ShooterGame.Weapon.MagazineAmmo"] = 2
    W.tick(2)
    eq(W.me.health.Health.CurrentValue, 10); eq(W.me.shield.Shield.CurrentValue, 1)
    eq(W.me.stacks["EX.ShooterGame.Weapon.MagazineAmmo"], 2)
    eq(W.me.stats.FinalReceivedDamageRatio.CurrentValue, 0, "damage stat restored")
    eq(W.me.stats.UseAmmoOnFire.CurrentValue, 1, "ammo stat restored")
    eq(W.me.pawn.bCanBeDamaged, true, "damageable again")
end)

test("main: missing settings.ini is created with defaults (all off)", function()
    local W = makeWorld()
    W.load(nil)
    local s = Settings.fromIni(readFile(W.dir .. SEP .. "settings.ini"))
    eq(s.infiniteHealth, false); eq(s.aimAssist, false)
    W.tick()
    eq(W.me.health.Health.CurrentValue, 20)
end)

test("main: settings persist - values in settings.ini at launch are applied immediately", function()
    local W = makeWorld({ role = "host" })
    W.load("infiniteArmor=1\n")
    W.tick()
    eq(W.me.shield.Shield.CurrentValue, 50); eq(W.me.health.Health.CurrentValue, 20)
end)

local function aimWorld(role, settings)
    local W = makeWorld({ role = role })
    W.near = W.enemy("B_Goblin_C", { X = 1000, Y = 50, Z = 0 })
    W.wide = W.enemy("B_Orc_C", { X = 1000, Y = 400, Z = 0 })   -- ~21.8 deg off
    W.load(settings or ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(6) -- enough slow ticks to refresh the enemy list
    return W
end

local function assertAimedAt(W, pt)
    truthy(W.setRot, "SetControlRotation was called")
    local dx, dy, dz = Aim.rotToDir(W.setRot.Pitch, W.setRot.Yaw)
    local vx, vy, vz = pt.X, pt.Y, pt.Z
    local len = math.sqrt(vx * vx + vy * vy + vz * vz)
    near(dx * vx / len + dy * vy / len + dz * vz / len, 1, 1e-6, "aim direction")
end

test("aim/main: holding key snaps to head of enemy nearest crosshair", function()
    local W = aimWorld("host")
    assertAimedAt(W, { X = 1000, Y = 50, Z = 70 })
    truthy(W.status().aimTarget:find("B_Goblin_C"), "status shows target")
    eq(W.remoteSetRot, nil, "teammate's controller never touched")
end)

test("aim/main: works as client too", function()
    local W = aimWorld("client")
    assertAimedAt(W, { X = 1000, Y = 50, Z = 70 })
end)

test("aim/main: key not held -> no aim in hold mode", function()
    local W = makeWorld()
    W.enemy("B_Goblin_C", { X = 1000, Y = 50, Z = 0 })
    W.load(ALL_ON)
    W.keysDown = {}
    W.tick(6)
    eq(W.setRot, nil)
end)

test("aim/main: always mode aims without key", function()
    local W = makeWorld()
    W.enemy("B_Goblin_C", { X = 1000, Y = 50, Z = 0 })
    W.load(ALL_ON:gsub("aimMode=hold", "aimMode=always"))
    W.keysDown = {}
    W.tick(6)
    assertAimedAt(W, { X = 1000, Y = 50, Z = 70 })
end)

test("aim/main: ignores dead, blocked, and out-of-radius enemies and other players", function()
    local W = makeWorld()
    W.enemy("Dead_C", { X = 1000, Y = 0, Z = 0 }, { dead = true })
    W.enemy("Blocked_C", { X = 1000, Y = 10, Z = 0 }, { blocked = true })
    W.enemy("Wide_C", { X = 1000, Y = 400, Z = 0 })
    -- teammate standing right on the crosshair
    W.mate.pawn.K2_GetActorLocation = function() return { X = 500, Y = 0, Z = 0 } end
    W.load(ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    eq(W.setRot, nil, "nothing valid inside 10 deg")
end)

test("aim/main: prefers game weak spot when available", function()
    local W = makeWorld()
    W.enemy("Dragon_C", { X = 2000, Y = 0, Z = 0 }, { weakSpot = { X = 2100, Y = 30, Z = 250 } })
    W.load(ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    assertAimedAt(W, { X = 2100, Y = 30, Z = 250 })
    truthy(W.status().aimTarget:find("weakspot"))
end)

test("aim/main: weak spot preference can be turned off", function()
    local W = makeWorld()
    W.enemy("Dragon_C", { X = 2000, Y = 0, Z = 0 }, { weakSpot = { X = 2100, Y = 30, Z = 250 } })
    W.load(ALL_ON .. "aimWeakSpot=0\n")
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    assertAimedAt(W, { X = 2000, Y = 0, Z = 70 })
end)

test("aim/main: radius setting is live (raising fov picks up wide enemy)", function()
    local W = makeWorld()
    W.enemy("B_Orc_C", { X = 1000, Y = 400, Z = 0 })
    W.load(ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    eq(W.setRot, nil)
    writeFile(W.dir .. SEP .. "settings.ini", ALL_ON:gsub("aimFov=10", "aimFov=30"))
    W.tick(6)
    assertAimedAt(W, { X = 1000, Y = 400, Z = 70 })
end)

test("main: title-screen DefaultPawn counts as menu, nothing applied, no probe", function()
    local W = makeWorld({ role = "solo", withTeammate = false })
    W.me.pawn._class = "DefaultPawn"
    W.registry["EXHealthSet"] = nil
    W.load(ALL_ON)
    W.tick(12)
    eq(W.status().role, "menu")
    eq(W.me.stats.FinalReceivedDamageRatio.CurrentValue, 0, "nothing applied on placeholder pawn")
    eq(io.open(W.dir .. SEP .. "probe.txt", "rb"), nil, "probe not written yet")
end)

test("main: probe written once in a real level", function()
    local W = makeWorld({ role = "solo", withTeammate = false })
    W.load(ALL_ON)
    W.tick(12)
    truthy(readFile(W.dir .. SEP .. "probe.txt"), "probe.txt exists")
end)

test("main: no GUI exe -> no launch attempt", function()
    local W = makeWorld()
    W.load(ALL_ON)
    eq(W.executed, nil)
end)

test("main: health is refilled every frame, not just every 100 ms", function()
    local W = makeWorld({ role = "host" })
    W.load(ALL_ON)
    W.tick()
    W.me.health.Health = W.attr(30)
    W.aimLoop()
    eq(W.me.health.Health.CurrentValue, 100)
end)

test("aim/main: friendly summons (team, thorn bloom) are never targeted", function()
    local W = makeWorld()
    W.enemy("B_TurretFlower_C", { X = 1000, Y = 0, Z = 0 }, { team = 0 })
    W.enemy("B_ThornBloom_Wall_C", { X = 1000, Y = 5, Z = 0 }, { team = 2, supers = { "EXASThornBloom", "EXASNPC" } })
    W.load(ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    eq(W.setRot, nil, "no friendly target")
    local W2 = makeWorld()
    W2.enemy("B_TurretFlower_C", { X = 1000, Y = 0, Z = 0 }, { team = 0 })
    W2.enemy("B_Goblin_C", { X = 1000, Y = 80, Z = 0 }, { team = 2 })
    W2.load(ALL_ON)
    W2.keysDown = { RightMouseButton = true }
    W2.tick(6)
    assertAimedAt(W2, { X = 1000, Y = 80, Z = 70 })
end)

test("aim/main: locked target behind its shield stays locked for a moment, then is dropped", function()
    local W = makeWorld()
    local e = W.enemy("B_ShieldGoblin_C", { X = 1000, Y = 30, Z = 0 })
    W.enemy("B_Other_C", { X = 1000, Y = 120, Z = 0 })
    W.load(ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    assertAimedAt(W, { X = 1000, Y = 30, Z = 70 })
    e.blocked = true          -- raises its shield
    W.clock = 1.0
    W.setRot = nil
    W.tick()
    assertAimedAt(W, { X = 1000, Y = 30, Z = 70 })
    W.clock = 3.0             -- still hidden after the sticky window
    W.setRot = nil
    W.tick()
    assertAimedAt(W, { X = 1000, Y = 120, Z = 70 })
end)

test("aim/main: game auto-aim point is used when there is no head socket", function()
    local W = makeWorld()
    W.enemy("B_Worm_C", { X = 2000, Y = 0, Z = 0 }, { auto = { X = 2000, Y = 0, Z = 140 }, noHead = true })
    W.load(ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    assertAimedAt(W, { X = 2000, Y = 0, Z = 140 })
    truthy(W.status().aimTarget:find("auto"))
end)

test("aim/main: wall-mounted enemy without head socket is aimed along its own up axis", function()
    local W = makeWorld()
    -- Worm on a wall facing the player: its "up" points back toward the camera (-X).
    W.enemy("B_WallWorm_C", { X = 2000, Y = 0, Z = 0 }, { noHead = true, up = { X = -1, Y = 0, Z = 0 } })
    W.load(ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    assertAimedAt(W, { X = 2000, Y = 0, Z = 0 }) -- straight at it, not above it
    truthy(W.status().aimTarget:find("capsule"))
end)

local function supplyWorld(settings, role)
    local W = makeWorld({ role = role or "host" })
    W.mesh = W.obj("StaticMeshComponent", {}, {
        _primitive = true,
        SetRenderCustomDepth = function(self, on) self.depth = on end,
        SetCustomDepthStencilValue = function(self, v) self.stencil = v end,
    })
    W.crate = W.obj("B_SupplyCrate_C", { "B_SupplyCrate_C", "EXASClayShootingBase", "Actor" }, {
        _supers = { "EXASDynamicPhysicalActor", "Actor" }, _props = { "Mesh" }, Mesh = W.mesh,
        K2_GetActorLocation = function() return { X = 1500, Y = 20, Z = 300 } end,
    })
    W.load(settings)
    return W
end

test("supplies: built-in supplies are targeted and highlighted", function()
    local W = supplyWorld(ALL_ON .. "aimSupplies=1\nhighlightSupplies=1\n")
    W.tick(6)
    eq(W.mesh.depth, true, "outlined"); eq(W.mesh.stencil, 2)
    W.keysDown = { RightMouseButton = true }
    W.camRot = { Pitch = 8, Yaw = 0, Roll = 0 } -- crate is ~3 deg away
    W.ctrlRot = W.camRot
    W.tick(2) -- status.ini is written at the start of a tick
    assertAimedAt(W, { X = 1500, Y = 20, Z = 300 })
    truthy(W.status().aimTarget:find("supply"))
end)

test("ping: key logs the object under the crosshair and changes nothing", function()
    local W = makeWorld()
    local mesh = W.obj("StaticMeshComponent", {}, { _primitive = true,
        SetRenderCustomDepth = function(self, on) self.depth = on end, SetCustomDepthStencilValue = function() end })
    W.obj("B_Mystery_C", { "Actor" }, { _supers = { "EXLevelActor", "Actor" }, _props = { "Mesh" }, Mesh = mesh,
        K2_GetActorLocation = function() return { X = 1500, Y = 20, Z = 300 } end })
    W.load(ALL_ON .. "aimSupplies=1\nhighlightSupplies=1\n")
    W.camRot = { Pitch = math.deg(math.atan(300, 1500)), Yaw = 0, Roll = 0 }
    W.keysDown = { F8 = true }
    W.tick()
    W.keysDown = {}
    W.tick(6)
    local log = readFile(W.dir .. SEP .. "pings.txt") or ""
    truthy(log:find("PING 1: B_Mystery_C | EXLevelActor < Actor"), log)
    truthy(log:find("meshes: StaticMeshComponent"), log)
    truthy(W.status().lastPing:find("B_Mystery_C"))
    eq(mesh.depth, nil, "not highlighted")
    eq(io.open(W.dir .. SEP .. "supply_classes.txt", "rb"), nil, "no supply list written")
    W.keysDown = { RightMouseButton = true }
    W.ctrlRot = W.camRot
    W.tick()
    eq(W.setRot, nil, "not targeted")
end)

test("supplies: not targeted when the option is off, outline removed when highlight is off", function()
    local W = supplyWorld(ALL_ON .. "highlightSupplies=1\n")
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    eq(W.mesh.depth, true)
    eq(W.setRot, nil, "aimSupplies off")
    writeFile(W.dir .. SEP .. "settings.ini", ALL_ON .. "highlightSupplies=0\n")
    W.tick(6)
    eq(W.mesh.depth, false)
end)

test("stats: fire rate, dash and spread apply to my stats only and are restored when turned off", function()
    local W = makeWorld({ role = "client" })
    W.load("fireRate=1\nfireRateMultiplier=3\nnoDashCooldown=1\nnoSpread=1\n")
    W.tick(3)
    local st = W.me.stats
    near(st.FireRateRatio.CurrentValue, 3.12, 1e-9, "1.04 x 3")
    eq(st.FireRateRatio.BaseValue, 1, "base untouched")
    near(st.DashCoolTime.CurrentValue, 0.05, 1e-9); eq(st.RemainDashCount.CurrentValue, 2)
    eq(st.AdditionalSpreadMinMaxRatio.CurrentValue, 0)
    eq(W.me.spread.SpreadAngleMultiplier_Aiming, 0); eq(W.me.spread.SpreadAngleMultiplier_Moving, 0)
    near(W.mate.stats.FireRateRatio.CurrentValue, 1.04, 1e-9, "mate untouched"); eq(W.mate.stats.DashCoolTime.CurrentValue, 5)
    -- a buff changes the game's value while the cheat is on: it becomes the new base for the multiplier
    st.FireRateRatio.CurrentValue = 1.5
    W.tick()
    near(st.FireRateRatio.CurrentValue, 4.5, 1e-9)
    writeFile(W.dir .. SEP .. "settings.ini", "fireRate=0\nnoDashCooldown=0\nnoSpread=0\n")
    W.tick(2)
    near(st.FireRateRatio.CurrentValue, 1.5, 1e-9, "restored to game value")
    eq(st.DashCoolTime.CurrentValue, 5); eq(st.AdditionalSpreadMinMaxRatio.CurrentValue, 1)
    eq(W.me.spread.SpreadAngleMultiplier_Aiming, 0.5); eq(W.me.spread.SpreadAngleMultiplier_Moving, 1.5)
end)

local function lootWorld(role)
    local W = makeWorld({ role = role })
    W.me.pawn.K2_GetActorLocation = function() return { X = 100, Y = 100, Z = 0 } end
    local function item(cls, isa, loc)
        return W.obj(cls, isa, {
            loc = loc,
            K2_GetActorLocation = function(self) return self.loc end,
            K2_TeleportTo = function(self, l) self.loc = { X = l.X, Y = l.Y, Z = l.Z } end,
        })
    end
    W.coin = item("B_Coin_C", { "EXAutoCollectObject" }, { X = 1500, Y = 100, Z = 0 })
    W.far = item("B_Coin_C", { "EXAutoCollectObject" }, { X = 9000, Y = 100, Z = 0 })
    W.exclusive = item("B_Exclusive_C", { "EXAutoCollectObject" }, { X = 600, Y = 100, Z = 0 })
    W.exclusive._supers = { "EXExclusiveAutoCollectObject" }
    W.load("lootMagnet=1\nlootMagnetRadius=30\n")
    W.tick(6)
    return W
end

test("loot magnet: host pulls pickups within the radius to me and widens pickup range", function()
    local W = lootWorld("host")
    eq(W.coin.loc.X, 100, "pulled"); eq(W.far.loc.X, 9000, "outside radius")
    eq(W.exclusive.loc.X, 600, "per-player drops are left alone")
    eq(W.me.stats.ItemDetectionRange.CurrentValue, 3000); eq(W.mate.stats.ItemDetectionRange.CurrentValue, 500)
end)

test("loot magnet: joined -> asks the host to pick up items in range (game's pickup request), moves nothing", function()
    local W = makeWorld({ role = "client" })
    W.me.pawn.K2_GetActorLocation = function() return { X = 100, Y = 100, Z = 0 } end
    local asked = {}
    W.me.pawn.ItemDetectionComponent = W.obj("EXItemDetectionComponent", {}, {
        ServerItemPickup = function(_, item) asked[item] = (asked[item] or 0) + 1 end })
    local function item(cls, loc, supers)
        return W.obj(cls, { "EXAutoCollectObject" }, { _supers = supers, loc = loc,
            K2_GetActorLocation = function(self) return self.loc end,
            K2_TeleportTo = function(self, l) self.loc = { X = l.X, Y = l.Y, Z = l.Z } end })
    end
    local coin = item("B_Coin_C", { X = 1500, Y = 100, Z = 0 })
    local far = item("B_Coin_C", { X = 9000, Y = 100, Z = 0 })
    local excl = item("B_Exclusive_C", { X = 600, Y = 100, Z = 0 }, { "EXExclusiveAutoCollectObject" })
    W.load("lootMagnet=1\nlootMagnetRadius=30\n")
    W.tick(6)
    eq(coin.loc.X, 1500, "not moved (the host owns it)")
    truthy((asked[coin] or 0) >= 1, "pickup requested")
    eq(asked[far], nil, "outside the radius"); eq(asked[excl], nil, "per-player drops left alone")
    -- Something the host refuses (full inventory) is not requested forever.
    W.clock = W.clock + 0
    for _ = 1, 100 do W.clock = W.clock + 0.6; W.tick(1) end
    eq(asked[coin], 6, "gives up after a few requests")
end)

test("main: enemies.txt lists each enemy class once with its aim points", function()
    local W = makeWorld()
    W.enemy("B_Goblin_C", { X = 1000, Y = 0, Z = 0 }, { weakSpot = { X = 1010, Y = 0, Z = 90 } })
    W.enemy("B_Goblin_C", { X = 1200, Y = 0, Z = 0 })
    W.load(ALL_ON)
    W.tick(6)
    local t = readFile(W.dir .. SEP .. "enemies.txt") or ""
    local _, n = t:gsub("B_Goblin_C |", "")
    eq(n, 1); truthy(t:find("weakspot=%(10,0,90%)"), t)
end)

test("settings: new options parse and clamp", function()
    local s = Settings.fromIni("fireRateMultiplier=50\nlootMagnetRadius=1\nnoSpread=1\naimSupplyKey=F7\n")
    eq(s.fireRateMultiplier, 10); eq(s.lootMagnetRadius, 5); eq(s.noSpread, true); eq(s.aimSupplyKey, "F7")
    eq(Settings.defaults().aimSupplyKey, "F8")
end)

test("aim: keepLock keeps a hidden target only for the sticky window", function()
    local lock = { key = 1 }
    eq(Aim.keepLock(lock, {}, 5, true, 0, 10, 10, 1.5), true)
    eq(Aim.keepLock(lock, {}, 5, false, 1, 10, 10, 1.5), true)
    eq(Aim.keepLock(lock, {}, 5, false, 2.4, 10, 10, 1.5), true)
    eq(Aim.keepLock(lock, {}, 5, false, 2.6, 10, 10, 1.5), false)
    eq(lock.key, nil)
    lock.key = 1
    eq(Aim.keepLock(lock, {}, 25, true, 0, 10, 10, 1.5), false, "drifted too far")
end)

test("aim: segment vs oriented box", function()
    local box = { center = { X = 500, Y = 0, Z = 0 }, axes = { { X = 1, Y = 0, Z = 0 }, { X = 0, Y = 1, Z = 0 }, { X = 0, Y = 0, Z = 1 } },
                  min = { X = -5, Y = -40, Z = -60 }, max = { X = 5, Y = 40, Z = 60 } }
    truthy(Aim.segmentHitsBox({ X = 0, Y = 0, Z = 0 }, { X = 1000, Y = 0, Z = 0 }, box), "straight through")
    eq(Aim.segmentHitsBox({ X = 0, Y = 0, Z = 0 }, { X = 1000, Y = 0, Z = 200 }, box), false, "passes over")
    eq(Aim.segmentHitsBox({ X = 0, Y = 0, Z = 0 }, { X = 400, Y = 0, Z = 0 }, box), false, "stops before")
    -- rotated 90 deg around Z: thin side now along Y
    local rot = { center = box.center, axes = { { X = 0, Y = 1, Z = 0 }, { X = -1, Y = 0, Z = 0 }, { X = 0, Y = 0, Z = 1 } },
                  min = box.min, max = box.max }
    eq(Aim.segmentHitsBox({ X = 0, Y = 20, Z = 0 }, { X = 1000, Y = 20, Z = 0 }, rot), false, "beside a rotated plank")
    truthy(Aim.segmentHitsBox({ X = 0, Y = 0, Z = 0 }, { X = 1000, Y = 0, Z = 0 }, rot))
end)

test("aim: facesCamera", function()
    local c = { X = 0, Y = 0, Z = 0 }
    truthy(Aim.facesCamera({ X = -30, Y = 0, Z = 50 }, c, { X = -1000, Y = 0, Z = 0 }), "backpack toward camera")
    eq(Aim.facesCamera({ X = 30, Y = 0, Z = 50 }, c, { X = -1000, Y = 0, Z = 0 }), false, "backpack away")
    truthy(Aim.facesCamera({ X = 5, Y = 0, Z = 120 }, c, { X = -1000, Y = 0, Z = 0 }), "on the head")
end)

local function gearWorld(settings, opts)
    local W = makeWorld()
    W.goblin = W.enemy("B_C1_Goblin_Barrel_C", { X = 1000, Y = 0, Z = 0 },
        { weakSpot = { X = 1000, Y = 0, Z = 40 }, auto = { X = 1000, Y = 0, Z = 70 } })
    local function comp(loc, mn, mx)
        return W.obj("StaticMeshComponent", {}, {
            _primitive = true, loc = loc,
            K2_GetComponentLocation = function(self) return self.loc end,
            GetForwardVector = function() return { X = 1, Y = 0, Z = 0 } end,
            GetRightVector = function() return { X = 0, Y = 1, Z = 0 } end,
            GetUpVector = function() return { X = 0, Y = 0, Z = 1 } end,
            K2_GetComponentScale = function() return { X = 1, Y = 1, Z = 1 } end,
            GetLocalBounds = function(_, a, b)
                a.X, a.Y, a.Z = mn.X, mn.Y, mn.Z
                b.X, b.Y, b.Z = mx.X, mx.Y, mx.Z
            end,
        })
    end
    if opts.barrelX then
        W.barrelMesh = comp({ X = opts.barrelX, Y = 0, Z = 50 }, { X = -15, Y = -15, Z = -20 }, { X = 15, Y = 15, Z = 20 })
        W.barrel = W.obj("B_GoblinBarrel_C", { "EXDamageableParts" }, {
            _supers = { "B_DamageableParts_C", "EXASDamageableParts" }, _props = { "Barrel_SM" }, Barrel_SM = W.barrelMesh,
            bIsBlock = true, bDestroy = false,
            GetAttachParentActor = function() return W.goblin end,
            K2_GetActorLocation = function() return { X = opts.barrelX, Y = 0, Z = 50 } end,
        })
    end
    if opts.shield then
        -- Held shield in front of the goblin, 120 cm tall (covers z -20..100).
        W.shieldMesh = comp({ X = 960, Y = 0, Z = 40 }, { X = -4, Y = -45, Z = -60 }, { X = 4, Y = 45, Z = 60 })
        W.shield = W.obj("B_GoblinShield_C", { "EXDamageableParts" }, {
            _supers = { "B_DamageableParts_C", "EXASDamageableParts" }, _props = { "Shield_SM" }, Shield_SM = W.shieldMesh,
            bIsBlock = true, bDestroy = true, -- like the game: set on intact shields ("destroy when broken")
            GetAttachParentActor = function() return W.goblin end,
            K2_GetActorLocation = function() return { X = 960, Y = 0, Z = 40 } end,
        })
        W.goblin.blocked = true -- the shield also blocks the line-of-sight trace
        if opts.onlyViaGoblin then
            -- In the real game FindAllOf missed the shield part; it is only reachable from the goblin itself.
            for k in pairs({ B_GoblinShield_C = 1, EXDamageableParts = 1, B_DamageableParts_C = 1, EXASDamageableParts = 1 }) do
                W.registry[k] = nil
            end
            if not opts.noComponent then
                W.goblin.ShieldComponent = W.obj("ShieldComponent", {}, { bShieldBroken = opts.broken == true })
            end
            -- Like the game: the shield is in the ChildActor field; GetChildActor() can't be called from Lua.
            W.goblin.B_GoblinShield = W.obj("ChildActorComponent", {}, { ChildActor = W.shield })
            if opts.broken then W.goblin.blocked = false end
        end
    end
    W.load(settings or ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    return W
end

test("aim/main: explosive gear facing me is preferred over the weak spot", function()
    local W = gearWorld(nil, { barrelX = 980 })   -- barrel on the side facing the camera (camera at origin)
    assertAimedAt(W, { X = 980, Y = 0, Z = 50 })
    truthy(W.status().aimTarget:find("explosive"))
end)

test("aim/main: explosive gear on the far side (back turned away) is skipped", function()
    local W = gearWorld(nil, { barrelX = 1020 })
    assertAimedAt(W, { X = 1000, Y = 0, Z = 40 })
    truthy(W.status().aimTarget:find("weakspot"))
end)

test("aim/main: explosive priority can be turned off", function()
    local W = gearWorld(ALL_ON .. "aimExplosives=0\n", { barrelX = 980 })
    assertAimedAt(W, { X = 1000, Y = 0, Z = 40 })
end)

test("aim/main: weak spot behind a shield -> aims over the shield instead", function()
    local W = gearWorld(nil, { shield = true })
    truthy(W.setRot, "still targets the shielded enemy")
    local st = W.status().aimTarget
    truthy(st:find("over shield"), st)
    -- the aim line must clear the shield's top edge (z = 100 at x = 960)
    local dx, dy, dz = Aim.rotToDir(W.setRot.Pitch, W.setRot.Yaw)
    truthy(dz / dx * 956 > 100, "line passes above the shield")
end)

test("aim/main: a goblin's shield is found through the goblin when FindAllOf misses it", function()
    local W = gearWorld(nil, { shield = true, onlyViaGoblin = true })
    local st = W.status().aimTarget
    truthy(st:find("over shield"), st)
    local dx, dy, dz = Aim.rotToDir(W.setRot.Pitch, W.setRot.Yaw)
    truthy(dz / dx * 956 > 100 + 12, "line clears the shield's top edge with margin")
end)

test("aim/main: plain shield goblin (no ShieldComponent, only the B_GoblinShield child actor) is handled", function()
    local W = gearWorld(nil, { shield = true, onlyViaGoblin = true, noComponent = true })
    local st = W.status().aimTarget
    truthy(st:find("over shield"), st)
    truthy(W.status().shieldsTracked:find("^1 %(shield goblins 1, still holding a shield 1%)"), W.status().shieldsTracked)
end)

test("aim/main: a broken shield is ignored; the weak spot is targeted again", function()
    local W = gearWorld(nil, { shield = true, onlyViaGoblin = true, broken = true })
    assertAimedAt(W, { X = 1000, Y = 0, Z = 40 })
end)

test("status: the file is not rewritten when nothing changed within the same second", function()
    local W = makeWorld()
    W.load(ALL_ON)
    W.tick(2)
    -- Start right after a second boundary so both io ticks fall in the same second.
    local t0 = os.time()
    while os.time() == t0 do end
    W.ioLoop()
    local path = W.dir .. SEP .. "status.ini"
    local f1 = io.open(path, "rb"); truthy(f1, "written"); f1:close()
    os.remove(path)
    W.ioLoop()
    local f2 = io.open(path, "rb")
    if f2 then f2:close() end
    eq(f2, nil, "unchanged within the second: not rewritten")
end)

local function axisBox(center, half)
    return { center = center, axes = { { X = 1, Y = 0, Z = 0 }, { X = 0, Y = 1, Z = 0 }, { X = 0, Y = 0, Z = 1 } },
             min = { X = -half.X, Y = -half.Y, Z = -half.Z }, max = half }
end

test("line of fire: a rock in front of a low weak spot -> aims at a part the shot can reach", function()
    local W = makeWorld()
    -- Shroom bomber: the game puts its weak spot down by the legs.
    W.enemy("B_C2_Goblin_Shroom_Bomber_C", { X = 1000, Y = 0, Z = 0 },
        { weakSpot = { X = 1000, Y = 0, Z = -60 }, auto = { X = 1000, Y = 0, Z = 30 } })
    local rock = W.obj("StaticMeshActor", { "Actor" }, {})
    W.blockers = { { box = axisBox({ X = 900, Y = 0, Z = -70 }, { X = 30, Y = 80, Z = 25 }), owner = rock } }
    W.load(ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    local st = W.status()
    truthy(st.aimTarget:find("clear shot"), st.aimTarget)
    truthy(st.lineOfFire:find("weakspot blocked by StaticMeshActor", 1, true), st.lineOfFire)
    local dx, dy, dz = Aim.rotToDir(W.setRot.Pitch, W.setRot.Yaw)
    truthy(dz / dx * 1000 > -20, "aims above the rock")
end)

test("line of fire: another enemy in the way of the weak spot -> target the closer enemy instead", function()
    local W = makeWorld()
    local back = W.enemy("B_Back_C", { X = 2000, Y = 10, Z = 0 }, { weakSpot = { X = 2000, Y = 10, Z = 40 } })
    local front = W.enemy("B_Front_C", { X = 1000, Y = 30, Z = 0 }, { weakSpot = { X = 1000, Y = 30, Z = 50 } })
    W.blockers = { { box = axisBox({ X = 1000, Y = 30, Z = 20 }, { X = 40, Y = 40, Z = 90 }), owner = front } }
    W.load(ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    local st = W.status()
    truthy(st.aimTarget:find("^B_Front_C"), st.aimTarget)
    truthy(st.aimTarget:find("in front of B_Back_C", 1, true), st.aimTarget)
    truthy(st.lineOfFire:find("switched"), st.lineOfFire)
    assertAimedAt(W, { X = 1000, Y = 30, Z = 50 })
    -- It stays on the closer enemy (locked), it does not flip back every frame.
    W.setRot = nil
    W.tick(3)
    assertAimedAt(W, { X = 1000, Y = 30, Z = 50 })
end)

test("aim: segmentHitsCapsule", function()
    local up = { X = 0, Y = 0, Z = 1 }
    local c = { X = 500, Y = 0, Z = 0 }
    local s = Aim.segmentHitsCapsule({ X = 0, Y = 0, Z = 0 }, { X = 1000, Y = 0, Z = 0 }, c, up, 90, 40)
    near(s, 0.5, 0.01)
    eq(Aim.segmentHitsCapsule({ X = 0, Y = 60, Z = 0 }, { X = 1000, Y = 60, Z = 0 }, c, up, 90, 40), nil, "passes beside")
    eq(Aim.segmentHitsCapsule({ X = 0, Y = 0, Z = 150 }, { X = 1000, Y = 0, Z = 150 }, c, up, 90, 40), nil, "passes over")
    truthy(Aim.segmentHitsCapsule({ X = 0, Y = 0, Z = 80 }, { X = 1000, Y = 0, Z = 80 }, c, up, 90, 40), "clips the top")
end)

test("line of fire: enemy body in the way (traces pass through bodies in this game) -> closer enemy", function()
    local W = makeWorld()
    local back = W.enemy("B_Back_C", { X = 2000, Y = 10, Z = 0 }, { weakSpot = { X = 2000, Y = 10, Z = 40 } })
    local front = W.enemy("B_Front_C", { X = 1000, Y = 15, Z = 0 }, { weakSpot = { X = 1000, Y = 15, Z = 50 } })
    local function capsule(h, r)
        return W.obj("CapsuleComponent", {}, { GetScaledCapsuleHalfHeight = function() return h end,
            GetScaledCapsuleRadius = function() return r end })
    end
    back.CapsuleComponent = capsule(90, 40)
    front.CapsuleComponent = capsule(90, 40)
    W.load(ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    truthy(W.status().aimTarget:find("^B_Front_C"), W.status().aimTarget)
    truthy(W.status().aimTarget:find("in front of B_Back_C", 1, true), W.status().aimTarget)
end)

test("line of fire: weak spot covered -> an exposed head comes before an exposed hand", function()
    local W = gearWorld(nil, { shield = true, onlyViaGoblin = true, noComponent = true })
    -- Shield covers z -20..100 in front of the goblin; its head sticks out above, a hand to the side.
    local bones = { { "spine_01", { X = 1000, Y = 0, Z = 40 } }, { "hand_r", { X = 1000, Y = 65, Z = 30 } },
                    { "head", { X = 1000, Y = 0, Z = 140 } } }
    W.goblin.Mesh = { IsValid = function() return true end,
        DoesSocketExist = function() return false end,
        GetNumBones = function() return #bones end,
        GetBoneName = function(_, i) local n = bones[i + 1][1]; return { ToString = function() return n end } end,
        GetSocketLocation = function(_, n) for _, b in ipairs(bones) do if b[1] == n.name then return b[2] end end end }
    W.tick(6)
    local st = W.status()
    truthy(st.aimTarget:find("(head", 1, true), st.aimTarget)
    assertAimedAt(W, { X = 1000, Y = 0, Z = 140 })
end)

test("line of fire: rock hides the weak spot -> exposed head bone before an exposed hand (closer to the weak spot)", function()
    local W = makeWorld()
    local e = W.enemy("B_RockHidden_C", { X = 1000, Y = 0, Z = 0 }, { weakSpot = { X = 1000, Y = 0, Z = 40 } })
    local bones = { { "spine_01", { X = 1000, Y = 0, Z = 40 } }, { "hand_r", { X = 1000, Y = 65, Z = 30 } },
                    { "head", { X = 1000, Y = 0, Z = 140 } } }
    e.Mesh = { IsValid = function() return true end,
        DoesSocketExist = function() return false end,
        GetNumBones = function() return #bones end,
        GetBoneName = function(_, i) local n = bones[i + 1][1]; return { ToString = function() return n end } end,
        GetSocketLocation = function(_, n) for _, b in ipairs(bones) do if b[1] == n.name then return b[2] end end end }
    local rock = W.obj("StaticMeshActor", { "Actor" }, {})
    W.blockers = { { box = axisBox({ X = 900, Y = 0, Z = 25 }, { X = 20, Y = 40, Z = 75 }), owner = rock } }
    W.load(ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    local st = W.status()
    truthy(st.aimTarget:find("head head+clear shot", 1, true), st.aimTarget .. " | " .. st.lineOfFire)
    assertAimedAt(W, { X = 1000, Y = 0, Z = 140 })
end)

test("aim: rotAxes matches Unreal's rotation matrix", function()
    local f, r, u = Aim.rotAxes(0, 90, 0)
    near(f.X, 0, 1e-9); near(f.Y, 1, 1e-9); near(r.X, -1, 1e-9); near(u.Z, 1, 1e-9)
    f = Aim.rotAxes(90, 0, 0)
    near(f.Z, 1, 1e-9)
    local yf, yr, yu = Aim.rotAxes(0, 90, 0)
    local w = Aim.toWorld({ X = 10, Y = 0, Z = 0 }, yf, yr, yu, 5, 0, 0)
    near(w.X, 10, 1e-9); near(w.Y, 5, 1e-9)
end)

test("line of fire: Troll Tamer's damage-proof mask covers the head -> aims at a body part it can hurt", function()
    local W = makeWorld()
    local tamer = W.enemy("B_C2_Troll_Tamer_C", { X = 1000, Y = 0, Z = 0 }, { weakSpot = { X = 1000, Y = 0, Z = 155 } })
    local bones = { { "spine_01", { X = 1000, Y = 0, Z = 90 } }, { "Head", { X = 1000, Y = 0, Z = 155 } },
                    { "Mask", { X = 900, Y = 0, Z = 150 } } }
    tamer.Mesh = { IsValid = function() return true end,
        DoesSocketExist = function() return false end,
        GetNumBones = function() return #bones end,
        GetBoneName = function(_, i) local n = bones[i + 1][1]; return { ToString = function() return n end } end,
        GetSocketLocation = function(_, n) for _, b in ipairs(bones) do if b[1] == n.name then return b[2] end end end,
        -- mask bone unrotated: the 97 cm board lies along X from x = 894 to 991, z = 140..160
        GetSocketRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end }
    W.load(ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    local st = W.status()
    truthy(st.lineOfFire:find("damage-proof", 1, true), st.lineOfFire)
    truthy(st.aimTarget:find("clear shot", 1, true) and not st.aimTarget:find("weakspot"), st.aimTarget)
    -- The aim line passes under the mask board (z 140..160 between x = 894 and 991).
    local dx, dy, dz = Aim.rotToDir(W.setRot.Pitch, W.setRot.Yaw)
    truthy(dz / dx * 991 < 136, "below the mask")
end)

test("line of fire: nothing in the way -> the farther enemy near the crosshair is kept", function()
    local W = makeWorld()
    W.enemy("B_Back_C", { X = 2000, Y = 10, Z = 0 }, { weakSpot = { X = 2000, Y = 10, Z = 40 } })
    W.enemy("B_Front_C", { X = 1000, Y = 300, Z = 0 }, { weakSpot = { X = 1000, Y = 300, Z = 50 } })
    W.load(ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    truthy(W.status().aimTarget:find("^B_Back_C"), W.status().aimTarget)
end)

test("line of fire: nothing in the way -> the weak spot is kept, even down low", function()
    local W = makeWorld()
    W.enemy("B_C2_Goblin_Shroom_Bomber_C", { X = 1000, Y = 0, Z = 0 },
        { weakSpot = { X = 1000, Y = 0, Z = -60 }, auto = { X = 1000, Y = 0, Z = 30 } })
    W.load(ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    truthy(W.status().aimTarget:find("weakspot"), W.status().aimTarget)
    assertAimedAt(W, { X = 1000, Y = 0, Z = -60 })
end)

test("line of fire: a shield too tall to aim over -> a body part sticking out past it", function()
    local W = gearWorld(nil, { shield = true, onlyViaGoblin = true, noComponent = true })
    -- Make the shield 3 m tall: no point over it hits the goblin.
    W.shieldMesh.loc = { X = 960, Y = 0, Z = 100 }
    W.shield.K2_GetActorLocation = function() return { X = 960, Y = 0, Z = 100 } end
    local bones = { { "spine_01", { X = 1000, Y = 0, Z = 40 } }, { "head", { X = 1000, Y = 0, Z = 80 } },
                    { "hand_r", { X = 1000, Y = 65, Z = 30 } }, { "ik_hand_gun", { X = 1000, Y = 200, Z = 30 } } }
    W.goblin.Mesh = { IsValid = function() return true end,
        DoesSocketExist = function() return false end,
        GetNumBones = function() return #bones end,
        GetBoneName = function(_, i) local n = bones[i + 1][1]; return { ToString = function() return n end } end,
        GetSocketLocation = function(_, n)
            for _, b in ipairs(bones) do if b[1] == n.name then return b[2] end end
        end }
    -- shield box: local -4..4 / -45..45 / -150..150 around its mesh center
    W.shieldMesh.GetLocalBounds = function(_, a, b)
        a.X, a.Y, a.Z = -4, -45, -150
        b.X, b.Y, b.Z = 4, 45, 150
    end
    W.tick(6)
    local st = W.status()
    truthy(st.aimTarget:find("body hand_r%+clear shot"), st.aimTarget .. " | " .. st.lineOfFire .. " | " .. st.shieldsTracked)
    assertAimedAt(W, { X = 1000, Y = 65, Z = 30 })
end)

test("aim/main: shield handling can be turned off", function()
    local W = gearWorld(ALL_ON .. "aimOverShields=0\naimLineOfSight=0\n", { shield = true })
    assertAimedAt(W, { X = 1000, Y = 0, Z = 40 })
end)

test("stats: reload and movement speed multiply my values only and restore", function()
    local W = makeWorld({ role = "host" })
    W.me.stats.ReloadSpeedRatio = W.attr(1)
    W.mate.stats.ReloadSpeedRatio = W.attr(1)
    W.me.pawn.CharacterMovement = W.obj("CharacterMovementComponent", {}, { MaxWalkSpeed = 650 })
    W.mate.pawn.CharacterMovement = W.obj("CharacterMovementComponent", {}, { MaxWalkSpeed = 650 })
    W.load("reloadSpeed=1\nreloadSpeedMultiplier=3\nmoveSpeed=1\nmoveSpeedMultiplier=1.5\n")
    W.tick(3)
    eq(W.me.stats.ReloadSpeedRatio.CurrentValue, 3); eq(W.mate.stats.ReloadSpeedRatio.CurrentValue, 1)
    eq(W.me.pawn.CharacterMovement.MaxWalkSpeed, 975); eq(W.mate.pawn.CharacterMovement.MaxWalkSpeed, 650)
    W.me.pawn.CharacterMovement.MaxWalkSpeed = 800 -- game switches to sprint speed
    W.tick()
    eq(W.me.pawn.CharacterMovement.MaxWalkSpeed, 1200)
    writeFile(W.dir .. SEP .. "settings.ini", "reloadSpeed=0\nmoveSpeed=0\n")
    W.tick(2)
    eq(W.me.stats.ReloadSpeedRatio.CurrentValue, 1); eq(W.me.pawn.CharacterMovement.MaxWalkSpeed, 800)
end)

test("highlight: closed loot chests are outlined, opened ones are not", function()
    local W = makeWorld()
    local function chest(opened)
        local mesh = W.obj("StaticMeshComponent", {}, {
            _primitive = true,
            SetRenderCustomDepth = function(self, on) self.depth = on end,
            SetCustomDepthStencilValue = function() end,
        })
        W.obj("EXASMaterialTreasureChest", { "EXASMaterialTreasureChest" }, { _props = { "ChestMesh" }, ChestMesh = mesh, bOpened = opened })
        return mesh
    end
    local closed, open = chest(false), chest(true)
    W.load("highlightChests=1\n")
    W.tick(6)
    eq(closed.depth, true); eq(open.depth, nil)
    writeFile(W.dir .. SEP .. "settings.ini", "highlightChests=0\n")
    W.tick(6)
    eq(closed.depth, false)
end)

test("main: leftover local controller without a pawn doesn't hide the real one", function()
    local W = makeWorld({ role = "host" })
    -- The leftover controller from the previous map is found first.
    local stale = W.obj("EXPlayerController", {}, {
        IsLocalController = function() return true end,
    })
    table.insert(W.registry["PlayerController"], 1, stale)
    W.enemy("B_Goblin_C", { X = 1000, Y = 50, Z = 0 })
    W.load(ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    eq(W.status().role, "host", "not stuck in menu")
    assertAimedAt(W, { X = 1000, Y = 50, Z = 70 })
end)

test("main: reloading the trainer keeps the game's original values (no stacked multipliers)", function()
    local W = makeWorld({ role = "host" })
    W.load("fireRate=1\nfireRateMultiplier=2\nnoSpread=1\n")
    W.tick(3)
    near(W.me.stats.FireRateRatio.CurrentValue, 2.08, 1e-9)
    eq(W.me.spread.SpreadAngleMultiplier_Aiming, 0)
    W.load(nil, true) -- reload in the same game session
    W.tick(3)
    near(W.me.stats.FireRateRatio.CurrentValue, 2.08, 1e-9, "not multiplied twice")
    writeFile(W.dir .. SEP .. "settings.ini", "fireRate=0\nnoSpread=0\n")
    W.tick(2)
    near(W.me.stats.FireRateRatio.CurrentValue, 1.04, 1e-9, "original restored after reload")
    eq(W.me.spread.SpreadAngleMultiplier_Aiming, 0.5, "spread restored after reload")
end)

test("aim: leadPoint leads moving targets and compensates drop", function()
    local cam = { X = 0, Y = 0, Z = 0 }
    local p = Aim.leadPoint(cam, { X = 1000, Y = 0, Z = 0 }, { X = 0, Y = 500, Z = 0 }, 10000, 0)
    near(p.Y, 50, 0.5, "0.1 s of flight -> 50 cm ahead")
    local d = Aim.leadPoint(cam, { X = 2000, Y = 0, Z = 0 }, nil, 10000, -980)
    near(d.Z, 0.5 * 980 * 0.04, 0.5, "aim above for drop")
    local same = Aim.leadPoint(cam, { X = 2000, Y = 0, Z = 0 }, { X = 0, Y = 500, Z = 0 }, nil, -980)
    eq(same.Y, 0, "no bullet speed -> no lead")
end)

test("supplies: flying clays are targeted without marking, and lead is applied", function()
    local W = makeWorld()
    W.me.stats.BulletSpeed = W.attr(10000)
    W.me.stats.BulletGravity = W.attr(0)
    W.clay = W.obj("B_ClayShooting_Stone_C", { "EXASClayShootingBase", "Actor" }, {
        K2_GetActorLocation = function() return { X = 1000, Y = 0, Z = 0 } end,
        GetVelocity = function() return { X = 0, Y = 500, Z = 0 } end,
    })
    W.load(ALL_ON .. "aimSupplies=1\n")
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    assertAimedAt(W, { X = 1000, Y = 50, Z = 0 })
    truthy(W.status().aimTarget:find("B_ClayShooting_Stone_C"))
end)

test("aim/main: lead can be turned off", function()
    local W = makeWorld()
    W.me.stats.BulletSpeed = W.attr(10000)
    W.me.stats.BulletGravity = W.attr(-980)
    local e = W.enemy("B_Goblin_C", { X = 1000, Y = 50, Z = 0 })
    W.load(ALL_ON .. "aimLead=0\n")
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    assertAimedAt(W, { X = 1000, Y = 50, Z = 70 })
end)

test("aim/main: boss weak spot reported under the floor is ignored; head beats the mid-body auto point", function()
    local W = makeWorld()
    W.enemy("B_C1_Ogre_Boss_C", { X = 3000, Y = 0, Z = 0 },
        { weakSpot = { X = 3003, Y = 15, Z = -782 }, auto = { X = 3000, Y = 0, Z = 60 } })
    W.load(ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    assertAimedAt(W, { X = 3000, Y = 0, Z = 70 }) -- head socket (fake head is +70)
    truthy(W.status().aimTarget:find("head"))
end)

test("aim: nearBody", function()
    local c, up = { X = 0, Y = 0, Z = 0 }, { X = 0, Y = 0, Z = 1 }
    truthy(Aim.nearBody({ X = 10, Y = 0, Z = 200 }, c, up, 88, 40), "high weak spot on a goblin with gear")
    eq(Aim.nearBody({ X = 3, Y = 15, Z = -782 }, c, up, 300, 120), false, "under the floor")
    eq(Aim.nearBody({ X = -9201, Y = 5518, Z = -911 }, c, up, 88, 40), false, "far away")
end)

local function guardWorld(settings, guardFirst)
    local W = makeWorld()
    W.main = W.enemy("B_C1_Troll_C", { X = 1000, Y = 0, Z = 0 })
    W.imp = W.enemy("B_ETC_Imp_LifeLine_C", { X = 600, Y = 400, Z = 0 }, { noHead = true })
    local link = W.obj("EXASLifeLineLinkActor", { "EXASLifeLineLinkActor" }, { SourceNPC = W.main, TargetNPC = W.imp })
    if guardFirst then link.SourceNPC, link.TargetNPC = W.imp, W.main end
    W.load(settings or ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    return W
end

test("aim/main: lifeline guard is shot before the enemy it protects", function()
    for _, swapped in ipairs({ false, true }) do
        local W = guardWorld(nil, swapped)
        truthy(W.setRot, "aimed")
        local dx, dy = Aim.rotToDir(W.setRot.Pitch, W.setRot.Yaw)
        truthy(dy > 0.3, "turned toward the imp (swapped=" .. tostring(swapped) .. ")")
        W.tick()
        truthy(W.status().aimTarget:find("B_ETC_Imp_LifeLine_C"))
        truthy(W.status().aimTarget:find("guard of B_C1_Troll_C"))
    end
end)

test("aim/main: once the guard dies the protected enemy is targeted again", function()
    local W = guardWorld()
    W.imp.IsDead = true
    W.tick(6)
    W.setRot = nil
    W.tick()
    assertAimedAt(W, { X = 1000, Y = 0, Z = 70 })
end)

test("aim/main: guard priority can be turned off", function()
    local W = guardWorld(ALL_ON .. "aimGuardsFirst=0\n")
    assertAimedAt(W, { X = 1000, Y = 0, Z = 70 })
end)

test("highlight: secret walls", function()
    local W = makeWorld()
    local mesh = W.obj("StaticMeshComponent", {}, {
        _primitive = true,
        SetRenderCustomDepth = function(self, on) self.depth = on end,
        SetCustomDepthStencilValue = function() end,
    })
    W.obj("B_SecretBreakableWall_C", { "B_SecretBreakableWall_C" }, { _props = { "StaticMeshComponent" }, StaticMeshComponent = mesh })
    W.load("highlightSecretWalls=1\n")
    W.tick(6)
    eq(mesh.depth, true)
end)

local function shroomWorld(settings)
    local W = makeWorld()
    W.colony = { IsValid = function() return true end, bIsBurrowed = false, bIsBurrowing = false }
    W.shroom = W.enemy("B_C2_Spore_Colony_Elpha_C", { X = 1000, Y = 0, Z = 0 })
    W.shroom.SporeColony = W.colony
    W.other = W.enemy("B_C1_Goblin_C", { X = 1000, Y = 120, Z = 0 })
    W.load(settings or ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    return W
end

test("aim/main: ducked mushroom is skipped, targeted again when it pops up", function()
    local W = shroomWorld()
    assertAimedAt(W, { X = 1000, Y = 0, Z = 70 })
    W.colony.bIsBurrowing = true
    W.setRot = nil
    W.tick()
    assertAimedAt(W, { X = 1000, Y = 120, Z = 70 })
    W.colony.bIsBurrowing, W.colony.bIsBurrowed = false, true
    W.setRot = nil
    W.tick()
    assertAimedAt(W, { X = 1000, Y = 120, Z = 70 })
    W.colony.bIsBurrowed = false
    W.keysDown = {} -- release and press again to re-pick
    W.tick()
    W.keysDown = { RightMouseButton = true }
    W.setRot = nil
    W.tick()
    assertAimedAt(W, { X = 1000, Y = 0, Z = 70 })
end)

local function giveHat(W)
    -- Body bones plus the hat orbs on top (prefix ElphaHat), like B_C2_Spore_Colony_Elpha_C.
    local bones = { { "pelvis", { X = 1000, Y = 0, Z = 0 } }, { "ElphaHat01", { X = 1000, Y = 0, Z = 60 } },
                    { "ElphaHat02", { X = 1000, Y = 20, Z = 95 } }, { "ElphaHat03", { X = 1000, Y = -20, Z = 80 } } }
    W.shroom.Mesh = { IsValid = function() return true end,
        DoesSocketExist = function(_, n) return n.name == "head" end,
        GetNumBones = function() return #bones end,
        GetBoneName = function(_, i) local n = bones[i + 1][1]; return { ToString = function() return n end } end,
        GetSocketLocation = function(_, n)
            for _, b in ipairs(bones) do if b[1] == n.name then return b[2] end end
            return { X = 1000, Y = 0, Z = 70 }
        end }
    W.colony.HatBonePrefix = { ToString = function() return "ElphaHat" end }
    W.colony.bHatDestroyed = false
end

test("aim/main: ducked mushroom -> shoots the hat orbs on top (topmost first)", function()
    local W = shroomWorld()
    giveHat(W)
    W.colony.bIsBurrowed = true
    W.setRot = nil
    W.tick(3)
    truthy(W.status().aimTarget:find("hat ElphaHat02"), W.status().aimTarget)
    assertAimedAt(W, { X = 1000, Y = 20, Z = 95 })
end)

test("aim/main: ducked mushroom with its hat broken is skipped", function()
    local W = shroomWorld()
    giveHat(W)
    W.colony.bIsBurrowed = true
    W.colony.bHatDestroyed = true
    W.setRot = nil
    W.tick(3)
    assertAimedAt(W, { X = 1000, Y = 120, Z = 70 })
end)

test("aim/main: top hat orb behind cover -> another hat orb, not the body", function()
    local W = shroomWorld()
    giveHat(W)
    W.colony.bIsBurrowed = true
    -- A ledge hides the top orb (y = 20, z = 95) but not the one at y = -20.
    local ledge = W.obj("StaticMeshActor", { "Actor" }, {})
    W.blockers = { { box = { center = { X = 950, Y = 25, Z = 90 },
        axes = { { X = 1, Y = 0, Z = 0 }, { X = 0, Y = 1, Z = 0 }, { X = 0, Y = 0, Z = 1 } },
        min = { X = -10, Y = -15, Z = -15 }, max = { X = 10, Y = 15, Z = 15 } }, owner = ledge } }
    W.setRot = nil
    W.tick(3)
    truthy(W.status().aimTarget:find("hat ElphaHat03"), W.status().aimTarget)
    assertAimedAt(W, { X = 1000, Y = -20, Z = 80 })
end)

test("aim/main: skipping ducked mushrooms can be turned off", function()
    local W = shroomWorld(ALL_ON .. "aimSkipBurrowed=0\n")
    W.colony.bIsBurrowed = true
    W.setRot = nil
    W.tick()
    assertAimedAt(W, { X = 1000, Y = 0, Z = 70 })
end)

test("aim/main: soul-binding shaman is shot before the monsters it binds", function()
    local W = makeWorld()
    W.troll = W.enemy("B_C1_Troll_SpearMan_C", { X = 1000, Y = 0, Z = 0 })
    W.shaman = W.enemy("B_C1_Goblin_Shaman_Elite_C", { X = 800, Y = -500, Z = 0 })
    W.registry["B_C1_Goblin_Shaman_Elite_C"] = { W.shaman }
    -- UE4SS-style TArray: ForEach(index, element) with element:get()
    W.shaman.SoulBindingMonsters = {
        ForEach = function(_, fn) fn(1, { get = function() return W.troll end }) end,
    }
    W.load(ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(7)
    truthy(W.status().aimTarget:find("guard of B_C1_Troll_SpearMan_C"), W.status().aimTarget)
    truthy(W.status().aimTarget:find("B_C1_Goblin_Shaman_Elite_C"))
    W.shaman.IsDead = true
    W.tick(6)
    W.setRot = nil
    W.tick()
    assertAimedAt(W, { X = 1000, Y = 0, Z = 70 })
    truthy((readFile(W.dir .. SEP .. "enemies.txt") or ""):find("BIND B_C1_Goblin_Shaman_Elite_C protects B_C1_Troll_SpearMan_C"))
end)

test("aim/main: Troll Summoner's shield -> the summoner is shot first, only while the shield is up", function()
    local W = makeWorld()
    W.troll = W.enemy("B_C1_Troll_SpearMan_C", { X = 1000, Y = 0, Z = 0 })
    W.summoner = W.enemy("B_C2_Troll_Summoner_C", { X = 800, Y = -500, Z = 0 }, { supers = { "EXASTrollSummoner" } })
    W.registry["EXASTrollSummoner"] = { W.summoner }
    -- The shield effect actor sits on the shielded troll.
    W.fx = W.obj("B_ReplicatedVFX_Troll_Summoner_Shield_C", { "B_ReplicatedVFX_Troll_Summoner_Shield_C", "Actor" }, {
        GetAttachParentActor = function() return W.troll end,
        K2_GetActorLocation = function() return { X = 1000, Y = 0, Z = 50 } end })
    W.load(ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(7)
    truthy(W.status().aimTarget:find("guard of B_C1_Troll_SpearMan_C"), W.status().aimTarget)
    truthy(W.status().aimTarget:find("B_C2_Troll_Summoner_C"))
    truthy((readFile(W.dir .. SEP .. "enemies.txt") or ""):find("SHIELD B_C2_Troll_Summoner_C protects B_C1_Troll_SpearMan_C"))
    -- Shield gone: back to the troll.
    W.registry["B_ReplicatedVFX_Troll_Summoner_Shield_C"] = nil
    W.tick(6)
    W.keysDown = {}; W.tick()
    W.keysDown = { RightMouseButton = true }
    W.setRot = nil
    W.tick()
    assertAimedAt(W, { X = 1000, Y = 0, Z = 70 })
end)

test("aim/main: summoner shield effect not attached -> the enemy standing in it is the protected one", function()
    local W = makeWorld()
    W.troll = W.enemy("B_C1_Troll_SpearMan_C", { X = 1000, Y = 0, Z = 0 })
    W.summoner = W.enemy("B_C2_Troll_Summoner_C", { X = 800, Y = -500, Z = 0 }, { supers = { "EXASTrollSummoner" } })
    W.registry["EXASTrollSummoner"] = { W.summoner }
    W.obj("B_ReplicatedVFX_Troll_Summoner_Shield_C", { "B_ReplicatedVFX_Troll_Summoner_Shield_C", "Actor" }, {
        K2_GetActorLocation = function() return { X = 1010, Y = 20, Z = 40 } end })
    W.load(ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(7)
    truthy(W.status().aimTarget:find("B_C2_Troll_Summoner_C"), W.status().aimTarget)
end)

test("aim/main: Troll Hunter Elite hiding in a bush (immune) is skipped until it comes out", function()
    local W = makeWorld()
    local hunter = W.enemy("B_C2_Troll_Hunter_Elite_C", { X = 1000, Y = 0, Z = 0 })
    W.enemy("B_C1_Goblin_C", { X = 1000, Y = 120, Z = 0 })
    local ability = W.obj("GA_NPC_Troll_Hunter_Elite_BushAmbush_C", { "GA_NPC_Troll_Hunter_Elite_BushAmbush_C" },
        { _outer = hunter, bAmbushDamageImmune = true })
    W.load(ALL_ON)
    W.keysDown = { RightMouseButton = true }
    W.tick(7)
    assertAimedAt(W, { X = 1000, Y = 120, Z = 70 })
    ability.bAmbushDamageImmune = false
    W.tick(6)
    W.keysDown = {}; W.tick()
    W.keysDown = { RightMouseButton = true }
    W.setRot = nil
    W.tick()
    assertAimedAt(W, { X = 1000, Y = 0, Z = 70 })
end)

test("stats: fire rate cheat also speeds up bow draw", function()
    local W = makeWorld({ role = "host" })
    W.me.stats.ChargeSpeedRate = W.attr(1)
    W.me.stats.ChargeDoneTime = W.attr(0.5)
    W.load("fireRate=1\nfireRateMultiplier=2\n")
    W.tick(3)
    near(W.me.stats.ChargeSpeedRate.CurrentValue, 2, 1e-9)
    near(W.me.stats.ChargeDoneTime.CurrentValue, 0.25, 1e-9)
    writeFile(W.dir .. SEP .. "settings.ini", "fireRate=0\n")
    W.tick(2)
    near(W.me.stats.ChargeSpeedRate.CurrentValue, 1, 1e-9); near(W.me.stats.ChargeDoneTime.CurrentValue, 0.5, 1e-9)
end)

test("ping: skips damage numbers, reports an enemy with its aim details", function()
    local W = makeWorld()
    W.obj("B_DamageFont_Team_Normal_C", { "Actor" }, { _supers = { "EXDamageDisplayActor", "EXPooledActor", "Actor" },
        K2_GetActorLocation = function() return { X = 600, Y = 1, Z = 0 } end })
    local boss = W.enemy("B_C2_Irmin_Boss_C", { X = 1500, Y = 30, Z = 0 }, { weakSpot = { X = 1504, Y = 1, Z = -103 } })
    boss._supers = { "EXASIrminBoss", "EXNPC", "Character", "Pawn", "Actor" }
    W.load(ALL_ON)
    W.keysDown = { F8 = true }
    W.tick()
    W.keysDown = {}
    W.tick()
    local log = readFile(W.dir .. SEP .. "pings.txt") or ""
    truthy(log:find("PING 1: B_C2_Irmin_Boss_C"), log)
    truthy(log:find("weakspot=%(4,%-29,%-103%)"), log)
    truthy(log:find("aim uses weakspot"), log)
    eq(log:find("DamageFont"), nil)
end)

test("ping: nothing near the crosshair is logged too", function()
    local W = makeWorld()
    W.load(ALL_ON)
    W.keysDown = { F8 = true }
    W.tick()
    truthy((readFile(W.dir .. SEP .. "pings.txt") or ""):find("PING 1: nothing within"))
end)

test("supplies: characters are never supply targets", function()
    local W = makeWorld()
    W.flower = W.obj("B_ThornBloom_C", { "EXASClayShootingBase", "Actor" }, { _supers = { "EXASThornBloom", "Character", "Actor" },
        K2_GetActorLocation = function() return { X = 1000, Y = 0, Z = 0 } end })
    W.load(ALL_ON .. "aimSupplies=1\n")
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    eq(W.setRot, nil)
end)

test("aim: oneShotSeconds", function()
    near(Aim.oneShotSeconds(600, 1, 0, 0.05, 0.4), 0.1, 1e-9, "600 rpm")
    near(Aim.oneShotSeconds(220, 10, 0.03, 0.05, 0.4), 60 / 2200 + 0.03, 1e-9, "10x fire rate")
    near(Aim.oneShotSeconds(6000, 1, 0, 0.05, 0.4), 0.05, 1e-9, "very fast clamps to min")
    near(Aim.oneShotSeconds(60, 1, 0, 0.05, 0.4), 0.4, 1e-9, "slow clamps to max")
    near(Aim.oneShotSeconds(nil, nil, 0, 0.05, 0.4), 0.4, 1e-9, "unknown")
end)

local function clayWorld(withTimer)
    local W = makeWorld()
    W.me.stats.FireRate = W.attr(600) -- fallback: 0.1 s per shot (+0.03 margin)
    W.me.weapon.bIsEquipped = true
    W.sinceFire = 5
    if withTimer then
        W.me.weapon.GetTimeSinceLastInteractedWith = function() return W.sinceFire end
    end
    local function clay(y)
        return W.obj("B_ClayShooting_Stone_C", { "EXASClayShootingBase", "Actor" }, {
            K2_GetActorLocation = function() return { X = 1000, Y = y, Z = 0 } end })
    end
    W.a, W.b = clay(10), clay(60)
    W.load(ALL_ON .. "aimSupplies=1\naimLead=0\n")
    W.keysDown = { RightMouseButton = true }
    W.tick(6)
    return W
end

local function aimedY(W)
    local dx, dy = Aim.rotToDir(W.setRot.Pitch, W.setRot.Yaw)
    return dy / dx * 1000
end

-- One frame; `shoot` = the weapon fired since the previous frame.
local function frame(W, shoot)
    W.clock = W.clock + 0.02
    W.sinceFire = shoot and 0.001 or (W.sinceFire + 0.02)
    W.tick()
end

test("clays: taken from any direction, outside the aim radius and behind you", function()
    local W = clayWorld(true)
    -- Replace the clays: one 45 deg to the side (aim radius is 10 deg) and one straight behind the camera.
    local function clayAt(x, y)
        return W.obj("B_ClayShooting_Stone_C", { "EXASClayShootingBase", "Actor" }, {
            K2_GetActorLocation = function() return { X = x, Y = y, Z = 0 } end })
    end
    W.a.removed, W.b.removed = true, true
    W.registry["EXASClayShootingBase"] = nil
    W.registry["B_ClayShooting_Stone_C"] = nil
    local side, behind = clayAt(1000, 1000), clayAt(-1000, 0)
    W.tick(6)
    local dx, dy = Aim.rotToDir(W.setRot.Pitch, W.setRot.Yaw)
    near(math.deg(math.atan(dy, dx)), 45, 0.5, "side clay first (shorter turn)")
    frame(W, false); frame(W, true); frame(W, false)
    dx, dy = Aim.rotToDir(W.setRot.Pitch, W.setRot.Yaw)
    truthy(dx < -0.99, "then the clay behind: " .. dx)
end)

test("clays: come before enemies, even one on the crosshair (clays are only up for a moment)", function()
    local W = clayWorld(true)
    W.a.removed, W.b.removed = true, true
    W.registry["EXASClayShootingBase"] = nil
    W.registry["B_ClayShooting_Stone_C"] = nil
    W.obj("B_ClayShooting_Stone_C", { "EXASClayShootingBase", "Actor" }, {
        K2_GetActorLocation = function() return { X = -1000, Y = 0, Z = 0 } end })
    W.enemy("B_Goblin_C", { X = 1000, Y = 20, Z = 0 })
    W.tick(6)
    truthy(W.status().aimTarget:find("supply"), W.status().aimTarget)
    local dx = Aim.rotToDir(W.setRot.Pitch, W.setRot.Yaw)
    truthy(dx < -0.99, "turned to the clay behind")
end)

test("clays: a clay appearing mid-fight takes over from the locked enemy; back to enemies after", function()
    local W = clayWorld(true)
    W.a.removed, W.b.removed = true, true
    W.registry["EXASClayShootingBase"] = nil
    W.registry["B_ClayShooting_Stone_C"] = nil
    W.enemy("B_Goblin_C", { X = 1000, Y = 20, Z = 0 })
    W.tick(6)
    truthy(W.status().aimTarget:find("B_Goblin_C"), W.status().aimTarget)
    local clay = W.obj("B_ClayShooting_Stone_C", { "EXASClayShootingBase", "Actor" }, {
        K2_GetActorLocation = function() return { X = 0, Y = 1000, Z = 0 } end })
    W.tick(6)
    truthy(W.status().aimTarget:find("supply"), "switched to the clay: " .. W.status().aimTarget)
    W.registry["EXASClayShootingBase"] = nil
    W.registry["B_ClayShooting_Stone_C"] = nil
    clay.IsValid = function() return false end
    W.tick(6)
    truthy(W.status().aimTarget:find("B_Goblin_C"), "back on the enemy: " .. W.status().aimTarget)
end)

test("clays: moves to the next clay as soon as the game reports a shot", function()
    local W = clayWorld(true)
    near(aimedY(W), 10, 0.5, "starts on the clay nearest the crosshair")
    for _ = 1, 5 do frame(W, false) end
    near(aimedY(W), 10, 0.5, "no shot yet: stays")
    frame(W, true)  -- shot fires at clay A
    frame(W, false)
    near(aimedY(W), 60, 0.5, "moved to clay B after one shot")
    frame(W, true)
    frame(W, false)
    near(aimedY(W), 10, 0.5, "both shot: back to the first rather than nothing")
end)

test("clays: a shot fired on the first frame of a new clay doesn't count for it", function()
    local W = clayWorld(true)
    frame(W, true)  -- shot at A (we were on A before) -> move to B
    frame(W, true)  -- this shot left while still aimed at A (first frame on B): B not done yet
    frame(W, false)
    near(aimedY(W), 60, 0.5, "still on B")
end)

test("clays: without shot info, falls back to one shot interval from the fire rate", function()
    local W = clayWorld(false)
    near(aimedY(W), 10, 0.5)
    for _ = 1, 8 do frame(W, false) end -- 0.16 s > 0.13 s
    near(aimedY(W), 60, 0.5)
end)

test("crash guard: destroyed highlighted objects are never asked for their class", function()
    local W = makeWorld()
    local mesh = W.obj("StaticMeshComponent", {}, { _primitive = true,
        SetRenderCustomDepth = function() end, SetCustomDepthStencilValue = function() end })
    local pickup = W.obj("B_Collectable_Gold_C", { "EXAutoCollectObject" }, { _props = { "Mesh" }, Mesh = mesh })
    W.load("highlightSupplies=1\n")
    W.tick(6)
    -- The game destroys it; touching its class now would crash the real game.
    pickup._dead = true
    pickup.GetClass = function() W.touchedDead = true; error("CRASH: class read from a destroyed object") end
    W.registry["EXAutoCollectObject"] = {}
    W.tick(6)
    eq(W.touchedDead, nil, "no class read on the destroyed object")
end)

test("highlight: a launcher missed by the parent-class lookup is still found by its own class", function()
    local W = makeWorld()
    local mesh = W.obj("StaticMeshComponent", {}, { _primitive = true,
        SetRenderCustomDepth = function(self, on) self.depth = on end, SetCustomDepthStencilValue = function() end })
    -- Registered under its own class only (the parent lookup doesn't return it).
    W.obj("B_MaterialGimmick_Tomb_C", { "B_MaterialGimmick_Tomb_C" }, { _supers = { "B_MaterialGimmick_Base_C", "Actor" },
        _props = { "StaticMesh" }, StaticMesh = mesh })
    W.load("highlightSupplies=1\n")
    W.tick(6)
    eq(mesh.depth, true)
    truthy(W.status().highlighted:find("B_MaterialGimmick_Tomb_C x1"), W.status().highlighted)
end)

test("supplies: a clay found by both parent and child class is targeted once", function()
    local W = makeWorld()
    W.obj("B_ClayShooting_Stone_C", { "EXASClayShootingBase", "B_ClayShooting_Stone_C", "Actor" }, {
        K2_GetActorLocation = function() return { X = 1000, Y = 0, Z = 0 } end })
    W.load(ALL_ON .. "aimSupplies=1\n")
    W.tick(7)
    eq(W.status().suppliesInLevel, "1")
end)

test("main: loops start only after everything else in main.lua has run", function()
    local W = makeWorld()
    W.load(ALL_ON)
    local src = readFile(SCRIPTS .. SEP .. "main.lua")
    local lastLoop = 0
    for pos in src:gmatch("()startLoop%(\"") do lastLoop = pos end
    local after = src:sub(lastLoop):gsub("^[^\n]*\n", "")
    for line in after:gmatch("[^\n]+") do
        truthy(line:match("^%s*startLoop%(") or line:match("^%s*%-%-") or line:match("^%s*$"),
            "code after the loops start: " .. line)
    end
end)

local function minimapWorld(settings, opts)
    opts = opts or {}
    local W = makeWorld()
    W.me.pawn.K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end
    W.ctrlRot = { Pitch = 0, Yaw = opts.yaw or -90, Roll = 0 } -- yaw -90: map rotation 0 (world X -> map X)
    W.imageClass = { IsValid = function() return true end }
    W.cdos = W.cdos or {}
    W.staticObjects["/Script/UMG.Image"] = W.imageClass
    W.imported = {}
    W.staticObjects["/Script/Engine.Default__KismetRenderingLibrary"] = {
        IsValid = function() return true end,
        ImportFileAsTexture2D = function(_, ctx, path)
            W.imported[#W.imported + 1] = path
            return { IsValid = function() return true end, path = path }
        end,
    }
    W.tree = { IsValid = function() return true end }
    W.images = {}
    W.overlay = { IsValid = function() return true end, GetOuter = function() return W.tree end,
        AddChildToOverlay = function(_, img)
            img.parent = W.overlay
            return { IsValid = function() return true end,
                SetHorizontalAlignment = function(s, v) img.halign = v end,
                SetVerticalAlignment = function(s, v) img.valign = v end }
        end }
    function W.construct(cls, outer, name)
        assert(cls == W.imageClass and outer == W.tree)
        local img = { IsValid = function(s) return not s.removed end, name = name and name.name, opacity = 1,
            GetFName = function(s) return { ToString = function() return s.name end } end,
            SetDesiredSizeOverride = function(s, v) s.size = v.X end,
            SetBrushSize = function(s, v) s.brush = v.X end,
            SetRenderOpacity = function(s, v) s.opacity = v end,
            SetRenderTranslation = function(s, v) s.x, s.y = v.X, v.Y end,
            SetBrushFromTexture = function(s, t) s.tex = t.path end,
            RemoveFromParent = function(s) s.removed = true end }
        W.images[#W.images + 1] = img
        W.registry["Image"] = W.registry["Image"] or {}
        table.insert(W.registry["Image"], img)
        return img
    end
    -- A leftover minimap from the camp comes first in the object list (it even claims to be in the viewport).
    W.staleOverlay = { IsValid = function() return true end, GetOuter = function() return W.tree end,
        AddChildToOverlay = function() error("drew on the stale camp minimap") end }
    W.staleMinimap = W.obj("W_Minimap_C", { "EXMinimap" }, { MinimapOverlay = W.staleOverlay, bIsMinimapRotating = true,
        IsInViewport = function() return true end })
    W.minimap = W.obj("W_Minimap_C", { "EXMinimap" }, { MinimapOverlay = W.overlay, bIsMinimapRotating = true,
        IsInViewport = function() return true end })
    -- The game's icon for my character lives on the real minimap.
    W.obj("W_MinimapIcon_C", { "W_MinimapIcon_C" }, { IconOwner = W.me.pawn, MinimapRef = W.minimap, MaxHalfSize = 184 })
    -- Like UE4SS: every lookup returns a NEW handle to the same widget.
    local realFind = nil
    W.wrapHandles = function(env)
        realFind = env.FindAllOf
        env.FindAllOf = function(c)
            local l = realFind(c)
            if c == "EXMinimap" and l then
                local out = {}
                for i, o in ipairs(l) do out[i] = setmetatable({}, { __index = o }) end
                return out
            end
            return l
        end
    end
    local function obj(cls, supers, loc)
        local mesh = W.obj("StaticMeshComponent", {}, { _primitive = true,
            SetRenderCustomDepth = function() end, SetCustomDepthStencilValue = function() end })
        return W.obj(cls, { cls, "Actor" }, { _supers = supers, _props = { "M" }, M = mesh,
            K2_GetActorLocation = function() return loc end })
    end
    W.chest = obj("B_MaterialTreasureChest_C", { "EXASMaterialTreasureChest", "Actor" }, { X = 1000, Y = 0, Z = 0 })
    W.secret = obj("B_SecretRoomReward_C", { "B_SuddenEventReward_C", "EXASSuddenEventReward", "Actor" }, { X = 0, Y = 50000, Z = 0 })
    W.registry["EXASMaterialTreasureChest"] = { W.chest }
    W.registry["EXASSuddenEventReward"] = { W.secret }
    W.load(settings)
    return W
end

local function drawn(W)
    local out = {}
    for _, img in ipairs(W.images) do
        if not img.removed and img.opacity == 1 and img.tex then out[#out + 1] = img end
    end
    return out
end

test("minimap: own icons drawn for highlighted objects at the right spot, pinned to the edge when far", function()
    local W = minimapWorld("highlightChests=1\nminimapIcons=1\n")
    W.tick(8)
    eq(#W.images, 64, "pool built once (24 badges + 40 dots), even though every lookup returns a new handle")
    eq(W.images[1].halign, 2); eq(W.images[1].size, 27)
    local d = drawn(W)
    eq(#d, 2, "chest and secret room chest")
    -- nearest first: chest at 10 m straight ahead -> 0.06 px/cm * 1000 = 60 px
    truthy(d[1].tex:find("chest.png"), d[1].tex)
    near(d[1].x, 60, 1e-6); near(d[1].y, 0, 1e-6)
    -- secret chest 500 m away: pinned to the 184 px edge
    truthy(d[2].tex:find("secret_chest.png"))
    near(math.sqrt(d[2].x ^ 2 + d[2].y ^ 2), 184, 1e-6)
    truthy(W.status().minimapIcons:find("^2 drawn"), W.status().minimapIcons)
end)

test("minimap: icons turn with the camera", function()
    local W = minimapWorld("highlightChests=1\nminimapIcons=1\n", { yaw = 0 }) -- rotation -90 deg
    W.tick(8)
    local d = drawn(W)
    near(d[1].x, 0, 1e-6); near(d[1].y, -60, 1e-6)
end)

test("minimap: turning the option off hides the icons; the pool is not rebuilt", function()
    local W = minimapWorld("highlightChests=1\nminimapIcons=1\n")
    W.tick(8)
    writeFile(W.dir .. SEP .. "settings.ini", "highlightChests=1\nminimapIcons=0\n")
    W.tick(8)
    eq(#drawn(W), 0)
    writeFile(W.dir .. SEP .. "settings.ini", "highlightChests=1\nminimapIcons=1\n")
    W.tick(8)
    eq(#drawn(W), 2); eq(#W.images, 64, "same pool")
end)

test("minimap: scale is measured from visible game icons only; hidden icons' stale positions are ignored", function()
    local W = minimapWorld("highlightChests=1\nminimapIcons=1\n")
    local function gameIcon(x, tx, visible)
        local owner = W.obj("B_Enemy_C", { "Actor" }, { K2_GetActorLocation = function() return { X = x, Y = 0, Z = 0 } end })
        W.obj("W_MinimapIcon_C", { "W_MinimapIcon_C" }, { IconOwner = owner, MinimapRef = W.minimap, MaxHalfSize = 184,
            RenderTransform = { Translation = { X = tx, Y = 0 } }, IsVisible = function() return visible end })
    end
    gameIcon(2000, 140, true)    -- 0.07 px/cm: the real scale
    gameIcon(3000, 42, false)    -- dead enemy: stale position, 0.014 px/cm (the bug)
    gameIcon(2500, 25, false)
    gameIcon(1500, 150, true)    -- 0.1 px/cm counts too
    gameIcon(1000, 1, true)      -- too close to the center to measure
    W.tick(8)
    local s = W.status().minimapIcons
    truthy(s:find("scale 0.0700") or s:find("scale 0.1000"), s)
    truthy(not s:find("scale 0.01"), s)
end)

test("minimap: one badge per secret wall; parked (origin) and other-area objects get none", function()
    local W = minimapWorld("highlightSecretWalls=1\nminimapIcons=1\n")
    local function wall(x, y, z)
        local mesh = W.obj("StaticMeshComponent", {}, { _primitive = true,
            SetRenderCustomDepth = function() end, SetCustomDepthStencilValue = function() end })
        return W.obj("B_SecretBreakableWall_C", { "B_SecretBreakableWall_C", "Actor" }, { _props = { "M" }, M = mesh,
            K2_GetActorLocation = function() return { X = x, Y = y, Z = z } end })
    end
    W.registry["B_SecretBreakableWall_C"] = {
        wall(2000, 0, 800), wall(2000, 172, 850),   -- one secret wall built from two pieces
        wall(0, 0, 0), wall(0, 0, 0),               -- unused walls parked at the world origin
        wall(-1500, 0, -110000),                    -- hidden dungeon sublevel far below
        wall(-2000, 0, 0),                          -- another real wall
    }
    W.tick(8)
    local d = drawn(W)
    eq(#d, 2, "two real walls, one badge each")
    near(d[1].x, 0.06 * 2000, 1e-6)
    near(d[2].x, -0.06 * 2000, 1e-6)
end)

test("minimap: dynamic event graves are highlighted with loot chests and get their own badge", function()
    local W = minimapWorld("highlightChests=1\nminimapIcons=1\n")
    local mesh = W.obj("StaticMeshComponent", {}, { _primitive = true,
        SetRenderCustomDepth = function() end, SetCustomDepthStencilValue = function() end })
    local grave = W.obj("BP_DynamicEvent_Grave_C", { "BP_DynamicEvent_Grave_C", "Actor" }, {
        _supers = { "EXASDynamicEventPoint", "EXLevelActor", "Actor" }, _props = { "M" }, M = mesh,
        K2_GetActorLocation = function() return { X = 500, Y = 0, Z = 0 } end })
    W.registry["BP_DynamicEvent_Grave_C"] = { grave }
    W.tick(8)
    local d = drawn(W)
    truthy(d[1].tex:find("event_grave.png"), d[1].tex)
    near(d[1].x, 30, 1e-6)
    -- The event is won: its reward chest appears next to the grave, and the grave's badge goes away.
    local rmesh = W.obj("StaticMeshComponent", {}, { _primitive = true,
        SetRenderCustomDepth = function() end, SetCustomDepthStencilValue = function() end })
    local reward = W.obj("B_SuddenEventReward_Level_01_C", { "B_SuddenEventReward_Level_01_C", "Actor" }, {
        _supers = { "B_SuddenEventReward_C", "EXASSuddenEventReward", "Actor" }, _props = { "M" }, M = rmesh,
        K2_GetActorLocation = function() return { X = 520, Y = 40, Z = 0 } end })
    table.insert(W.registry["EXASSuddenEventReward"], reward)
    W.tick(8)
    for _, img in ipairs(drawn(W)) do
        truthy(not img.tex:find("event_grave.png"), "grave badge removed after the event")
    end
    truthy(W.status().highlighted:find("B_SuddenEventReward_Level_01_C"), W.status().highlighted)
    truthy(not W.status().highlighted:find("BP_DynamicEvent_Grave_C"), W.status().highlighted)
end)

test("highlights: a won grave (completed material) stays hidden even after its reward chest is gone", function()
    local W = minimapWorld("highlightChests=1\nminimapIcons=1\n")
    local done = W.obj("MaterialInstanceConstant", {}, {})
    local pre = W.obj("MaterialInstanceConstant", {}, {})
    local current = W.obj("MaterialInstanceDynamic", {}, { Parent = pre })
    local vmesh = W.obj("StaticMeshComponent", {}, { _primitive = true,
        SetRenderCustomDepth = function() end, SetCustomDepthStencilValue = function() end,
        GetMaterial = function() return current end })
    local grave = W.obj("BP_DynamicEvent_Grave_C", { "BP_DynamicEvent_Grave_C", "Actor" }, {
        _supers = { "EXASDynamicEventPoint", "EXLevelActor", "Actor" }, _props = { "VisualMesh" }, VisualMesh = vmesh,
        CompletedMaterial = done,
        K2_GetActorLocation = function() return { X = 500, Y = 0, Z = 0 } end })
    W.registry["BP_DynamicEvent_Grave_C"] = { grave }
    W.tick(8)
    truthy(W.status().highlighted:find("BP_DynamicEvent_Grave_C"), "not started yet: highlighted")
    current = W.obj("MaterialInstanceDynamic", {}, { Parent = done })   -- event won
    W.tick(8)
    truthy(not W.status().highlighted:find("BP_DynamicEvent_Grave_C"), W.status().highlighted)
    current = W.obj("MaterialInstanceDynamic", {}, { Parent = pre })    -- even if it looked unfinished again
    W.tick(8)
    truthy(not W.status().highlighted:find("BP_DynamicEvent_Grave_C"), "stays hidden")
end)

test("minimap: magnet items as small dots (only within magnet range), under the badges", function()
    local W = minimapWorld("minimapLootDots=1\nlootMagnetRadius=30\n")
    local function pickup(cls, x, supers)
        return W.obj(cls, { cls, "EXAutoCollectObject", "Actor" }, { _supers = supers,
            K2_GetActorLocation = function() return { X = x, Y = 0, Z = 0 } end })
    end
    W.registry["EXAutoCollectObject"] = { pickup("B_Collectable_Gold_C", 1000), pickup("B_Collectable_Gold_C", 5000),
        pickup("B_Exclusive_C", 500, { "EXExclusiveAutoCollectObject" }) }
    W.tick(8)
    local d = drawn(W)
    eq(#d, 1, "the coin 10 m away; not the one 50 m away, not the per-player drop")
    truthy(d[1].tex:find("loot_dot.png"), d[1].tex)
    eq(d[1].size, 9); eq(d[1].brush, 9, "brush size too (the override alone left 32 px dots)"); near(d[1].x, 60, 1e-6)
    truthy(W.status().minimapIcons:find("1 loot dots"), W.status().minimapIcons)
    -- Dot slots were added to the overlay before the badge slots (badges draw on top).
    truthy(W.images[1].name:find("_25$"), W.images[1].name)
end)

test("highlights: an artifact box I opened is dropped; one a teammate opened stays; other dungeons skipped", function()
    local W = minimapWorld("highlightChests=1\nminimapIcons=1\n")
    local function box(x, users, fullName, activated)
        local mesh = W.obj("StaticMeshComponent", {}, { _primitive = true,
            SetRenderCustomDepth = function() end, SetCustomDepthStencilValue = function() end })
        return W.obj("B_LA_Artifact_Box_C", { "B_LA_Artifact_Box_C", "Actor" }, {
            _supers = { "EXASArtifactBox", "Actor" }, _props = { "M" }, M = mesh, bActivated = activated,
            -- UE4SS-style TArray of player states
            UsedPlayer = { ForEach = function(_, fn) for i, u in ipairs(users) do fn(i, { get = function() return u end }) end end },
            GetFullName = function() return fullName end,
            K2_GetActorLocation = function() return { X = x, Y = 0, Z = 0 } end })
    end
    local here = "/Game/Maps/Dungeon/HiddenSubLevel_L_Dungeon_Battle_04_Design_Ch2.L_Dungeon_Battle_04_Design:PersistentLevel.B_LA_Artifact_Box_C"
    local there = "/Game/Maps/Dungeon/HiddenSubLevel_L_Dungeon_Trap_04_Design_Ch2.L_Dungeon_Trap_04_Design:PersistentLevel.B_LA_Artifact_Box_C"
    local mine = box(300, { W.me.ps }, here, true)
    local mates = box(600, { W.mate.ps }, here, true)
    local otherDungeon = box(900, {}, there, false)
    W.registry["EXASArtifactBox"] = { mine, mates, otherDungeon }
    W.tick(8)
    local h = W.status().highlighted
    local _, n = h:gsub("B_LA_Artifact_Box_C", "")
    truthy(h:find("B_LA_Artifact_Box_C x1"), h)
    local badges = 0
    for _, img in ipairs(drawn(W)) do if img.tex:find("artifact_box.png") then badges = badges + 1; near(img.x, 0.06 * 600, 1e-6) end end
    eq(badges, 1, "only the box a teammate opened")
end)

test("minimap: icons left by an earlier trainer version are removed", function()
    local W = minimapWorld("highlightChests=1\nminimapIcons=1\n")
    local stray = { IsValid = function(s) return not s.removed end,
        GetFName = function() return { ToString = function() return "GDT_MinimapIcon_123_4" end } end,
        RemoveFromParent = function(s) s.removed = true end }
    W.registry["Image"] = { stray }
    W.tick(8)
    eq(stray.removed, true)
    truthy(W.images[1].name:find("^GDT_MinimapIcon_"), tostring(W.images[1].name))
    for _, img in ipairs(W.images) do eq(img.removed, nil, "our own icons stay") end
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
