-- Module: Api/GameAdapters.lua
-- Responsibility: Verified WoW Forever 1.60.1 adapters for bags, merchant, durability, map/coords, timers, combat buffs/HP, and quest turn-in.
-- Layer: Api (all C_Secrets & pcall boundaries enforced here; zero raw C_* calls in Domain/Features).
local _, ns = ...
ns.Api = ns.Api or {}

local SafeAPI = ns.Api.SafeAPI
local UNAVAILABLE = SafeAPI.UNAVAILABLE
local type = type
local pcall = pcall
local ipairs = ipairs
local tonumber = tonumber
local tostring = tostring
local string_match = string.match

local GameAdapters = {}
ns.Api.GameAdapters = GameAdapters

-- Handles both modern boolean (true/false) and classic Lua (1/nil) WoW API returns.
local function IsTruthy(v)
    return v ~= nil and v ~= false and v ~= 0
end

-- Fail-closed shift helper: returns true|false|nil (nil when unreadable/secret so QoL automation won't bypass user Shift)
function GameAdapters.IsShiftDownState()
    if type(_G.IsShiftKeyDown) ~= "function" then
        return nil
    end
    local v = SafeAPI.SafeRead(_G.IsShiftKeyDown)
    if v == UNAVAILABLE then
        return nil
    end
    return IsTruthy(v)
end

function GameAdapters.IsShiftDown()
    local st = GameAdapters.IsShiftDownState()
    return st == true
end

function GameAdapters.GetEpochTimestamp()
    local t = SafeAPI.SafeRead(_G.time)
    if t ~= UNAVAILABLE and type(t) == "number" then
        return t
    end
    return 0
end

function GameAdapters.StartTicker(intervalSec, fn)
    if C_Timer and type(C_Timer.NewTicker) == "function" then
        local ok, ticker = pcall(C_Timer.NewTicker, intervalSec, fn)
        if ok and ticker then
            return ticker
        end
    end
    return nil
end

function GameAdapters.CancelTicker(ticker)
    if ticker and type(ticker.Cancel) == "function" then
        pcall(ticker.Cancel, ticker)
    end
end

function GameAdapters.GetPlayerZoneText()
    local z = SafeAPI.SafeRead(_G.GetRealZoneText)
    if z ~= UNAVAILABLE and type(z) == "string" and z ~= "" then
        return z
    end
    return ""
end

function GameAdapters.RunAfter(delaySec, fn)
    if C_Timer and type(C_Timer.After) == "function" then
        local ok = pcall(C_Timer.After, delaySec, fn)
        return ok and true or false
    end
    return false
end

function GameAdapters.GetNumBuybackItems()
    if type(_G.GetNumBuybackItems) ~= "function" then
        return nil
    end
    local n = SafeAPI.SafeRead(_G.GetNumBuybackItems)
    if n == UNAVAILABLE or type(n) ~= "number" or n < 0 then
        return nil
    end
    return n
end

function GameAdapters.ScanBagItems()
    if not (C_Container and type(C_Container.GetContainerNumSlots) == "function" and type(C_Container.GetContainerItemInfo) == "function") then
        return {}
    end
    local out = {}
    for bag = 0, 4 do
        local numSlots = SafeAPI.SafeRead(C_Container.GetContainerNumSlots, bag)
        if numSlots ~= UNAVAILABLE and type(numSlots) == "number" and numSlots > 0 then
            for slot = 1, numSlots do
                local info = SafeAPI.SafeRead(C_Container.GetContainerItemInfo, bag, slot)
                if info ~= UNAVAILABLE and type(info) == "table" then
                    local itemID = (not SafeAPI.IsSecret(info.itemID)) and info.itemID or nil
                    local quality = (not SafeAPI.IsSecret(info.quality)) and info.quality or nil
                    local stackCount = (not SafeAPI.IsSecret(info.stackCount)) and info.stackCount or 1
                    -- Fail-closed on secret isLocked: treat secret lock state as locked (true)
                    local isLocked = SafeAPI.IsSecret(info.isLocked) or (info.isLocked == true)
                    local itemName = (not SafeAPI.IsSecret(info.itemName)) and info.itemName or nil
                    local unitPrice = 0
                    if type(itemID) == "number" and C_Item and type(C_Item.GetItemInfo) == "function" then
                        local okI, iName, _, _, _, _, _, _, _, _, _, sellPrice = pcall(C_Item.GetItemInfo, itemID)
                        if okI then
                            if (not itemName) and (not SafeAPI.IsSecret(iName)) and type(iName) == "string" then
                                itemName = iName
                            end
                            if (not SafeAPI.IsSecret(sellPrice)) and type(sellPrice) == "number" then
                                unitPrice = sellPrice
                            end
                        end
                    end
                    if type(itemID) == "number" then
                        out[#out + 1] = {
                            bag = bag,
                            slot = slot,
                            itemID = itemID,
                            quality = quality,
                            stackCount = (type(stackCount) == "number" and stackCount > 0) and stackCount or 1,
                            isLocked = isLocked,
                            name = itemName or ("#" .. tostring(itemID)),
                            unitPrice = unitPrice,
                        }
                    end
                end
            end
        end
    end
    return out
end

function GameAdapters.SellContainerItem(bag, slot)
    if SafeAPI.InCombat() then
        return false
    end
    if not (C_Container and type(C_Container.UseContainerItem) == "function") then
        return false
    end
    local ok = pcall(C_Container.UseContainerItem, bag, slot)
    return ok and true or false
end

function GameAdapters.GetRepairInfo()
    local canRepairRaw = SafeAPI.SafeRead(_G.CanMerchantRepair)
    if canRepairRaw == UNAVAILABLE or not IsTruthy(canRepairRaw) then
        return false, 0, false, nil, nil, false
    end
    if type(_G.GetRepairAllCost) ~= "function" then
        return false, 0, false, nil, nil, false
    end
    local ok, c, n = pcall(_G.GetRepairAllCost)
    if (not ok) or SafeAPI.IsSecret(c) or SafeAPI.IsSecret(n) or type(c) ~= "number" or c < 0 then
        return false, 0, false, nil, nil, false
    end
    local cost = c
    -- Needs repair strictly when cost > 0 AND 2nd return (canRepair) is truthy; when cost == 0,
    -- repair is complete regardless of whether the client keeps canRepair true or sets it false/nil.
    local needsRepair = (cost > 0) and IsTruthy(n)
    local canGuildRaw = SafeAPI.SafeRead(_G.CanGuildBankRepair)
    local canGuild = canGuildRaw ~= UNAVAILABLE and IsTruthy(canGuildRaw)
    local guildWithdraw = SafeAPI.SafeRead(_G.GetGuildBankWithdrawMoney)
    if guildWithdraw == UNAVAILABLE or type(guildWithdraw) ~= "number" then
        guildWithdraw = nil
    end
    local guildMoney = SafeAPI.SafeRead(_G.GetGuildBankMoney)
    if guildMoney == UNAVAILABLE or type(guildMoney) ~= "number" then
        guildMoney = nil
    end
    return needsRepair, cost, canGuild, guildWithdraw, guildMoney, true
end

function GameAdapters.RepairAll(useGuild)
    if SafeAPI.InCombat() or type(_G.RepairAllItems) ~= "function" then
        return false
    end
    local ok = pcall(_G.RepairAllItems, useGuild and true or false)
    return ok and true or false
end

function GameAdapters.GetDurabilitySlots()
    if type(_G.GetInventoryItemDurability) ~= "function" then
        return nil
    end
    local slots = {}
    for slotId = 1, 18 do
        local ok, cur, maxV = pcall(_G.GetInventoryItemDurability, slotId)
        if ok and (not SafeAPI.IsSecret(cur)) and (not SafeAPI.IsSecret(maxV))
            and type(cur) == "number" and type(maxV) == "number" and maxV > 0
        then
            slots[#slots + 1] = { cur = cur, max = maxV }
        end
    end
    return (#slots > 0) and slots or nil
end

function GameAdapters.GetPlayerPosition()
    if not (C_Map and type(C_Map.GetBestMapForUnit) == "function" and type(C_Map.GetPlayerMapPosition) == "function") then
        return nil
    end
    local mapID = SafeAPI.SafeRead(C_Map.GetBestMapForUnit, "player")
    if mapID == UNAVAILABLE or type(mapID) ~= "number" or mapID <= 0 then
        return nil
    end
    local pos = SafeAPI.SafeRead(C_Map.GetPlayerMapPosition, mapID, "player")
    if pos == UNAVAILABLE or type(pos) ~= "table" then
        return nil
    end
    local x, y = pos.x, pos.y
    if (x == nil or y == nil) and type(pos.GetXY) == "function" then
        local okXY, gx, gy = pcall(pos.GetXY, pos)
        if okXY then x, y = gx, gy end
    end
    if SafeAPI.IsSecret(x) or SafeAPI.IsSecret(y) or type(x) ~= "number" or type(y) ~= "number" then
        return nil
    end
    -- Honest facing: nil if unavailable (never fabricates 0 / North)
    local facing = SafeAPI.SafeRead(_G.GetPlayerFacing)
    return {
        mapID = mapID,
        x = x,
        y = y,
        facing = (facing ~= UNAVAILABLE and type(facing) == "number") and facing or nil,
    }
end

function GameAdapters.IsPlayerDeadOrGhostState()
    if type(_G.UnitIsDeadOrGhost) ~= "function" then
        return nil
    end
    local v = SafeAPI.SafeRead(_G.UnitIsDeadOrGhost, "player")
    if v == UNAVAILABLE then
        return nil
    end
    return IsTruthy(v)
end

function GameAdapters.IsPlayerDeadOrGhost()
    return GameAdapters.IsPlayerDeadOrGhostState() == true
end

function GameAdapters.GetPlayerClass()
    if type(_G.UnitClass) == "function" then
        local ok, _, cls = pcall(_G.UnitClass, "player")
        if ok and (not SafeAPI.IsSecret(cls)) and type(cls) == "string" then
            return cls
        end
    end
    return nil
end

function GameAdapters.GetPlayerClassAndBuffs(spellList)
    local engClass = GameAdapters.GetPlayerClass()
    local knownSet = {}
    local activeSet = {}
    local auraReadable = (C_UnitAuras and type(C_UnitAuras.GetPlayerAuraBySpellID) == "function") and true or false
    for _, sid in ipairs(spellList or {}) do
        local isKnown = false
        if C_Spell and type(C_Spell.IsSpellKnown) == "function" then
            local k = SafeAPI.SafeRead(C_Spell.IsSpellKnown, sid)
            if k ~= UNAVAILABLE and IsTruthy(k) then isKnown = true end
        elseif type(_G.IsPlayerSpell) == "function" then
            local k = SafeAPI.SafeRead(_G.IsPlayerSpell, sid)
            if k ~= UNAVAILABLE and IsTruthy(k) then isKnown = true end
        end
        if isKnown then knownSet[sid] = true end

        if auraReadable then
            local a = SafeAPI.SafeRead(C_UnitAuras.GetPlayerAuraBySpellID, sid)
            if a == UNAVAILABLE then
                auraReadable = false
            elseif type(a) == "table" then
                activeSet[sid] = true
            end
        end
    end
    local hasMainHandEnchant = nil
    if type(_G.GetWeaponEnchantInfo) == "function" then
        local okW, mh = pcall(_G.GetWeaponEnchantInfo)
        if okW and not SafeAPI.IsSecret(mh) then
            hasMainHandEnchant = IsTruthy(mh)
        end
    end
    return engClass, knownSet, activeSet, hasMainHandEnchant, auraReadable
end

function GameAdapters.GetPlayerHealth()
    if type(_G.UnitHealth) ~= "function" or type(_G.UnitHealthMax) ~= "function" then
        return nil, nil
    end
    local hp = SafeAPI.SafeRead(_G.UnitHealth, "player")
    local hpMax = SafeAPI.SafeRead(_G.UnitHealthMax, "player")
    if hp == UNAVAILABLE or hpMax == UNAVAILABLE or type(hp) ~= "number" or type(hpMax) ~= "number" then
        return nil, nil
    end
    return hp, hpMax
end

function GameAdapters.IsFishingPoleEquipped()
    if type(_G.GetInventoryItemID) ~= "function" then
        return false
    end
    local itemID = SafeAPI.SafeRead(_G.GetInventoryItemID, "player", 16)
    if itemID == UNAVAILABLE or type(itemID) ~= "number" then
        return false
    end
    if C_Item and type(C_Item.GetItemInfo) == "function" then
        local ok, _, _, _, _, _, _, _, _, _, _, _, classID, subClassID = pcall(C_Item.GetItemInfo, itemID)
        if ok and (not SafeAPI.IsSecret(classID)) and (not SafeAPI.IsSecret(subClassID)) then
            return classID == 2 and subClassID == 20
        end
    end
    return false
end

function GameAdapters.GetZoneLayerID(unit)
    if type(_G.UnitGUID) ~= "function" then
        return nil
    end
    local guid = SafeAPI.SafeRead(_G.UnitGUID, unit or "target")
    if guid == UNAVAILABLE or type(guid) ~= "string" then
        return nil
    end
    local zoneUID = string_match(guid, "^%a+%-%d+%-%d+%-%d+%-(%d+)%-")
    return zoneUID and tonumber(zoneUID) or nil
end

function GameAdapters.AcceptQuestSafe()
    if type(_G.QuestFlagsPVP) ~= "function" then
        return false, "PVP_CHECK_UNAVAILABLE"
    end
    local isPvp = SafeAPI.SafeRead(_G.QuestFlagsPVP)
    if isPvp == UNAVAILABLE or IsTruthy(isPvp) then
        return false, "PVP_FLAG_CONFIRM_REQUIRED"
    end
    if type(_G.AcceptQuest) == "function" then
        local ok = pcall(_G.AcceptQuest)
        return ok and true or false, ok and "ACCEPTED" or "FAILED"
    end
    return false, "UNSUPPORTED"
end

function GameAdapters.CompleteQuestSafe()
    if type(_G.GetQuestMoneyToGet) == "function" then
        local reqMoney = SafeAPI.SafeRead(_G.GetQuestMoneyToGet)
        if reqMoney == UNAVAILABLE or (type(reqMoney) == "number" and reqMoney > 0) then
            return false, "MONEY_CONFIRM_REQUIRED"
        end
    end
    if type(_G.GetNumQuestItems) == "function" then
        local reqItems = SafeAPI.SafeRead(_G.GetNumQuestItems)
        if reqItems == UNAVAILABLE or (type(reqItems) == "number" and reqItems > 0) then
            return false, "ITEM_DONATION_CONFIRM_REQUIRED"
        end
    end
    if type(_G.IsQuestCompletable) == "function" then
        local completable = SafeAPI.SafeRead(_G.IsQuestCompletable)
        if completable == UNAVAILABLE or not IsTruthy(completable) then
            return false, "NOT_COMPLETABLE"
        end
    end
    if type(_G.CompleteQuest) == "function" then
        local ok = pcall(_G.CompleteQuest)
        return ok and true or false, ok and "COMPLETED" or "FAILED"
    end
    return false, "UNSUPPORTED"
end

function GameAdapters.TurnInQuestSafe()
    if type(_G.GetQuestMoneyToGet) == "function" then
        local reqMoney = SafeAPI.SafeRead(_G.GetQuestMoneyToGet)
        if reqMoney == UNAVAILABLE or (type(reqMoney) == "number" and reqMoney > 0) then
            return false, "MONEY_CONFIRM_REQUIRED"
        end
    end
    -- Fail-closed on GetNumQuestChoices: must be a readable number <= 1
    if type(_G.GetNumQuestChoices) ~= "function" then
        return false, "CHOICES_UNAVAILABLE"
    end
    local choices = SafeAPI.SafeRead(_G.GetNumQuestChoices)
    if choices == UNAVAILABLE or type(choices) ~= "number" then
        return false, "CHOICES_UNAVAILABLE"
    end
    if choices > 1 then
        return false, "MULTIPLE_CHOICES"
    end
    if type(_G.GetQuestReward) == "function" then
        local ok = pcall(_G.GetQuestReward, 1)
        return ok and true or false, ok and "TURNED_IN" or "FAILED"
    end
    return false, "UNSUPPORTED"
end

function GameAdapters.GetMonotonicTime()
    local t = SafeAPI.SafeRead(_G.GetTime)
    if t ~= UNAVAILABLE and type(t) == "number" then
        return t
    end
    return nil
end

function GameAdapters.IsAutoLootModifierDown()
    if type(_G.IsModifiedClick) == "function" then
        local v = SafeAPI.SafeRead(_G.IsModifiedClick, "AUTOLOOTTOGGLE")
        if v == UNAVAILABLE then
            return nil
        end
        return IsTruthy(v)
    end
    if type(_G.IsShiftKeyDown) ~= "function" then
        return nil
    end
    local v = SafeAPI.SafeRead(_G.IsShiftKeyDown)
    if v == UNAVAILABLE then
        return nil
    end
    return IsTruthy(v)
end

function GameAdapters.GetCVarRaw(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local v = UNAVAILABLE
    if C_CVar and type(C_CVar.GetCVar) == "function" then
        v = SafeAPI.SafeRead(C_CVar.GetCVar, name)
    elseif type(_G.GetCVar) == "function" then
        v = SafeAPI.SafeRead(_G.GetCVar, name)
    end
    if v == UNAVAILABLE then
        return nil
    end
    return v
end

function GameAdapters.GetCVarBool(name)
    local v = GameAdapters.GetCVarRaw(name)
    if v == nil then
        return nil
    end
    if v == "1" or v == "true" or v == true or v == 1 then
        return true
    end
    if v == "0" or v == "false" or v == false or v == 0 then
        return false
    end
    return nil
end

function GameAdapters.SetCVarSafe(name, value)
    if SafeAPI.InCombat() then
        return false, "IN_COMBAT"
    end
    if type(name) ~= "string" or name == "" then
        return false, "INVALID"
    end
    if C_CVar and type(C_CVar.SetCVar) == "function" then
        local ok = pcall(C_CVar.SetCVar, name, tostring(value))
        return ok and true or false, ok and "APPLIED" or "FAILED"
    end
    if type(_G.SetCVar) == "function" then
        local ok = pcall(_G.SetCVar, name, tostring(value))
        return ok and true or false, ok and "APPLIED" or "FAILED"
    end
    return false, "UNSUPPORTED"
end

function GameAdapters.FastLootAll()
    if type(_G.GetNumLootItems) ~= "function" or type(_G.LootSlot) ~= "function" then
        return 0
    end
    local count = SafeAPI.SafeRead(_G.GetNumLootItems)
    if count == UNAVAILABLE or type(count) ~= "number" or count <= 0 then
        return 0
    end
    local looted = 0
    for slot = count, 1, -1 do
        local ok = pcall(_G.LootSlot, slot)
        if ok then
            looted = looted + 1
        end
    end
    return looted
end

function GameAdapters.GetInstanceContext()
    if type(_G.IsInInstance) ~= "function" then
        return nil, nil, nil
    end
    local ok, inInst, instType = pcall(_G.IsInInstance)
    if (not ok) or SafeAPI.IsSecret(inInst) or SafeAPI.IsSecret(instType) then
        return nil, nil, nil
    end
    local instName = ""
    if type(_G.GetInstanceInfo) == "function" then
        local okN, rawName = pcall(_G.GetInstanceInfo)
        if okN and (not SafeAPI.IsSecret(rawName)) and type(rawName) == "string" then
            instName = rawName
        end
    end
    return IsTruthy(inInst), (type(instType) == "string" and instType or "none"), instName
end

function GameAdapters.HasSelfResOption()
    if type(_G.HasSoulstone) ~= "function" then
        return nil
    end
    local ok, res = pcall(_G.HasSoulstone)
    if (not ok) or SafeAPI.IsSecret(res) then
        return nil
    end
    if type(res) == "string" then
        return res ~= ""
    end
    return IsTruthy(res)
end

function GameAdapters.ReleaseSpiritSafe()
    if type(_G.RepopMe) ~= "function" then
        return false
    end
    local ok = pcall(_G.RepopMe)
    return ok and true or false
end

-- Fail-closed combat check for Resurrection: checks player combat, caster combat, active boss encounter,
-- IsEncounterInProgress, and refuses if UnitAffectingCombat is missing/errors/secret or casterName is unreadable.
function GameAdapters.IsResurrectInCombat(casterName, bossActive)
    if bossActive == true then
        return true
    end
    if SafeAPI.InCombat() then
        return true
    end
    if type(_G.IsEncounterInProgress) == "function" then
        local enc = SafeAPI.SafeRead(_G.IsEncounterInProgress)
        if enc == UNAVAILABLE or IsTruthy(enc) then
            return true
        end
    end
    if type(_G.UnitAffectingCombat) ~= "function" then
        return true
    end
    local okP, resP = pcall(_G.UnitAffectingCombat, "player")
    if (not okP) or SafeAPI.IsSecret(resP) or IsTruthy(resP) then
        return true
    end
    if SafeAPI.IsSecret(casterName) or type(casterName) ~= "string" or casterName == "" then
        return true
    end
    if type(_G.UnitExists) == "function" then
        local ex = SafeAPI.SafeRead(_G.UnitExists, casterName)
        if ex == UNAVAILABLE or not IsTruthy(ex) then
            return true
        end
    end
    local okC, resC = pcall(_G.UnitAffectingCombat, casterName)
    if (not okC) or SafeAPI.IsSecret(resC) or IsTruthy(resC) then
        return true
    end
    return false
end

function GameAdapters.GetItemSellPrice(itemID)
    if type(itemID) ~= "number" or itemID <= 0 then
        return nil
    end
    if not (C_Item and type(C_Item.GetItemInfo) == "function") then
        return nil
    end
    local ok, _, _, _, _, _, _, _, _, _, _, sellPrice = pcall(C_Item.GetItemInfo, itemID)
    if ok and (not SafeAPI.IsSecret(sellPrice)) and type(sellPrice) == "number" and sellPrice > 0 then
        return sellPrice
    end
    return nil
end

function GameAdapters.GetItemLevel(itemID)
    if type(itemID) ~= "number" or itemID <= 0 then
        return nil
    end
    if C_Item and type(C_Item.GetDetailedItemLevelInfo) == "function" then
        local ilvl = SafeAPI.SafeRead(C_Item.GetDetailedItemLevelInfo, itemID)
        if ilvl ~= UNAVAILABLE and type(ilvl) == "number" and ilvl > 0 then
            return ilvl
        end
    end
    return nil
end

function GameAdapters.IsControlDown()
    if type(_G.IsControlKeyDown) ~= "function" then return false end
    local v = SafeAPI.SafeRead(_G.IsControlKeyDown)
    return v ~= UNAVAILABLE and IsTruthy(v)
end

function GameAdapters.IsAltDown()
    if type(_G.IsAltKeyDown) ~= "function" then return false end
    local v = SafeAPI.SafeRead(_G.IsAltKeyDown)
    return v ~= UNAVAILABLE and IsTruthy(v)
end

function GameAdapters.ToggleQuestWatchSafe(questID, currentlyWatched)
    if SafeAPI.InCombat() or type(questID) ~= "number" or questID <= 0 or not C_QuestLog then
        return false
    end
    if currentlyWatched then
        if type(C_QuestLog.RemoveQuestWatch) == "function" then
            return pcall(C_QuestLog.RemoveQuestWatch, questID) and true or false
        end
    else
        if type(C_QuestLog.AddQuestWatch) == "function" then
            return pcall(C_QuestLog.AddQuestWatch, questID) and true or false
        end
    end
    return false
end

function GameAdapters.InsertQuestChatLink(questID)
    if type(questID) ~= "number" or questID <= 0 or type(_G.GetQuestLink) ~= "function" then
        return false
    end
    local link = SafeAPI.SafeRead(_G.GetQuestLink, questID)
    if link == UNAVAILABLE or type(link) ~= "string" or link == "" then
        return false
    end
    if type(_G.ChatEdit_InsertLink) == "function" then
        local ok, res = pcall(_G.ChatEdit_InsertLink, link)
        if ok and res ~= false then return true end
    end
    local edit = (type(_G.ChatEdit_GetActiveWindow) == "function") and SafeAPI.SafeRead(_G.ChatEdit_GetActiveWindow) or nil
    if edit and edit ~= UNAVAILABLE and type(edit.Insert) == "function" then
        return pcall(edit.Insert, edit, link) and true or false
    end
    return false
end

function GameAdapters.HasActiveChatEditBox()
    if type(_G.ChatEdit_GetActiveWindow) ~= "function" then return false end
    local edit = SafeAPI.SafeRead(_G.ChatEdit_GetActiveWindow)
    return edit ~= nil and edit ~= UNAVAILABLE
end

function GameAdapters.GetMapName(mapID)
    if type(mapID) ~= "number" or mapID <= 0 then return nil end
    if C_Map and type(C_Map.GetMapInfo) == "function" then
        local info = SafeAPI.SafeRead(C_Map.GetMapInfo, mapID)
        if info ~= UNAVAILABLE and type(info) == "table" and not SafeAPI.IsSecret(info.name) and type(info.name) == "string" then
            return info.name
        end
    end
    return nil
end

-- Tri-state quest completion check: true (completed), false (not completed), nil (unavailable/secret).
function GameAdapters.IsQuestCompleted(questID)
    if type(questID) ~= "number" or questID <= 0 then return nil end
    if C_QuestLog and type(C_QuestLog.IsQuestFlaggedCompleted) == "function" then
        local v = SafeAPI.SafeRead(C_QuestLog.IsQuestFlaggedCompleted, questID)
        if v == UNAVAILABLE then return nil end
        return IsTruthy(v)
    end
    return nil
end

function GameAdapters.GetCursorScreenPosition()
    if type(_G.GetCursorPosition) ~= "function" then
        return nil, nil
    end
    local ok, x, y = pcall(_G.GetCursorPosition)
    if (not ok) or SafeAPI.IsSecret(x) or SafeAPI.IsSecret(y) or type(x) ~= "number" or type(y) ~= "number" then
        return nil, nil
    end
    return x, y
end

function GameAdapters.AcceptResurrectSafe(casterName, bossActive)
    if GameAdapters.IsResurrectInCombat(casterName, bossActive) then
        return false, "IN_COMBAT"
    end
    if type(_G.AcceptResurrect) ~= "function" then
        return false, "UNSUPPORTED"
    end
    local ok = pcall(_G.AcceptResurrect)
    return ok and true or false, ok and "ACCEPTED" or "FAILED"
end

local function NormalizeRealmToken(rawRealm)
    if type(rawRealm) ~= "string" or rawRealm == "" then
        return nil
    end
    local cleaned = string.gsub(rawRealm, "[%s%-']", "")
    if cleaned == "" then
        return nil
    end
    return string.lower(cleaned)
end

-- Parses "Name-Realm" or "Name" (attaching ownRealmNorm ONLY when no '-' suffix is present).
local function NormalizeFullName(raw, ownRealmNorm)
    if type(raw) ~= "string" or raw == "" then
        return nil, nil
    end
    local base, realm = string_match(raw, "^([^%-]+)%-(.+)$")
    if base and realm then
        return string.lower(base), NormalizeRealmToken(realm)
    end
    if not ownRealmNorm then
        return nil, nil
    end
    return string.lower(raw), ownRealmNorm
end

local function NamesMatchSameRealm(targetBase, targetRealm, candidateRaw, ownRealmNorm)
    local cBase, cRealm = NormalizeFullName(candidateRaw, ownRealmNorm)
    return (cBase ~= nil) and (cRealm ~= nil) and (cBase == targetBase) and (cRealm == targetRealm)
end

function GameAdapters.IsTrustedInviter(inviterName)
    if SafeAPI.IsSecret(inviterName) or type(inviterName) ~= "string" or inviterName == "" then
        return false
    end
    local ownRealmNorm = NormalizeRealmToken(SafeAPI.GetCanonicalRealm())
    local targetBase, targetRealm = NormalizeFullName(inviterName, ownRealmNorm)
    if (not targetBase) or (not targetRealm) then
        return false
    end
    if C_FriendList and type(C_FriendList.GetNumFriends) == "function" and type(C_FriendList.GetFriendInfoByIndex) == "function" then
        local numF = SafeAPI.SafeRead(C_FriendList.GetNumFriends)
        if numF ~= UNAVAILABLE and type(numF) == "number" and numF > 0 then
            for i = 1, numF do
                local info = SafeAPI.SafeRead(C_FriendList.GetFriendInfoByIndex, i)
                if info ~= UNAVAILABLE and type(info) == "table" and (not SafeAPI.IsSecret(info.name)) then
                    if NamesMatchSameRealm(targetBase, targetRealm, info.name, ownRealmNorm) then
                        return true
                    end
                end
            end
        end
    elseif type(_G.GetNumFriends) == "function" and type(_G.GetFriendInfo) == "function" then
        local numF = SafeAPI.SafeRead(_G.GetNumFriends)
        if numF ~= UNAVAILABLE and type(numF) == "number" and numF > 0 then
            for i = 1, numF do
                local okF, fName = pcall(_G.GetFriendInfo, i)
                if okF and (not SafeAPI.IsSecret(fName)) and NamesMatchSameRealm(targetBase, targetRealm, fName, ownRealmNorm) then
                    return true
                end
            end
        end
    end
    if type(_G.GetNumGuildMembers) == "function" and type(_G.GetGuildRosterInfo) == "function" then
        local numG = SafeAPI.SafeRead(_G.GetNumGuildMembers)
        if numG ~= UNAVAILABLE and type(numG) == "number" and numG > 0 then
            for i = 1, numG do
                local okG, gName = pcall(_G.GetGuildRosterInfo, i)
                if okG and (not SafeAPI.IsSecret(gName)) and NamesMatchSameRealm(targetBase, targetRealm, gName, ownRealmNorm) then
                    return true
                end
            end
        end
    end
    return false
end

function GameAdapters.AcceptGroupInviteSafe()
    if type(_G.AcceptGroup) ~= "function" then
        return false
    end
    local ok = pcall(_G.AcceptGroup)
    return ok and true or false
end

function GameAdapters.GetPlayerXPInfo()
    if type(_G.UnitXP) ~= "function" or type(_G.UnitXPMax) ~= "function" or type(_G.UnitLevel) ~= "function" then
        return nil, nil, nil, nil, 0, false
    end
    local okX, xp = pcall(_G.UnitXP, "player")
    local okM, maxXP = pcall(_G.UnitXPMax, "player")
    local okL, lvl = pcall(_G.UnitLevel, "player")
    if not (okX and okM and okL) then
        return nil, nil, nil, nil, 0, false
    end
    if SafeAPI.IsSecret(xp) or SafeAPI.IsSecret(maxXP) or SafeAPI.IsSecret(lvl)
        or type(xp) ~= "number" or xp < 0
        or type(maxXP) ~= "number" or maxXP < 0
        or type(lvl) ~= "number" or lvl < 1
    then
        return nil, nil, nil, nil, 0, false
    end
    local maxLvl = nil
    if type(_G.GetMaxPlayerLevel) == "function" then
        local ml = SafeAPI.SafeRead(_G.GetMaxPlayerLevel)
        if ml ~= UNAVAILABLE and type(ml) == "number" and ml > 0 then
            maxLvl = ml
        end
    end
    local rested = 0
    if type(_G.GetXPExhaustion) == "function" then
        local r = SafeAPI.SafeRead(_G.GetXPExhaustion)
        if r ~= UNAVAILABLE and type(r) == "number" and r > 0 then
            rested = r
        end
    end
    return math.floor(xp), math.floor(maxXP), math.floor(lvl), maxLvl, math.floor(rested), true
end

function GameAdapters.GetPlayerName()
    if type(_G.UnitName) ~= "function" then return nil end
    local ok, name = pcall(_G.UnitName, "player")
    if ok and (not SafeAPI.IsSecret(name)) and type(name) == "string" and name ~= "" then
        return name
    end
    return nil
end

function GameAdapters.GetPlayerClassLocalized()
    if type(_G.UnitClass) ~= "function" then return nil, nil end
    local ok, loc, eng = pcall(_G.UnitClass, "player")
    if ok and (not SafeAPI.IsSecret(loc)) and (not SafeAPI.IsSecret(eng)) and type(eng) == "string" then
        return (type(loc) == "string" and loc or eng), eng
    end
    return nil, nil
end

function GameAdapters.GetPlayerLevel()
    if type(_G.UnitLevel) ~= "function" then return nil end
    local lvl = SafeAPI.SafeRead(_G.UnitLevel, "player")
    if lvl ~= UNAVAILABLE and type(lvl) == "number" and lvl >= 1 then
        return math.floor(lvl)
    end
    return nil
end

function GameAdapters.GetUnspentTalentPoints()
    if type(_G.UnitCharacterPoints) == "function" then
        local pts = SafeAPI.SafeRead(_G.UnitCharacterPoints, "player")
        if pts ~= UNAVAILABLE and type(pts) == "number" and pts >= 0 then
            return math.floor(pts)
        end
    end
    if type(_G.GetUnspentTalentPoints) == "function" then
        local pts = SafeAPI.SafeRead(_G.GetUnspentTalentPoints)
        if pts ~= UNAVAILABLE and type(pts) == "number" and pts >= 0 then
            return math.floor(pts)
        end
    end
    return nil
end

function GameAdapters.GetKnownSpellSet(spellIDs)
    local set = {}
    for _, sid in ipairs(spellIDs or {}) do
        if type(sid) == "number" and sid > 0 then
            local k = UNAVAILABLE
            if C_Spell and type(C_Spell.IsSpellKnown) == "function" then
                k = SafeAPI.SafeRead(C_Spell.IsSpellKnown, sid)
            elseif type(_G.IsPlayerSpell) == "function" then
                k = SafeAPI.SafeRead(_G.IsPlayerSpell, sid)
            end
            if k ~= UNAVAILABLE and IsTruthy(k) then
                set[sid] = true
            end
        end
    end
    return set
end

function GameAdapters.GetSpellName(spellID)
    if type(spellID) ~= "number" or spellID <= 0 then return nil end
    if C_Spell and type(C_Spell.GetSpellInfo) == "function" then
        local info = SafeAPI.SafeRead(C_Spell.GetSpellInfo, spellID)
        if info ~= UNAVAILABLE and type(info) == "table" and not SafeAPI.IsSecret(info.name) and type(info.name) == "string" then
            return info.name
        end
    end
    return nil
end

function GameAdapters.IsInRaidState()
    if type(_G.IsInRaid) ~= "function" then return nil end
    local v = SafeAPI.SafeRead(_G.IsInRaid)
    if v == UNAVAILABLE then return nil end
    return IsTruthy(v)
end

function GameAdapters.IsInGroupState()
    if type(_G.IsInGroup) ~= "function" then return nil end
    local v = SafeAPI.SafeRead(_G.IsInGroup)
    if v == UNAVAILABLE then return nil end
    return IsTruthy(v)
end

function GameAdapters.IsInRaidSafe()
    return GameAdapters.IsInRaidState() == true
end

function GameAdapters.IsInGroupSafe()
    return GameAdapters.IsInGroupState() == true
end

-- Returns (name, status): status is "OK" | "SECRET" | "UNKNOWN" (rejects UNKNOWNOBJECT / unresolved names, F3)
function GameAdapters.GetUnitNameSafe(unit)
    if type(_G.UnitName) ~= "function" then return nil, "UNKNOWN" end
    local ok, raw = pcall(_G.UnitName, unit)
    if not ok then return nil, "UNKNOWN" end
    if SafeAPI.IsSecret(raw) then return nil, "SECRET" end
    if type(raw) ~= "string" or raw == "" then return nil, "UNKNOWN" end
    local unk = _G.UNKNOWNOBJECT
    if (type(unk) == "string" and raw == unk) or raw == "알 수 없음" or raw == "Unknown" then
        return nil, "UNKNOWN"
    end
    return raw, "OK"
end

function GameAdapters.IsUnitPlayer(unit)
    if unit == "player" then return true end
    if type(_G.UnitIsUnit) == "function" then
        local v = SafeAPI.SafeRead(_G.UnitIsUnit, unit, "player")
        if v ~= UNAVAILABLE then
            return IsTruthy(v)
        end
    end
    return false
end

-- Scans player's helpful external auras for newly received single-target buffs (F5 runtime consumer, secret-safe).
-- Returns (casterName, buffName, status) where status is "OK" | "UNREADABLE".
-- Fail-Closed: if ANY aura or its fields are secret/unreadable, leaves seenAuraIDs untouched and returns "UNREADABLE".
function GameAdapters.ScanNewExternalBuff(seenAuraIDs)
    if not (C_UnitAuras and type(C_UnitAuras.GetAuraDataByIndex) == "function") then
        return nil, nil, "UNREADABLE"
    end
    seenAuraIDs = seenAuraIDs or {}
    local current = {}
    local foundCaster, foundBuff = nil, nil
    for i = 1, 40 do
        local aura = SafeAPI.SafeRead(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
        if aura == UNAVAILABLE then
            return nil, nil, "UNREADABLE"
        end
        if type(aura) ~= "table" then
            break
        end
        if SafeAPI.IsSecret(aura.spellId) or SafeAPI.IsSecret(aura.name) or SafeAPI.IsSecret(aura.sourceUnit) then
            return nil, nil, "UNREADABLE"
        end
        local sid = aura.spellId
        local bName = aura.name
        local src = aura.sourceUnit
        if type(sid) == "number" and sid > 0 then
            current[sid] = true
            if (not foundCaster) and (not seenAuraIDs[sid]) and type(src) == "string" and src ~= "" and not GameAdapters.IsUnitPlayer(src) then
                local cName, st = GameAdapters.GetUnitNameSafe(src)
                if st == "OK" and type(bName) == "string" and bName ~= "" then
                    foundCaster, foundBuff = cName, bName
                end
            end
        end
    end
    for k in pairs(seenAuraIDs) do seenAuraIDs[k] = nil end
    for k, v in pairs(current) do seenAuraIDs[k] = v end
    return foundCaster, foundBuff, "OK"
end

-- Returns (units, ok): ok=false when group size is unreadable while in group (Fail-Closed for F3).
function GameAdapters.GetRosterUnitTokens()
    local units = { "player" }
    local inGroup = GameAdapters.IsInGroupState()
    local isRaid = GameAdapters.IsInRaidState()
    if inGroup == nil or isRaid == nil then
        return units, false
    end
    if not inGroup then
        return units, true
    end
    if type(_G.GetNumGroupMembers) ~= "function" then
        return units, false
    end
    local n = SafeAPI.SafeRead(_G.GetNumGroupMembers)
    if n == UNAVAILABLE or type(n) ~= "number" or n <= 0 then
        return units, false
    end
    local num = math.floor(n)
    if isRaid then
        units = {}
        local cap = (num > 40) and 40 or num
        for i = 1, cap do
            units[#units + 1] = "raid" .. tostring(i)
        end
    elseif num > 1 then
        local cap = (num - 1 > 4) and 4 or (num - 1)
        for i = 1, cap do
            units[#units + 1] = "party" .. tostring(i)
        end
    end
    return units, true
end

-- Invariant I1: Checks SafeAPI.IsSecret FIRST on all 5 returns of UnitDetailedThreatSituation before any op.
function GameAdapters.GetUnitThreatSample(unit, targetUnit)
    if type(_G.UnitDetailedThreatSituation) ~= "function" then
        return nil
    end
    local target = targetUnit or "target"
    if type(_G.UnitExists) == "function" then
        local ex = SafeAPI.SafeRead(_G.UnitExists, target)
        if ex == UNAVAILABLE or not IsTruthy(ex) then
            return nil
        end
    end
    local ok, isTanking, status, scaledPct, rawPct, threatValue = pcall(_G.UnitDetailedThreatSituation, unit, target)
    if not ok then
        return nil
    end
    local name = unit
    if type(_G.UnitName) == "function" then
        local okN, rawName = pcall(_G.UnitName, unit)
        if okN and (not SafeAPI.IsSecret(rawName)) and type(rawName) == "string" and rawName ~= "" then
            name = rawName
        end
    end
    local cls = nil
    if type(_G.UnitClass) == "function" then
        local okC, _, eng = pcall(_G.UnitClass, unit)
        if okC and (not SafeAPI.IsSecret(eng)) and type(eng) == "string" then
            cls = eng
        end
    end
    if SafeAPI.IsSecret(isTanking) or SafeAPI.IsSecret(status)
        or SafeAPI.IsSecret(scaledPct) or SafeAPI.IsSecret(rawPct) or SafeAPI.IsSecret(threatValue)
    then
        return { unit = unit, name = name, class = cls, isSecret = true }
    end
    if scaledPct == nil and threatValue == nil then
        return nil
    end
    return {
        unit = unit,
        name = name,
        class = cls,
        isPlayer = GameAdapters.IsUnitPlayer(unit),
        isSecret = false,
        isTanking = IsTruthy(isTanking),
        status = (type(status) == "number") and status or 0,
        scaledPct = (type(scaledPct) == "number") and scaledPct or nil,
        rawPct = (type(rawPct) == "number") and rawPct or nil,
        threatValue = (type(threatValue) == "number") and threatValue or nil,
    }
end

function GameAdapters.IsChatMessagingLocked()
    if C_ChatInfo and type(C_ChatInfo.InChatMessagingLockdown) == "function" then
        local v = SafeAPI.SafeRead(C_ChatInfo.InChatMessagingLockdown)
        if v == UNAVAILABLE then
            return true
        end
        return IsTruthy(v)
    end
    return false
end

function GameAdapters.SendChatSafe(msg, channel, target)
    if SafeAPI.InCombat() or GameAdapters.IsChatMessagingLocked() then
        return false, "LOCKED"
    end
    if SafeAPI.IsSecret(msg) or type(msg) ~= "string" or msg == "" then
        return false, "INVALID_MSG"
    end
    local clean = string.gsub(msg, "|", "")
    local ch = (type(channel) == "string" and channel ~= "") and channel or "PARTY"
    if C_ChatInfo and type(C_ChatInfo.SendChatMessage) == "function" then
        local ok = pcall(C_ChatInfo.SendChatMessage, clean, ch, nil, target)
        return ok and true or false, ok and "SENT" or "FAILED"
    end
    if type(_G.SendChatMessage) == "function" then
        local ok = pcall(_G.SendChatMessage, clean, ch, nil, target)
        return ok and true or false, ok and "SENT" or "FAILED"
    end
    return false, "UNSUPPORTED"
end

function GameAdapters.DoEmoteSafe(token, target)
    if SafeAPI.InCombat() or GameAdapters.IsChatMessagingLocked() then
        return false, "LOCKED"
    end
    if type(_G.DoEmote) ~= "function" or type(token) ~= "string" or token == "" then
        return false, "UNSUPPORTED"
    end
    local ok = pcall(_G.DoEmote, token, target)
    return ok and true or false, ok and "SENT" or "FAILED"
end

-- Returns map { [slotId] = iLvl } for equipped items (slots 1..18); omits unreadable/empty slots (KPI-2 zero fabrication).
function GameAdapters.GetEquippedItemLevelMap()
    local map = {}
    if type(_G.GetInventoryItemID) ~= "function" then
        return map
    end
    for slotId = 1, 18 do
        local itemID = SafeAPI.SafeRead(_G.GetInventoryItemID, "player", slotId)
        if itemID ~= UNAVAILABLE and type(itemID) == "number" and itemID > 0 then
            local ilvl = GameAdapters.GetItemLevel(itemID)
            if type(ilvl) == "number" and ilvl > 0 then
                -- For paired slots (ring 11/12, trinket 13/14), track lowest equipped iLvl so upgrade check is honest
                local key = (slotId == 12) and 11 or ((slotId == 14) and 13 or slotId)
                if not map[key] or ilvl < map[key] then
                    map[key] = ilvl
                end
            end
        end
    end
    return map
end

function GameAdapters.GetPlayerFaction()
    if type(_G.UnitFactionGroup) ~= "function" then return nil end
    local ok, eng = pcall(_G.UnitFactionGroup, "player")
    if ok and (not SafeAPI.IsSecret(eng)) and type(eng) == "string" and eng ~= "" then
        return eng
    end
    return nil
end

-- KPI-10: Secret-safe Combo Points reader (Rogue / Feral Druid)
function GameAdapters.GetComboPointsSafe()
    if type(_G.UnitPower) == "function" then
        local pts = SafeAPI.SafeRead(_G.UnitPower, "player", 4)
        local maxP = (type(_G.UnitPowerMax) == "function") and SafeAPI.SafeRead(_G.UnitPowerMax, "player", 4) or 5
        if pts ~= UNAVAILABLE and type(pts) == "number" then
            return pts, (maxP ~= UNAVAILABLE and type(maxP) == "number" and maxP > 0) and maxP or 5
        end
    end
    if type(_G.GetComboPoints) == "function" then
        local pts = SafeAPI.SafeRead(_G.GetComboPoints, "player", "target")
        if pts ~= UNAVAILABLE and type(pts) == "number" then
            return pts, 5
        end
    end
    return 0, 5
end

-- KPI-10: Secret-safe & combat-safe Target Range check using CheckInteractDistance (B2: skipped in combat to avoid ADDON_ACTION_BLOCKED)
function GameAdapters.GetTargetRangeFlags()
    if SafeAPI.InCombat() then
        return true, nil, nil, nil, nil
    end
    if type(_G.UnitExists) ~= "function" then return false end
    local ex = SafeAPI.SafeRead(_G.UnitExists, "target")
    if ex == UNAVAILABLE or not IsTruthy(ex) then
        return false
    end
    if type(_G.CheckInteractDistance) ~= "function" then
        return true, nil, nil, nil, nil
    end
    local function CheckDist(idx)
        local v = SafeAPI.SafeRead(_G.CheckInteractDistance, "target", idx)
        if v == UNAVAILABLE then return nil end
        return IsTruthy(v)
    end
    return true, CheckDist(3), CheckDist(2), CheckDist(1), CheckDist(4)
end

-- KPI-10: Secret-safe player helpful auras with expirationTime for Short Buff HUD
function GameAdapters.GetPlayerHelpfulAuras()
    local out = {}
    if not (C_UnitAuras and type(C_UnitAuras.GetAuraDataByIndex) == "function") then
        return out
    end
    for i = 1, 40 do
        local a = SafeAPI.SafeRead(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
        if a == UNAVAILABLE or type(a) ~= "table" then
            break
        end
        if (not SafeAPI.IsSecret(a.name)) and (not SafeAPI.IsSecret(a.duration)) and (not SafeAPI.IsSecret(a.expirationTime))
            and type(a.name) == "string" and type(a.duration) == "number" and type(a.expirationTime) == "number"
        then
            out[#out + 1] = {
                name = a.name,
                spellId = (not SafeAPI.IsSecret(a.spellId)) and a.spellId or nil,
                duration = a.duration,
                expirationTime = a.expirationTime,
            }
        end
    end
    return out
end

-- KPI-10: Local + Server clock time
function GameAdapters.GetClockInfo()
    local lh, lm = nil, nil
    if type(_G.date) == "function" then
        local ok, dt = pcall(_G.date, "*t")
        if ok and type(dt) == "table" and type(dt.hour) == "number" and type(dt.min) == "number" then
            lh, lm = dt.hour, dt.min
        end
    end
    local sh, sm = nil, nil
    if type(_G.GetGameTime) == "function" then
        local ok, h, m = pcall(_G.GetGameTime)
        if ok and (not SafeAPI.IsSecret(h)) and (not SafeAPI.IsSecret(m)) and type(h) == "number" and type(m) == "number" then
            sh, sm = h, m
        end
    end
    return lh, lm, sh, sm
end

-- KPI-11: Secret-safe Corpse map position walker (C_DeathInfo.GetCorpseMapPosition)
function GameAdapters.GetCorpsePosition(deathMapID)
    if not (C_DeathInfo and type(C_DeathInfo.GetCorpseMapPosition) == "function") then
        return nil
    end
    local candidates, seen = {}, {}
    local function Add(mid)
        if type(mid) == "number" and mid > 0 and not seen[mid] then
            seen[mid] = true
            candidates[#candidates + 1] = mid
        end
    end
    if C_Map and type(C_Map.GetBestMapForUnit) == "function" then
        local cur = SafeAPI.SafeRead(C_Map.GetBestMapForUnit, "player")
        if cur ~= UNAVAILABLE then Add(cur) end
    end
    Add(deathMapID)
    if C_Map and type(C_Map.GetMapInfo) == "function" then
        for i = 1, 4 do
            local mid = candidates[i]
            if not mid then break end
            local info = SafeAPI.SafeRead(C_Map.GetMapInfo, mid)
            if info ~= UNAVAILABLE and type(info) == "table" and not SafeAPI.IsSecret(info.parentMapID) then
                Add(info.parentMapID)
            end
        end
    end
    for _, mid in ipairs(candidates) do
        local pos = SafeAPI.SafeRead(C_DeathInfo.GetCorpseMapPosition, mid)
        if pos ~= UNAVAILABLE and type(pos) == "table" then
            local x, y = pos.x, pos.y
            if (x == nil or y == nil) and type(pos.GetXY) == "function" then
                local okXY, gx, gy = pcall(pos.GetXY, pos)
                if okXY then x, y = gx, gy end
            end
            if (not SafeAPI.IsSecret(x)) and (not SafeAPI.IsSecret(y))
                and type(x) == "number" and type(y) == "number"
                and x > 0 and x < 1 and y > 0 and y < 1
            then
                return { mapID = mid, x = x, y = y }
            end
        end
    end
    return nil
end

-- KPI-12: Extended Character Stats (nil-safe, zero fabricated zeros)
function GameAdapters.GetExtendedCharacterStats()
    local st = {}
    if type(_G.UnitAttackPower) == "function" then
        local ok, base, pos, neg = pcall(_G.UnitAttackPower, "player")
        if ok and (not SafeAPI.IsSecret(base)) and type(base) == "number" then
            local p = (not SafeAPI.IsSecret(pos) and type(pos) == "number") and pos or 0
            local n = (not SafeAPI.IsSecret(neg) and type(neg) == "number") and neg or 0
            st.attackPower = base + p + n
        end
    end
    if type(_G.GetCritChance) == "function" then
        local v = SafeAPI.SafeRead(_G.GetCritChance)
        if v ~= UNAVAILABLE and type(v) == "number" then st.meleeCrit = v end
    end
    if type(_G.GetSpellCritChance) == "function" then
        local best = nil
        for school = 2, 7 do
            local v = SafeAPI.SafeRead(_G.GetSpellCritChance, school)
            if v ~= UNAVAILABLE and type(v) == "number" and (not best or v > best) then best = v end
        end
        st.spellCrit = best
    end
    if type(_G.GetSpellBonusDamage) == "function" then
        local best = nil
        for school = 2, 7 do
            local v = SafeAPI.SafeRead(_G.GetSpellBonusDamage, school)
            if v ~= UNAVAILABLE and type(v) == "number" and (not best or v > best) then best = v end
        end
        st.spellPower = best
    end
    if type(_G.UnitArmor) == "function" then
        local ok, _, eff = pcall(_G.UnitArmor, "player")
        if ok and (not SafeAPI.IsSecret(eff)) and type(eff) == "number" then st.armor = eff end
    end
    if type(_G.GetDodgeChance) == "function" then
        local v = SafeAPI.SafeRead(_G.GetDodgeChance)
        if v ~= UNAVAILABLE and type(v) == "number" then st.dodge = v end
    end
    if type(_G.GetParryChance) == "function" then
        local v = SafeAPI.SafeRead(_G.GetParryChance)
        if v ~= UNAVAILABLE and type(v) == "number" then st.parry = v end
    end
    if type(_G.GetBlockChance) == "function" then
        local v = SafeAPI.SafeRead(_G.GetBlockChance)
        if v ~= UNAVAILABLE and type(v) == "number" then st.block = v end
    end
    if type(_G.GetUnitSpeed) == "function" then
        local ok, curSpd, runSpd = pcall(_G.GetUnitSpeed, "player")
        local eff = (ok and not SafeAPI.IsSecret(runSpd) and type(runSpd) == "number" and runSpd > 0) and runSpd
            or ((ok and not SafeAPI.IsSecret(curSpd) and type(curSpd) == "number" and curSpd >= 0) and curSpd or nil)
        if eff ~= nil then
            st.moveSpeedPct = math.floor((eff / 7.0) * 100 + 0.5)
        end
    end
    return st
end

-- KPI-12: Read-only active trade snapshot (zero auto-trade taint)
function GameAdapters.GetTradeSnapshot()
    local partner, pSt = GameAdapters.GetUnitNameSafe("npc")
    local givenCopper = 0
    if type(_G.GetPlayerTradeMoney) == "function" then
        local v = SafeAPI.SafeRead(_G.GetPlayerTradeMoney)
        if v ~= UNAVAILABLE and type(v) == "number" and v >= 0 then givenCopper = v end
    end
    local recvCopper = 0
    if type(_G.GetTargetTradeMoney) == "function" then
        local v = SafeAPI.SafeRead(_G.GetTargetTradeMoney)
        if v ~= UNAVAILABLE and type(v) == "number" and v >= 0 then recvCopper = v end
    end
    local gItems, rItems = {}, {}
    if type(_G.GetTradePlayerItemInfo) == "function" then
        for i = 1, 6 do
            local ok, name, _, qty = pcall(_G.GetTradePlayerItemInfo, i)
            if ok and (not SafeAPI.IsSecret(name)) and type(name) == "string" and name ~= "" then
                local q = (not SafeAPI.IsSecret(qty) and type(qty) == "number" and qty > 1) and ("x" .. tostring(qty)) or ""
                gItems[#gItems + 1] = name .. q
            end
        end
    end
    if type(_G.GetTradeTargetItemInfo) == "function" then
        for i = 1, 6 do
            local ok, name, _, qty = pcall(_G.GetTradeTargetItemInfo, i)
            if ok and (not SafeAPI.IsSecret(name)) and type(name) == "string" and name ~= "" then
                local q = (not SafeAPI.IsSecret(qty) and type(qty) == "number" and qty > 1) and ("x" .. tostring(qty)) or ""
                rItems[#rItems + 1] = name .. q
            end
        end
    end
    return {
        partner = (pSt == "OK" and partner) or "상대방",
        givenCopper = givenCopper,
        receivedCopper = recvCopper,
        givenItems = table.concat(gItems, ", "),
        receivedItems = table.concat(rItems, ", "),
    }
end
