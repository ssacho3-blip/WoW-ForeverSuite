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
    if z == UNAVAILABLE then
        local z2 = SafeAPI.SafeRead(_G.GetZoneText)
        if z2 ~= UNAVAILABLE and type(z2) == "string" and z2 ~= "" then
            return z2
        end
    end
    return ""
end

function GameAdapters.GetPlayerZoneContext()
    local aliases, seen = {}, {}
    local function addAlias(raw)
        if raw ~= UNAVAILABLE and (not SafeAPI.IsSecret(raw)) and type(raw) == "string" and raw ~= "" and not seen[raw] then
            seen[raw] = true
            aliases[#aliases + 1] = raw
        end
    end

    local realZ = SafeAPI.SafeRead(_G.GetRealZoneText)
    local zoneZ = SafeAPI.SafeRead(_G.GetZoneText)
    local subZ = SafeAPI.SafeRead(_G.GetSubZoneText)
    addAlias(realZ)
    addAlias(zoneZ)
    addAlias(subZ)

    local mapID, parentMapID = nil, nil
    local zoneMapType = (_G.Enum and _G.Enum.UIMapType and _G.Enum.UIMapType.Zone) or 3
    if C_Map and type(C_Map.GetBestMapForUnit) == "function" then
        local mid = SafeAPI.SafeRead(C_Map.GetBestMapForUnit, "player")
        if mid ~= UNAVAILABLE and type(mid) == "number" and mid > 0 then
            mapID = mid
            if type(C_Map.GetMapInfo) == "function" then
                local info = SafeAPI.SafeRead(C_Map.GetMapInfo, mid)
                if info ~= UNAVAILABLE and type(info) == "table" then
                    addAlias(info.name)
                    local pMid = (not SafeAPI.IsSecret(info.parentMapID)) and info.parentMapID or nil
                    if type(pMid) == "number" and pMid > 0 and pMid ~= mid then
                        local pInfo = SafeAPI.SafeRead(C_Map.GetMapInfo, pMid)
                        -- Include parent map ONLY when parent is a Zone (Enum.UIMapType.Zone == 3), never Continent(2)/World(1)/Cosmic(0)
                        if pInfo ~= UNAVAILABLE and type(pInfo) == "table"
                            and (not SafeAPI.IsSecret(pInfo.mapType)) and pInfo.mapType == zoneMapType
                        then
                            parentMapID = pMid
                            addAlias(pInfo.name)
                        end
                    end
                end
            end
        end
    end

    local localQuestIDs = {}
    local function collectMapPOIs(mid)
        if not (mid and mid > 0 and _G.C_QuestLog and type(_G.C_QuestLog.GetQuestsOnMap) == "function") then
            return
        end
        local rows = SafeAPI.SafeRead(_G.C_QuestLog.GetQuestsOnMap, mid)
        if rows == UNAVAILABLE or type(rows) ~= "table" then
            return
        end
        for i = 1, #rows do
            local r = rows[i]
            if type(r) == "table" and (not SafeAPI.IsSecret(r.questID)) and type(r.questID) == "number" and r.questID > 0 then
                local isStart = (not SafeAPI.IsSecret(r.isQuestStart)) and (r.isQuestStart == true)
                local depth = (not SafeAPI.IsSecret(r.childDepth)) and r.childDepth or 0
                local rMap = (not SafeAPI.IsSecret(r.mapID)) and r.mapID or nil
                if (not isStart) and (type(depth) ~= "number" or depth == 0) and (rMap == nil or rMap == mid) then
                    localQuestIDs[r.questID] = true
                end
            end
        end
    end
    collectMapPOIs(mapID)
    collectMapPOIs(parentMapID)

    local primary = aliases[1] or ""
    return {
        zone = primary,
        aliases = aliases,
        mapID = mapID,
        parentMapID = parentMapID,
        localQuestIDs = localQuestIDs,
    }
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

local KNOWN_FISHING_POLE_IDS = {
    [6256] = true,  -- 낚싯대 (Fishing Pole)
    [6365] = true,  -- 튼튼한 낚싯대 (Strong Fishing Pole)
    [6366] = true,  -- 검은나무 낚싯대 (Darkwood Fishing Pole)
    [6367] = true,  -- 커다란 철제 낚싯대 (Big Iron Fishing Pole)
    [12225] = true, -- 블럼프 가문의 낚싯대 (Blump Family Fishing Pole)
    [19022] = true, -- 내트 페이글의 최고급 낚싯대 FC-5000 (Nat Pagle's Extreme Angler FC-5000)
    [19970] = true, -- 아케이나이트 낚싯대 (Arcanite Fishing Pole)
    [25978] = true, -- 세스의 흑연 낚싯대 (Seth's Graphite Fishing Pole)
    [44050] = true, -- 칼루아크 명품 낚싯대 (Mastercraft Kalu'ak Fishing Pole)
    [45858] = true, -- 내트의 행운 낚싯대 (Nat's Lucky Fishing Pole)
}

local function IsFishingPoleItemID(itemID)
    if type(itemID) ~= "number" or itemID <= 0 then
        return false
    end
    if KNOWN_FISHING_POLE_IDS[itemID] then
        return true
    end
    if C_Item and type(C_Item.GetItemInfo) == "function" then
        local ok, _, _, _, _, _, _, itemSubType, _, _, _, _, classID, subClassID = pcall(C_Item.GetItemInfo, itemID)
        if ok then
            if (not SafeAPI.IsSecret(classID)) and (not SafeAPI.IsSecret(subClassID))
                and classID == 2 and subClassID == 20
            then
                return true
            end
            if (not SafeAPI.IsSecret(itemSubType)) and type(itemSubType) == "string" then
                local low = string.lower(itemSubType)
                if string.find(low, "fishing", 1, true) or string.find(itemSubType, "낚싯대", 1, true) then
                    return true
                end
            end
        end
    end
    return false
end

function GameAdapters.IsFishingPoleEquipped()
    if type(_G.GetInventoryItemID) ~= "function" then
        return false
    end
    local itemID = SafeAPI.SafeRead(_G.GetInventoryItemID, "player", 16)
    if itemID == UNAVAILABLE or type(itemID) ~= "number" then
        return false
    end
    return IsFishingPoleItemID(itemID)
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

function GameAdapters.GetCVarSafe(name)
    if type(name) ~= "string" or name == "" then
        return nil, "INVALID"
    end
    if C_CVar and type(C_CVar.GetCVar) == "function" then
        local v = SafeAPI.SafeRead(C_CVar.GetCVar, name)
        if v == UNAVAILABLE then return nil, "UNAVAILABLE" end
        return v, (v ~= nil) and "OK" or "NOT_FOUND"
    end
    if type(_G.GetCVar) == "function" then
        local v = SafeAPI.SafeRead(_G.GetCVar, name)
        if v == UNAVAILABLE then return nil, "UNAVAILABLE" end
        return v, (v ~= nil) and "OK" or "NOT_FOUND"
    end
    return nil, "UNSUPPORTED"
end

function GameAdapters.SetCVarSafe(name, value)
    if SafeAPI.InCombat() then
        return false, "IN_COMBAT"
    end
    if type(name) ~= "string" or name == "" then
        return false, "INVALID"
    end
    if C_CVar and type(C_CVar.SetCVar) == "function" then
        local ok, res = pcall(C_CVar.SetCVar, name, tostring(value))
        local applied = ok and res ~= false
        return applied, applied and "APPLIED" or "FAILED"
    end
    if type(_G.SetCVar) == "function" then
        local ok, res = pcall(_G.SetCVar, name, tostring(value))
        local applied = ok and res ~= false
        return applied, applied and "APPLIED" or "FAILED"
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

local function IsValidWaypoint(m, x, y)
    if SafeAPI.IsSecret(m) or SafeAPI.IsSecret(x) or SafeAPI.IsSecret(y) then
        return false
    end
    if type(m) ~= "number" or m <= 0 or math.floor(m) ~= m then
        return false
    end
    if type(x) ~= "number" or type(y) ~= "number" then
        return false
    end
    if x < 0 or x > 1 or y < 0 or y > 1 then
        return false
    end
    return (x > 0 or y > 0)
end

local function ReadQuestTitleSafe(questID)
    if C_QuestLog and type(C_QuestLog.GetTitleForQuestID) == "function" then
        local t = SafeAPI.SafeRead(C_QuestLog.GetTitleForQuestID, questID)
        if t ~= UNAVAILABLE and type(t) == "string" and t ~= "" then
            return t
        end
    end
    if C_QuestLog and type(C_QuestLog.GetLogIndexForQuestID) == "function" and type(C_QuestLog.GetInfo) == "function" then
        local idx = SafeAPI.SafeRead(C_QuestLog.GetLogIndexForQuestID, questID)
        if idx ~= UNAVAILABLE and type(idx) == "number" and idx > 0 then
            local info = SafeAPI.SafeRead(C_QuestLog.GetInfo, idx)
            if info ~= UNAVAILABLE and type(info) == "table" and not SafeAPI.IsSecret(info.title) and type(info.title) == "string" and info.title ~= "" then
                return info.title
            end
        end
    end
    return nil
end

local function ReadQuestReadyState(questID)
    if C_QuestLog and type(C_QuestLog.IsComplete) == "function" then
        local v = SafeAPI.SafeRead(C_QuestLog.IsComplete, questID)
        if v ~= UNAVAILABLE and IsTruthy(v) then
            return true
        end
    end
    if C_QuestLog and type(C_QuestLog.ReadyForTurnIn) == "function" then
        local v = SafeAPI.SafeRead(C_QuestLog.ReadyForTurnIn, questID)
        if v ~= UNAVAILABLE and IsTruthy(v) then
            return true
        end
    end
    return false
end

local CAPITAL_MAP_IDS = { 1453, 1454, 1455, 1456, 1457, 1458 }

-- 4-Tier Zero-Taint, C_Secrets-safe Quest Waypoint Resolver (WoW Forever 1.60.1 + ForeverSuite LoD DB fallback).
-- Returns { mapID, x, y, isComplete, title, waypointText, source } or nil.
function GameAdapters.ResolveQuestWaypoint(questID, allowLoadPacks)
    if SafeAPI.IsSecret(questID) or type(questID) ~= "number" or questID <= 0 then
        return nil
    end
    local isComplete = ReadQuestReadyState(questID)
    local title = ReadQuestTitleSafe(questID)
    local wpText = ""
    if C_QuestLog and type(C_QuestLog.GetNextWaypointText) == "function" then
        local t = SafeAPI.SafeRead(C_QuestLog.GetNextWaypointText, questID)
        if t ~= UNAVAILABLE and type(t) == "string" then
            wpText = t
        end
    end

    -- Tier 1: Native Blizzard C_QuestLog.GetNextWaypoint(questID) -> (mapID, x, y)
    if C_QuestLog and type(C_QuestLog.GetNextWaypoint) == "function" then
        local ok, m, x, y = pcall(C_QuestLog.GetNextWaypoint, questID)
        if ok and IsValidWaypoint(m, x, y) then
            return { mapID = m, x = x, y = y, isComplete = isComplete, title = title, waypointText = wpText, source = "blizz_waypoint" }
        end
    end

    -- Tier 2: Native Blizzard QuestPOIGetIconInfo(questID) + GetQuestUiMapID(questID, true)
    local questUiMapID = nil
    if type(_G.GetQuestUiMapID) == "function" then
        local okM, qm = pcall(_G.GetQuestUiMapID, questID, true)
        if okM and not SafeAPI.IsSecret(qm) and type(qm) == "number" and qm > 0 then
            questUiMapID = qm
        end
    end
    if type(_G.QuestPOIGetIconInfo) == "function" and questUiMapID then
        local okP, ended, px, py = pcall(_G.QuestPOIGetIconInfo, questID)
        if okP and not SafeAPI.IsSecret(ended) and IsValidWaypoint(questUiMapID, px, py) then
            if (not isComplete) or IsTruthy(ended) then
                return { mapID = questUiMapID, x = px, y = py, isComplete = isComplete, title = title, waypointText = wpText, source = "blizz_poi_icon" }
            end
        end
    end

    -- Tier 3: Per-map waypoint & quest POI scan (skip multi-map scan in combat to avoid burst allocations)
    if C_QuestLog and not SafeAPI.InCombat() then
        local candidates = {}
        local seenMap = {}
        local function AddMap(m)
            if type(m) == "number" and m > 0 and math.floor(m) == m and not seenMap[m] then
                seenMap[m] = true
                candidates[#candidates + 1] = m
            end
        end
        local pos = GameAdapters.GetPlayerPosition()
        if pos and type(pos.mapID) == "number" then
            AddMap(pos.mapID)
            if C_Map and type(C_Map.GetMapInfo) == "function" then
                local info = SafeAPI.SafeRead(C_Map.GetMapInfo, pos.mapID)
                if info ~= UNAVAILABLE and type(info) == "table" and not SafeAPI.IsSecret(info.parentMapID) then
                    AddMap(info.parentMapID)
                end
            end
        end
        AddMap(questUiMapID)
        if isComplete then
            for _, cm in ipairs(CAPITAL_MAP_IDS) do
                AddMap(cm)
            end
        end
        for _, m in ipairs(candidates) do
            if type(C_QuestLog.GetNextWaypointForMap) == "function" then
                local okW, wx, wy = pcall(C_QuestLog.GetNextWaypointForMap, questID, m)
                if okW and IsValidWaypoint(m, wx, wy) then
                    return { mapID = m, x = wx, y = wy, isComplete = isComplete, title = title, waypointText = wpText, source = "blizz_map_waypoint" }
                end
            end
            if type(C_QuestLog.GetQuestsOnMap) == "function" then
                local okQ, pois = pcall(C_QuestLog.GetQuestsOnMap, m)
                if okQ and not SafeAPI.IsSecret(pois) and type(pois) == "table" then
                    for _, poi in ipairs(pois) do
                        if type(poi) == "table" and not SafeAPI.IsSecret(poi) then
                            local okF, pqid, isStart, isEnd, px, py = pcall(function()
                                return poi.questID, poi.isQuestStart, poi.isQuestEnd, poi.x, poi.y
                            end)
                            if okF and (not SafeAPI.IsSecret(pqid)) and pqid == questID
                                and (not SafeAPI.IsSecret(isStart)) and (not isStart)
                                and IsValidWaypoint(m, px, py)
                            then
                                if (not isComplete) or (not SafeAPI.IsSecret(isEnd) and isEnd == true) or (isEnd == nil) then
                                    return { mapID = m, x = px, y = py, isComplete = isComplete, title = title, waypointText = wpText, source = "blizz_map_poi" }
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Tier 4: ForeverSuite compiled LoD Quest Coordinate DB fallback (OOC lazy-load only when requested)
    if allowLoadPacks and not SafeAPI.InCombat() then
        SafeAPI.LoadDataPack("ForeverSuite_Data_QuestExtra")
        SafeAPI.LoadDataPack("ForeverSuite_Data_MapPins")
    end
    local packs = _G.ForeverSuiteData and _G.ForeverSuiteData.packs
    if type(packs) == "table" then
        local order = { "quest_routes", "class_quests", "dungeon_quests", "map_quest_starts" }
        for _, packKey in ipairs(order) do
            local pack = packs[packKey]
            if type(pack) == "table" and type(pack.entries) == "table" then
                for _, e in ipairs(pack.entries) do
                    if type(e) == "table" and e.questID == questID and IsValidWaypoint(e.mapID, e.x, e.y) then
                        local note = (type(e.npc) == "string" and e.npc ~= "" and ("NPC: " .. e.npc))
                            or (type(e.giver) == "string" and e.giver ~= "" and ("NPC: " .. e.giver))
                            or (type(e.title) == "string" and e.title) or wpText
                        return {
                            mapID = e.mapID,
                            x = e.x,
                            y = e.y,
                            isComplete = isComplete,
                            title = title or e.title,
                            waypointText = note,
                            source = "fs_pack_" .. packKey,
                        }
                    end
                end
            end
        end
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
        local dur = (not SafeAPI.IsSecret(aura.duration)) and aura.duration or nil
        if type(sid) == "number" and sid > 0 then
            current[sid] = true
            local durOk = (type(dur) ~= "number") or dur <= 0 or dur >= 180
            if (not foundCaster) and (not seenAuraIDs[sid]) and durOk and type(src) == "string" and src ~= "" and not GameAdapters.IsUnitPlayer(src) then
                local isPlayerCaster = true
                if type(_G.UnitIsPlayer) == "function" then
                    local up = SafeAPI.SafeRead(_G.UnitIsPlayer, src)
                    if up ~= UNAVAILABLE and up == false then
                        isPlayerCaster = false
                    end
                end
                if isPlayerCaster then
                    local cName, st = GameAdapters.GetUnitNameSafe(src)
                    if st == "OK" and type(bName) == "string" and bName ~= "" then
                        foundCaster, foundBuff = cName, bName
                    end
                end
            end
        end
    end
    for k in pairs(seenAuraIDs) do seenAuraIDs[k] = nil end
    for k, v in pairs(current) do seenAuraIDs[k] = v end
    return foundCaster, foundBuff, "OK"
end

-- Secret-safe scan of all current player HELPFUL auras (Fail-Closed: returns nil, false on ANY unreadable/Secret aura)
function GameAdapters.ScanPlayerHelpfulAuras()
    if not (C_UnitAuras and type(C_UnitAuras.GetAuraDataByIndex) == "function") then
        return nil, false
    end
    local out = {}
    for i = 1, 40 do
        local aura = SafeAPI.SafeRead(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
        if aura == UNAVAILABLE then
            return nil, false
        end
        if type(aura) ~= "table" then
            break
        end
        if SafeAPI.IsSecret(aura.spellId) or SafeAPI.IsSecret(aura.name) then
            return nil, false
        end
        local sid = aura.spellId
        local bName = aura.name
        if type(bName) == "string" and bName ~= "" then
            out[#out + 1] = {
                spellId = (type(sid) == "number") and sid or 0,
                name = bName,
            }
        end
    end
    return out, true
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

function GameAdapters.GetPlayerRaceLocalized()
    if type(_G.UnitRace) ~= "function" then return nil, nil end
    local ok, loc, eng = pcall(_G.UnitRace, "player")
    if ok then
        loc = (not SafeAPI.IsSecret(loc) and type(loc) == "string" and loc ~= "") and loc or nil
        eng = (not SafeAPI.IsSecret(eng) and type(eng) == "string" and eng ~= "") and eng or nil
        return loc, eng
    end
    return nil, nil
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
    -- Phase 3 v6 extended stats (Carbon audit: Healing, Ranged AP, MP5 cast/base, Melee/Spell Hit%)
    st.meleeAP = st.attackPower
    st.speedPct = st.moveSpeedPct
    if type(_G.GetSpellBonusHealing) == "function" then
        local h = SafeAPI.SafeRead(_G.GetSpellBonusHealing)
        if h ~= UNAVAILABLE and type(h) == "number" then st.healingPower = h end
    end
    if type(_G.UnitRangedAttackPower) == "function" then
        local ok, base, pos, neg = pcall(_G.UnitRangedAttackPower, "player")
        if ok and (not SafeAPI.IsSecret(base)) and type(base) == "number" then
            local p = (not SafeAPI.IsSecret(pos) and type(pos) == "number") and pos or 0
            local n = (not SafeAPI.IsSecret(neg) and type(neg) == "number") and neg or 0
            st.rangedAP = base + p + n
        end
    end
    if type(_G.GetManaRegen) == "function" then
        local ok, base, casting = pcall(_G.GetManaRegen)
        if ok and (not SafeAPI.IsSecret(base)) and type(base) == "number" then
            st.mp5Base = math.floor(base * 5 + 0.5)
            st.mp5Cast = ((not SafeAPI.IsSecret(casting)) and type(casting) == "number") and math.floor(casting * 5 + 0.5) or nil
        end
    end
    if type(_G.GetHitModifier) == "function" then
        local mh = SafeAPI.SafeRead(_G.GetHitModifier)
        if mh ~= UNAVAILABLE and type(mh) == "number" then st.meleeHitPct = mh end
    end
    if type(_G.GetSpellHitModifier) == "function" then
        local sh = SafeAPI.SafeRead(_G.GetSpellHitModifier)
        if sh ~= UNAVAILABLE and type(sh) == "number" then st.spellHitPct = sh end
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

-- v3.0: Built-in WoW icon & safe whisper/link helpers (0-KB asset strategy; secret-safe input checks first)
function GameAdapters.GetItemIconSafe(itemID)
    if SafeAPI.IsSecret(itemID) or type(itemID) ~= "number" or itemID <= 0 then
        return nil
    end
    if C_Item and type(C_Item.GetItemInfoInstant) == "function" then
        local ok, _, _, _, _, icon = pcall(C_Item.GetItemInfoInstant, itemID)
        if ok and (not SafeAPI.IsSecret(icon)) and (type(icon) == "number" or (type(icon) == "string" and icon ~= "")) then
            return icon
        end
    end
    if C_Item and type(C_Item.GetItemInfo) == "function" then
        local ok, _, _, _, _, _, _, _, _, _, icon = pcall(C_Item.GetItemInfo, itemID)
        if ok and (not SafeAPI.IsSecret(icon)) and (type(icon) == "number" or (type(icon) == "string" and icon ~= "")) then
            return icon
        end
    end
    return nil
end

function GameAdapters.GetSpellIconSafe(spellID)
    if SafeAPI.IsSecret(spellID) or type(spellID) ~= "number" or spellID <= 0 then
        return nil
    end
    if C_Spell and type(C_Spell.GetSpellInfo) == "function" then
        local info = SafeAPI.SafeRead(C_Spell.GetSpellInfo, spellID)
        if info ~= UNAVAILABLE and type(info) == "table" and not SafeAPI.IsSecret(info.iconID) then
            if type(info.iconID) == "number" or (type(info.iconID) == "string" and info.iconID ~= "") then
                return info.iconID
            end
        end
    end
    return nil
end

function GameAdapters.GetItemLinkSafe(itemID)
    if SafeAPI.IsSecret(itemID) or type(itemID) ~= "number" or itemID <= 0 then
        return nil
    end
    if C_Item and type(C_Item.GetItemInfo) == "function" then
        local ok, _, link = pcall(C_Item.GetItemInfo, itemID)
        if ok and (not SafeAPI.IsSecret(link)) and type(link) == "string" and link ~= "" then
            return link
        end
    end
    if C_Item and type(C_Item.RequestLoadItemDataByID) == "function" then
        pcall(C_Item.RequestLoadItemDataByID, itemID)
    end
    return nil
end

function GameAdapters.InsertItemChatLink(itemID)
    local link = GameAdapters.GetItemLinkSafe(itemID)
    if not link then return false end
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

-- Opens WoW chat input pre-filled with `/w <sender> <prefill>` without auto-sending (zero spam, zero taint).
-- Strictly verifies the active chat edit box received the exact draft (supporting both Blizzard FrameXML deferred
-- setText=1/text=draft and immediate GetText()==draft); fails closed so caller opens CopyPasteModal if unverified.
function GameAdapters.OpenWhisperDraftSafe(sender, prefillText)
    if SafeAPI.IsSecret(sender) or type(sender) ~= "string" or sender == "" then
        return false, "INVALID_SENDER"
    end
    if SafeAPI.IsSecret(prefillText) then
        return false, "SECRET_TEXT"
    end
    local cleanSender = string.gsub(sender, "[|%c]", "")
    local msg = (type(prefillText) == "string" and prefillText ~= "") and string.gsub(prefillText, "[|%c]", "") or ""
    local draft = "/w " .. cleanSender .. " " .. msg
    if type(_G.ChatFrame_OpenChat) ~= "function" or type(_G.ChatEdit_GetActiveWindow) ~= "function" then
        return false, "UNSUPPORTED"
    end
    local ok = pcall(_G.ChatFrame_OpenChat, draft)
    if not ok then
        return false, "OPEN_FAILED"
    end
    local edit = SafeAPI.SafeRead(_G.ChatEdit_GetActiveWindow)
    if type(edit) ~= "table" or edit == UNAVAILABLE then
        return false, "NOT_OPENED"
    end
    if (not SafeAPI.IsSecret(edit.setText)) and edit.setText == 1
        and (not SafeAPI.IsSecret(edit.text)) and edit.text == draft
    then
        return true, "OPENED"
    end
    if type(edit.GetText) == "function" then
        local okT, txt = pcall(edit.GetText, edit)
        if okT and (not SafeAPI.IsSecret(txt)) and type(txt) == "string" and txt == draft then
            return true, "OPENED"
        end
    end
    return false, "DRAFT_MISMATCH"
end

-- Returns detailed equipped item info map { [slotId] = { itemID, name, ilvl, icon, quality } } for BiS 2-pane comparison.
-- Resolves effective item level from full equipped item link (preserving instance modifiers) before falling back to itemID.
function GameAdapters.GetEquippedItemInfoMap()
    local map = {}
    if type(_G.GetInventoryItemID) ~= "function" then
        return map
    end
    for slotId = 1, 18 do
        local itemID = SafeAPI.SafeRead(_G.GetInventoryItemID, "player", slotId)
        if (not SafeAPI.IsSecret(itemID)) and itemID ~= UNAVAILABLE and type(itemID) == "number" and itemID > 0 then
            local link = nil
            if type(_G.GetInventoryItemLink) == "function" then
                local rawLink = SafeAPI.SafeRead(_G.GetInventoryItemLink, "player", slotId)
                if (not SafeAPI.IsSecret(rawLink)) and rawLink ~= UNAVAILABLE and type(rawLink) == "string" and rawLink ~= "" then
                    link = rawLink
                end
            end
            local ilvl = nil
            if link and C_Item and type(C_Item.GetDetailedItemLevelInfo) == "function" then
                local v = SafeAPI.SafeRead(C_Item.GetDetailedItemLevelInfo, link)
                if (not SafeAPI.IsSecret(v)) and v ~= UNAVAILABLE and type(v) == "number" and v > 0 then
                    ilvl = v
                end
            end
            if ilvl == nil then
                ilvl = GameAdapters.GetItemLevel(itemID)
            end
            local icon = GameAdapters.GetItemIconSafe(itemID)
            local name, quality = nil, nil
            local queryRef = link or itemID
            if C_Item and type(C_Item.GetItemInfo) == "function" then
                local ok, n, _, q = pcall(C_Item.GetItemInfo, queryRef)
                if ok then
                    if not SafeAPI.IsSecret(n) and type(n) == "string" then name = n end
                    if not SafeAPI.IsSecret(q) and type(q) == "number" then quality = q end
                end
            end
            local key = (slotId == 12) and 11 or ((slotId == 14) and 13 or slotId)
            local cur = map[key]
            local shouldReplace = false
            if not cur then
                shouldReplace = true
            elseif cur.ilvl == nil and type(ilvl) == "number" then
                shouldReplace = true
            elseif type(cur.ilvl) == "number" and type(ilvl) == "number" and ilvl < cur.ilvl then
                shouldReplace = true
            end
            if shouldReplace then
                map[key] = {
                    itemID = itemID,
                    name = name or ("#" .. tostring(itemID)),
                    ilvl = ilvl,
                    icon = icon,
                    quality = quality,
                }
            end
        end
    end
    return map
end

function GameAdapters.GetPlayerXPSnapshot()
    local cur = (type(_G.UnitXP) == "function") and SafeAPI.SafeRead(_G.UnitXP, "player") or UNAVAILABLE
    local maxV = (type(_G.UnitXPMax) == "function") and SafeAPI.SafeRead(_G.UnitXPMax, "player") or UNAVAILABLE
    if cur == UNAVAILABLE or maxV == UNAVAILABLE or type(cur) ~= "number" or type(maxV) ~= "number" or maxV <= 0 then
        return nil
    end
    local rest = (type(_G.GetXPExhaustion) == "function") and SafeAPI.SafeRead(_G.GetXPExhaustion) or UNAVAILABLE
    local restNum = (rest ~= UNAVAILABLE and type(rest) == "number" and rest > 0) and rest or 0
    return {
        xp = cur,
        xpMax = maxV,
        xpPct = math.floor((cur / maxV) * 100 + 0.5),
        restedPct = math.floor((restNum / maxV) * 100 + 0.5),
    }
end

-- B7: Secret-safe loot roll item inspector for Roll Preview
function GameAdapters.GetLootRollItemSafe(rollID)
    if SafeAPI.IsSecret(rollID) or type(rollID) ~= "number" or rollID <= 0 then
        return nil
    end
    local link = (type(_G.GetLootRollItemLink) == "function") and SafeAPI.SafeRead(_G.GetLootRollItemLink, rollID) or UNAVAILABLE
    if link == UNAVAILABLE or type(link) ~= "string" or link == "" then
        return nil
    end
    local idStr = string_match(link, "item:(%d+)")
    local itemID = idStr and tonumber(idStr) or nil
    if not itemID or itemID <= 0 then return nil end
    local name, quality, icon, equipLoc
    if C_Item and type(C_Item.GetItemInfo) == "function" then
        local ok, n, _, q, _, _, _, _, _, eq, ic = pcall(C_Item.GetItemInfo, link)
        if ok then
            if not SafeAPI.IsSecret(n) and type(n) == "string" then name = n end
            if not SafeAPI.IsSecret(q) and type(q) == "number" then quality = q end
            if not SafeAPI.IsSecret(eq) and type(eq) == "string" then equipLoc = eq end
            if not SafeAPI.IsSecret(ic) then icon = ic end
        end
    end
    local ilvl = GameAdapters.GetItemLevel(itemID)
    return {
        rollID = rollID,
        itemID = itemID,
        link = link,
        name = name or ("#" .. tostring(itemID)),
        quality = quality,
        itemLevel = ilvl,
        equipLoc = equipLoc,
        icon = icon or GameAdapters.GetItemIconSafe(itemID),
    }
end

-- C2/C7: Dependency-inverted audio ducking predicate (wired by Composition Root to Bridges/Spoken)
GameAdapters.audioDuckPredicate = nil
function GameAdapters.SetAudioDuckPredicate(fn)
    GameAdapters.audioDuckPredicate = (type(fn) == "function") and fn or nil
end

-- I7: Play notification sound file (ForeverSuite_Media_Assets) or built-in SoundKitID safely without touching CVars
function GameAdapters.PlayNotificationSound(soundKey, volumePct, channel, isSurvivalAlert)
    if type(GameAdapters.audioDuckPredicate) == "function" then
        local okDuck, shouldDuck = pcall(GameAdapters.audioDuckPredicate, isSurvivalAlert == true)
        if okDuck and shouldDuck == true then
            return false
        end
    end
    local ch = (channel == "Master") and "Master" or "SFX"
    if type(soundKey) == "number" and soundKey > 0 and type(_G.PlaySound) == "function" then
        return pcall(_G.PlaySound, soundKey, ch) and true or false
    end
    if type(soundKey) ~= "string" or soundKey == "" or soundKey == "none" then
        return false
    end
    if soundKey == "raid_warning" and type(_G.PlaySound) == "function" then
        return pcall(_G.PlaySound, 8959, ch) and true or false
    end
    if soundKey == "quest_complete" and type(_G.PlaySound) == "function" then
        return pcall(_G.PlaySound, 619, ch) and true or false
    end
    if type(_G.PlaySoundFile) == "function" then
        local vol = tonumber(volumePct) or 75
        local step = (vol <= 35) and 25 or ((vol <= 62) and 50 or ((vol <= 87) and 75 or 100))
        local ext = (soundKey == "cash") and ".wav"
            or ((soundKey == "cooking_master" and step == 100) and ".mp3" or ".ogg")
        local mediaRoot = (_G.ForeverSuiteMedia and type(_G.ForeverSuiteMedia.mediaRoot) == "string")
            and _G.ForeverSuiteMedia.mediaRoot or "Interface\\AddOns\\ForeverSuite_Media_Assets\\"
        local path = mediaRoot .. "Notifications\\" .. soundKey .. "_" .. tostring(step) .. ext
        local ok, played = pcall(_G.PlaySoundFile, path, ch)
        if ok and played ~= false then return true end
    end
    if type(_G.PlaySound) == "function" then
        return pcall(_G.PlaySound, 8959, ch) and true or false
    end
    return false
end

-- D7: Safe addon-message channel for Party Quest Sync (C_ChatInfo.RegisterAddonMessagePrefix / SendAddonMessage)
function GameAdapters.RegisterAddonPrefixSafe(prefix)
    if type(prefix) ~= "string" or prefix == "" then return false end
    if C_ChatInfo and type(C_ChatInfo.RegisterAddonMessagePrefix) == "function" then
        local ok = pcall(C_ChatInfo.RegisterAddonMessagePrefix, prefix)
        return ok and true or false
    end
    return false
end

function GameAdapters.SendAddonMessageSafe(prefix, payload, channel)
    if SafeAPI.InCombat() or GameAdapters.IsChatMessagingLocked() then
        return false, "LOCKED"
    end
    if type(prefix) ~= "string" or type(payload) ~= "string" or #payload > 240 then
        return false, "INVALID"
    end
    local ch = channel or (GameAdapters.IsInRaidSafe() and "RAID" or (GameAdapters.IsInGroupSafe() and "PARTY" or nil))
    if not ch then return false, "NO_GROUP" end
    if C_ChatInfo and type(C_ChatInfo.SendAddonMessage) == "function" then
        local ok = pcall(C_ChatInfo.SendAddonMessage, prefix, payload, ch)
        return ok and true or false, ok and "SENT" or "FAILED"
    end
    return false, "UNSUPPORTED"
end

-- F5: Read-only Bag + Bank item count scan (zero bag UI conflict with Baganator/Syndicator!)
function GameAdapters.ScanBagsAndBankCounts(includeBank)
    local counts = {}
    if not (C_Container and type(C_Container.GetContainerNumSlots) == "function" and type(C_Container.GetContainerItemInfo) == "function") then
        return counts
    end
    local function ScanBag(bag)
        local n = SafeAPI.SafeRead(C_Container.GetContainerNumSlots, bag)
        if n == UNAVAILABLE or type(n) ~= "number" or n <= 0 then return end
        for slot = 1, n do
            local info = SafeAPI.SafeRead(C_Container.GetContainerItemInfo, bag, slot)
            if info ~= UNAVAILABLE and type(info) == "table" and not SafeAPI.IsSecret(info.itemID) and type(info.itemID) == "number" and info.itemID > 0 then
                local qty = (not SafeAPI.IsSecret(info.stackCount) and type(info.stackCount) == "number" and info.stackCount > 0) and info.stackCount or 1
                counts[info.itemID] = (counts[info.itemID] or 0) + qty
            end
        end
    end
    for bag = 0, 4 do ScanBag(bag) end
    if includeBank then
        ScanBag(-1)
        for bag = 5, 11 do ScanBag(bag) end
    end
    return counts
end

-- I3: Spell-based target range check (C_Spell.IsSpellInRange)
function GameAdapters.IsSpellInRangeSafe(spellID, unit)
    if type(spellID) ~= "number" or spellID <= 0 then return nil end
    if C_Spell and type(C_Spell.IsSpellInRange) == "function" then
        local v = SafeAPI.SafeRead(C_Spell.IsSpellInRange, spellID, unit or "target")
        if v == UNAVAILABLE then return nil end
        return IsTruthy(v)
    end
    return nil
end

-- I6: Spell cooldown reader (C_Spell.GetSpellCooldown, secret-safe)
function GameAdapters.GetSpellCooldownSafe(spellID)
    if type(spellID) ~= "number" or spellID <= 0 then return nil end
    if C_Spell and type(C_Spell.GetSpellCooldown) == "function" then
        local cd = SafeAPI.SafeRead(C_Spell.GetSpellCooldown, spellID)
        if cd ~= UNAVAILABLE and type(cd) == "table"
            and (not SafeAPI.IsSecret(cd.startTime)) and (not SafeAPI.IsSecret(cd.duration))
            and type(cd.startTime) == "number" and type(cd.duration) == "number"
        then
            local isEnabled = nil
            if not SafeAPI.IsSecret(cd.isEnabled) then
                isEnabled = IsTruthy(cd.isEnabled)
            end
            return cd.startTime, cd.duration, isEnabled
        end
    end
    return nil
end

-- F2: Fishing skill level & main-hand lure duration reader
function GameAdapters.GetFishingStatusSafe()
    local hasLure, lureMs = false, 0
    if type(_G.GetWeaponEnchantInfo) == "function" then
        local ok, mh, mhExp = pcall(_G.GetWeaponEnchantInfo)
        if ok and (not SafeAPI.IsSecret(mh)) and IsTruthy(mh) then
            hasLure = true
            if (not SafeAPI.IsSecret(mhExp)) and type(mhExp) == "number" and mhExp > 0 then
                lureMs = mhExp
            end
        end
    end
    local skill, maxSkill = nil, nil
    if type(_G.GetNumSkillLines) == "function" and type(_G.GetSkillLineInfo) == "function" then
        local n = SafeAPI.SafeRead(_G.GetNumSkillLines)
        if n ~= UNAVAILABLE and type(n) == "number" then
            for i = 1, n do
                local ok, sName, isHdr, _, sRank, _, _, sMax = pcall(_G.GetSkillLineInfo, i)
                if ok and (not SafeAPI.IsSecret(sName)) and not isHdr
                    and (sName == "낚시" or sName == "Fishing")
                then
                    if not SafeAPI.IsSecret(sRank) and type(sRank) == "number" then skill = sRank end
                    if not SafeAPI.IsSecret(sMax) and type(sMax) == "number" then maxSkill = sMax end
                    break
                end
            end
        end
    end
    return {
        hasLure = hasLure,
        lureSec = math.floor(lureMs / 1000),
        skill = skill,
        maxSkill = maxSkill,
    }
end

GameAdapters.FISHING_LURES = {
    { itemID = 6533, bonus = 100, fallbackName = "아쿠아다이내믹 물고기 유인기" },
    { itemID = 7307, bonus = 75,  fallbackName = "살덩이 벌레" },
    { itemID = 6532, bonus = 75,  fallbackName = "빛나는 미끼" },
    { itemID = 6811, bonus = 50,  fallbackName = "아쿠아다이내믹 물고기 렌즈" },
    { itemID = 6530, bonus = 50,  fallbackName = "밤벌레" },
    { itemID = 6529, bonus = 25,  fallbackName = "반짝이는 미끼" },
}

function GameAdapters.FindBestFishingLureInBags()
    local items = GameAdapters.ScanBagItems()
    local byID = {}
    for i = 1, #items do
        local it = items[i]
        if type(it.itemID) == "number" and not it.isLocked then
            local rec = byID[it.itemID]
            if not rec then
                byID[it.itemID] = {
                    itemID = it.itemID,
                    name = it.name,
                    count = it.stackCount or 1,
                    bag = it.bag,
                    slot = it.slot,
                }
            else
                rec.count = rec.count + (it.stackCount or 1)
            end
        end
    end
    for i = 1, #GameAdapters.FISHING_LURES do
        local spec = GameAdapters.FISHING_LURES[i]
        local found = byID[spec.itemID]
        if found then
            return {
                itemID = spec.itemID,
                bonus = spec.bonus,
                name = (found.name and found.name ~= ("#" .. tostring(spec.itemID))) and found.name or spec.fallbackName,
                count = found.count,
                bag = found.bag,
                slot = found.slot,
            }
        end
    end
    return nil
end

function GameAdapters.FindFishingPoleInBags()
    local items = GameAdapters.ScanBagItems()
    for i = 1, #items do
        local it = items[i]
        if type(it.itemID) == "number" and not it.isLocked and IsFishingPoleItemID(it.itemID) then
            return { itemID = it.itemID, name = it.name, bag = it.bag, slot = it.slot }
        end
    end
    return nil
end

function GameAdapters.GetEquippedWeaponsSafe()
    if type(_G.GetInventoryItemID) ~= "function" then
        return nil, nil
    end
    local mh = SafeAPI.SafeRead(_G.GetInventoryItemID, "player", 16)
    local oh = SafeAPI.SafeRead(_G.GetInventoryItemID, "player", 17)
    mh = (mh ~= UNAVAILABLE and type(mh) == "number" and mh > 0) and mh or nil
    oh = (oh ~= UNAVAILABLE and type(oh) == "number" and oh > 0) and oh or nil
    return mh, oh
end

function GameAdapters.EquipItemByIDSafe(itemID)
    if SafeAPI.InCombat() then
        return false, "IN_COMBAT"
    end
    if type(itemID) ~= "number" or itemID <= 0 then
        return false, "INVALID_ITEM"
    end
    if type(_G.EquipItemByName) == "function" then
        local ok = pcall(_G.EquipItemByName, itemID)
        if ok then return true, "EQUIPPED" end
    end
    -- Fallback: locate item in bags and UseContainerItem OOC
    local items = GameAdapters.ScanBagItems()
    for i = 1, #items do
        local it = items[i]
        if it.itemID == itemID and not it.isLocked then
            if C_Container and type(C_Container.UseContainerItem) == "function" then
                local ok = pcall(C_Container.UseContainerItem, it.bag, it.slot)
                if ok then return true, "USED_BAG_ITEM" end
            end
        end
    end
    return false, "NOT_FOUND"
end

local FISHING_AUDIO_CVARS = {
    { name = "Sound_SFXVolume", target = "1.0" },
    { name = "Sound_AmbienceVolume", target = "0.15" },
    { name = "Sound_MusicVolume", target = "0.15" },
}

function GameAdapters.SetFishingSoundBoostSafe(enable)
    if SafeAPI.InCombat() then
        return false, "IN_COMBAT"
    end
    local ps = ns.Api and ns.Api.ProfileStore
    if enable then
        for i = 1, #FISHING_AUDIO_CVARS do
            local spec = FISHING_AUDIO_CVARS[i]
            local cur = GameAdapters.GetCVarRaw(spec.name)
            if cur ~= nil and ps and type(ps.RecordCvarJournal) == "function" then
                ps:RecordCvarJournal(spec.name, tostring(cur))
            end
            GameAdapters.SetCVarSafe(spec.name, spec.target)
        end
        return true, "BOOST_ON"
    else
        local journal = ps and ps.db and ps.db.v2 and ps.db.v2.state and ps.db.v2.state.cvarRestoreJournal
        for i = 1, #FISHING_AUDIO_CVARS do
            local spec = FISHING_AUDIO_CVARS[i]
            local orig = type(journal) == "table" and journal[spec.name] or nil
            if orig ~= nil then
                if GameAdapters.SetCVarSafe(spec.name, orig) and ps and type(ps.ClearCvarJournal) == "function" then
                    ps:ClearCvarJournal(spec.name)
                end
            end
        end
        return true, "BOOST_OFF"
    end
end

local FISHING_INTERACT_CVARS = {
    { name = "SoftTargetInteract", target = "3" },
    { name = "SoftTargetInteractArc", target = "2" },
    { name = "SoftTargetInteractRange", target = "30" },
    { name = "SoftTargetIconGameObject", target = "1" },
}

function GameAdapters.SetFishingOneKeyInteractSafe(enable)
    if SafeAPI.InCombat() then
        return false, "IN_COMBAT"
    end
    local ps = ns.Api and ns.Api.ProfileStore
    if enable then
        for i = 1, #FISHING_INTERACT_CVARS do
            local spec = FISHING_INTERACT_CVARS[i]
            local cur = GameAdapters.GetCVarRaw(spec.name)
            if cur ~= nil and ps and type(ps.RecordCvarJournal) == "function" then
                ps:RecordCvarJournal(spec.name, tostring(cur))
            end
            GameAdapters.SetCVarSafe(spec.name, spec.target)
        end
        return true, "INTERACT_ON"
    else
        local journal = ps and ps.db and ps.db.v2 and ps.db.v2.state and ps.db.v2.state.cvarRestoreJournal
        for i = 1, #FISHING_INTERACT_CVARS do
            local spec = FISHING_INTERACT_CVARS[i]
            local orig = type(journal) == "table" and journal[spec.name] or nil
            if orig ~= nil then
                if GameAdapters.SetCVarSafe(spec.name, orig) and ps and type(ps.ClearCvarJournal) == "function" then
                    ps:ClearCvarJournal(spec.name)
                end
            end
        end
        return true, "INTERACT_OFF"
    end
end

function GameAdapters.GetFishingSpellNameSafe()
    local ids = { 7620, 7731, 7732, 18248, 33095 }
    for i = 1, #ids do
        local name = GameAdapters.GetSpellName(ids[i])
        if type(name) == "string" and name ~= "" then
            return name
        end
    end
    return "낚시"
end

-- A7: Safe OOC ActionBar snapshot & restore + EditMode export/import + Chat window layout
function GameAdapters.SnapshotActionBarSafe(maxSlot)
    local cap = (type(maxSlot) == "number" and maxSlot > 0 and maxSlot <= 120) and maxSlot or 72
    if type(_G.GetActionInfo) ~= "function" then return {} end
    local snap = {}
    for slot = 1, cap do
        local ok, kind, id, sub = pcall(_G.GetActionInfo, slot)
        if ok and (not SafeAPI.IsSecret(kind)) and (not SafeAPI.IsSecret(id))
            and (kind == "spell" or kind == "item" or kind == "macro") and id
        then
            snap[slot] = { kind = kind, id = id, sub = (not SafeAPI.IsSecret(sub)) and sub or nil }
        end
    end
    return snap
end

function GameAdapters.RestoreActionBarSafe(snap)
    if SafeAPI.InCombat() then return false, "IN_COMBAT" end
    if type(snap) ~= "table" or type(_G.PlaceAction) ~= "function" then return false, "UNSUPPORTED" end
    local restored = 0
    for slot, rec in pairs(snap) do
        if type(slot) == "number" and slot >= 1 and slot <= 120 and type(rec) == "table" then
            local picked = false
            if rec.kind == "spell" then
                if C_Spell and type(C_Spell.PickupSpell) == "function" then
                    picked = pcall(C_Spell.PickupSpell, rec.id)
                elseif type(_G.PickupSpell) == "function" then
                    picked = pcall(_G.PickupSpell, rec.id)
                end
            elseif rec.kind == "item" then
                if C_Item and type(C_Item.PickupItem) == "function" then
                    picked = pcall(C_Item.PickupItem, rec.id)
                elseif type(_G.PickupItem) == "function" then
                    picked = pcall(_G.PickupItem, rec.id)
                end
            elseif rec.kind == "macro" and type(_G.PickupMacro) == "function" then
                picked = pcall(_G.PickupMacro, rec.id)
            end
            if picked then
                pcall(_G.PlaceAction, slot)
                if type(_G.ClearCursor) == "function" then pcall(_G.ClearCursor) end
                restored = restored + 1
            end
        end
    end
    return true, restored
end

function GameAdapters.ExportEditModeStringSafe()
    if SafeAPI.InCombat() then return nil, "IN_COMBAT" end
    if not (C_EditMode and type(C_EditMode.GetLayouts) == "function" and type(C_EditMode.ConvertLayoutInfoToString) == "function") then
        return nil, "UNSUPPORTED"
    end
    local layouts = SafeAPI.SafeRead(C_EditMode.GetLayouts)
    if layouts == UNAVAILABLE or type(layouts) ~= "table" or type(layouts.layouts) ~= "table" then
        return nil, "NO_LAYOUTS"
    end
    local activeIdx = layouts.activeLayout or 1
    local info = layouts.layouts[activeIdx] or layouts.layouts[1]
    if type(info) ~= "table" then return nil, "NO_ACTIVE_LAYOUT" end
    local str = SafeAPI.SafeRead(C_EditMode.ConvertLayoutInfoToString, info)
    if str == UNAVAILABLE or type(str) ~= "string" or str == "" then return nil, "ENCODE_FAILED" end
    return str, "OK"
end

function GameAdapters.ImportEditModeStringSafe(layoutStr, layoutName)
    if SafeAPI.InCombat() then return false, "IN_COMBAT" end
    if type(layoutStr) ~= "string" or layoutStr == "" then return false, "EMPTY" end
    if not (C_EditMode and type(C_EditMode.ConvertStringToLayoutInfo) == "function"
        and type(C_EditMode.GetLayouts) == "function" and type(C_EditMode.SaveLayouts) == "function")
    then
        return false, "UNSUPPORTED"
    end
    local info = SafeAPI.SafeRead(C_EditMode.ConvertStringToLayoutInfo, layoutStr)
    if info == UNAVAILABLE or type(info) ~= "table" then return false, "INVALID_STRING" end
    info.layoutName = (type(layoutName) == "string" and layoutName ~= "") and layoutName or "ForeverSuite"
    local layouts = SafeAPI.SafeRead(C_EditMode.GetLayouts)
    if layouts == UNAVAILABLE or type(layouts) ~= "table" then return false, "NO_LAYOUTS" end
    layouts.layouts = layouts.layouts or {}
    if #layouts.layouts >= 5 then
        return false, "LAYOUT_LIMIT"
    end
    layouts.layouts[#layouts.layouts + 1] = info
    local ok = pcall(C_EditMode.SaveLayouts, layouts)
    return ok and true or false, ok and "IMPORTED" or "SAVE_FAILED"
end

-- G4/G5: Safe channel join, dynamic channel index lookup, & chat font size
function GameAdapters.GetChannelIndexByNameSafe(channelName)
    if type(channelName) ~= "string" or channelName == "" then return nil end
    if type(_G.GetChannelName) == "function" then
        local ok, idx = pcall(_G.GetChannelName, channelName)
        if ok and (not SafeAPI.IsSecret(idx)) and type(idx) == "number" and idx > 0 then
            return idx
        end
    end
    return nil
end

function GameAdapters.JoinChannelSafe(channelName)
    if SafeAPI.InCombat() or type(channelName) ~= "string" or channelName == "" then return false end
    if type(_G.JoinPermanentChannel) == "function" then
        return pcall(_G.JoinPermanentChannel, channelName) and true or false
    end
    if type(_G.JoinChannelByName) == "function" then
        return pcall(_G.JoinChannelByName, channelName) and true or false
    end
    return false
end

function GameAdapters.SetChatFontSizeSafe(size)
    if SafeAPI.InCombat() then return false, "IN_COMBAT" end
    local sz = tonumber(size)
    if not sz or sz < 10 or sz > 24 then return false, "INVALID_SIZE" end
    local applied = 0
    local maxW = _G.NUM_CHAT_WINDOWS or 10
    for i = 1, maxW do
        local cf = _G["ChatFrame" .. tostring(i)]
        if cf then
            if type(_G.FCF_SetChatWindowFontSize) == "function" then
                if pcall(_G.FCF_SetChatWindowFontSize, nil, cf, sz) then applied = applied + 1 end
            elseif type(cf.SetFont) == "function" and type(cf.GetFont) == "function" then
                local ok, p, _, fl = pcall(cf.GetFont, cf)
                if ok and type(p) == "string" and pcall(cf.SetFont, cf, p, sz, fl or "") then
                    applied = applied + 1
                end
            end
        end
    end
    return applied > 0, applied
end

function GameAdapters.IsPlayerFeignDeath()
    if type(_G.UnitIsFeignDeath) == "function" then
        local v = SafeAPI.SafeRead(_G.UnitIsFeignDeath, "player")
        return v ~= SafeAPI.UNAVAILABLE and v == true
    end
    return false
end

function GameAdapters.IsPlayerMounted()
    if type(_G.IsMounted) == "function" then
        local v = SafeAPI.SafeRead(_G.IsMounted)
        return v ~= SafeAPI.UNAVAILABLE and v == true
    end
    return false
end

function GameAdapters.GetGatheringTrackers()
    local out = {}
    if not (C_Minimap and type(C_Minimap.GetNumTrackingTypes) == "function" and type(C_Minimap.GetTrackingInfo) == "function") then
        return out
    end
    local n = SafeAPI.SafeRead(C_Minimap.GetNumTrackingTypes)
    if n == SafeAPI.UNAVAILABLE or type(n) ~= "number" or n <= 0 then
        return out
    end
    for i = 1, n do
        local ok, infoOrName, _, active, category = pcall(C_Minimap.GetTrackingInfo, i)
        if ok then
            local name, isActive, isSpell
            if type(infoOrName) == "table" then
                name = infoOrName.name
                isActive = infoOrName.active == true
                isSpell = infoOrName.type == "spell" or infoOrName.subType == 1
            else
                name = infoOrName
                isActive = active == true
                isSpell = (category == "spell")
            end
            if type(name) == "string" and name ~= "" and isSpell then
                if string.find(name, "약초", 1, true) or string.find(name, "광맥", 1, true)
                    or string.find(name, "광물", 1, true) or string.find(name, "보물", 1, true)
                    or string.find(name, "Herb", 1, true) or string.find(name, "Mineral", 1, true)
                    or string.find(name, "Treasure", 1, true)
                then
                    out[#out + 1] = { index = i, name = name, active = isActive }
                end
            end
        end
    end
    return out
end

function GameAdapters.SetTrackingSafe(trackingIndex, active)
    if SafeAPI.InCombat() or type(trackingIndex) ~= "number" or trackingIndex < 1 then
        return false
    end
    if C_Minimap and type(C_Minimap.SetTracking) == "function" then
        return pcall(C_Minimap.SetTracking, trackingIndex, active == true) and true or false
    end
    return false
end

function GameAdapters.GetServerTimeSafe()
    if type(_G.GetServerTime) == "function" then
        local t = SafeAPI.SafeRead(_G.GetServerTime)
        if t ~= UNAVAILABLE and type(t) == "number" and t > 0 then
            return math.floor(t)
        end
    end
    if type(_G.time) == "function" then
        local t = SafeAPI.SafeRead(_G.time)
        if t ~= UNAVAILABLE and type(t) == "number" and t > 0 then
            return math.floor(t)
        end
    end
    return nil
end

function GameAdapters.GetItemCooldownSafe(itemID)
    if type(itemID) ~= "number" or itemID <= 0 then return nil end
    if type(_G.GetItemCooldown) ~= "function" then return nil end
    local ok, startTime, duration, enabled = pcall(_G.GetItemCooldown, itemID)
    if ok and (not SafeAPI.IsSecret(startTime)) and (not SafeAPI.IsSecret(duration))
        and type(startTime) == "number" and type(duration) == "number"
    then
        local isEnabled = nil
        if not SafeAPI.IsSecret(enabled) then
            isEnabled = IsTruthy(enabled)
        end
        return startTime, duration, isEnabled
    end
    return nil
end

function GameAdapters.HasItemInBagsSafe(itemID)
    if type(itemID) ~= "number" or itemID <= 0 then return false end
    local fn = (C_Item and type(C_Item.GetItemCount) == "function" and C_Item.GetItemCount)
        or (type(_G.GetItemCount) == "function" and _G.GetItemCount)
        or nil
    if not fn then return false end
    local ok, cnt = pcall(fn, itemID, false, false, false)
    return ok and (not SafeAPI.IsSecret(cnt)) and type(cnt) == "number" and cnt > 0
end

function GameAdapters.GetPlayerCharKeySafe()
    local name = GameAdapters.GetPlayerName()
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local realm = SafeAPI.GetCanonicalRealm()
    if realm == nil or realm == UNAVAILABLE or type(realm) ~= "string" or realm == "" then
        return nil
    end
    return name .. "-" .. realm
end

function GameAdapters.GetItemNameSafe(itemID)
    if type(itemID) ~= "number" or itemID <= 0 then return nil end
    if C_Item and type(C_Item.GetItemInfo) == "function" then
        local ok, name = pcall(C_Item.GetItemInfo, itemID)
        if ok and (not SafeAPI.IsSecret(name)) and type(name) == "string" and name ~= "" then
            return name
        end
    end
    if type(_G.GetItemInfo) == "function" then
        local ok, name = pcall(_G.GetItemInfo, itemID)
        if ok and (not SafeAPI.IsSecret(name)) and type(name) == "string" and name ~= "" then
            return name
        end
    end
    return nil
end
