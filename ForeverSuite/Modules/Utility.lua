local _, ns = ...

local type = type
local select = select
local tonumber = tonumber
local tostring = tostring
local math_min = math.min
local math_floor = math.floor

local NUM_TOTAL_BAGS = 4
local POOR_QUALITY = (_G.Enum and _G.Enum.ItemQuality and _G.Enum.ItemQuality.Poor) or 0
local BUYBACK_HARD_CAP = 12

local Utility = {
    title = "편의 및 상점 자동화 (Utility)",
    priority = "P1",
    description = "자동 수리(길드→개인), 회색템 판매(12개 한도), 고속 루팅, 추가 스킬창(ActionBar) 자동 확장",
    yieldTo = { "Leatrix_Plus" },
    merchantOpen = false,
    qolApplied = false,
    extraBarsApplied = false,
    activeExtraBarCount = 0,
    reusableSellQueue = {},
}

local function IsShiftBypassActive()
    if _G.IsShiftKeyDown and _G.IsShiftKeyDown() then
        return true
    end
    return false
end

function Utility:OnInitialize()
    self.merchantOpen = false
    self.qolApplied = false
    self.extraBarsApplied = false
    self.activeExtraBarCount = 0
    ns.WipeTable(self.reusableSellQueue)
end

function Utility:ApplyExtraActionBars(forceExpand)
    if not forceExpand and not ns.ProfileManager:Get("utility", "extraActionBars") then
        return false
    end
    if ns.InCombat() then
        if ns.CombatQueue and ns.CombatQueue.RunOrDefer then
            ns.CombatQueue:RunOrDefer("Utility_ApplyExtraActionBars", function()
                self:ApplyExtraActionBars(forceExpand)
            end)
        end
        return false
    end

    local b1, b2, b3, b4, b5, b6, b7 = false, false, false, false, false, false, false
    if type(_G.GetActionBarToggles) == "function" then
        local ok, r1, r2, r3, r4, r5, r6, r7 = pcall(_G.GetActionBarToggles)
        if ok then
            b1 = (r1 == true or r1 == 1)
            b2 = (r2 == true or r2 == 1)
            b3 = (r3 == true or r3 == 1)
            b4 = (r4 == true or r4 == 1)
            b5 = (r5 == true or r5 == 1)
            b6 = (r6 == true or r6 == 1)
            b7 = (r7 == true or r7 == 1)
        end
    end

    local mode = ns.ProfileManager:Get("utility", "extraActionBarMode") or "STANDARD"
    local expandAll = forceExpand or (mode == "EXPANDED") or (b1 and b2)
    local wantBar2 = true
    local wantBar3 = true
    local wantBar4 = true
    local wantBar5 = expandAll or b4
    local wantBar6 = expandAll or b5

    ns.SafeSetCVar("alwaysShowActionBars", "1")
    local mask = 7 -- Bar2(1) + Bar3(2) + Bar4(4)
    if wantBar5 then
        mask = mask + 8
    end
    if wantBar6 then
        mask = mask + 16
    end
    ns.SafeSetCVar("enableMultiActionBars", tostring(mask))

    if type(_G.SetActionBarToggles) == "function" then
        pcall(_G.SetActionBarToggles, wantBar2, wantBar3, wantBar4, wantBar5, true, wantBar6, b6, b7)
    end

    if type(_G.Settings) == "table" and type(_G.Settings.SetValue) == "function" then
        local proxyMap = {
            { "PROXY_SHOW_ACTIONBAR_2", wantBar2 },
            { "PROXY_SHOW_ACTIONBAR_3", wantBar3 },
            { "PROXY_SHOW_ACTIONBAR_4", wantBar4 },
            { "PROXY_SHOW_ACTIONBAR_5", wantBar5 },
            { "PROXY_SHOW_ACTIONBAR_6", wantBar6 },
        }
        for i = 1, #proxyMap do
            local entry = proxyMap[i]
            if entry[2] then
                local hasSetting = true
                if type(_G.Settings.GetSetting) == "function" then
                    local okSet, settingObj = pcall(_G.Settings.GetSetting, entry[1])
                    hasSetting = okSet and (settingObj ~= nil)
                end
                if hasSetting then
                    pcall(_G.Settings.SetValue, entry[1], true)
                end
            end
        end
    end

    if type(_G.MultiActionBar_Update) == "function" then
        pcall(_G.MultiActionBar_Update)
    end
    if type(_G.ActionBarController_UpdateAll) == "function" then
        pcall(_G.ActionBarController_UpdateAll)
    end

    local frameNames = { "MultiBarBottomLeft", "MultiBarBottomRight", "MultiBarRight" }
    if wantBar5 then
        frameNames[#frameNames + 1] = "MultiBarLeft"
    end
    if wantBar6 then
        frameNames[#frameNames + 1] = "MultiBar5"
    end
    for i = 1, #frameNames do
        local f = _G[frameNames[i]]
        if type(f) == "table" then
            if type(f.SetShown) == "function" then
                pcall(f.SetShown, f, true)
            elseif type(f.Show) == "function" then
                pcall(f.Show, f)
            end
            if type(f.SetShowGrid) == "function" then
                pcall(f.SetShowGrid, f, true, 2)
            end
            if type(f.UpdateGridLayout) == "function" then
                pcall(f.UpdateGridLayout, f)
            end
        end
    end

    self.extraBarsApplied = true
    self.activeExtraBarCount = 3 + (wantBar5 and 1 or 0) + (wantBar6 and 1 or 0)
    return true
end

function Utility:ToggleExtraActionBars()
    local curMode = ns.ProfileManager:Get("utility", "extraActionBarMode") or "STANDARD"
    local nextMode = (curMode == "EXPANDED") and "STANDARD" or "EXPANDED"
    if ns.ProfileManager:CanWrite() then
        ns.ProfileManager:Set("utility", "extraActionBars", true, "account")
        ns.ProfileManager:Set("utility", "extraActionBarMode", nextMode, "account")
    end
    local ok = self:ApplyExtraActionBars(true)
    if ok then
        ns.Print("추가 스킬창(행동 단축바) 확장 적용 완료 (활성 추가 스킬창: " .. tostring(self.activeExtraBarCount) .. "개 · 빈 슬롯 표시 켜짐)")
    else
        ns.Print("전투 종료 후 추가 스킬창 확장이 자동 적용됩니다.")
    end
    return ok
end

function Utility:ApplyQoLCVars()
    if not ns.ProfileManager:Get("utility", "applyQoLCVars") then
        return
    end
    if ns.ProfileManager:ApplyTemporaryCVar("countdownForCooldowns", "1") then
        self.qolApplied = true
    else
        ns.SafeSetCVar("countdownForCooldowns", "1")
    end
end

function Utility:RestoreQoLCVars()
    if self.qolApplied then
        ns.ProfileManager:RestoreTemporaryCVar("countdownForCooldowns")
        self.qolApplied = false
    end
end

function Utility:TryAutoRepair()
    if ns.IsFeatureYielded("repair") then
        return
    end
    if not ns.ProfileManager:Get("utility", "autoRepair") then
        return
    end
    if not (_G.CanMerchantRepair and _G.CanMerchantRepair()) then
        return
    end
    if not _G.GetRepairAllCost or not _G.RepairAllItems then
        return
    end

    local repairCost, canRepair = _G.GetRepairAllCost()
    if not canRepair or type(repairCost) ~= "number" or ns.IsSecret(repairCost) or repairCost <= 0 then
        return
    end

    if ns.ProfileManager:Get("utility", "useGuildRepair") and _G.IsInGuild and _G.IsInGuild() then
        if _G.CanGuildBankRepair and _G.CanGuildBankRepair() then
            local rawWithdraw = _G.GetGuildBankWithdrawMoney and _G.GetGuildBankWithdrawMoney() or 0
            local rawFunds = _G.GetGuildBankMoney and _G.GetGuildBankMoney() or repairCost
            if type(rawWithdraw) == "number" and not ns.IsSecret(rawWithdraw) and type(rawFunds) == "number" and not ns.IsSecret(rawFunds) then
                if (rawWithdraw == -1 or rawWithdraw >= repairCost) and rawFunds >= repairCost then
                    _G.RepairAllItems(true)
                    ns.Print("길드 자금으로 장비 수리 완료 (" .. ns.FormatMoney(repairCost) .. ")")
                    return
                end
            end
        end
    end

    local myMoney = _G.GetMoney and _G.GetMoney() or 0
    if type(myMoney) == "number" and not ns.IsSecret(myMoney) and myMoney >= repairCost then
        ns.SetPendingMoneyReason("REPAIR", 1.5, -1, -repairCost)
        _G.RepairAllItems(false)
        ns.Print("개인 골드로 장비 수리 완료 (" .. ns.FormatMoney(repairCost) .. ")")
    else
        ns.Warn("골드가 부족하여 자동 수리를 건너뜁니다 (필요: " .. ns.FormatMoney(repairCost) .. ")")
    end
end

function Utility:TryAutoSellJunk()
    if ns.IsFeatureYielded("sell") then
        return 0
    end
    if not ns.ProfileManager:Get("utility", "autoSellJunk") then
        return 0
    end
    if not self.merchantOpen or IsShiftBypassActive() then
        return 0
    end
    if not (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo and C_Container.UseContainerItem) then
        return 0
    end

    local configuredCap = tonumber(ns.ProfileManager:Get("utility", "maxSellBatch")) or BUYBACK_HARD_CAP
    local batchLimit = math_min(BUYBACK_HARD_CAP, configuredCap > 0 and configuredCap or BUYBACK_HARD_CAP)

    local queue = ns.WipeTable(self.reusableSellQueue)

    for bag = 0, NUM_TOTAL_BAGS do
        local numSlots = C_Container.GetContainerNumSlots(bag) or 0
        if type(numSlots) == "number" and not ns.IsSecret(numSlots) then
            for slot = 1, numSlots do
                if #queue >= batchLimit then
                    break
                end
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if type(info) == "table" and not ns.IsSecret(info.quality) and info.quality == POOR_QUALITY and not info.isLocked and not info.hasNoValue then
                    local itemID = info.itemID
                    if itemID and not ns.IsSecret(itemID) and not ns.ProfileManager:IsProtectedItem(itemID) then
                        local rawSell = nil
                        if C_Item and C_Item.GetItemInfo then
                            rawSell = select(11, C_Item.GetItemInfo(itemID))
                        end
                        local sellPrice = (type(rawSell) == "number" and not ns.IsSecret(rawSell)) and rawSell or 0
                        if sellPrice > 0 then
                            local rawStack = info.stackCount
                            local stackCount = (type(rawStack) == "number" and not ns.IsSecret(rawStack)) and rawStack or 1
                            queue[#queue + 1] = {
                                bag = bag,
                                slot = slot,
                                itemID = itemID,
                                expected = sellPrice * stackCount,
                            }
                        end
                    end
                end
            end
        end
        if #queue >= batchLimit then
            break
        end
    end

    local soldCount = 0
    local expectedCopper = 0
    for i = 1, #queue do
        if not self.merchantOpen or IsShiftBypassActive() then
            break
        end
        local entry = queue[i]
        local liveInfo = C_Container.GetContainerItemInfo(entry.bag, entry.slot)
        if type(liveInfo) == "table"
            and not liveInfo.isLocked
            and not ns.IsSecret(liveInfo.itemID)
            and liveInfo.itemID == entry.itemID
            and not ns.IsSecret(liveInfo.quality)
            and liveInfo.quality == POOR_QUALITY
        then
            ns.SetPendingMoneyReason("VENDOR_SELL", 1.5, 1, entry.expected)
            C_Container.UseContainerItem(entry.bag, entry.slot)
            soldCount = soldCount + 1
            expectedCopper = expectedCopper + entry.expected
        end
    end

    if soldCount > 0 then
        ns.Print("회색 잡템 " .. tostring(soldCount) .. "칸 판매 요청 (예상 수익: " .. ns.FormatMoney(expectedCopper) .. ", 1회 안전 한도 " .. tostring(batchLimit) .. "칸)")
    end
    return soldCount
end

function Utility:OnMerchantShow()
    self.merchantOpen = true
    if IsShiftBypassActive() then
        ns.Print("Shift 키 입력 감지: 상점 자동화를 일시 건너뜁니다.")
        return
    end
    self:TryAutoRepair()
    self:TryAutoSellJunk()
end

function Utility:OnMerchantClosed()
    self.merchantOpen = false
end

function Utility:OnLootReady()
    if not ns.ProfileManager:Get("utility", "fastAutoLoot") then
        return
    end
    if ns.InCombat() or IsShiftBypassActive() then
        return
    end
    if not (_G.GetNumLootItems and _G.LootSlot) then
        return
    end
    local autoLootOn = (ns.SafeGetCVar("autoLootDefault") == "1")
    if _G.IsModifiedClick and _G.IsModifiedClick("AUTOLOOTTOGGLE") then
        autoLootOn = not autoLootOn
    end
    if not autoLootOn then
        return
    end
    local count = _G.GetNumLootItems()
    if type(count) ~= "number" or ns.IsSecret(count) or count <= 0 then
        return
    end
    for slot = count, 1, -1 do
        _G.LootSlot(slot)
    end
end

function Utility:OnPlayerEnteringWorld()
    self:ApplyExtraActionBars(false)
end

function Utility:OnEnable(ctx)
    self:ApplyQoLCVars()
    self:ApplyExtraActionBars(false)
    ctx:RegisterEvent("PLAYER_ENTERING_WORLD", Utility.OnPlayerEnteringWorld)
    ctx:RegisterEvent("MERCHANT_SHOW", Utility.OnMerchantShow)
    ctx:RegisterEvent("MERCHANT_CLOSED", Utility.OnMerchantClosed)
    ctx:RegisterEvent("LOOT_READY", Utility.OnLootReady)
    ctx:AddCleanup(function()
        Utility:RestoreQoLCVars()
    end)
end

function Utility:OnDisable()
    self.merchantOpen = false
    self:RestoreQoLCVars()
    ns.WipeTable(self.reusableSellQueue)
end

ns.ModuleManager:Register("Utility", Utility)
