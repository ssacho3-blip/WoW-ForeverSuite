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
    description = "자동 수리(길드→개인), 회색템 판매(12개 한도), 고속 루팅, QoL CVar 자동 제어",
    yieldTo = { "Leatrix_Plus" },
    merchantOpen = false,
    qolApplied = false,
    reusableSellQueue = {},
}

local function IsShiftBypassActive()
    if _G.IsShiftKeyDown and _G.IsShiftKeyDown() then
        return true
    end
    return false
end

local EXTRA_BAR_FRAMES = {
    "MultiBarBottomLeft",
    "MultiBarBottomRight",
    "MultiBarRight",
    "MultiBarLeft",
    "MultiBar5",
    "MultiBar6",
    "MultiBar7",
}

local ACTIONBAR_PROXY_KEYS = {
    "PROXY_SHOW_ACTIONBAR_2",
    "PROXY_SHOW_ACTIONBAR_3",
    "PROXY_SHOW_ACTIONBAR_4",
    "PROXY_SHOW_ACTIONBAR_5",
    "PROXY_SHOW_ACTIONBAR_6",
    "PROXY_SHOW_ACTIONBAR_7",
    "PROXY_SHOW_ACTIONBAR_8",
}

function Utility:OnInitialize()
    self.merchantOpen = false
    self.qolApplied = false
    ns.WipeTable(self.reusableSellQueue)
end

function Utility:EnsureMainActionBarVisible()
    if ns.InCombat() then
        return
    end
    ns.SafeSetCVar("alwaysShowActionBars", "1")
    for _, mainName in ipairs({ "MainMenuBar", "MainActionBar" }) do
        local mf = _G[mainName]
        if type(mf) == "table" then
            if type(mf.SetShown) == "function" then
                pcall(mf.SetShown, mf, true)
            elseif type(mf.Show) == "function" then
                pcall(mf.Show, mf)
            end
        end
    end
    for idx = 1, 12 do
        local btn = _G["ActionButton" .. tostring(idx)]
        if type(btn) == "table" then
            if type(btn.SetShowGrid) == "function" then
                pcall(btn.SetShowGrid, btn, true, 1)
            end
            if type(btn.Show) == "function" then
                pcall(btn.Show, btn)
            end
        end
    end
end

function Utility:RevertExtraActionBarsIfNeeded(markFinal, forceClean)
    local acct = ns.ProfileManager and ns.ProfileManager.runtimeAccount
    local charTbl = ns.ProfileManager and ns.ProfileManager.runtimeChar
    local utilTbl = (type(acct) == "table" and type(acct.utility) == "table") and acct.utility or nil
    local hadLegacyFlag = (utilTbl ~= nil and (utilTbl.extraActionBars ~= nil or utilTbl.extraActionBarMode ~= nil))
    local charRolledBack = (type(charTbl) == "table" and charTbl._extraBarsRollback20261107 == true)
    local acctRolledBack = (utilTbl ~= nil and utilTbl._extraBarsRollback20261107 == true)
    local alreadyRolledBack = charRolledBack or (charTbl == nil and acctRolledBack)
    local curMulti = ns.SafeGetCVar("enableMultiActionBars")
    local hasLegacyMultiMask = (curMulti == "7" or curMulti == "31" or curMulti == "127")

    -- Always keep Main ActionBar 1 (slots 1..12) visible so stance changes or empty slots never hide the main bar
    self:EnsureMainActionBarVisible()

    if (not forceClean) and alreadyRolledBack and not hadLegacyFlag and not hasLegacyMultiMask then
        return false
    end

    if ns.InCombat() then
        if ns.CombatQueue and ns.CombatQueue.RunOrDefer then
            ns.CombatQueue:RunOrDefer("Utility_RevertExtraActionBars", function()
                self:RevertExtraActionBarsIfNeeded(markFinal, forceClean)
            end)
        end
        return false
    end

    local okAlways = ns.SafeSetCVar("alwaysShowActionBars", "1")
    local okMulti = ns.SafeSetCVar("enableMultiActionBars", "0")

    if type(_G.SetActionBarToggles) == "function" then
        pcall(_G.SetActionBarToggles, false, false, false, false, true, false, false, false)
    end

    if type(_G.Settings) == "table" and type(_G.Settings.SetValue) == "function" then
        for i = 1, #ACTIONBAR_PROXY_KEYS do
            local key = ACTIONBAR_PROXY_KEYS[i]
            local hasSetting = true
            if type(_G.Settings.GetSetting) == "function" then
                local okSet, settingObj = pcall(_G.Settings.GetSetting, key)
                hasSetting = okSet and (settingObj ~= nil)
            end
            if hasSetting then
                pcall(_G.Settings.SetValue, key, false)
            end
        end
    end

    if type(_G.MultiActionBar_Update) == "function" then
        pcall(_G.MultiActionBar_Update)
    end
    if type(_G.ActionBarController_UpdateAll) == "function" then
        pcall(_G.ActionBarController_UpdateAll)
    end

    for i = 1, #EXTRA_BAR_FRAMES do
        local fName = EXTRA_BAR_FRAMES[i]
        local f = _G[fName]
        if type(f) == "table" then
            if type(f.SetShowGrid) == "function" then
                pcall(f.SetShowGrid, f, false, 2)
            end
            if type(f.SetShown) == "function" then
                pcall(f.SetShown, f, false)
            elseif type(f.Hide) == "function" then
                pcall(f.Hide, f)
            end
        end
    end

    self:EnsureMainActionBarVisible()

    local verifiedClean = (okAlways == true and okMulti == true)
        and (ns.SafeGetCVar("enableMultiActionBars") == "0")
    if not verifiedClean then
        return false
    end

    if ns.ProfileManager and ns.ProfileManager:CanWrite() then
        if utilTbl then
            utilTbl.extraActionBars = nil
            utilTbl.extraActionBarMode = nil
            if markFinal then
                utilTbl._extraBarsRollback20261106 = true
                utilTbl._extraBarsRollback20261107 = true
            end
        end
        if markFinal and type(charTbl) == "table" then
            charTbl._extraBarsRollback20261106 = true
            charTbl._extraBarsRollback20261107 = true
        end
    end
    return true
end

function Utility:CleanActionBarsNow()
    local ok = self:RevertExtraActionBarsIfNeeded(true, true)
    if ok then
        ns.Print("추가 스킬창 정리 및 1번 메인 스킬창(1~12번 슬롯) 고정 표시 완료")
    else
        ns.Print("전투 종료 후 스킬창 정리가 자동 적용됩니다.")
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
    self:RevertExtraActionBarsIfNeeded(true)
end

function Utility:OnEnable(ctx)
    self.ctx = ctx
    self:ApplyQoLCVars()
    self:RevertExtraActionBarsIfNeeded(false)
    ctx:RegisterEvent("PLAYER_ENTERING_WORLD", Utility.OnPlayerEnteringWorld)
    ctx:RegisterEvent("MERCHANT_SHOW", Utility.OnMerchantShow)
    ctx:RegisterEvent("MERCHANT_CLOSED", Utility.OnMerchantClosed)
    ctx:RegisterEvent("LOOT_READY", Utility.OnLootReady)
    ctx:AddCleanup(function()
        Utility:RestoreQoLCVars()
    end)
end

function Utility:OnDisable()
    self.ctx = nil
    self.merchantOpen = false
    self:RestoreQoLCVars()
    ns.WipeTable(self.reusableSellQueue)
end

ns.ModuleManager:Register("Utility", Utility)
