-- Module: Modules/Economy.lua
-- Responsibility: Session gold delta ledger (vendorSell, repair, quest, other) with Auctionator coexistence and live BagHUD tooltip sync.
-- Dependencies: Core/Init.lua, Core/MoneyLedgerQueue.lua, Core/ProfileManager.lua, Core/ModuleManager.lua.
-- Public API: Economy (ResetSessionBaseline, SyncCursorToCurrentMoney, IsMerchantContextOpen, ClassifyMoneyDelta, OnPlayerMoney, GetNetDelta, PrintLedgerSummary).
-- Combat/Secret Safety: Guards secret GetMoney()/GetRepairAllCost()/GetRewardMoney() returns via ns.IsSecret without fabricating zero deltas.
local _, ns = ...

local type = type
local pcall = pcall
local select = select
local string_format = string.format

local Economy = {
    title = "경매장 공존 및 골드 원장 (Economy)",
    priority = "P2",
    description = "Auctionator 공존, PLAYER_MONEY 델타 정합성 검증 세션 골드 수지 원장",
    yieldTo = { "Auctionator" },
    active = false,
    hooksInstalled = false,
    initializedBaseline = false,
    secretGap = false,
    settingObserverBound = false,
    merchantOpen = false,
    questCompleteSeen = false,
    cachedRepairCost = 0,
    cachedQuestReward = 0,
    baselineMoney = 0,
    lastMoney = 0,
    ledger = {
        vendorSell = 0,
        repair = 0,
        quest = 0,
        other = 0,
    },
}

local function NotifyHoveredBagTooltip()
    local invRec = ns.ModuleManager and ns.ModuleManager:GetModule("Inventory")
    if invRec and invRec.state == "ENABLED" and invRec.definition and invRec.definition.RefreshHoveredGoldTooltip then
        invRec.definition:RefreshHoveredGoldTooltip()
    end
end

local function ReadCleanPositiveMoney(fn)
    if type(fn) ~= "function" then
        return 0, false
    end
    local val, flag = fn()
    if ns.IsSecret(val) or type(val) ~= "number" then
        return 0, false
    end
    if flag ~= nil and not ns.IsSecret(flag) and flag == false then
        return 0, true
    end
    if val > 0 then
        return val, true
    end
    return 0, true
end

function Economy:IsMerchantContextOpen()
    if self.merchantOpen then
        return true
    end
    local mf = _G.MerchantFrame
    if type(mf) == "table" and type(mf.IsShown) == "function" then
        local ok, shown = pcall(mf.IsShown, mf)
        if ok and not ns.IsSecret(shown) and shown then
            return true
        end
    end
    return false
end

function Economy:RefreshCachedRepairCost()
    local cost = ReadCleanPositiveMoney(_G.GetRepairAllCost)
    self.cachedRepairCost = cost
end

function Economy:RefreshCachedQuestReward()
    local reward = ReadCleanPositiveMoney(_G.GetRewardMoney)
    self.cachedQuestReward = reward
end

function Economy:SyncCursorToCurrentMoney()
    if not _G.GetMoney then
        return false
    end
    local current = _G.GetMoney()
    if not ns.IsSecret(current) and type(current) == "number" then
        self.lastMoney = current
        self.secretGap = false
        return true
    end
    self.secretGap = true
    return false
end

function Economy:ResetSessionBaseline()
    local current = _G.GetMoney and _G.GetMoney()
    if ns.IsSecret(current) or type(current) ~= "number" then
        current = 0
        self.secretGap = true
    else
        self.secretGap = false
    end
    self.baselineMoney = current
    self.lastMoney = current
    self.ledger.vendorSell = 0
    self.ledger.repair = 0
    self.ledger.quest = 0
    self.ledger.other = 0
    self.initializedBaseline = true
    NotifyHoveredBagTooltip()
end

local function ConsumeFreshArmFlag(flagKey)
    local armed = ns[flagKey]
    if armed == nil then
        return false
    end
    ns[flagKey] = nil
    return type(armed) == "number" and (ns.GetNow() - armed) <= 3.0
end

function Economy:InstallAttributionHooks()
    if self.hooksInstalled or type(_G.hooksecurefunc) ~= "function" then
        return
    end
    self.hooksInstalled = true

    if type(_G.RepairAllItems) == "function" then
        pcall(_G.hooksecurefunc, "RepairAllItems", function(guildBank)
            if ConsumeFreshArmFlag("_fsRepairArmedAt") then
                Economy.cachedRepairCost = 0
                return
            end
            if not Economy.active or not ns.ProfileManager:Get("economy", "trackSessionGold") then
                return
            end
            if guildBank then
                Economy.cachedRepairCost = 0
                return
            end
            local cost = Economy.cachedRepairCost
            if cost <= 0 then
                cost = ReadCleanPositiveMoney(_G.GetRepairAllCost)
            end
            Economy.cachedRepairCost = 0
            if cost > 0 then
                ns.SetPendingMoneyReason("REPAIR", 2.0, -1, -cost)
            end
        end)
    end

    if type(_G.C_Container) == "table" and type(_G.C_Container.UseContainerItem) == "function" then
        pcall(_G.hooksecurefunc, _G.C_Container, "UseContainerItem", function(bag, slot, target)
            if ConsumeFreshArmFlag("_fsSellArmedAt") then
                return
            end
            if not Economy.active or not ns.ProfileManager:Get("economy", "trackSessionGold") then
                return
            end
            if target ~= nil or not Economy:IsMerchantContextOpen() then
                return
            end
            local expectedSell = nil
            if type(_G.C_Container.GetContainerItemInfo) == "function" then
                local okInfo, info = pcall(_G.C_Container.GetContainerItemInfo, bag, slot)
                if okInfo and type(info) == "table" then
                    if info.hasNoValue == true then
                        return
                    end
                    if C_Item and type(C_Item.GetItemInfo) == "function" and info.itemID and not ns.IsSecret(info.itemID) then
                        local rawSell = select(11, C_Item.GetItemInfo(info.itemID))
                        if type(rawSell) == "number" and not ns.IsSecret(rawSell) and rawSell > 0 then
                            local stack = (type(info.stackCount) == "number" and not ns.IsSecret(info.stackCount)) and info.stackCount or 1
                            expectedSell = rawSell * stack
                        end
                    end
                end
            end
            ns.SetPendingMoneyReason("VENDOR_SELL", 2.0, 1, expectedSell)
        end)
    end

    if type(_G.GetQuestReward) == "function" then
        pcall(_G.hooksecurefunc, "GetQuestReward", function()
            if ConsumeFreshArmFlag("_fsQuestArmedAt") then
                Economy.cachedQuestReward = 0
                Economy.questCompleteSeen = false
                return
            end
            if not Economy.active or not ns.ProfileManager:Get("economy", "trackSessionGold") then
                return
            end
            local reward = Economy.cachedQuestReward
            if reward <= 0 and type(_G.GetRewardMoney) == "function" then
                reward = ReadCleanPositiveMoney(_G.GetRewardMoney)
            end
            Economy.cachedQuestReward = 0
            Economy.questCompleteSeen = false
            if reward > 0 then
                ns.SetPendingMoneyReason("QUEST", 3.0, 1, reward)
            elseif type(_G.GetRewardMoney) ~= "function" then
                ns.SetPendingMoneyReason("QUEST", 3.0, 1, nil)
            end
        end)
    end
end

function Economy:ClassifyMoneyDelta(delta)
    if ns.IsSecret(delta) or type(delta) ~= "number" or delta == 0 then
        return nil
    end
    local reason = ns.ConsumePendingMoneyReason(delta)
    if reason == "VENDOR_SELL" and delta > 0 then
        return "VENDOR_SELL"
    elseif reason == "REPAIR" and delta < 0 then
        self.cachedRepairCost = 0
        return "REPAIR"
    elseif reason == "QUEST" and delta > 0 then
        self.cachedQuestReward = 0
        return "QUEST"
    end
    return nil
end

function Economy:OnInitialize()
    if not self.settingObserverBound and ns.ProfileManager and ns.ProfileManager.OnSettingChanged then
        self.settingObserverBound = true
        ns.ProfileManager:OnSettingChanged(function(section, key, value)
            if section == "economy" and key == "trackSessionGold" and value then
                Economy:SyncCursorToCurrentMoney()
            end
        end)
    end
end

function Economy:OnMerchantShow()
    self.merchantOpen = true
    self:RefreshCachedRepairCost()
end

function Economy:OnMerchantClosed()
    self.merchantOpen = false
    self.cachedRepairCost = 0
end

function Economy:OnDurabilityChanged()
    if self:IsMerchantContextOpen() then
        self:RefreshCachedRepairCost()
    end
end

function Economy:OnQuestComplete()
    self.questCompleteSeen = true
    self:RefreshCachedQuestReward()
end

function Economy:OnQuestFinished()
    self.questCompleteSeen = false
    self.cachedQuestReward = 0
end

function Economy:OnPlayerMoney()
    if not ns.ProfileManager:Get("economy", "trackSessionGold") then
        return
    end
    if not _G.GetMoney then
        return
    end
    local current = _G.GetMoney()
    if ns.IsSecret(current) or type(current) ~= "number" then
        self.secretGap = true
        return
    end
    if not self.initializedBaseline then
        self:ResetSessionBaseline()
        return
    end
    if self.secretGap then
        self.lastMoney = current
        self.secretGap = false
        return
    end

    local delta = current - self.lastMoney
    self.lastMoney = current
    if delta == 0 then
        return
    end

    local reason = self:ClassifyMoneyDelta(delta)

    if reason == "VENDOR_SELL" then
        self.ledger.vendorSell = self.ledger.vendorSell + delta
    elseif reason == "REPAIR" then
        self.ledger.repair = self.ledger.repair + delta
    elseif reason == "QUEST" then
        self.ledger.quest = self.ledger.quest + delta
    else
        self.ledger.other = self.ledger.other + delta
    end
    NotifyHoveredBagTooltip()
end

function Economy:GetNetDelta()
    return self.ledger.vendorSell + self.ledger.repair + self.ledger.quest + self.ledger.other
end

function Economy:PrintLedgerSummary()
    local net = self:GetNetDelta()
    ns.Print(string_format(
        "세션 골드 원장 — 순증감: %s (상점판매: %s | 수리: %s | 퀘스트: %s | 기타: %s)",
        ns.FormatMoney(net),
        ns.FormatMoney(self.ledger.vendorSell),
        ns.FormatMoney(self.ledger.repair),
        ns.FormatMoney(self.ledger.quest),
        ns.FormatMoney(self.ledger.other)
    ))
end

function Economy:OnEnable(ctx)
    self.active = true
    self:InstallAttributionHooks()
    if not self.initializedBaseline then
        self:ResetSessionBaseline()
    else
        self:SyncCursorToCurrentMoney()
    end
    if self:IsMerchantContextOpen() then
        self:RefreshCachedRepairCost()
    end
    ctx:RegisterEvent("PLAYER_MONEY", Economy.OnPlayerMoney)
    ctx:RegisterEvent("MERCHANT_SHOW", Economy.OnMerchantShow)
    ctx:RegisterEvent("MERCHANT_CLOSED", Economy.OnMerchantClosed)
    ctx:RegisterEvent("UPDATE_INVENTORY_DURABILITY", Economy.OnDurabilityChanged)
    ctx:RegisterEvent("QUEST_COMPLETE", Economy.OnQuestComplete)
    ctx:RegisterEvent("QUEST_FINISHED", Economy.OnQuestFinished)
    ctx:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        if not Economy.initializedBaseline then
            Economy:ResetSessionBaseline()
        end
    end)
end

function Economy:OnDisable()
    self.active = false
    self.merchantOpen = false
    self.questCompleteSeen = false
    self.cachedRepairCost = 0
    self.cachedQuestReward = 0
end

ns.ModuleManager:Register("Economy", Economy)
