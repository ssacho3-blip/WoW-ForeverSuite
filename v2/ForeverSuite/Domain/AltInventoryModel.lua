-- Module: Domain/AltInventoryModel.lua
-- Responsibility: Pure Cross-Character (Alt) summary model (Gold, Level, Class, Zone, Professions;
--                 Contract C3: complements Syndicator/Baganator without duplicating bag indexing).
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local pairs = pairs
local tostring = tostring
local math_floor = math.floor
local string_lower = string.lower
local string_find = string.find
local table_insert = table.insert
local table_sort = table.sort

local AltInventoryModel = {}
ns.Domain.AltInventoryModel = AltInventoryModel

function AltInventoryModel.MakeCharKey(name, realm)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local r = (type(realm) == "string" and realm ~= "") and realm or "ForeverKR"
    return name .. "-" .. r
end

function AltInventoryModel.RecordSnapshot(store, snap)
    if type(store) ~= "table" or type(snap) ~= "table" then
        return false
    end
    local key = AltInventoryModel.MakeCharKey(snap.name, snap.realm)
    if not key then
        return false
    end
    local prev = type(store[key]) == "table" and store[key] or {}
    store[key] = {
        key = key,
        name = snap.name,
        realm = snap.realm or prev.realm or "ForeverKR",
        class = (type(snap.class) == "string" and snap.class ~= "") and snap.class or prev.class,
        level = (type(snap.level) == "number" and snap.level > 0) and math_floor(snap.level) or prev.level,
        gold = (type(snap.gold) == "number" and snap.gold >= 0) and math_floor(snap.gold) or prev.gold,
        zone = (type(snap.zone) == "string" and snap.zone ~= "") and snap.zone or prev.zone,
        updatedAt = (type(snap.updatedAt) == "number") and math_floor(snap.updatedAt) or (prev.updatedAt or 0),
        bagFree = (type(snap.bagFree) == "number") and math_floor(snap.bagFree) or prev.bagFree,
    }
    return true
end

function AltInventoryModel.Summarize(store, query)
    local rows = {}
    local totalGold = 0
    local q = string_lower(tostring(query or ""))
    for _, rec in pairs(store or {}) do
        if type(rec) == "table" and type(rec.name) == "string" then
            local hay = string_lower(rec.name .. " " .. tostring(rec.realm or "") .. " " .. tostring(rec.class or "") .. " " .. tostring(rec.zone or ""))
            if q == "" or string_find(hay, q, 1, true) then
                table_insert(rows, rec)
                totalGold = totalGold + ((type(rec.gold) == "number" and rec.gold > 0) and math_floor(rec.gold) or 0)
            end
        end
    end
    table_sort(rows, function(a, b)
        if (a.gold or 0) ~= (b.gold or 0) then
            return (a.gold or 0) > (b.gold or 0)
        end
        return tostring(a.key) < tostring(b.key)
    end)
    return {
        rows = rows,
        charCount = #rows,
        totalGold = totalGold,
    }
end
