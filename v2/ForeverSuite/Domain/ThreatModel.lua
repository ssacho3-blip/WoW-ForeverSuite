-- Module: Domain/ThreatModel.lua
-- Responsibility: Pure Secret-Safe Threat Meter model (Invariant I1: zero sorting/arithmetic/0% coercion on secret values).
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local ipairs = ipairs
local tostring = tostring
local math_max = math.max
local math_min = math.min
local math_floor = math.floor
local string_format = string.format
local table_insert = table.insert
local table_sort = table.sort

local ThreatModel = {}
ns.Domain.ThreatModel = ThreatModel

function ThreatModel.FormatThreatValue(val)
    if type(val) ~= "number" or val ~= val then
        return "—"
    end
    local absV = (val < 0) and -val or val
    if absV >= 1000000 then
        return string_format("%.1fM", val / 1000000)
    elseif absV >= 1000 then
        return string_format("%.1fk", val / 1000)
    end
    return tostring(math_floor(val + 0.5))
end

-- samples: array of { unit, name, class, isSecret, isTanking, status, scaledPct, rawPct, threatValue }
-- Invariant I1: If ANY sample has isSecret == true, disables sorting/summing/highlight and emits fixed-order "집계 불가" rows.
function ThreatModel.BuildSnapshot(samples, maxRows)
    local cap = (type(maxRows) == "number" and maxRows >= 1) and math_floor(maxRows) or 6
    local list = type(samples) == "table" and samples or {}
    if #list == 0 then
        return { mode = "EMPTY", rows = {}, warning = false }
    end

    local anySecret = false
    for _, s in ipairs(list) do
        if type(s) == "table" and s.isSecret == true then
            anySecret = true
            break
        end
    end

    if anySecret then
        local rows = {}
        for i = 1, math_min(#list, cap) do
            local s = list[i]
            rows[#rows + 1] = {
                unit = tostring(s.unit or ("unit" .. tostring(i))),
                name = tostring(s.name or s.unit or "대상"),
                class = s.class,
                isTanking = false,
                ratio = nil,
                rightText = "집계 불가",
                tone = "MUTED",
            }
        end
        return { mode = "SECRET_LOCKED", rows = rows, warning = false }
    end

    local valid = {}
    local maxVal = 0
    for _, s in ipairs(list) do
        if type(s) == "table" then
            local tv = (type(s.threatValue) == "number" and s.threatValue == s.threatValue) and s.threatValue or nil
            local pct = (type(s.scaledPct) == "number" and s.scaledPct == s.scaledPct) and s.scaledPct or nil
            if tv ~= nil or pct ~= nil then
                local score = tv or pct or 0
                if score > maxVal then maxVal = score end
                table_insert(valid, {
                    unit = tostring(s.unit or ""),
                    name = tostring(s.name or s.unit or "아군"),
                    class = s.class,
                    isPlayer = (s.isPlayer == true) or (s.unit == "player"),
                    isTanking = s.isTanking == true,
                    status = (type(s.status) == "number") and s.status or 0,
                    scaledPct = pct,
                    threatValue = tv,
                    score = score,
                })
            end
        end
    end

    if #valid == 0 then
        return { mode = "EMPTY", rows = {}, warning = false }
    end

    table_sort(valid, function(a, b)
        if a.isTanking ~= b.isTanking then
            return a.isTanking
        end
        if a.score ~= b.score then
            return a.score > b.score
        end
        return a.unit < b.unit
    end)

    local rows = {}
    local playerWarning = false
    -- Compute player aggro warning across ALL valid entries BEFORE capping to maxRows (F4: raid rank >=7)
    for i = 1, #valid do
        local v = valid[i]
        if v.isPlayer and (not v.isTanking) and v.scaledPct ~= nil and v.scaledPct >= 90 then
            playerWarning = true
            break
        end
    end

    for i = 1, math_min(#valid, cap) do
        local v = valid[i]
        local ratio = 0
        if v.scaledPct ~= nil then
            ratio = math_max(0, math_min(1, v.scaledPct / 100))
        elseif maxVal > 0 then
            ratio = math_max(0, math_min(1, v.score / maxVal))
        end
        local pctText = (v.scaledPct ~= nil) and (string_format("%.0f%%", v.scaledPct)) or "—"
        local valText = (v.threatValue ~= nil) and ThreatModel.FormatThreatValue(v.threatValue) or ""
        local rightText = (valText ~= "") and (valText .. " (" .. pctText .. ")") or pctText

        local tone = "PRIMARY"
        if v.isTanking then
            tone = "GOLD"
        elseif v.isPlayer and v.scaledPct ~= nil and v.scaledPct >= 90 then
            tone = "DANGER"
        elseif v.isPlayer and v.scaledPct ~= nil and v.scaledPct >= 75 then
            tone = "WARN"
        end

        rows[#rows + 1] = {
            unit = v.unit,
            name = (v.isTanking and "★ " or "") .. v.name,
            class = v.class,
            isTanking = v.isTanking,
            isPlayer = v.isPlayer,
            ratio = ratio,
            rightText = rightText,
            tone = tone,
        }
    end

    return {
        mode = "LIVE",
        rows = rows,
        warning = playerWarning,
    }
end
