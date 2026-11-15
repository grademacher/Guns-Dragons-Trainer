-- Aim assist math. Pure Lua, no UE4SS dependencies (unit tested).
-- Unreal conventions: X forward, Y right, Z up; yaw/pitch in degrees.

local M = {}

-- Wraps an angle to (-180, 180].
function M.normAxis(a)
    a = a % 360
    if a > 180 then a = a - 360 end
    return a
end

-- Direction vector -> pitch, yaw.
function M.dirToRot(dx, dy, dz)
    local yaw = math.deg(math.atan(dy, dx))
    local pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy)))
    return pitch, yaw
end

-- Pitch, yaw -> unit direction vector.
function M.rotToDir(pitch, yaw)
    local p, y = math.rad(pitch), math.rad(yaw)
    local cp = math.cos(p)
    return cp * math.cos(y), cp * math.sin(y), math.sin(p)
end

-- Picks the candidate closest (in angle) to the crosshair.
--   cam        = { X, Y, Z } camera location
--   camRot     = { Pitch, Yaw } camera rotation
--   candidates = array of { point = {X,Y,Z}, ... } (any extra fields are passed through)
--   fovDeg     = max angle from crosshair
--   maxDist    = max distance in Unreal units
--   visible    = optional function(candidate) -> bool, only called for candidates that pass the cone test
-- Returns the winning candidate and its angle in degrees, or nil.
function M.pickTarget(cam, camRot, candidates, fovDeg, maxDist, visible)
    local fx, fy, fz = M.rotToDir(camRot.Pitch, camRot.Yaw)
    local cosFov = math.cos(math.rad(fovDeg))
    local maxDist2 = maxDist * maxDist

    -- Sort cone hits by angle so the (expensive) visibility check runs on the best ones first.
    local hits = {}
    for _, c in ipairs(candidates) do
        local p = c.point
        if p then
            local dx, dy, dz = p.X - cam.X, p.Y - cam.Y, p.Z - cam.Z
            local d2 = dx * dx + dy * dy + dz * dz
            if d2 > 1 and d2 <= maxDist2 then
                local dot = (dx * fx + dy * fy + dz * fz) / math.sqrt(d2)
                if dot >= cosFov then
                    hits[#hits + 1] = { c = c, dot = dot }
                end
            end
        end
    end
    table.sort(hits, function(a, b) return a.dot > b.dot end)
    for _, h in ipairs(hits) do
        if visible == nil or visible(h.c) then
            return h.c, math.deg(math.acos(math.min(1, h.dot)))
        end
    end
    return nil
end

-- Angle in degrees between the crosshair and `point`, or nil if behind the camera / out of range.
function M.angleTo(cam, camRot, point, maxDist)
    local fx, fy, fz = M.rotToDir(camRot.Pitch, camRot.Yaw)
    local dx, dy, dz = point.X - cam.X, point.Y - cam.Y, point.Z - cam.Z
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 <= 1 or (maxDist and d2 > maxDist * maxDist) then return nil end
    local dot = (dx * fx + dy * fy + dz * fz) / math.sqrt(d2)
    if dot <= 0 then return nil end
    return math.deg(math.acos(math.min(1, dot)))
end

-- Sticky target lock: keeps the current target while it stays near the crosshair, even if it is briefly
-- hidden (behind its own shield, while blocking, ...), so the aim doesn't jump away mid-fight.
--   lock      = state table { key, lostAt } (mutated)
--   cand      = the locked target's candidate this frame, or nil if it is gone / dead
--   angle     = its angle from the crosshair
--   isVisible = its line-of-sight result (true when the check is off)
--   now       = seconds
-- Returns true to keep aiming at it.
function M.keepLock(lock, cand, angle, isVisible, now, fovDeg, extraFov, stickySeconds)
    if cand == nil or angle == nil or angle > fovDeg + extraFov then
        lock.key, lock.lostAt = nil, nil
        return false
    end
    if isVisible then
        lock.lostAt = nil
        return true
    end
    lock.lostAt = lock.lostAt or now
    if now - lock.lostAt <= stickySeconds then return true end
    lock.key, lock.lostAt = nil, nil
    return false
end

local function dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
local function sub(a, b) return { X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z } end

-- Does the segment a->b pass through an oriented box?
--   box = { center = {X,Y,Z}, axes = { x, y, z unit vectors }, scale = {X,Y,Z},
--           min = {X,Y,Z}, max = {X,Y,Z} (local, unscaled) }, margin = extra cm around the box
function M.segmentHitsBox(a, b, box, margin)
    margin = margin or 0
    local la, lb = sub(a, box.center), sub(b, box.center)
    local t0, t1 = 0, 1
    local keys = { "X", "Y", "Z" }
    for i = 1, 3 do
        local ax, k = box.axes[i], keys[i]
        local s = math.abs(box.scale and box.scale[k] or 1)
        if s < 1e-6 then s = 1e-6 end
        local lo, hi = box.min[k] * s - margin, box.max[k] * s + margin
        local pa, pb = dot(la, ax), dot(lb, ax)
        local d = pb - pa
        if math.abs(d) < 1e-9 then
            if pa < lo or pa > hi then return false end
        else
            local ta, tb = (lo - pa) / d, (hi - pa) / d
            if ta > tb then ta, tb = tb, ta end
            if ta > t0 then t0 = ta end
            if tb < t1 then t1 = tb end
            if t0 > t1 then return false end
        end
    end
    return true
end

-- Is a part on the enemy (e.g. a backpack) on the side facing the camera?
-- Parts close to the enemy's vertical axis (on the head, held above) count as visible from anywhere.
function M.facesCamera(partPoint, enemyCenter, cam, centerRadius)
    local nx, ny = partPoint.X - enemyCenter.X, partPoint.Y - enemyCenter.Y
    local nl = math.sqrt(nx * nx + ny * ny)
    if nl <= (centerRadius or 15) then return true end
    local vx, vy = cam.X - enemyCenter.X, cam.Y - enemyCenter.Y
    local vl = math.sqrt(vx * vx + vy * vy)
    if vl < 1e-6 then return true end
    return (nx * vx + ny * vy) / (nl * vl) > 0.15
end

-- Is `point` plausibly on the enemy's body? Generous box around its capsule (half height / radius in cm):
-- up to 2.5 half-heights + 50 cm above its center (tall weak spots, banners), no lower than just past its
-- feet, and 4 radii + 100 cm sideways.
function M.nearBody(point, center, up, halfHeight, radius)
    local rel = sub(point, center)
    local along = dot(rel, up)
    local sx, sy, sz = rel.X - up.X * along, rel.Y - up.Y * along, rel.Z - up.Z * along
    local side = math.sqrt(sx * sx + sy * sy + sz * sz)
    return along <= halfHeight * 2.5 + 50 and along >= -(halfHeight * 1.2 + 30) and side <= radius * 4 + 100
end

-- How long to stay on a clay so one shot goes out: one shot interval at the current fire rate
-- (rounds per minute x multiplier) plus a small margin, clamped to [minS, maxS].
function M.oneShotSeconds(fireRate, fireRateRatio, margin, minS, maxS)
    local rpm = (fireRate or 0) * (fireRateRatio or 1)
    local t = rpm > 0 and 60 / rpm or maxS
    t = t + (margin or 0)
    if t < minS then t = minS elseif t > maxS then t = maxS end
    return t
end

-- Where to aim so a bullet (speed cm/s, gravity cm/s^2 on Z, negative = falls) hits a target moving at
-- `vel`. Returns `point` unchanged when the speed is unknown.
function M.leadPoint(cam, point, vel, speed, gravity)
    if not speed or speed <= 0 then return point end
    vel = vel or { X = 0, Y = 0, Z = 0 }
    gravity = gravity or 0
    local p = point
    for _ = 1, 3 do -- converge on the flight time
        local dx, dy, dz = p.X - cam.X, p.Y - cam.Y, p.Z - cam.Z
        local t = math.sqrt(dx * dx + dy * dy + dz * dz) / speed
        if t > 3 then t = 3 end
        p = {
            X = point.X + vel.X * t,
            Y = point.Y + vel.Y * t,
            Z = point.Z + vel.Z * t - 0.5 * gravity * t * t,
        }
    end
    return p
end

-- Computes the new control rotation that puts the crosshair on `point`.
--   ctrlRot   = current control rotation { Pitch, Yaw }
--   camRot    = current camera rotation { Pitch, Yaw } (may differ from control rotation by recoil / camera effects)
--   smoothing = 0..1, fraction of the remaining angle to cover this frame (1 = snap)
function M.aimRotation(cam, point, ctrlRot, camRot, smoothing)
    local tPitch, tYaw = M.dirToRot(point.X - cam.X, point.Y - cam.Y, point.Z - cam.Z)
    local cPitch, cYaw = M.normAxis(ctrlRot.Pitch), M.normAxis(ctrlRot.Yaw)
    local offPitch = M.normAxis(M.normAxis(camRot.Pitch) - cPitch)
    local offYaw = M.normAxis(M.normAxis(camRot.Yaw) - cYaw)
    local wantPitch, wantYaw = tPitch - offPitch, tYaw - offYaw
    local s = math.max(0.01, math.min(1.0, smoothing))
    local newPitch = M.normAxis(cPitch + M.normAxis(wantPitch - cPitch) * s)
    local newYaw = M.normAxis(cYaw + M.normAxis(wantYaw - cYaw) * s)
    -- Keep pitch in the range Unreal clamps view pitch to.
    if newPitch > 89.9 then newPitch = 89.9 elseif newPitch < -89.9 then newPitch = -89.9 end
    return newPitch, newYaw
end

return M
