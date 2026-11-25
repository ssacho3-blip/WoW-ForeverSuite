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

function GameAdapters.IsPlayerDeadOrGhost()
    local v = SafeAPI.SafeRead(_G.UnitIsDeadOrGhost, "player")
    return v ~= UNAVAILABLE and IsTruthy(v)
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
    local okC, resC = pcall(_G.UnitAffectingCombat, casterName)
    if (not okC) or SafeAPI.IsSecret(resC) or IsTruthy(resC) then
        return true
    end
    return false
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
