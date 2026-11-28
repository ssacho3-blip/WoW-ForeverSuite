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

-- Phase 3: Split learnable spells into current vs upcoming [curLv+1 .. min(60, curLv+5)] with cost & gold deficit.
function CharacterGuideModel.SplitUpcomingSpells(trainingEntries, playerClass, playerLevel, knownSpellSet, playerMoneyCopper)
    local learnableNow = {}
    local upcoming5 = {}
    local totalCost = 0
    if type(trainingEntries) ~= "table" or type(playerClass) ~= "string" or playerClass == "" then
        return { learnableNow = learnableNow, upcoming5 = upcoming5, totalCost = 0, deficit = 0 }
    end
    local curLv = (type(playerLevel) == "number" and playerLevel >= 1) and math_floor(playerLevel) or 1
    local maxUpcoming = curLv + 5
    if maxUpcoming > 60 then maxUpcoming = 60 end
    local known = type(knownSpellSet) == "table" and knownSpellSet or {}

    for _, sp in ipairs(trainingEntries) do
        if type(sp) == "table" and sp.class == playerClass
            and type(sp.spellID) == "number" and sp.spellID > 0
            and type(sp.level) == "number" and not known[sp.spellID]
        then
            local lv = math_floor(sp.level)
            local cost = (type(sp.cost) == "number" and sp.cost > 0) and math_floor(sp.cost) or 0
            local rec = { spellID = sp.spellID, level = lv, cost = cost, name = sp.name }
            if lv <= curLv then
                table_insert(learnableNow, rec)
                totalCost = totalCost + cost
            elseif lv <= maxUpcoming then
                table_insert(upcoming5, rec)
                totalCost = totalCost + cost
            end
        end
    end

    table_sort(learnableNow, function(a, b) return a.level ~= b.level and a.level < b.level or a.spellID < b.spellID end)
    table_sort(upcoming5, function(a, b) return a.level ~= b.level and a.level < b.level or a.spellID < b.spellID end)

    local money = (type(playerMoneyCopper) == "number" and playerMoneyCopper >= 0) and math_floor(playerMoneyCopper) or 0
    local deficit = totalCost - money
    if deficit < 0 then deficit = 0 end
    return {
        learnableNow = learnableNow,
        upcoming5 = upcoming5,
        totalCost = totalCost,
        deficit = deficit,
    }
end

-- Phase 3: Top-3 actionable upgrades (reqLevel <= playerLevel+3, unique-equipped dedup, 2H compares 16+17 combined iLvl).
function CharacterGuideModel.RankTopUpgrades(bisItems, playerLevel, equippedBySlot, limit)
    local out = {}
    if type(bisItems) ~= "table" then
        return out
    end
    local curLv = (type(playerLevel) == "number" and playerLevel >= 1) and math_floor(playerLevel) or 60
    local maxReq = curLv + 3
    local eq = type(equippedBySlot) == "table" and equippedBySlot or {}
    local cap = (type(limit) == "number" and limit > 0) and math_floor(limit) or 3
    local seenUnique = {}

    for _, it in ipairs(bisItems) do
        if type(it) == "table" and type(it.itemLevel) == "number" and it.itemLevel > 0 then
            local req = (type(it.reqLevel) == "number" and it.reqLevel > 0) and it.reqLevel or 0
            local idKey = it.itemID or it.title
            local dupUnique = (it.uniqueEquipped == true) and idKey and seenUnique[idKey]
            if req <= maxReq and not dupUnique then
                local slotNum = it.equipSlot
                if slotNum == 12 then slotNum = 11 elseif slotNum == 14 then slotNum = 13 end
                local eqBaseline = 0
                if it.isTwoHand == true or it.slot == "양손" then
                    local mh = (type(eq[16]) == "number") and eq[16] or 0
                    local oh = (type(eq[17]) == "number") and eq[17] or 0
                    if mh > 0 and oh > 0 then
                        eqBaseline = (mh + oh) * 0.5
                    else
                        -- Equipped 2H leaves slot 17 empty; compare directly against mainhand without halving
                        eqBaseline = (mh > oh) and mh or oh
                    end
                elseif type(slotNum) == "number" and type(eq[slotNum]) == "number" then
                    eqBaseline = eq[slotNum]
                end
                local delta = it.itemLevel - eqBaseline
                if delta > 0 then
                    if it.uniqueEquipped == true and idKey then
                        seenUnique[idKey] = true
                    end
                    table_insert(out, {
                        itemID = it.itemID,
                        title = tostring(it.title or ("#" .. tostring(it.itemID or "?"))),
                        itemLevel = it.itemLevel,
                        delta = math_floor(delta + 0.5),
                        acq = tostring(it.acq or "던전/퀘스트"),
                    })
                end
            end
        end
    end

    table_sort(out, function(a, b)
        if a.delta ~= b.delta then return a.delta > b.delta end
        return a.itemLevel > b.itemLevel
    end)

    if #out > cap then
        local trimmed = {}
        for i = 1, cap do trimmed[i] = out[i] end
        return trimmed
    end
    return out
end
