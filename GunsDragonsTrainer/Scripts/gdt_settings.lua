-- Settings shared between the in-game mod and the trainer window.
-- Stored as plain "key=value" lines in settings.ini next to the mod, which the GUI writes
-- and the mod re-reads while the game runs. Pure Lua, no UE4SS dependencies (unit tested).

local M = {}

-- Every setting, its type, default, and limits. The GUI uses the same keys.
M.schema = {
    { key = "infiniteHealth", type = "bool",   default = false },
    { key = "infiniteAmmo",   type = "bool",   default = false },
    { key = "infiniteArmor",  type = "bool",   default = false },
    { key = "infiniteRevives", type = "bool",  default = false },
    { key = "aimAssist",      type = "bool",   default = false },
    { key = "aimFov",         type = "number", default = 10,  min = 1, max = 90 },   -- degrees around crosshair
    { key = "aimMode",        type = "enum",   default = "hold", values = { hold = true, always = true } },
    { key = "aimHoldKey",     type = "string", default = "RightMouseButton" },
    { key = "aimSmoothing",   type = "number", default = 100, min = 1, max = 100 },  -- percent of the way per frame
    { key = "aimMaxDistance", type = "number", default = 100, min = 5, max = 1000 }, -- meters
    { key = "aimLineOfSight", type = "bool",   default = true },
    { key = "aimWeakSpot",    type = "bool",   default = true },
    { key = "aimSupplies",    type = "bool",   default = false },  -- also target marked supply objects
    { key = "aimSupplyKey",   type = "string", default = "F8" },   -- ping key: logs the object under the crosshair to pings.txt
    { key = "highlightSupplies", type = "bool", default = false },
    { key = "lootMagnet",     type = "bool",   default = false },
    { key = "lootMagnetRadius", type = "number", default = 30, min = 5, max = 100 }, -- meters
    { key = "minimapLootDots", type = "bool",  default = false },  -- dots on the minimap for pickups in magnet range
    { key = "noDashCooldown", type = "bool",   default = false },
    { key = "noSpread",       type = "bool",   default = false },
    { key = "fireRate",       type = "bool",   default = false },
    { key = "fireRateMultiplier", type = "number", default = 2, min = 1, max = 10 },
    { key = "reloadSpeed",    type = "bool",   default = false },
    { key = "reloadSpeedMultiplier", type = "number", default = 2, min = 1, max = 5 },
    { key = "moveSpeed",      type = "bool",   default = false },
    { key = "moveSpeedMultiplier", type = "number", default = 1.5, min = 1, max = 3 },
    { key = "aimExplosives",  type = "bool",   default = true },   -- prefer explosive gear when it's in clean view
    { key = "aimOverShields", type = "bool",   default = true },   -- never aim into a shield; go over it
    { key = "highlightChests", type = "bool",  default = false },
    { key = "aimLead",        type = "bool",   default = true },   -- lead moving targets, compensate bullet drop
    { key = "aimGuardsFirst", type = "bool",   default = true },   -- shoot lifeline guards before the enemy they protect
    { key = "highlightSecretWalls", type = "bool", default = false },
    { key = "aimSkipBurrowed", type = "bool",  default = true },
    { key = "minimapIcons",   type = "bool",   default = false },  -- experimental: highlighted objects on the minimap   -- ignore spore colonies while ducked (damage blocked)
}

local byKey = {}
for _, s in ipairs(M.schema) do byKey[s.key] = s end

function M.defaults()
    local t = {}
    for _, s in ipairs(M.schema) do t[s.key] = s.default end
    return t
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- Parses "key=value" text. Unknown keys are kept as strings (the GUI stores its own window state).
function M.parseIni(text)
    local raw = {}
    if type(text) ~= "string" then return raw end
    for line in text:gmatch("[^\r\n]+") do
        line = trim(line)
        if line ~= "" and not line:match("^[;#]") then
            local k, v = line:match("^([^=]+)=(.*)$")
            if k then raw[trim(k)] = trim(v) end
        end
    end
    return raw
end

local function coerce(spec, v)
    if v == nil then return spec.default end
    if spec.type == "bool" then
        v = tostring(v):lower()
        if v == "1" or v == "true" or v == "on" or v == "yes" then return true end
        if v == "0" or v == "false" or v == "off" or v == "no" then return false end
        return spec.default
    elseif spec.type == "number" then
        local n = tonumber(v)
        if n == nil or n ~= n then return spec.default end
        if spec.min and n < spec.min then n = spec.min end
        if spec.max and n > spec.max then n = spec.max end
        return n
    elseif spec.type == "enum" then
        v = tostring(v):lower()
        if spec.values[v] then return v end
        return spec.default
    else
        v = tostring(v)
        if v == "" then return spec.default end
        return v
    end
end

-- Turns raw ini values into a fully populated, validated settings table.
function M.fromIni(text)
    local raw = M.parseIni(text)
    local out = {}
    for _, s in ipairs(M.schema) do out[s.key] = coerce(s, raw[s.key]) end
    return out
end

function M.toIni(settings)
    local lines = {}
    for _, s in ipairs(M.schema) do
        local v = settings[s.key]
        if s.type == "bool" then v = v and "1" or "0" end
        lines[#lines + 1] = s.key .. "=" .. tostring(v)
    end
    return table.concat(lines, "\n") .. "\n"
end

M.spec = byKey
return M
