-- Module: Domain/AltCooldownModel.lua
-- Responsibility: Pure multi-day alt crafting cooldown tracker (Transmute 48h, Salt Shaker 72h, Mooncloth 96h).
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local pairs = pairs
local math_floor = math.floor
local string_format = string.format
local table_insert = table.insert
local table_sort = table.sort

local AltCooldownModel = {
    RECIPES = {
        transmute   = { id = "transmute",   label = "연금술 변환",   durationSec = 48 * 3600 },
        salt_shaker = { id = "salt_shaker", label = "소금 정제기",   durationSec = 72 * 3600 },
        mooncloth   = { id = "mooncloth",   label = "달빛 옷감",     durationSec = 96 * 3600 },
    },
}
ns.Domain.AltCooldownModel = AltCooldownModel

function AltCooldownModel.RecordUse(store, charKey, recipeId, nowUnix)
    local spec = AltCooldownModel.RECIPES[recipeId]
    if type(store) ~= "table" or type(charKey) ~= "string" or charKey == "" or not spec then
        return false, "INVALID_ARGS"
    end
    local now = (type(nowUnix) == "number" and nowUnix > 0) and math_floor(nowUnix) or 0
    if now <= 0 then
        return false, "INVALID_TIME"
    end
    if type(store[charKey]) ~= "table" then
        store[charKey] = {}
    end
    store[charKey][recipeId] = now + spec.durationSec
    return true, store[charKey][recipeId]
end

function AltCooldownModel.EvaluateAll(store, nowUnix)
    local ready = {}
    local cooling = {}
    if type(store) ~= "table" then
        return ready, cooling
    end
    local now = (type(nowUnix) == "number" and nowUnix > 0) and math_floor(nowUnix) or 0
    for charKey, recMap in pairs(store) do
        if type(recMap) == "table" then
            for recipeId, readyAt in pairs(recMap) do
                local spec = AltCooldownModel.RECIPES[recipeId]
                if spec and type(readyAt) == "number" then
                    local rem = readyAt - now
                    local item = {
                        charKey = charKey,
                        recipeId = recipeId,
                        label = spec.label,
                        readyAt = readyAt,
                        remainingSec = (rem > 0) and rem or 0,
                    }
                    if rem <= 0 then
                        table_insert(ready, item)
                    else
                        table_insert(cooling, item)
                    end
                end
            end
        end
    end
    table_sort(ready, function(a, b) return a.charKey < b.charKey or (a.charKey == b.charKey and a.recipeId < b.recipeId) end)
    table_sort(cooling, function(a, b) return a.remainingSec < b.remainingSec end)
    return ready, cooling
end

function AltCooldownModel.FormatRemaining(sec)
    if type(sec) ~= "number" or sec <= 0 then
        return "준비 완료"
    end
    local h = math_floor(sec / 3600)
    local m = math_floor((sec % 3600) / 60)
    return string_format("%d시간 %02d분", h, m)
end
