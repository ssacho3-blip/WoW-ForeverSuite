-- Module: Domain/SettingsSchemaModel.lua
-- Responsibility: Declarative settings schema registry, validation, defaults, and search filtering.
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local ipairs = ipairs
local tostring = tostring
local string_lower = string.lower
local string_find = string.find
local table_insert = table.insert

local SettingsSchemaModel = {}
ns.Domain.SettingsSchemaModel = SettingsSchemaModel

function SettingsSchemaModel.ValidateSliderSchema(item)
    if type(item) ~= "table" then return false end
    local lo, hi, st = item.min, item.max, item.step
    if type(lo) ~= "number" or type(hi) ~= "number" or type(st) ~= "number" then
        return false
    end
    if lo ~= lo or hi ~= hi or st ~= st then
        return false
    end
    return (lo < hi) and (st > 0)
end

function SettingsSchemaModel.ClampSliderValue(item, rawVal)
    if not SettingsSchemaModel.ValidateSliderSchema(item) then
        return nil
    end
    local v = rawVal
    if type(v) ~= "number" or v ~= v then
        v = item.default
    end
    if type(v) ~= "number" or v ~= v then
        v = item.min
    end
    if v < item.min then v = item.min end
    if v > item.max then v = item.max end
    return v
end

function SettingsSchemaModel.BuildDefaults(schemas)
    local out = {}
    for _, item in ipairs(schemas or {}) do
        if type(item) == "table" and type(item.section) == "string" and type(item.key) == "string" then
            out[item.section] = out[item.section] or {}
            out[item.section][item.key] = item.default
        end
    end
    return out
end

function SettingsSchemaModel.FilterByQuery(schemas, query)
    local q = string_lower(tostring(query or ""))
    if q == "" then
        return schemas or {}
    end
    local matched = {}
    for _, item in ipairs(schemas or {}) do
        if type(item) == "table" then
            local hay = string_lower(
                tostring(item.section or "") .. " " ..
                tostring(item.key or "") .. " " ..
                tostring(item.label or "") .. " " ..
                tostring(item.desc or "")
            )
            if string_find(hay, q, 1, true) then
                table_insert(matched, item)
            end
        end
    end
    return matched
end
