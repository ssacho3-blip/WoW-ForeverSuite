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
