-- Guns & Dragons Trainer (UE4SS Lua mod)
--
-- Only ever touches THIS PC's player:
--   * health / ammo / armor / loot magnet change server-owned state, so they take effect when this PC
--     is the host (or playing solo). As a client in someone else's session they stay inactive.
--   * aim assist only moves this PC's camera, so it works whether you host or join.
--   * spread / fire rate / dash change stats on your own player state. Fully effective as host; as a
--     client they are best effort (the host's game has the final say).
-- Toggles come from settings.ini, written by TrainerGUI.exe. Status goes back to the GUI via status.ini.
--
-- UE 5.7 note: never pass gameplay tag containers (or other structs holding arrays) to game functions
-- from here. UE4SS v4.0.0 crashes the game doing that (that was the "infinite health" crash).

local cfg = require("config")
local Settings = require("gdt_settings")
local Aim = require("gdt_aim")

local VERSION = "3.5.2"
local TAG = "[G&D Trainer] "

local function log(fmt, ...)
    print(TAG .. string.format(fmt, ...) .. "\n")
end

---------------------------------------------------------------------------
-- Paths and files
---------------------------------------------------------------------------

local function detectModDir()
    local ok, src = pcall(function() return debug.getinfo(1, "S").source end)
    if ok and type(src) == "string" then
        src = src:gsub("^@", ""):gsub("/", "\\")
        local dir = src:match("^(.*)\\Scripts\\[^\\]+$")
        if dir then return dir end
    end
    local ok2, dirs = pcall(IterateGameDirectories)
    if ok2 and dirs then
        local win64 = dirs.Game and dirs.Game.Binaries and dirs.Game.Binaries.Win64
        if win64 and win64.__absolute_path then
            return win64.__absolute_path .. "\\ue4ss\\Mods\\GunsDragonsTrainer"
        end
    end
    return "."
end

local MOD_DIR = detectModDir()
local SETTINGS_PATH = MOD_DIR .. "\\settings.ini"
local STATUS_PATH = MOD_DIR .. "\\status.ini"
local PROBE_PATH = MOD_DIR .. "\\probe.txt"
local ENEMIES_PATH = MOD_DIR .. "\\enemies.txt"
local PINGS_PATH = MOD_DIR .. "\\pings.txt"

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end

local function writeFileAtomic(path, text)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    f:write(text)
    f:close()
    os.remove(path)
    return os.rename(tmp, path)
end

local function appendFile(path, text)
    local f = io.open(path, "ab")
    if not f then return end
    f:write(text)
    f:close()
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local S = Settings.defaults()
local lastSettingsText = nil

local status = {
    version = VERSION,
    role = "menu",     -- menu | solo | host | client
    notice = "",
    aimTarget = "",
    aimLoop = "",
    lastMarked = "",
    lastError = "",
}

local function try(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local errorCount = 0
local function reportError(where, err)
    errorCount = errorCount + 1
    status.lastError = string.format("%s: %s", where, tostring(err))
    if errorCount <= 20 or errorCount % 500 == 0 then
        log("error in %s: %s", where, tostring(err))
    end
end

local function valid(obj)
    if obj == nil then return false end
    local ok, res = pcall(function() return obj:IsValid() end)
    return ok and res == true
end

local function addr(obj)
    local ok, a = pcall(function() return obj:GetAddress() end)
    if ok then return a end
    return nil
end

local function isVec(v)
    if v == nil then return false end
    local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end)
    return ok and type(x) == "number" and type(y) == "number" and type(z) == "number"
end

local function vec(v) return { X = v.X, Y = v.Y, Z = v.Z } end

local function near(a, b, dist)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz <= dist * dist
end

local fnameCache = {}
local function fname(s)
    local n = fnameCache[s]
    if n == nil then
        n = FName(s)
        fnameCache[s] = n
    end
    return n
end

local cdoCache = {}
local function cdo(path)
    local o = cdoCache[path]
    if not valid(o) then
        o = StaticFindObject(path)
        cdoCache[path] = o
    end
    return o
end

local function kismetSystem() return cdo("/Script/Engine.Default__KismetSystemLibrary") end
local function teamStatics() return cdo("/Script/EXGame.Default__EXTeamStatics") end
local function primitiveClass() return cdo("/Script/Engine.PrimitiveComponent") end

-- Always check valid() first: reading the class of an object the game has already destroyed and freed
-- crashes inside the engine (FName::ToString), which pcall can't catch. That was the 2026-11-15 crash.
local function className(obj)
    if not valid(obj) then return "?" end
    return try(function() return obj:GetClass():GetFName():ToString() end) or "?"
end

-- Class name plus its parents' names (cached per class name), e.g. { "B_Worm_C", "EXASNPCBase", ... }.
local chainCache = {}
local function classChain(obj)
    if not valid(obj) then return { "?" } end
    local cls = try(function() return obj:GetClass() end)
    local name = cls and try(function() return cls:GetFName():ToString() end) or "?"
    local chain = chainCache[name]
    if chain then return chain end
    chain = { name }
    local cur = cls
    for _ = 1, 12 do
        cur = cur and try(function() return cur:GetSuperStruct() end)
        if not valid(cur) then break end
        chain[#chain + 1] = try(function() return cur:GetFName():ToString() end) or "?"
    end
    chainCache[name] = chain
    return chain
end

local function chainHas(obj, set)
    for _, n in ipairs(classChain(obj)) do
        if set[n] then return true end
    end
    return false
end

local function toSet(list)
    local s = {}
    for _, v in ipairs(list or {}) do s[v] = true end
    return s
end

local IGNORE_CLASSES = toSet(cfg.aim.ignoreClasses)
local now = os.clock

---------------------------------------------------------------------------
-- This PC's player
---------------------------------------------------------------------------

local cachedPC = nil

-- The player controller owned by this PC. On a listen server the host also has controllers for
-- every remote player; IsLocalController() filters those out.
local lastPCScan = -100

local function hasPawn(pc)
    return valid(try(function() return pc.Pawn end))
end

-- Levels can hold a leftover local controller from the previous map (no pawn). Prefer the local
-- controller that actually has a pawn, and re-check about once a second while ours has none.
local function localPC()
    if valid(cachedPC) and hasPawn(cachedPC) then return cachedPC end
    if valid(cachedPC) and os.clock() - lastPCScan < 1 then return cachedPC end
    lastPCScan = os.clock()
    local best = nil
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(pc) and try(function() return pc:IsLocalController() end) == true then
            if hasPawn(pc) then best = pc; break end
            best = best or pc
        end
    end
    cachedPC = best
    return cachedPC
end

local function localPawn(pc)
    local p = pc and try(function() return pc.Pawn end)
    if valid(p) then return p end
    return nil
end

-- Menus/title screen give the player a placeholder pawn; only a real game character counts as "in a level".
local MENU_PAWNS = { DefaultPawn = true, SpectatorPawn = true, EXSpectatorPawn = true }

local function updateRole(pc)
    if not pc then status.role = "menu"; return end
    local pawn = localPawn(pc)
    if not pawn or MENU_PAWNS[className(pawn)] then status.role = "menu"; return end
    local ksl = kismetSystem()
    local standalone = valid(ksl) and try(function() return ksl:IsStandalone(pc) end) == true
    local server = valid(ksl) and try(function() return ksl:IsServer(pc) end) == true
    if standalone then
        status.role = "solo"
    elseif server then
        status.role = "host"
    else
        status.role = "client"
    end
end

local function hasAuthority()
    return status.role == "solo" or status.role == "host"
end

local function inLevel()
    return status.role ~= "menu"
end

-- Addresses of this PC's controller, pawn and player state. Used to decide whether an attribute set or
-- weapon belongs to us (its outer chain leads to one of these).
local function localOwners(pc)
    local owners = {}
    if not pc then return owners end
    local a = addr(pc); if a then owners[a] = true end
    local pawn = localPawn(pc)
    if pawn then owners[addr(pawn)] = true end
    local ps = try(function() return pc.PlayerState end)
    if valid(ps) then owners[addr(ps)] = true end
    return owners
end

local function ownedBy(obj, owners)
    local cur = obj
    for _ = 1, 6 do
        cur = try(function() return cur:GetOuter() end)
        if not valid(cur) then return false end
        local a = addr(cur)
        if a and owners[a] then return true end
    end
    return false
end

-- Cache of our own objects per class, so we don't scan every object in the game 10x a second.
local ownedCache = {}
local function ownedInstances(cls, owners, forceRefresh)
    local list = ownedCache[cls]
    local stale = forceRefresh or list == nil
    if not stale then
        for _, o in ipairs(list) do
            if not valid(o) then stale = true; break end
        end
    end
    if stale then
        list = {}
        if owners then
            for _, o in ipairs(FindAllOf(cls) or {}) do
                if valid(o) and ownedBy(o, owners) then list[#list + 1] = o end
            end
        end
        ownedCache[cls] = list
    end
    return list
end

local function cachedOwned(cls)
    local list = ownedCache[cls] or {}
    local out = {}
    for _, o in ipairs(list) do if valid(o) then out[#out + 1] = o end end
    return out
end

---------------------------------------------------------------------------
-- Attributes (GAS FGameplayAttributeData: BaseValue / CurrentValue)
---------------------------------------------------------------------------

local function readAttr(set, name)
    return try(function()
        local v = set[name].CurrentValue
        if type(v) == "number" then return v end
        return nil
    end)
end

local function writeAttr(set, name, value)
    return try(function()
        local a = set[name]
        a.BaseValue = value
        a.CurrentValue = value
        return true
    end)
end

local function writeCurrent(set, name, value)
    return try(function()
        set[name].CurrentValue = value
        return true
    end)
end

local function topUp(sets, pairsList)
    for _, set in ipairs(sets) do
        for _, pr in ipairs(pairsList) do
            local cur, max = readAttr(set, pr[1]), readAttr(set, pr[2])
            if cur and max and max > 0 and cur < max then
                writeAttr(set, pr[1], max)
            end
        end
    end
end

local function same(a, b)
    return math.abs(a - b) <= 1e-4 * math.max(1, math.abs(b))
end

-- Stat overrides that remember the game's own value, so turning a cheat off puts it back.
-- If the game changes the stat (perks, buffs), that becomes the new natural value.
local overrides = {}
local spreadSaved = {} -- spread data asset address -> { obj, values }

-- The game's own values are also saved to runtime_state.txt, so a trainer reload (Ctrl+R, or the
-- automatic reload after an update) can still restore them instead of multiplying them again.
-- Entries are only trusted inside the same game session (same engine object address).
local STATE_PATH = MOD_DIR .. "\\runtime_state.txt"
local stateDirty = false
local restored = { o = {}, s = {} }

local function sessionId()
    local e = try(function() return FindFirstOf("GameEngine") end)
    return tostring(e and addr(e) or "none")
end

local function loadState()
    local text = readFile(STATE_PATH)
    if not text then return end
    local session = text:match("^session=([^\r\n]*)")
    if session ~= sessionId() then return end
    for kind, a, b, c in text:gmatch("([os])|([^|\r\n]+)|([^|\r\n]+)|([^|\r\n]+)") do
        if kind == "o" then
            restored.o[a] = { natural = tonumber(b), written = tonumber(c) }
        else
            restored.s[a .. "|" .. b] = tonumber(c)
        end
    end
end

local function saveState()
    if not stateDirty then return end
    stateDirty = false
    local lines = { "session=" .. sessionId() }
    for key, st in pairs(overrides) do
        if st.natural ~= nil and st.written ~= nil then
            lines[#lines + 1] = string.format("o|%s|%.17g|%.17g", key, st.natural, st.written)
        end
    end
    for a, saved in pairs(spreadSaved) do
        for f, v in pairs(saved.values) do
            lines[#lines + 1] = string.format("s|%s|%s|%.17g", tostring(a), f, v)
        end
    end
    writeFileAtomic(STATE_PATH, table.concat(lines, "\n") .. "\n")
end

local function readProp(obj, name)
    local v = try(function() return obj[name] end)
    if type(v) == "number" then return v end
    return nil
end

local function writeProp(obj, name, value)
    return try(function() obj[name] = value; return true end)
end

-- kind "attr" = gameplay attribute (CurrentValue), "prop" = plain number property.
local function overrideValue(kind, feature, obj, name, fn)
    local get = kind == "attr" and readAttr or readProp
    local put = kind == "attr" and writeCurrent or writeProp
    local cur = get(obj, name)
    if cur == nil then return end
    local key = kind .. tostring(addr(obj)) .. ":" .. name
    local st = overrides[key]
    if not st then
        st = { obj = obj, name = name, feature = feature, get = get, put = put }
        local r = restored.o[key]
        if r and r.written and same(cur, r.written) then st.natural, st.written = r.natural, r.written end
        overrides[key] = st
    end
    if st.written == nil or not same(cur, st.written) then st.natural = cur; stateDirty = true end
    local want = fn(st.natural)
    if not same(cur, want) then put(obj, name, want) end
    if st.written == nil or not same(st.written, want) then stateDirty = true end
    st.written = want
end

local function override(feature, set, name, fn) overrideValue("attr", feature, set, name, fn) end

local function release(feature)
    for key, st in pairs(overrides) do
        if st.feature == feature then
            if valid(st.obj) and st.written ~= nil and st.natural ~= nil then
                local cur = st.get(st.obj, st.name)
                if cur and same(cur, st.written) then st.put(st.obj, st.name, st.natural) end
            end
            overrides[key] = nil
            stateDirty = true
        end
    end
end

local function statSets()
    return cachedOwned(cfg.stats.set)
end

---------------------------------------------------------------------------
-- Infinite health (host / solo)
---------------------------------------------------------------------------

local undamageablePawn = nil

local function healthFrame()
    if not (S.infiniteHealth and hasAuthority()) then return end
    topUp(cachedOwned("EXHealthSet"), cfg.health.attributes)
end

local function healthTick(pc)
    local pawn = localPawn(pc)
    if pawn and addr(pawn) ~= undamageablePawn then
        try(function() pawn.bCanBeDamaged = false end)
        undamageablePawn = addr(pawn)
    end
    local d = cfg.health.damageTakenStat
    if d then
        for _, set in ipairs(cachedOwned(d.set)) do
            override("health", set, d.name, function() return d.value end)
        end
    end
    healthFrame()
end

local function healthOff(pc)
    release("health")
    if undamageablePawn then
        local pawn = localPawn(pc)
        if pawn and addr(pawn) == undamageablePawn then try(function() pawn.bCanBeDamaged = true end) end
        undamageablePawn = nil
    end
end

---------------------------------------------------------------------------
-- Infinite ammo / armor (host / solo)
---------------------------------------------------------------------------

local function ammoTick()
    for _, w in ipairs(cachedOwned("EXRangedWeaponInstance")) do
        local size = try(function() return w:GetMagazineSize() end)
        local cur = try(function() return w:GetCurrentMagazineAmmo() end)
        if type(size) == "number" and type(cur) == "number" and size > 0 and cur < size then
            try(function() w:AddCurrentMagazineAmmo(size - cur) end)
        end
    end
    -- Older path: magazine stored as stat tag stacks on inventory items.
    local magTag = { TagName = fname(cfg.ammo.magazineAmmoTag) }
    local sizeTag = { TagName = fname(cfg.ammo.magazineSizeTag) }
    for _, item in ipairs(cachedOwned("EXInventoryItemInstance")) do
        local size = try(function() return item:GetStatTagStackCount(sizeTag) end)
        if type(size) == "number" and size > 0 then
            local cur = try(function() return item:GetStatTagStackCount(magTag) end) or 0
            if cur < size then
                try(function() item:AddStatTagStack(magTag, size - cur) end)
            end
        end
    end
    topUp(cachedOwned("EXEnergyMagazineAttributeSet"), cfg.ammo.energyAttributes)
    local u = cfg.ammo.useAmmoStat
    if u then
        for _, set in ipairs(cachedOwned(u.set)) do
            override("ammo", set, u.name, function() return u.value end)
        end
    end
end

local function armorTick()
    topUp(cachedOwned(cfg.armor.set), cfg.armor.attributes)
end

---------------------------------------------------------------------------
-- Weapon / movement stats (best effort as client)
---------------------------------------------------------------------------

local function spreadOn()
    for _, set in ipairs(statSets()) do
        for _, name in ipairs(cfg.stats.spreadZero) do
            override("spread", set, name, function() return 0 end)
        end
    end
    for _, w in ipairs(cachedOwned("EXRangedWeaponInstance")) do
        local sd = try(function() return w.SpreadData end)
        local a = valid(sd) and addr(sd)
        if a then
            local saved = spreadSaved[a]
            if not saved then
                saved = { obj = sd, values = {} }
                for _, f in ipairs(cfg.spreadDataFields) do
                    local v = try(function() return sd[f] end)
                    -- After a reload the asset is already zeroed; take the original from the saved state.
                    local r = restored.s[tostring(a) .. "|" .. f]
                    if type(v) == "number" then saved.values[f] = (v == 0 and r) or v end
                end
                spreadSaved[a] = saved
                stateDirty = true
            end
            for f in pairs(saved.values) do
                if try(function() return sd[f] end) ~= 0 then try(function() sd[f] = 0 end) end
            end
        end
    end
end

local function spreadOff()
    release("spread")
    for a, saved in pairs(spreadSaved) do
        if valid(saved.obj) then
            for f, v in pairs(saved.values) do try(function() saved.obj[f] = v end) end
        end
        spreadSaved[a] = nil
        stateDirty = true
    end
end

local function dashTick()
    local st = cfg.stats
    for _, set in ipairs(statSets()) do
        override("dash", set, st.dashCooldown, function(n) return math.min(n, st.dashCooldownValue) end)
    end
    topUp(statSets(), { st.dashCharges })
end

local function fireRateTick()
    local mult = S.fireRateMultiplier
    for _, set in ipairs(statSets()) do
        override("fireRate", set, cfg.stats.fireRate, function(n) return n * mult end)
        -- Bows: draw faster and reach full draw sooner.
        override("fireRate", set, cfg.stats.chargeSpeed, function(n) return n * mult end)
        override("fireRate", set, cfg.stats.chargeTime, function(n) return n / mult end)
    end
end

local function reloadTick()
    local mult = S.reloadSpeedMultiplier
    for _, set in ipairs(statSets()) do
        override("reload", set, cfg.stats.reloadSpeed, function(n) return n * mult end)
    end
end

local function moveTick(pawn)
    local mc = try(function() return pawn.CharacterMovement end)
    if not valid(mc) then return end
    local mult = S.moveSpeedMultiplier
    overrideValue("prop", "move", mc, "MaxWalkSpeed", function(n) return n * mult end)
end

local function lootRangeTick()
    local range = S.lootMagnetRadius * 100
    for _, set in ipairs(statSets()) do
        override("loot", set, cfg.stats.lootRange, function(n) return math.max(n, range) end)
    end
end

---------------------------------------------------------------------------
-- Supplies: highlight, loot magnet, ping
---------------------------------------------------------------------------

local function supplyClassNames()
    return cfg.supplies.classes or {}
end

local supplies = {}

local function refreshSupplies()
    local list, seen = {}, {}
    for _, cls in ipairs(supplyClassNames()) do
        for _, o in ipairs(FindAllOf(cls) or {}) do
            local a = addr(o)
            -- Characters are never supplies (an old mark could name an enemy or a friendly summon).
            -- The same object can come back from a parent and a child class lookup: keep it once.
            if a and not seen[a] and valid(o) and try(function() return o.bHidden end) ~= true
                and not chainHas(o, { Character = true }) then
                seen[a] = true
                list[#list + 1] = o
            end
        end
    end
    supplies = list
end

-- Outlines use the game's custom-depth outline: SetRenderCustomDepth + stencil on each mesh component.
local componentProps = {} -- class name -> list of property names holding primitive components

local function primitiveComponents(actor)
    local cname = className(actor)
    local names = componentProps[cname]
    local prim = primitiveClass()
    if names == nil then
        names = {}
        local cls = try(function() return actor:GetClass() end)
        for _ = 1, 8 do
            if not valid(cls) then break end
            try(function()
                cls:ForEachProperty(function(p)
                    local ptype = try(function() return p:GetClass():GetFName():ToString() end)
                    if ptype == "ObjectProperty" and #names < 8 then
                        local n = p:GetFName():ToString()
                        local v = try(function() return actor[n] end)
                        if valid(v) and valid(prim) and try(function() return v:IsA(prim) end) == true then
                            names[#names + 1] = n
                        end
                    end
                end)
            end)
            cls = try(function() return cls:GetSuperStruct() end)
        end
        componentProps[cname] = names
    end
    local out = {}
    for _, n in ipairs(names) do
        local c = try(function() return actor[n] end)
        if valid(c) then out[#out + 1] = c end
    end
    if #out == 0 then
        local root = try(function() return actor:K2_GetRootComponent() end)
        if valid(root) and valid(prim) and try(function() return root:IsA(prim) end) == true then out[1] = root end
    end
    return out
end

local highlighted = {} -- address -> actor

local function setOutline(actor, on)
    -- Use the game's own outline switch where a class has one (it may be an empty Blueprint event),
    -- and also put the meshes in the custom-depth outline pass directly.
    pcall(function() actor:K2_EnableOutline(on) end)
    for _, c in ipairs(primitiveComponents(actor)) do
        try(function()
            c:SetRenderCustomDepth(on)
            c:SetCustomDepthStencilValue(on and cfg.supplies.outlineStencil or 0)
        end)
    end
end

-- Minimap icons drawn by the trainer: our own icon images (icons\*.png next to the mod, loaded as textures
-- once) on a fixed pool of image widgets that is added to the game's minimap once. Every frame the pool is
-- moved onto the nearest highlighted objects. The game never creates or hides these, so objects it has no
-- icon for (secret walls) or hides (unexplored rooms) still show.
-- NEVER read or set enum values (e.g. widget Visibility) from here: UE4SS's enum handling is broken on this
-- UE 5.7 build and doing so crashed the game (2026-11-15 01:55). Hide with render opacity instead.
local MM = cfg.minimap
local mm = {
    widget = nil, overlay = nil, pool = {},          -- pool[i] = { img, tex, x, y, shown }
    textures = {},                                   -- file name -> texture
    scale = MM.defaultScale, edge = MM.defaultEdge, calibratedAt = -100,
    drawList = {},                                   -- { actor, icon } for highlighted objects with an icon
    session = tostring(os.time()),
}
local CENTER = 2 -- EHorizontalAlignment / EVerticalAlignment "Center" (plain byte parameters)

local function minimapIconFor(actor)
    for _, e in ipairs(MM.icons) do
        if chainHas(actor, { [e.parent] = true }) then return e.icon end
    end
    return nil
end

-- The minimap on screen. A leftover minimap from the previous map stays alive (v3.5.1 drew on the camp's), so
-- use the one your own player icon belongs to: every game icon widget records its minimap (MinimapRef).
-- Re-checked about once a second.
local function minimapWidget(pc)
    if mm.pick and valid(mm.pick) and now() - (mm.pickedAt or -100) < 1 then return mm.pick end
    mm.pickedAt = now()
    local pawnA = pc and addr(localPawn(pc))
    local found, first = nil, nil
    for _, iw in ipairs(FindAllOf(MM.iconWidgetClass) or {}) do
        if valid(iw) then
            local own = try(function() return iw.IconOwner end)
            local ref = try(function() return iw.MinimapRef end)
            if valid(ref) then
                first = first or ref
                if pawnA and valid(own) and addr(own) == pawnA then found = ref; break end
            end
        end
    end
    if not found then
        for _, w in ipairs(FindAllOf("EXMinimap") or {}) do
            if valid(w) and try(function() return w:IsInViewport() end) == true then found = w; break end
        end
    end
    mm.pick = found or first
    return mm.pick
end

local function iconTexture(name, pc)
    local t = mm.textures[name]
    if valid(t) then return t end
    local lib = cdo("/Script/Engine.Default__KismetRenderingLibrary")
    if not valid(lib) then return nil end
    t = try(function() return lib:ImportFileAsTexture2D(pc, MOD_DIR .. "\\icons\\" .. name) end)
    if valid(t) then mm.textures[name] = t; return t end
    return nil
end

local function dropPool()
    for _, p in ipairs(mm.pool) do
        if valid(p.img) then pcall(function() p.img:RemoveFromParent() end) end
    end
    mm.pool = {}
end

-- Images left on the minimap by an earlier trainer version (hot reload) are removed by their name prefix.
local function removeStrayIcons()
    for _, img in ipairs(FindAllOf("Image") or {}) do
        if valid(img) then
            local n = try(function() return img:GetFName():ToString() end) or ""
            if n:sub(1, #MM.namePrefix) == MM.namePrefix and not n:find(mm.session, 1, true) then
                pcall(function() img:RemoveFromParent() end)
            end
        end
    end
end

local function ensurePool(pc)
    local w = minimapWidget(pc)
    if not w then return false end
    -- Compare addresses: UE4SS hands out a new Lua handle on every lookup, so handles never compare equal
    -- (comparing handles rebuilt the whole pool every frame in v3.5.0).
    local wa = addr(w)
    if wa == mm.widgetAddr and #mm.pool > 0 and valid(mm.overlay) then return true end
    dropPool()
    mm.widget, mm.widgetAddr, mm.overlay = w, wa, try(function() return w.MinimapOverlay end)
    if not valid(mm.overlay) then return false end
    removeStrayIcons()
    local imageClass = cdo("/Script/UMG.Image")
    local tree = try(function() return mm.overlay:GetOuter() end)
    if not valid(imageClass) or not valid(tree) then return false end
    local size = { X = MM.iconSize, Y = MM.iconSize }
    for i = 1, MM.poolSize do
        local name = FName(string.format("%s%s_%d", MM.namePrefix, mm.session, i))
        local img = StaticConstructObject(imageClass, tree, name)
        if not valid(img) then break end
        local slot = mm.overlay:AddChildToOverlay(img)
        if valid(slot) then
            slot:SetHorizontalAlignment(CENTER)
            slot:SetVerticalAlignment(CENTER)
        end
        img:SetDesiredSizeOverride(size)
        img:SetRenderOpacity(0)
        mm.pool[#mm.pool + 1] = { img = img, shown = false }
    end
    log("minimap: %d icon slots ready", #mm.pool)
    return #mm.pool > 0
end

-- Measures the minimap's scale (px per cm) and edge radius from the game's own icons.
local function calibrateMinimap(pawnLoc)
    local ratios = {}
    for _, iw in ipairs(FindAllOf(MM.iconWidgetClass) or {}) do
        if valid(iw) then
            local ref = try(function() return iw.MinimapRef end)
            if not (valid(ref) and addr(ref) == mm.widgetAddr) then goto continue end
            local own = try(function() return iw.IconOwner end)
            local edge = try(function() return iw.MaxHalfSize end)
            if type(edge) == "number" and edge > 20 then mm.edge = edge end
            local ol = valid(own) and try(function() return own:K2_GetActorLocation() end)
            local tr = try(function() local t = iw.RenderTransform.Translation; return { X = t.X, Y = t.Y } end)
            if isVec(ol) and tr and type(tr.X) == "number" then
                local dx, dy = ol.X - pawnLoc.X, ol.Y - pawnLoc.Y
                local d = math.sqrt(dx * dx + dy * dy)
                local t = math.sqrt(tr.X * tr.X + tr.Y * tr.Y)
                if d > 300 and t > 3 and t < mm.edge * 0.9 then ratios[#ratios + 1] = t / d end
            end
        end
        ::continue::
    end
    if #ratios > 0 then
        table.sort(ratios)
        mm.scale = ratios[math.floor((#ratios + 1) / 2)]
    end
end

local function minimapFrame(pc)
    if not S.minimapIcons or #mm.drawList == 0 then
        for _, p in ipairs(mm.pool) do
            if p.shown and valid(p.img) then pcall(function() p.img:SetRenderOpacity(0) end); p.shown = false end
        end
        return
    end
    if not ensurePool(pc) then return end
    local pawn = localPawn(pc)
    local here = pawn and try(function() return pawn:K2_GetActorLocation() end)
    if not isVec(here) then return end
    if now() - mm.calibratedAt > MM.calibrateSeconds then
        mm.calibratedAt = now()
        pcall(calibrateMinimap, here)
    end
    -- The map turns with the camera: rotation -(yaw + 90). A fixed map uses -90.
    local rotating = try(function() return mm.widget.bIsMinimapRotating end) ~= false
    local yaw = 0
    if rotating then
        local cr = try(function() return pc:GetControlRotation() end)
        yaw = cr and cr.Yaw or 0
    end
    local th = math.rad(-(yaw + 90))
    local c, s = math.cos(th), math.sin(th)
    -- Nearest objects first.
    local items = {}
    for _, e in ipairs(mm.drawList) do
        local l = valid(e.actor) and try(function() return e.actor:K2_GetActorLocation() end)
        if isVec(l) then
            local dx, dy = l.X - here.X, l.Y - here.Y
            items[#items + 1] = { dx = dx, dy = dy, d2 = dx * dx + dy * dy, icon = e.icon }
        end
    end
    table.sort(items, function(a, b) return a.d2 < b.d2 end)
    for i, p in ipairs(mm.pool) do
        local it = items[i]
        if it and valid(p.img) then
            local x = mm.scale * (it.dx * c - it.dy * s)
            local y = mm.scale * (it.dx * s + it.dy * c)
            local r = math.sqrt(x * x + y * y)
            if r > mm.edge then x, y = x / r * mm.edge, y / r * mm.edge end -- pinned to the edge like the game's
            if p.tex ~= it.icon then
                local tex = iconTexture(it.icon, pc)
                if tex then pcall(function() p.img:SetBrushFromTexture(tex, false) end); p.tex = it.icon end
                pcall(function() p.img:SetDesiredSizeOverride({ X = MM.iconSize, Y = MM.iconSize }) end)
            end
            if not p.x or math.abs(p.x - x) > 0.25 or math.abs(p.y - y) > 0.25 then
                pcall(function() p.img:SetRenderTranslation({ X = x, Y = y }) end)
                p.x, p.y = x, y
            end
            if not p.shown and p.tex then pcall(function() p.img:SetRenderOpacity(1) end); p.shown = true end
        elseif p.shown and valid(p.img) then
            pcall(function() p.img:SetRenderOpacity(0) end); p.shown = false
        end
    end
end

-- Called after highlights change: which highlighted objects get a minimap icon.
local function syncIcons()
    local list = {}
    if S.minimapIcons then
        for _, o in pairs(highlighted) do
            if valid(o) then
                local icon = minimapIconFor(o)
                if icon then list[#list + 1] = { actor = o, icon = icon } end
            end
        end
    end
    mm.drawList = list
end

local function highlightTick()
    local want = {}
    local function addAll(classes, skip)
        for _, cls in ipairs(classes or {}) do
            for _, o in ipairs(FindAllOf(cls) or {}) do
                if valid(o) and try(function() return o.bHidden end) ~= true and not (skip and skip(o)) then
                    want[#want + 1] = o
                end
            end
        end
    end
    if S.highlightSupplies then
        for _, o in ipairs(supplies) do want[#want + 1] = o end
        addAll(cfg.supplies.highlightPickupClasses)
    end
    if S.highlightSecretWalls then addAll(cfg.secretWalls.classes) end
    if S.highlightChests then
        addAll(cfg.chests.classes, function(o)
            return try(function() return o.bOpened end) == true or try(function() return o.bDisappearing end) == true
        end)
    end
    local keep = {}
    for _, o in ipairs(want) do
        local a = addr(o)
        if a then
            keep[a] = true
            if not highlighted[a] then
                setOutline(o, true)
                highlighted[a] = o
            end
        end
    end
    for a, o in pairs(highlighted) do
        if not keep[a] then
            if valid(o) then setOutline(o, false) end
            highlighted[a] = nil
        end
    end
    syncIcons()
end

local function highlightOff()
    for a, o in pairs(highlighted) do
        if valid(o) then setOutline(o, false) end
        highlighted[a] = nil
    end
    syncIcons()
end

local LOOT_SKIP = cfg.loot.skipClasses or {}
local lootItems = {}
local lootTries = {}

local function refreshLoot()
    local list = {}
    for _, cls in ipairs(cfg.loot.classes) do
        for _, o in ipairs(FindAllOf(cls) or {}) do
            if valid(o) and not chainHas(o, LOOT_SKIP) then list[#list + 1] = o end
        end
    end
    lootItems = list
end

local ZERO_ROT = { Pitch = 0, Yaw = 0, Roll = 0 }

local function lootMagnetTick(pawn)
    local here = try(function() return pawn:K2_GetActorLocation() end)
    if not isVec(here) then return end
    here = vec(here)
    local radius = S.lootMagnetRadius * 100
    for _, item in ipairs(lootItems) do
        if valid(item) and try(function() return item.bHidden end) ~= true
            and try(function() return item.bObtainable end) ~= false then
            local a = addr(item)
            local loc = try(function() return item:K2_GetActorLocation() end)
            if a and isVec(loc) and near(loc, here, radius) and not near(loc, here, 60) then
                lootTries[a] = (lootTries[a] or 0) + 1
                -- Something we can't pick up (full, another player's) stops being pulled after a while.
                if lootTries[a] <= 30 then
                    try(function() item:K2_TeleportTo(here, ZERO_ROT) end)
                end
            end
        end
    end
end


---------------------------------------------------------------------------
-- Aim assist
---------------------------------------------------------------------------

local enemies = {}
local loggedEnemyClasses = {}

local function teamIdOf(p)
    local t = try(function() return p.MyTeamID.TeamID end)
    if type(t) == "number" then return t end
    t = try(function() return p.CurrentTeamID end)
    if type(t) == "number" then return t end
    return nil
end

-- 0 = friendly, 1 = neutral, 2 = hostile (ETeamAttitude), nil = unknown.
local function attitude(myPawn, other)
    local ts = teamStatics()
    if valid(ts) then
        local a = try(function() return ts:GetAttitudeBetween(myPawn, other) end)
        if type(a) == "number" then return a end
    end
    local mine, theirs = teamIdOf(myPawn), teamIdOf(other)
    if mine and theirs then return mine == theirs and 0 or 2 end
    return nil
end

local function isFriendly(myPawn, e)
    if chainHas(e, IGNORE_CLASSES) then return true end
    if try(function() return e.bIsThornBloom end) == true then return true end
    return myPawn ~= nil and attitude(myPawn, e) == 0
end

local function upVector(actor)
    local u = try(function() return actor:GetActorUpVector() end)
    if isVec(u) then return vec(u) end
    return { X = 0, Y = 0, Z = 1 }
end

local function sanePoint(v, actorLoc)
    return isVec(v) and near(v, actorLoc, 1500) and not near(v, { X = 0, Y = 0, Z = 0 }, 1)
end

local headSocketCache = {} -- class name -> socket name or false

local function headSocket(pawn, mesh)
    local cls = className(pawn)
    local sock = headSocketCache[cls]
    if sock == nil then
        sock = false
        for _, name in ipairs(cfg.aim.headSockets) do
            if try(function() return mesh:DoesSocketExist(fname(name)) end) == true then
                sock = name
                break
            end
        end
        headSocketCache[cls] = sock
    end
    return sock
end

---------------------------------------------------------------------------
-- Enemy gear: shields (aim around them) and explosives (aim at them)
---------------------------------------------------------------------------

local PARTS = cfg.parts
local SPHERE_SHIELDS = toSet(PARTS.ignoreShieldClasses)
local shields = {}              -- list of shield actors (held shields, forward shields)
local explosivesByOwner = {}    -- enemy address -> list of explosive part actors
local shieldOwners = {}         -- enemy address -> true when it carries a shield
local loggedPartClasses = {}

local function matchesPattern(obj, patterns)
    for _, n in ipairs(classChain(obj)) do
        local l = n:lower()
        for _, p in ipairs(patterns) do
            if l:find(p, 1, true) then return true end
        end
    end
    return false
end

local function partOwner(p)
    local o = try(function() return p:GetAttachParentActor() end)
    if not valid(o) then o = try(function() return p:GetOwner() end) end
    if valid(o) then return o end
    return nil
end

local shapeCache = {} -- shield address -> { comp, min, max } | false

local function readOut(fn)
    local a, b = {}, {}
    local ok = pcall(fn, a, b)
    if ok and isVec(a) and isVec(b) then return vec(a), vec(b) end
    return nil
end

-- Oriented box of a shield's mesh in world space (see Aim.segmentHitsBox), or nil.
local function shieldBox(s)
    local a = addr(s)
    local sh = shapeCache[a]
    if sh == nil then
        sh = false
        for _, c in ipairs(primitiveComponents(s)) do
            local mn, mx = readOut(function(x, y) c:GetLocalBounds(x, y) end)
            if mn and (mx.X - mn.X) + (mx.Y - mn.Y) + (mx.Z - mn.Z) > 1 then
                sh = { comp = c, min = mn, max = mx }
                break
            end
        end
        shapeCache[a] = sh
    end
    if sh and valid(sh.comp) then
        local c = sh.comp
        local loc = try(function() return c:K2_GetComponentLocation() end)
        local f = try(function() return c:GetForwardVector() end)
        local r = try(function() return c:GetRightVector() end)
        local u = try(function() return c:GetUpVector() end)
        local sc = try(function() return c:K2_GetComponentScale() end)
        if isVec(loc) and isVec(f) and isVec(r) and isVec(u) then
            return { center = vec(loc), axes = { vec(f), vec(r), vec(u) },
                     scale = isVec(sc) and vec(sc) or { X = 1, Y = 1, Z = 1 }, min = sh.min, max = sh.max }
        end
    end
    -- Fallback: world-aligned bounds of the whole actor.
    local o, e = readOut(function(x, y) s:GetActorBounds(false, x, y, false) end)
    if o then
        return { center = o, axes = { { X = 1, Y = 0, Z = 0 }, { X = 0, Y = 1, Z = 0 }, { X = 0, Y = 0, Z = 1 } },
                 min = { X = -e.X, Y = -e.Y, Z = -e.Z }, max = e }
    end
    return nil
end

local function logPartClass(p, owner, kind)
    local cname = className(p)
    if loggedPartClasses[cname] then return end
    loggedPartClasses[cname] = true
    local box = kind == "shield" and shieldBox(p)
    appendFile(ENEMIES_PATH, string.format("PART %s | %s | owner=%s | kind=%s | box=%s\n", cname,
        table.concat(classChain(p), " < ", 2, math.min(4, #classChain(p))), owner and className(owner) or "-", kind,
        box and string.format("(%.0fx%.0fx%.0f)", box.max.X - box.min.X, box.max.Y - box.min.Y, box.max.Z - box.min.Z) or "-"))
end

local function refreshParts()
    local sh, ex, owners = {}, {}, {}
    for _, p in ipairs(FindAllOf("EXDamageableParts") or {}) do
        if valid(p) and try(function() return p.bHidden end) ~= true and try(function() return p.bDestroy end) ~= true then
            local owner = partOwner(p)
            local oa = owner and addr(owner)
            local kind = "other"
            if matchesPattern(p, PARTS.explosivePatterns) then
                kind = "explosive"
                if oa then ex[oa] = ex[oa] or {}; table.insert(ex[oa], p) end
            elseif try(function() return p.bIsBlock end) == true then
                kind = "shield"
                sh[#sh + 1] = p
                if oa then owners[oa] = true end
            end
            if cfg.writeProbe then pcall(logPartClass, p, owner, kind) end
        end
    end
    for _, s in ipairs(FindAllOf("EXShieldActor") or {}) do
        if valid(s) and try(function() return s.bHidden end) ~= true and not chainHas(s, SPHERE_SHIELDS) then
            sh[#sh + 1] = s
            local owner = partOwner(s)
            if owner then owners[addr(owner)] = true end
            if cfg.writeProbe then pcall(logPartClass, s, owner, "shield") end
        end
    end
    shields, explosivesByOwner, shieldOwners = sh, ex, owners
end

-- Lifeline guards: protected enemy address -> guard actor (alive guards only).
local guardOf = {}
local loggedLinks = {}

local function refreshGuards()
    local map = {}
    for _, l in ipairs(FindAllOf(cfg.guards.linkClass) or {}) do
        if valid(l) then
            local a = try(function() return l.SourceNPC end)
            local b = try(function() return l.TargetNPC end)
            if valid(a) and valid(b) then
                local guard, protected = b, a
                if matchesPattern(a, cfg.guards.guardPatterns) and not matchesPattern(b, cfg.guards.guardPatterns) then
                    guard, protected = a, b
                end
                if cfg.writeProbe then
                    local k = className(a) .. ">" .. className(b)
                    if not loggedLinks[k] then
                        loggedLinks[k] = true
                        appendFile(ENEMIES_PATH, string.format("LINK source=%s target=%s | guard=%s\n",
                            className(a), className(b), className(guard)))
                    end
                end
                local pa = addr(protected)
                if pa and try(function() return guard.IsDead end) ~= true then map[pa] = guard end
            end
        end
    end
    -- Binders (soul-binding shamans): every monster on their list is protected by them.
    for _, b in ipairs(cfg.guards.binders or {}) do
        for _, holder in ipairs(FindAllOf(b.class) or {}) do
            if valid(holder) and try(function() return holder.IsDead end) ~= true then
                local bound = {}
                pcall(function()
                    local list = holder[b.listProp]
                    if type(list) == "table" and list.ForEach == nil then
                        for _, m in ipairs(list) do bound[#bound + 1] = m end
                    else
                        list:ForEach(function(_, elem) bound[#bound + 1] = elem:get() end)
                    end
                end)
                for _, m in ipairs(bound) do
                    local ma = valid(m) and addr(m)
                    if ma and ma ~= addr(holder) and not map[ma] then
                        map[ma] = holder
                        if cfg.writeProbe then
                            local k = className(holder) .. ">" .. className(m)
                            if not loggedLinks[k] then
                                loggedLinks[k] = true
                                appendFile(ENEMIES_PATH, string.format("BIND %s protects %s\n", className(holder), className(m)))
                            end
                        end
                    end
                end
            end
        end
    end
    guardOf = map
end

-- Is the line from the camera to `point` blocked by any shield near the target?
local function blockedByShield(cam, point, targetLoc)
    for _, s in ipairs(shields) do
        if valid(s) then
            local sl = try(function() return s:K2_GetActorLocation() end)
            if isVec(sl) and near(sl, targetLoc, PARTS.shieldSearchRadius) then
                local box = shieldBox(s)
                if box and Aim.segmentHitsBox(cam, point, box, 3) then return true end
            end
        end
    end
    return false
end

local function partCenter(p)
    for _, c in ipairs(primitiveComponents(p)) do
        local v = try(function() return c:K2_GetComponentLocation() end)
        if isVec(v) then return vec(v) end
    end
    local v = try(function() return p:K2_GetActorLocation() end)
    if isVec(v) then return vec(v) end
    return nil
end

-- Aim points on an enemy, best first: explosive gear in clean view, the game's weak spot, the game's own
-- auto-aim point, a head socket, and the upper part of the capsule along the enemy's own up axis
-- (so wall-mounted enemies work).
local function aimPoints(pawn, actorLoc, cam)
    local pts = {}
    if S.aimExplosives and cam then
        for _, p in ipairs(explosivesByOwner[addr(pawn)] or {}) do
            if valid(p) and try(function() return p.bDestroy end) ~= true then
                local e = partCenter(p)
                if e and near(e, actorLoc, 1500) and Aim.facesCamera(e, actorLoc, cam, PARTS.explosiveCenterRadius) then
                    pts[#pts + 1] = { point = e, kind = "explosive" }
                end
            end
        end
    end
    local half, radius = 88, 40
    local cap = try(function() return pawn.CapsuleComponent end)
    if valid(cap) then
        local h = try(function() return cap:GetScaledCapsuleHalfHeight() end)
        if type(h) == "number" then half = h end
        local r = try(function() return cap:GetScaledCapsuleRadius() end)
        if type(r) == "number" then radius = r end
    end
    local up = upVector(pawn)
    if S.aimWeakSpot then
        local w = try(function() return pawn:GetWeakSpotBodyInstanceLocation(0) end)
        -- The game sometimes reports a weak spot far outside the body (the ogre boss gave one 7.8 m
        -- under its feet); only trust points within reach of the enemy's own capsule.
        if sanePoint(w, actorLoc) and Aim.nearBody(vec(w), actorLoc, up, half, radius) then
            pts[#pts + 1] = { point = vec(w), kind = "weakspot" }
        end
    end
    -- Head socket before the game's auto-aim point: on big bosses the auto-aim point is mid-body.
    local mesh = try(function() return pawn.Mesh end)
    if valid(mesh) then
        local sock = headSocket(pawn, mesh)
        if sock then
            local v = try(function() return mesh:GetSocketLocation(fname(sock)) end)
            if isVec(v) then pts[#pts + 1] = { point = vec(v), kind = "head" } end
        end
    end
    local a = try(function() return pawn:GetAutoAimLocation(true, false) end)
    if sanePoint(a, actorLoc) then pts[#pts + 1] = { point = vec(a), kind = "auto" } end
    local k = half * cfg.aim.headHeightFraction
    pts[#pts + 1] = { point = { X = actorLoc.X + up.X * k, Y = actorLoc.Y + up.Y * k, Z = actorLoc.Z + up.Z * k }, kind = "capsule" }
    return pts
end

-- Picks the aim point. With shields around, the first point the camera can see past them wins; if a shield
-- covers them all, the body/head point is raised along the enemy's up axis until the line clears the shield.
local function aimPoint(pawn, actorLoc, cam)
    local pts = aimPoints(pawn, actorLoc, cam)
    if not (cam and S.aimOverShields and #shields > 0) then return pts[1].point, pts[1].kind end
    for _, p in ipairs(pts) do
        if not blockedByShield(cam, p.point, actorLoc) then return p.point, p.kind end
    end
    local base = pts[#pts]
    for _, p in ipairs(pts) do
        if p.kind ~= "explosive" and p.kind ~= "weakspot" then base = p; break end
    end
    local up = upVector(pawn)
    for h = PARTS.overShieldStep, PARTS.overShieldMax, PARTS.overShieldStep do
        local q = { X = base.point.X + up.X * h, Y = base.point.Y + up.Y * h, Z = base.point.Z + up.Z * h }
        if not blockedByShield(cam, q, actorLoc) then return q, base.kind .. "+over shield" end
    end
    return pts[1].point, pts[1].kind
end

local function isAlive(pawn)
    if try(function() return pawn.IsDead end) == true then return false end
    local hc = try(function() return pawn:GetHealthComponent() end)
    if valid(hc) then
        if try(function() return hc:IsDeadOrDying() end) == true then return false end
        local hp = try(function() return hc:GetHealth() end)
        if type(hp) == "number" and hp <= 0 then return false end
    end
    if try(function() return pawn.bHidden end) == true then return false end
    return true
end

-- Ducked mushroom (spore colony) enemies: damage is blocked, so they aren't worth aiming at.
local noBurrowClass = {} -- class name -> true when the class has no spore colony component

local function isBurrowed(pawn)
    local cname = className(pawn)
    if noBurrowClass[cname] then return false end
    local comp = try(function() return pawn:GetSporeColony() end)
    if not valid(comp) then comp = try(function() return pawn[cfg.burrow.componentProp] end) end
    if not valid(comp) then
        -- Remember non-mushroom classes; a mushroom checked right as it spawns may not have it yet.
        if not chainHas(pawn, { EXASSporeColonyElpha = true }) then noBurrowClass[cname] = true end
        return false
    end
    for _, f in ipairs(cfg.burrow.flags) do
        if try(function() return comp[f] end) == true then return true end
    end
    return false
end

-- One line per enemy class seen, so aim points can be checked after a session (enemies.txt).
local function logEnemyClass(e, myPawn)
    local cname = className(e)
    if loggedEnemyClasses[cname] then return end
    loggedEnemyClasses[cname] = true
    local loc = try(function() return e:K2_GetActorLocation() end)
    if not isVec(loc) then return end
    loc = vec(loc)
    local function rel(v)
        if not isVec(v) then return "-" end
        return string.format("(%.0f,%.0f,%.0f)", v.X - loc.X, v.Y - loc.Y, v.Z - loc.Z)
    end
    local up = upVector(e)
    local line = string.format("%s | %s | attitude=%s team=%s | up=(%.2f,%.2f,%.2f) | weakspot=%s auto=%s autoAdj=%s | picked=%s\n",
        cname, table.concat(classChain(e), " < ", 2, math.min(5, #classChain(e))),
        tostring(myPawn and attitude(myPawn, e)), tostring(teamIdOf(e)), up.X, up.Y, up.Z,
        rel(try(function() return e:GetWeakSpotBodyInstanceLocation(0) end)),
        rel(try(function() return e:GetAutoAimLocation(true, false) end)),
        rel(try(function() return e:GetAutoAimAdjustLocation() end)),
        select(2, aimPoint(e, loc)))
    appendFile(ENEMIES_PATH, line)
end

local function refreshEnemies(pc)
    local myPawn = localPawn(pc)
    local players = {}
    for _, p in ipairs(FindAllOf("EXPlayerCharacter") or {}) do
        local a = addr(p); if a then players[a] = true end
    end
    local list = {}
    for _, c in ipairs(FindAllOf("EXCharacter") or {}) do
        local a = addr(c)
        if a and not players[a] and valid(c) then
            if cfg.writeProbe then pcall(logEnemyClass, c, myPawn) end
            if not isFriendly(myPawn, c) then list[#list + 1] = c end
        end
    end
    enemies = list
end

local holdKeyName, holdKey = nil, nil
local function wantsAim(pc)
    if S.aimMode == "always" then return true end
    if holdKeyName ~= S.aimHoldKey then
        holdKeyName = S.aimHoldKey
        holdKey = { KeyName = fname(holdKeyName) }
    end
    return try(function() return pc:IsInputKeyDown(holdKey) end) == true
end

-- Never pinged: floating damage numbers, effects, bullets and projectiles. They sit in front of whatever
-- you're actually looking at.
local PING_SKIP_PARENTS = toSet(cfg.ping.skipParents)
local pingCount = 0

local function relVec(v, origin)
    if not isVec(v) then return "-" end
    return string.format("(%.0f,%.0f,%.0f)", v.X - origin.X, v.Y - origin.Y, v.Z - origin.Z)
end

-- Ping: writes what's under the crosshair to pings.txt (for checking objects/enemies later). Changes nothing.
local function pingObject(pc)
    local camMgr = try(function() return pc.PlayerCameraManager end)
    local camLoc = valid(camMgr) and try(function() return camMgr:GetCameraLocation() end)
    local camRot = valid(camMgr) and try(function() return camMgr:GetCameraRotation() end)
    if not isVec(camLoc) or camRot == nil then return end
    local cam, camR = vec(camLoc), { Pitch = camRot.Pitch, Yaw = camRot.Yaw }
    local pawnA = addr(localPawn(pc))
    local ignore = cfg.ping.ignoreClasses or {}
    local maxDist = cfg.ping.maxDistance * 100
    local hits = {}
    for _, a in ipairs(FindAllOf("Actor") or {}) do
        local cname = className(a)
        if not ignore[cname] and addr(a) ~= pawnA and valid(a) and try(function() return a.bHidden end) ~= true then
            local loc = try(function() return a:K2_GetActorLocation() end)
            if isVec(loc) then
                local ang = Aim.angleTo(cam, camR, loc, maxDist)
                if ang and ang < cfg.ping.maxAngle and not chainHas(a, PING_SKIP_PARENTS) then
                    hits[#hits + 1] = { actor = a, angle = ang, loc = vec(loc) }
                end
            end
        end
    end
    table.sort(hits, function(x, y) return x.angle < y.angle end)
    pingCount = pingCount + 1
    local NL = string.char(10)
    if #hits == 0 then
        status.lastMarked = "Ping " .. pingCount .. ": nothing found under the crosshair"
        appendFile(PINGS_PATH, string.format("[%s] PING %d: nothing within %.0f deg of the crosshair",
            os.date("%H:%M:%S"), pingCount, cfg.ping.maxAngle) .. NL)
        return
    end
    local h = hits[1]
    local a, loc = h.actor, h.loc
    local chain = classChain(a)
    local dx, dy, dz = loc.X - cam.X, loc.Y - cam.Y, loc.Z - cam.Z
    local lines = { string.format("[%s] PING %d: %s | %s | %.1f m, %.1f deg off crosshair",
        os.date("%H:%M:%S"), pingCount, chain[1], table.concat(chain, " < ", 2, math.min(7, #chain)),
        math.sqrt(dx * dx + dy * dy + dz * dz) / 100, h.angle) }
    if chainHas(a, { Character = true }) then
        local myPawn = localPawn(pc)
        local p, kind = aimPoint(a, loc, cam)
        lines[#lines + 1] = string.format("    attitude=%s team=%s alive=%s burrowed=%s guarded by=%s | weakspot=%s auto=%s | aim uses %s %s",
            tostring(myPawn and attitude(myPawn, a)), tostring(teamIdOf(a)), tostring(isAlive(a)), tostring(isBurrowed(a)),
            guardOf[addr(a)] and className(guardOf[addr(a)]) or "nobody",
            relVec(try(function() return a:GetWeakSpotBodyInstanceLocation(0) end), loc),
            relVec(try(function() return a:GetAutoAimLocation(true, false) end), loc), kind, relVec(p, loc))
    end
    local comps = {}
    for _, c in ipairs(primitiveComponents(a)) do comps[#comps + 1] = className(c) end
    if #comps > 0 then lines[#lines + 1] = "    meshes: " .. table.concat(comps, ", ") end
    local others = {}
    for i = 2, math.min(3, #hits) do
        others[#others + 1] = string.format("%s (%.1f deg)", className(hits[i].actor), hits[i].angle)
    end
    if #others > 0 then lines[#lines + 1] = "    also near the crosshair: " .. table.concat(others, ", ") end
    appendFile(PINGS_PATH, table.concat(lines, NL) .. NL)
    status.lastMarked = string.format("Ping %d: %s (%s)", pingCount, chain[1], table.concat(chain, " < ", 2, math.min(4, #chain)))
    log("ping %d: %s", pingCount, chain[1])
end

local markKeyName, markKey, markWasDown = nil, nil, false
local function markKeyTick(pc)
    if markKeyName ~= S.aimSupplyKey then
        markKeyName = S.aimSupplyKey
        markKey = { KeyName = fname(markKeyName) }
    end
    local down = try(function() return pc:IsInputKeyDown(markKey) end) == true
    if down and not markWasDown then
        local ok, err = pcall(pingObject, pc)
        if not ok then reportError("ping", err) end
    end
    markWasDown = down
end

local ZERO = { X = 0, Y = 0, Z = 0 }
local lock = { key = nil, lostAt = nil }

-- Clay rotation state: clays already shot (address -> time) and time spent firing at the current clay.
local clayShot = {}
local clayDwell = { key = nil, frames = 0, firing = 0 }
local lastFrameAt = nil
local curDt = 0 -- seconds since the previous frame (set in frameTick)

local function frameDelta()
    local t = now()
    local d = lastFrameAt and (t - lastFrameAt) or 0
    lastFrameAt = t
    if d < 0 or d > 0.25 then d = 0 end -- paused / hitch
    return d
end

-- Shot detection from the game itself (no key settings): the equipped weapon's "time since last fired"
-- timer resets when a shot goes out, whatever button fires and whatever the weapon (bows included).
-- shotThisFrame: true = a shot went out since the previous frame, false = no shot, nil = can't tell.
local shotThisFrame = nil
local shotsSeen = 0
local lastFireT, lastWeaponAddr = nil, nil

local function equippedWeapon()
    for _, w in ipairs(cachedOwned("EXRangedWeaponInstance")) do
        if try(function() return w.bIsEquipped end) == true then return w end
    end
    return nil
end

local function detectShot()
    local w = equippedWeapon()
    local t = w and try(function() return w:GetTimeSinceLastInteractedWith() end)
    if type(t) ~= "number" then lastFireT, lastWeaponAddr = nil, nil; return nil end
    local wa = addr(w)
    local fired = false
    if wa == lastWeaponAddr and lastFireT ~= nil then fired = t + 1e-3 < lastFireT end
    lastFireT, lastWeaponAddr = t, wa
    return fired
end

local function aimTick(pc)
    if not S.aimAssist then status.aimTarget = ""; lock.key = nil; return end
    if not wantsAim(pc) then status.aimTarget = ""; lock.key = nil; return end

    local camMgr = try(function() return pc.PlayerCameraManager end)
    if not valid(camMgr) then return end
    local camLoc = try(function() return camMgr:GetCameraLocation() end)
    local camRot = try(function() return camMgr:GetCameraRotation() end)
    if not isVec(camLoc) or camRot == nil then return end
    local cam = vec(camLoc)
    local camR = { Pitch = camRot.Pitch, Yaw = camRot.Yaw }
    local maxDist = S.aimMaxDistance * 100

    -- Cheap first pass on actor locations with a wider cone, then exact aim points for the survivors.
    local wideFov = math.min(89, S.aimFov + math.max(20, cfg.aim.stickyExtraFov))
    local fx, fy, fz = Aim.rotToDir(camR.Pitch, camR.Yaw)
    local cosWide = math.cos(math.rad(wideFov))
    local candidates = {}
    local function consider(actor, isSupply)
        if not valid(actor) then return end
        local loc = try(function() return actor:K2_GetActorLocation() end)
        if not isVec(loc) then return end
        local dx, dy, dz = loc.X - cam.X, loc.Y - cam.Y, loc.Z - cam.Z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if d > 1 and d <= maxDist + 500 and (dx * fx + dy * fy + dz * fz) / d >= cosWide then
            if isSupply then
                candidates[#candidates + 1] = { actor = actor, point = vec(loc), kind = "supply", key = addr(actor) }
            elseif isAlive(actor) and not (S.aimSkipBurrowed and isBurrowed(actor)) then
                local p, kind = aimPoint(actor, vec(loc), cam)
                candidates[#candidates + 1] = { actor = actor, point = p, kind = kind, key = addr(actor) }
            end
        end
    end
    for _, e in ipairs(enemies) do consider(e, false) end
    if S.aimSupplies then
        local t = now()
        for k, at in pairs(clayShot) do
            if t - at > cfg.supplies.retargetSeconds then clayShot[k] = nil end
        end
        local before = #candidates
        for _, s in ipairs(supplies) do
            local k = addr(s)
            if not (k and clayShot[k]) then consider(s, true) end
        end
        -- Every clay in view was shot already: take them again rather than nothing.
        if #candidates == before then
            for _, s in ipairs(supplies) do consider(s, true) end
        end
    end

    local visible = function() return true end
    if S.aimLineOfSight then
        visible = function(c)
            if try(function() return pc:LineOfSightTo(c.actor, ZERO, false) end) ~= false then return true end
            -- A carried shield blocks the line-of-sight trace to the body; we aim over it instead.
            return S.aimOverShields and c.key ~= nil and shieldOwners[c.key] == true
        end
    end

    -- Keep the current target while it stays close, even if it ducks behind a shield for a moment.
    local best, angle = nil, nil
    if lock.key then
        for _, c in ipairs(candidates) do
            if c.key == lock.key then
                local a = Aim.angleTo(cam, camR, c.point, maxDist)
                if Aim.keepLock(lock, c, a, visible(c), now(), S.aimFov, cfg.aim.stickyExtraFov, cfg.aim.stickySeconds) then
                    best, angle = c, a
                end
                break
            end
        end
        if not best then lock.key, lock.lostAt = nil, nil end
    end
    if not best then
        best, angle = Aim.pickTarget(cam, camR, candidates, S.aimFov, maxDist, visible)
        if best then lock.key, lock.lostAt = best.key, nil end
    end
    -- An enemy kept invulnerable by a lifeline guard: shoot the guard first, wherever it is.
    if best and S.aimGuardsFirst and best.key and guardOf[best.key] then
        local g = guardOf[best.key]
        local gl = valid(g) and isAlive(g) and try(function() return g:K2_GetActorLocation() end)
        if isVec(gl) and near(gl, cam, maxDist) then
            local p = aimPoint(g, vec(gl), cam)
            best = { actor = g, point = p, kind = "guard of " .. className(best.actor), key = addr(g) }
            angle = Aim.angleTo(cam, camR, p) or angle
            lock.key, lock.lostAt = best.key, nil
        end
    end
    if not best then status.aimTarget = ""; return end

    -- One shot per clay: once a shot goes out while we're already on this clay, move to the next one.
    if best.kind == "supply" and best.key then
        if clayDwell.key ~= best.key then clayDwell.key, clayDwell.frames, clayDwell.firing = best.key, 0, 0 end
        clayDwell.frames = clayDwell.frames + 1
        local done = false
        if shotThisFrame ~= nil then
            -- The shot that just went out was aimed with last frame's rotation, so it counts only if we
            -- were already on this clay then.
            done = shotThisFrame and clayDwell.frames > 1
        else
            -- Can't see shots (no weapon info): fall back to one shot interval from the fire rate stat.
            local set = statSets()[1]
            local need = Aim.oneShotSeconds(set and readAttr(set, cfg.supplies.fireRateStat),
                set and readAttr(set, cfg.stats.fireRate), cfg.supplies.shotMargin,
                cfg.supplies.minDwell, cfg.supplies.maxDwell)
            clayDwell.firing = clayDwell.firing + curDt
            done = clayDwell.firing >= need
        end
        if done then
            clayShot[best.key] = now()
            clayDwell.key = nil
            lock.key, lock.lostAt = nil, nil -- next frame picks the next clay
        end
    else
        clayDwell.key = nil
    end

    local ctrl = try(function() return pc:GetControlRotation() end)
    if ctrl == nil then return end
    local target = best.point
    if S.aimLead then
        -- Lead moving targets (flying clays) and compensate bullet drop, using this PC's bullet stats.
        local set = statSets()[1]
        local speed = set and readAttr(set, cfg.stats.bulletSpeed)
        local grav = set and readAttr(set, cfg.stats.bulletGravity) or 0
        local vel = try(function() return best.actor:GetVelocity() end)
        target = Aim.leadPoint(cam, target, isVec(vel) and vec(vel) or nil, speed, grav)
    end
    local pitch, yaw = Aim.aimRotation(cam, target, { Pitch = ctrl.Pitch, Yaw = ctrl.Yaw }, camR, S.aimSmoothing / 100)
    pc:SetControlRotation({ Pitch = pitch, Yaw = yaw, Roll = 0 })
    status.aimTarget = string.format("%s (%s, %.1f deg)", className(best.actor), best.kind, angle or 0)
end

local function frameTick()
    curDt = frameDelta()
    local pc = localPC()
    if not pc or not localPawn(pc) then return end
    shotThisFrame = detectShot()
    if shotThisFrame then shotsSeen = shotsSeen + 1 end
    healthFrame()
    markKeyTick(pc)
    aimTick(pc)
    local ok, err = pcall(minimapFrame, pc)
    if not ok then reportError("minimap", err) end
end

---------------------------------------------------------------------------
-- Probe: records what this game build exposes, so names can be checked without a debugger
---------------------------------------------------------------------------

local probeWritten = false

local function describeClass(lines, obj)
    local cls = try(function() return obj:GetClass() end)
    local depth = 0
    while valid(cls) and depth < 6 do
        local full = try(function() return cls:GetFullName() end) or "?"
        lines[#lines + 1] = "  class " .. full
        local props = {}
        try(function()
            cls:ForEachProperty(function(p)
                props[#props + 1] = string.format("%s:%s", p:GetFName():ToString(), p:GetClass():GetFName():ToString())
            end)
        end)
        if #props > 0 then lines[#lines + 1] = "    props: " .. table.concat(props, ", ") end
        local super = try(function() return cls:GetSuperStruct() end)
        if not valid(super) then break end
        local superName = try(function() return super:GetFName():ToString() end) or ""
        if not superName:match("^EX") then
            lines[#lines + 1] = "    (super " .. superName .. ")"
            break
        end
        cls = super
        depth = depth + 1
    end
end

local function writeProbe(pc)
    local lines = { "Guns & Dragons Trainer probe " .. VERSION, "role=" .. status.role, "" }
    local function section(title, obj)
        lines[#lines + 1] = "== " .. title
        if valid(obj) then describeClass(lines, obj) else lines[#lines + 1] = "  (no instance)" end
    end
    section("EXHealthSet (ours)", cachedOwned("EXHealthSet")[1])
    section("Stats (ours)", statSets()[1])
    section("Weapon (ours)", cachedOwned("EXRangedWeaponInstance")[1])
    local w = cachedOwned("EXRangedWeaponInstance")[1]
    section("Weapon spread data", w and try(function() return w.SpreadData end))
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Enemy classes and aim points are logged to enemies.txt as they appear."
    writeFileAtomic(PROBE_PATH, table.concat(lines, "\n") .. "\n")
    log("wrote %s", PROBE_PATH)
end

---------------------------------------------------------------------------
-- Settings / status exchange with the GUI
---------------------------------------------------------------------------

local function loadSettings()
    local text = readFile(SETTINGS_PATH)
    if text == nil then
        writeFileAtomic(SETTINGS_PATH, Settings.toIni(S))
        lastSettingsText = Settings.toIni(S)
        return
    end
    if text == lastSettingsText then return end
    lastSettingsText = text
    local prev = S
    S = Settings.fromIni(text)
    for _, spec in ipairs(Settings.schema) do
        if prev[spec.key] ~= S[spec.key] then
            log("%s = %s", spec.key, tostring(S[spec.key]))
        end
    end
end

local function writeStatus()
    local roleNotice = {
        menu = "Not in a level yet.",
        solo = "Solo: all cheats available.",
        host = "Hosting: all cheats apply to your character only.",
        client = "Joined someone else's game: health, ammo, armor and loot magnet need you to host. "
            .. "Aim works; spread, fire rate, reload, dash and move speed are best effort.",
    }
    status.notice = roleNotice[status.role] or ""
    local lines = {
        "heartbeat=" .. os.time(),
        "version=" .. status.version,
        "role=" .. status.role,
        "notice=" .. status.notice,
        "aimTarget=" .. status.aimTarget,
        "aimLoop=" .. status.aimLoop,
        "suppliesInLevel=" .. #supplies,
        "shotDetection=" .. (shotThisFrame == nil and "unavailable (using fire rate timing)" or ("ok, shots seen: " .. shotsSeen)),
        "highlighted=" .. (function()
            local byClass, list = {}, {}
            for _, o in pairs(highlighted) do
                if valid(o) then
                    local c = className(o); byClass[c] = (byClass[c] or 0) + 1
                end
            end
            for c, n in pairs(byClass) do list[#list + 1] = c .. " x" .. n end
            table.sort(list)
            return table.concat(list, ", ")
        end)(),
        "minimapIcons=" .. (function()
            local shown = 0
            for _, p in ipairs(mm.pool) do if p.shown then shown = shown + 1 end end
            return string.format("%d drawn of %d (scale %.4f px/cm, edge %.0f px, %d slots)",
                shown, #mm.drawList, mm.scale, mm.edge, #mm.pool)
        end)(),
        "lastPing=" .. status.lastMarked,
        "lastError=" .. status.lastError:gsub("[\r\n]", " "),
    }
    writeFileAtomic(STATUS_PATH, table.concat(lines, "\n") .. "\n")
end

---------------------------------------------------------------------------
-- Main loops (all game work runs on the game thread)
---------------------------------------------------------------------------

local OWNED_CLASSES = { "EXHealthSet", "EXRangedWeaponInstance", "EXInventoryItemInstance",
    "EXEnergyMagazineAttributeSet", cfg.stats.set }

local slowTicks = 0
local function slowTick()
    slowTicks = slowTicks + 1
    local pc = localPC()
    updateRole(pc)
    local pawn = localPawn(pc)
    local every = math.max(1, math.floor(cfg.aim.enemyRefreshSeconds * 1000 / cfg.refillIntervalMs))
    local refreshNow = slowTicks % every == 0

    if not inLevel() or not pawn then
        release("health"); release("ammo"); release("dash"); release("fireRate"); release("loot")
        release("reload"); release("move")
        spreadOff()
        return
    end

    -- Our own attribute sets / weapons; rescanned once a second (weapon pickups, respawns).
    local owners = localOwners(pc)
    local rescan = slowTicks % 10 == 1
    for _, cls in ipairs(OWNED_CLASSES) do ownedInstances(cls, owners, rescan) end

    if refreshNow then
        if S.aimAssist then refreshEnemies(pc) end
        if S.aimSupplies or S.highlightSupplies then refreshSupplies() else supplies = {} end
        if S.lootMagnet and hasAuthority() then refreshLoot() end
        if S.aimAssist then refreshParts(); refreshGuards() end
        if S.highlightSupplies or S.highlightChests or S.highlightSecretWalls then highlightTick() else highlightOff() end
    end

    -- Host / solo only.
    if S.infiniteHealth and hasAuthority() then healthTick(pc) else healthOff(pc) end
    if S.infiniteAmmo and hasAuthority() then ammoTick() else release("ammo") end
    if S.infiniteArmor and hasAuthority() then armorTick() end
    if S.lootMagnet and hasAuthority() then lootMagnetTick(pawn) end

    -- Own stats, any role.
    if S.noDashCooldown then dashTick() else release("dash") end
    if S.fireRate then fireRateTick() else release("fireRate") end
    if S.noSpread then spreadOn() else spreadOff() end
    if S.lootMagnet then lootRangeTick() else release("loot") end
    if S.reloadSpeed then reloadTick() else release("reload") end
    if S.moveSpeed then moveTick(pawn) else release("move") end

    -- Probe once our real character exists (it owns a health set); the title screen has none.
    if cfg.writeProbe and not probeWritten and #cachedOwned("EXHealthSet") > 0 then
        probeWritten = true
        local ok, err = pcall(writeProbe, pc)
        if not ok then reportError("probe", err) end
    end
end

local function ioTick()
    local ok, err = pcall(loadSettings)
    if not ok then reportError("settings", err) end
    ok, err = pcall(writeStatus)
    if not ok then reportError("status", err) end
    ok, err = pcall(saveState)
    if not ok then reportError("state", err) end
end

local function guarded(name, fn)
    return function()
        local ok, err = pcall(fn)
        if not ok then reportError(name, err) end
        return false -- keep looping
    end
end

-- Runs fn on the game thread. Prefers every-frame (frames) or delay-based game thread loops from
-- UE4SS 4.x; falls back to an async timer that hops onto the game thread.
local function startLoop(name, fn, ms, frames)
    local g = guarded(name, fn)
    if frames and type(LoopInGameThreadAfterFrames) == "function" then
        local ok, h = pcall(LoopInGameThreadAfterFrames, frames, g)
        if ok and h ~= nil and h ~= false and not (type(h) == "number" and h < 0) then return "frames" end
    end
    if type(LoopInGameThreadWithDelay) == "function" then
        local ok, h = pcall(LoopInGameThreadWithDelay, ms, g)
        if ok and h ~= nil and h ~= false and not (type(h) == "number" and h < 0) then return "delay" end
    end
    LoopAsync(ms, function()
        ExecuteInGameThread(g)
        return false
    end)
    return "async"
end

local function launchGui()
    if not cfg.autoLaunchGui then return end
    local exe = MOD_DIR .. "\\" .. cfg.guiExe
    local f = io.open(exe, "rb")
    if not f then
        log("%s not found, skipping GUI launch", exe)
        return
    end
    f:close()
    -- The GUI is single-instance and closes itself when the game exits.
    local ok, err = pcall(os.execute, string.format('start "" "%s" --attach', exe))
    if not ok then log("could not launch GUI: %s", tostring(err)) end
end

-- Load settings before anything else so the first frame already uses saved toggles.
do
    local ok, err = pcall(loadState)
    if not ok then reportError("state", err) end
end
ioTick()
if cfg.writeProbe then
    writeFileAtomic(ENEMIES_PATH, "class | parents | attitude (0 friendly, 1 neutral, 2 hostile) team | up axis"
        .. " | aim points relative to the actor | point used\n")
end
-- Everything slow (the GUI launch can block for about a second) happens BEFORE the loops start: once they
-- start they run on the game thread, and nothing else in this file may run at the same time.
launchGui()
log("v%s loading from %s", VERSION, MOD_DIR)

-- Last statements of the file: start the loops.
status.aimLoop = startLoop("aim", frameTick, cfg.aim.fallbackTickMs, 1)
startLoop("refill", slowTick, cfg.refillIntervalMs, nil)
startLoop("io", ioTick, cfg.settingsPollMs, nil)
