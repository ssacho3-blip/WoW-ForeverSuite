-- Module: Domain/CombatHudModel.lua
-- Responsibility: Pure KPI-10 Combat HUD evaluators (Combo Points, Target Range brackets, Short Buff expiry sort,
--                 and On-Screen Clock formatter).
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local ipairs = ipairs
local math_floor = math.floor
local string_format = string.format
local table_insert = table.insert
local table_sort = table.sort

local CombatHudModel = {}
ns.Domain.CombatHudModel = CombatHudModel

-- Evaluates combo points into bounded pip state table ({ active, count, max, isFull }).
function CombatHudModel.EvaluateComboPoints(points, maxPoints)
    if type(points) ~= "number" or points ~= points or points <= 0 then
        return { active = false, count = 0, max = 5, isFull = false }
    end
    local maxP = (type(maxPoints) == "number" and maxPoints >= 1 and maxPoints <= 10) and math_floor(maxPoints) or 5
    local cnt = math_floor(points)
    if cnt > maxP then cnt = maxP end
    return {
        active = cnt > 0,
        count = cnt,
        max = maxP,
        isFull = cnt >= maxP,
    }
end

-- Classifies target interaction range flags (CheckInteractDistance 3=Duel~10y, 2=Trade~11y, 1=Inspect~28y, 4=Follow~28y).
-- Returns nil when target does not exist or all flags are unreadable.
function CombatHudModel.ClassifyTargetRange(hasTarget, inDuel10, inTrade11, inInspect28, inFollow28)
    if hasTarget ~= true then
        return nil
    end
    if inDuel10 == true then
        return { label = "근접 (≤10m)", tone = "SUCCESS", close = true }
    end
    if inTrade11 == true then
        return { label = "근거리 (≤11m)", tone = "SUCCESS", close = true }
    end
    if inInspect28 == true or inFollow28 == true then
        return { label = "중거리 (12~28m)", tone = "GOLD", close = false }
    end
    -- B1: Only assert >28m when at least one 28m check explicitly returned false (Zero Fabricated Status)
    if inInspect28 == false or inFollow28 == false then
        return { label = "원거리 (>28m)", tone = "WARN", close = false }
    end
    return nil
end

-- Filters & sorts short-duration helpful buffs expiring within maxRemSec (default 30s).
function CombatHudModel.FilterShortBuffs(auras, now, maxRemSec, limit)
    local out = {}
    if type(auras) ~= "table" or type(now) ~= "number" or now ~= now then
        return out
    end
    local capSec = (type(maxRemSec) == "number" and maxRemSec > 0) and maxRemSec or 30
    local maxRows = (type(limit) == "number" and limit > 0) and limit or 5
    for _, a in ipairs(auras) do
        if type(a) == "table" and type(a.name) == "string" and a.name ~= ""
            and type(a.expirationTime) == "number" and a.expirationTime > now
            and type(a.duration) == "number" and a.duration > 0
        then
            local rem = a.expirationTime - now
            if rem > 0 and rem <= capSec then
                table_insert(out, {
                    name = a.name,
                    spellId = a.spellId,
                    auraInstanceID = a.auraInstanceID,
                    remaining = rem,
                    duration = a.duration,
                    urgent = (rem <= 5),
                })
            end
        end
    end
    table_sort(out, function(x, y)
        if x.remaining ~= y.remaining then return x.remaining < y.remaining end
        return x.name < y.name
    end)
    while #out > maxRows do
        out[#out] = nil
    end
    return out
end

function CombatHudModel.FormatClockText(localH, localM, srvH, srvM)
    local locTxt = (type(localH) == "number" and type(localM) == "number")
        and string_format("%02d:%02d", math_floor(localH), math_floor(localM))
        or "-:-"
    if type(srvH) == "number" and type(srvM) == "number" then
        return "로컬 " .. locTxt .. " · 서버 " .. string_format("%02d:%02d", math_floor(srvH), math_floor(srvM))
    end
    return "시각 " .. locTxt
end
