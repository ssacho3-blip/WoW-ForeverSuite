-- Module: Domain/CharacterGuideModel.lua
-- Responsibility: Pure Talent Point Reminder & Learnable Class Training Spell evaluator (backed by ForeverSuite_Data_Atlas).
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local ipairs = ipairs
local tostring = tostring
local math_floor = math.floor
local table_insert = table.insert
local table_sort = table.sort

local CharacterGuideModel = {}
ns.Domain.CharacterGuideModel = CharacterGuideModel

function CharacterGuideModel.EvaluateTalentReminder(unspentPoints, playerLevel)
    if type(unspentPoints) ~= "number" or unspentPoints <= 0 then
        return nil
    end
    local pts = math_floor(unspentPoints)
    local lvl = (type(playerLevel) == "number" and playerLevel >= 10) and math_floor(playerLevel) or 10
    return {
        points = pts,
        level = lvl,
        message = "미사용 특성 포인트 " .. tostring(pts) .. "점이 남아 있습니다 (N키로 특성 창 열기).",
    }
end

-- Returns sorted list of learnable class spells at or below playerLevel not yet in knownSpellSet.
function CharacterGuideModel.FindLearnableSpells(trainingEntries, playerClass, playerLevel, knownSpellSet, limit)
    local out = {}
    if type(trainingEntries) ~= "table" or type(playerClass) ~= "string" or playerClass == "" then
        return out
    end
    if type(playerLevel) ~= "number" or playerLevel < 1 then
        return out
    end
    local known = type(knownSpellSet) == "table" and knownSpellSet or {}
    local cap = (type(limit) == "number" and limit > 0) and math_floor(limit) or 25

    for _, sp in ipairs(trainingEntries) do
        if type(sp) == "table" and sp.class == playerClass
            and type(sp.spellID) == "number" and sp.spellID > 0
            and type(sp.level) == "number" and sp.level <= playerLevel
            and not known[sp.spellID]
        then
            table_insert(out, {
                spellID = sp.spellID,
                level = math_floor(sp.level),
                cost = (type(sp.cost) == "number" and sp.cost >= 0) and math_floor(sp.cost) or 0,
            })
        end
    end

    table_sort(out, function(a, b)
        if a.level ~= b.level then
            return a.level > b.level
        end
        return a.spellID < b.spellID
    end)

    if #out > cap then
        local trimmed = {}
        for i = 1, cap do trimmed[i] = out[i] end
        return trimmed
    end
    return out
end
