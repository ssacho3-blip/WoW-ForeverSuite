-- Module: Domain/PetRewardModel.lua
-- Responsibility: Pure KPI-4 Hunter Pet multi-spawn & rare/family filter + Forever Reward mode/faction filter.
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
local string_lower = string.lower
local string_find = string.find
local string_gmatch = string.gmatch
local string_match = string.match
local table_insert = table.insert

local PetRewardModel = {}
ns.Domain.PetRewardModel = PetRewardModel

-- Parses compact multi-spawn string "mapID:x:y:zone|mapID:x:y:zone" into array of { mapID, x, y, zone }.
function PetRewardModel.ParseMultiLocs(raw)
    local out = {}
    if type(raw) ~= "string" or raw == "" then
        return out
    end
    for tok in string_gmatch(raw, "[^|]+") do
        local mid, sx, sy, zone = string_match(tok, "^(%d+):([%d%.]+):([%d%.]+):(.*)$")
        local m, x, y = tonumber(mid), tonumber(sx), tonumber(sy)
        if m and x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
            table_insert(out, { mapID = m, x = x, y = y, zone = zone or "" })
        end
    end
    return out
end

function PetRewardModel.FilterPets(entries, opts)
    opts = type(opts) == "table" and opts or {}
    local rareOnly = opts.rareOnly == true
    local family = opts.family or "all"
    local q = string_lower(tostring(opts.query or ""))
    local out = {}
    for _, e in ipairs(entries or {}) do
        if type(e) == "table" then
            local rareOk = (not rareOnly) or (e.rare == true)
            local famOk = (family == "all") or (e.family == family)
            if rareOk and famOk then
                if q == "" then
                    table_insert(out, e)
                else
                    local hay = string_lower(tostring(e.title or "") .. " " .. tostring(e.altName or "") .. " " .. tostring(e.zone or "") .. " " .. tostring(e.family or ""))
                    if string_find(hay, q, 1, true) then
                        table_insert(out, e)
                    end
                end
            end
        end
    end
    return out
end

function PetRewardModel.FilterRewards(entries, opts)
    opts = type(opts) == "table" and opts or {}
    local mode = opts.mode or "all" -- all | honor | reputation | merchant
    local team = opts.team or "all" -- all | Alliance | Horde | Neutral
    local q = string_lower(tostring(opts.query or ""))
    local out = {}
    for _, e in ipairs(entries or {}) do
        if type(e) == "table" then
            local modeOk = (mode == "all") or (e.mode == mode)
            local teamOk = (team == "all") or (e.team == team) or (e.team == "Neutral")
            if modeOk and teamOk then
                if q == "" then
                    table_insert(out, e)
                else
                    local hay = string_lower(tostring(e.title or "") .. " " .. tostring(e.altName or "") .. " " .. tostring(e.note or "") .. " " .. tostring(e.zone or ""))
                    if string_find(hay, q, 1, true) then
                        table_insert(out, e)
                    end
                end
            end
        end
    end
    return out
end
