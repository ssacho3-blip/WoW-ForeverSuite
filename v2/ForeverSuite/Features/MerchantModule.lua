-- Module: Features/MerchantModule.lua
-- Responsibility: Async AWAIT_GUILD repair fallback, buyback-budgeted junk sell, /fs2 protect (links), /fs2 cheap.
-- Layer: Features (PLAYER_MONEY is sole ledger writer via sign-matched FIFO attribution queue).
local _, ns = ...
ns.Features = ns.Features or {}

local ipairs = ipairs
local tostring = tostring

local MerchantModule = {
    merchantOpen = false,
    awaitingGuildRepair = nil, -- { expectedCost = number, seq = number }
    repairSeq = 0,
    lastToast = nil,
    quickStrip = nil,
}
ns.Features.MerchantModule = MerchantModule

function MerchantModule:EnsureQuickStrip()
    if self.quickStrip then
        return self.quickStrip
    end
    local W = ns.UI and ns.UI.Widgets
    local T = ns.UI and ns.UI.Tokens
    if not (W and T and type(W.HudGlass) == "function") then
        return nil
    end
    local bar = W.HudGlass(_G.UIParent, 304, 28, "ForeverSuiteMerchantQuickBar", T.ELEVATION.L2_PANEL, {
        bg = { 0.055, 0.048, 0.060, 0.90 },
        border = T.BORDER.GOLD_SOFT,
    })
    if type(W.MakeDraggable) == "function" then
        W.MakeDraggable(bar, "merchantQuickBar", nil)
    end

    local sellBtn = W.MiniButton(bar, "잡템 판매", 72, 20, function()
        MerchantModule:ManualSellJunk()
    end, "재구매 안전 한도(12칸) 내 잡템 수동 판매")
    sellBtn:SetPoint("LEFT", bar, "LEFT", 6, 0)

    local repairBtn = W.MiniButton(bar, "수리", 54, 20, function()
        MerchantModule:ManualRepair()
    end, "길드/개인 수리 즉시 실행")
    repairBtn:SetPoint("LEFT", sellBtn, "RIGHT", 4, 0)

    local cheapBtn = W.MiniButton(bar, "싼템 Top5", 76, 20, function()
        MerchantModule:PrintCheapestItems()
    end, "가방 최저가 정리 추천 Top 5 출력")
    cheapBtn:SetPoint("LEFT", repairBtn, "RIGHT", 4, 0)

    local protBtn = W.MiniButton(bar, "보호 관리", 76, 20, function()
        if ns.UI and ns.UI.CommandHub then
            ns.UI.CommandHub:JumpTo("utilities", { subTab = "protect" })
        end
    end, "판매 보호 아이템 목록 관리 열기")
    protBtn:SetPoint("LEFT", cheapBtn, "RIGHT", 4, 0)

    bar._sellBtn = sellBtn
    bar._repairBtn = repairBtn
    bar._cheapBtn = cheapBtn
    bar._protBtn = protBtn
    bar:Hide()
    self.quickStrip = bar
    return bar
end

function MerchantModule:ShowQuickStrip()
    local bar = self:EnsureQuickStrip()
    if not bar then return false end
    -- Zero-Taint: read-only MerchantFrame bounds; parent remains strictly _G.UIParent
    local mf = _G.MerchantFrame
    local anchored = false
    if type(mf) == "table" and type(mf.GetLeft) == "function" and type(mf.GetTop) == "function" then
        local okL, ml = pcall(mf.GetLeft, mf)
        local okT, mt = pcall(mf.GetTop, mf)
        if okL and okT and type(ml) == "number" and type(mt) == "number"
            and (not ns.Api.SafeAPI.IsSecret(ml)) and (not ns.Api.SafeAPI.IsSecret(mt))
            and ml >= 0 and mt > 0
        then
            local uiScale = (_G.UIParent and type(_G.UIParent.GetEffectiveScale) == "function") and _G.UIParent:GetEffectiveScale() or 1.0
            local mfScale = (type(mf.GetEffectiveScale) == "function") and mf:GetEffectiveScale() or uiScale
            local ratio = (type(uiScale) == "number" and uiScale > 0 and type(mfScale) == "number" and mfScale > 0) and (mfScale / uiScale) or 1.0
            bar:ClearAllPoints()
            bar:SetPoint("BOTTOMLEFT", _G.UIParent, "BOTTOMLEFT", ml * ratio, mt * ratio + 4)
            anchored = true
        end
    end
    if not anchored then
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", _G.UIParent, "TOPLEFT", 24, -108)
    end
    bar:Show()
    return true
end

function MerchantModule:ManualRepair()
    if ns.Api.SafeAPI.InCombat() then
        ns.Api.SafeAPI.Print("전투 중에는 수동 수리를 실행할 수 없습니다.")
        return false, "IN_COMBAT"
    end
    if not self.merchantOpen then
        ns.Api.SafeAPI.Print("상점 창이 열려 있을 때만 수리할 수 있습니다.")
        return false, "MERCHANT_CLOSED"
    end
    local needsRepair, cost, canGuild, guildWithdraw, guildMoney, readable = ns.Api.GameAdapters.GetRepairInfo()
    if not readable then
        ns.Api.SafeAPI.Print("이 상인은 장비 수리를 지원하지 않습니다.")
        return false, "CANNOT_REPAIR"
    end
    if not needsRepair then
        ns.Api.SafeAPI.Print("수리가 필요한 장비가 없습니다.")
        return false, "NO_REPAIR_NEEDED"
    end
    local useGuild = ns.Api.ProfileStore:Get("merchant", "useGuildRepair")
    local money = ns.Api.SafeAPI.GetPlayerMoney()
    local decision = ns.Domain.MerchantModel.DecideRepair(
        cost, true, canGuild, useGuild, money, guildWithdraw, guildMoney
    )
    if decision == "GUILD" then
        if ns.Api.GameAdapters.RepairAll(true) then
            self.repairSeq = self.repairSeq + 1
            local seq = self.repairSeq
            local scheduled = ns.Api.GameAdapters.RunAfter(0.6, function()
                if MerchantModule.awaitingGuildRepair and MerchantModule.awaitingGuildRepair.seq == seq then
                    MerchantModule:ResolvePendingGuildRepair("timer")
                end
            end)
            if scheduled then
                self.awaitingGuildRepair = { expectedCost = cost, seq = seq }
            end
            return true, "GUILD_REQUESTED"
        end
        ns.Api.SafeAPI.Print("길드 수리 요청이 차단되었거나 실패했습니다.")
        return false, "GUILD_FAILED"
    elseif decision == "PERSONAL" then
        local attr = ns.Features.LedgerPage and ns.Features.LedgerPage:EnqueueAttribution("repair", -cost, "개인 수리") or nil
        if ns.Api.GameAdapters.RepairAll(false) then
            local msg = "개인 수리 요청 -" .. ns.Domain.LedgerModel.FormatCopper(cost)
            ns.Api.SafeAPI.Print("상점 수동 수리: " .. msg)
            return true, "PERSONAL_REQUESTED"
        elseif attr and ns.Features.LedgerPage then
            ns.Features.LedgerPage:CancelAttribution(attr)
        end
        return false, "PERSONAL_FAILED"
    elseif decision == "INSUFFICIENT_FUNDS" then
        ns.Api.SafeAPI.Print("수리 골드 부족: 필요 " .. ns.Domain.LedgerModel.FormatCopper(cost))
        return false, "INSUFFICIENT_FUNDS"
    end
    return false, decision
end

function MerchantModule:ManualSellJunk()
    if ns.Api.SafeAPI.InCombat() then
        ns.Api.SafeAPI.Print("전투 중에는 잡템 판매를 실행할 수 없습니다.")
        return false, "IN_COMBAT"
    end
    if not self.merchantOpen then
        ns.Api.SafeAPI.Print("상점 창이 열려 있을 때만 잡템을 판매할 수 있습니다.")
        return false, "MERCHANT_CLOSED"
    end
    local protected = ns.Api.ProfileStore.db and ns.Api.ProfileStore.db.v2 and ns.Api.ProfileStore.db.v2.protectedItems
    local existingBuyback = ns.Api.GameAdapters.GetNumBuybackItems()
    if type(protected) ~= "table" or type(existingBuyback) ~= "number" then
        ns.Api.SafeAPI.Print("보호 목록 또는 재구매 상태를 읽을 수 없어 판매를 중단했습니다.")
        return false, "UNREADABLE"
    end
    local items = ns.Api.GameAdapters.ScanBagItems()
    local batch, _, residual = ns.Domain.MerchantModel.SelectJunkToSell(items, protected, 12, existingBuyback)
    if #batch == 0 then
        if residual > 0 then
            ns.Api.SafeAPI.Print("재구매 창(12칸)이 가득 차 잡템 " .. tostring(residual) .. "개 판매를 보류했습니다.")
            return false, "BUYBACK_FULL"
        end
        ns.Api.SafeAPI.Print("판매할 잡템(회색)이 없습니다.")
        return false, "NO_JUNK"
    end
    local soldCount = 0
    local soldCopper = 0
    for _, it in ipairs(batch) do
        local attr = ns.Features.LedgerPage and ns.Features.LedgerPage:EnqueueAttribution("vendorSell", it.totalPrice, "잡템 판매") or nil
        if ns.Api.GameAdapters.SellContainerItem(it.bag, it.slot) then
            soldCount = soldCount + 1
            soldCopper = soldCopper + it.totalPrice
        elseif attr and ns.Features.LedgerPage then
            ns.Features.LedgerPage:CancelAttribution(attr)
        end
    end
    if soldCount > 0 then
        local msg = "잡템 " .. tostring(soldCount) .. "개 판매 요청 (~" .. ns.Domain.LedgerModel.FormatCopper(soldCopper) .. ")"
        if residual > 0 then
            msg = msg .. " (잔여 " .. tostring(residual) .. "개)"
        end
        ns.Api.SafeAPI.Print("상점 원클릭: " .. msg)
        return true, "SOLD"
    end
    return false, "SELL_FAILED"
end

function MerchantModule:ResolvePendingGuildRepair(source)
    local pending = self.awaitingGuildRepair
    if not pending then
        return "NO_PENDING"
    end

    if not self.merchantOpen then
        self.awaitingGuildRepair = nil
        return "MERCHANT_CLOSED"
    end

    local stillNeeds, remainingCost, _, _, _, readable = ns.Api.GameAdapters.GetRepairInfo()
    if not readable then
        if source == "event" then
            return "STILL_WAITING"
        end
        self.awaitingGuildRepair = nil
        ns.Api.SafeAPI.Print("길드 수리 결과 확인 불가(API 읽기 불가) - 이중 수리 방지를 위해 중단했습니다.")
        return "UNREADABLE"
    end

    -- When readable == true (CanMerchantRepair() confirmed) and remainingCost == 0, guild repair succeeded
    -- regardless of whether GetRepairAllCost's 2nd return stays true (capability flag) or becomes false/nil.
    if remainingCost == 0 then
        self.awaitingGuildRepair = nil
        local msg = "길드 수리 완료 -" .. ns.Domain.LedgerModel.FormatCopper(pending.expectedCost)
        ns.Api.SafeAPI.Print("상점 자동화: " .. msg)
        self.lastToast = ns.UI.Widgets.Toast("길드 수리 완료", msg, "SUCCESS")
        return "GUILD_OK"
    end

    -- On durability event with cost still > 0, keep waiting! Only the timeout timer may decide failure.
    if source == "event" then
        return "STILL_WAITING"
    end

    self.awaitingGuildRepair = nil

    -- Timeout confirmed remainingCost > 0 -> fall back safely to personal repair if affordable
    if not stillNeeds or remainingCost <= 0 then
        ns.Api.SafeAPI.Print("길드 수리 미완료(상태 불일치) - 수동 수리를 확인해 주세요.")
        return "FAILED"
    end
    local curMoney = ns.Api.SafeAPI.GetPlayerMoney()
    if type(curMoney) ~= "number" then
        ns.Api.SafeAPI.Print("길드 수리 미확인 및 개인 골드 조회 불가 - 수동 확인이 필요합니다.")
        return "FAILED"
    end
    if curMoney >= remainingCost then
        local attr = ns.Features.LedgerPage and ns.Features.LedgerPage:EnqueueAttribution("repair", -remainingCost, "개인 수리(폴백)") or nil
        if ns.Api.GameAdapters.RepairAll(false) then
            local msg = "개인 수리 요청(길드 폴백) -" .. ns.Domain.LedgerModel.FormatCopper(remainingCost)
            ns.Api.SafeAPI.Print("상점 자동화: " .. msg)
            self.lastToast = ns.UI.Widgets.Toast("개인 수리 요청", msg, "INFO")
            return "PERSONAL_FALLBACK"
        elseif attr and ns.Features.LedgerPage then
            ns.Features.LedgerPage:CancelAttribution(attr)
        end
        ns.Api.SafeAPI.Print("개인 수리 폴백 요청이 차단되었거나 실패했습니다.")
    else
        ns.Api.SafeAPI.Print("길드 수리 불가 및 개인 골드 부족: 필요 " .. ns.Domain.LedgerModel.FormatCopper(remainingCost))
    end
    return "FAILED"
end

function MerchantModule:OnMerchantShow()
    self.merchantOpen = true
    self.awaitingGuildRepair = nil
    if ns.Api.SafeAPI.IsV1Loaded() then
        return false, "YIELDED_TO_V1"
    end
    self:ShowQuickStrip()
    if ns.Api.GameAdapters.IsShiftDown() then
        return false, "SHIFT_BYPASS"
    end

    local summaryParts = {}

    -- 1. Auto-repair (async AWAIT_GUILD verification: event confirms success only; 0.6s timer decides fallback)
    if ns.Api.ProfileStore:Get("merchant", "autoRepair") then
        local needsRepair, cost, canGuild, guildWithdraw, guildMoney, readable = ns.Api.GameAdapters.GetRepairInfo()
        if readable and needsRepair then
            local useGuild = ns.Api.ProfileStore:Get("merchant", "useGuildRepair")
            local money = ns.Api.SafeAPI.GetPlayerMoney()
            local decision = ns.Domain.MerchantModel.DecideRepair(
                cost, true, canGuild, useGuild, money, guildWithdraw, guildMoney
            )
            if decision == "GUILD" then
                if ns.Api.GameAdapters.RepairAll(true) then
                    self.repairSeq = self.repairSeq + 1
                    local seq = self.repairSeq
                    local scheduled = ns.Api.GameAdapters.RunAfter(0.6, function()
                        if MerchantModule.awaitingGuildRepair and MerchantModule.awaitingGuildRepair.seq == seq then
                            MerchantModule:ResolvePendingGuildRepair("timer")
                        end
                    end)
                    if scheduled then
                        self.awaitingGuildRepair = { expectedCost = cost, seq = seq }
                    else
                        ns.Api.SafeAPI.Print("길드 수리 요청 전송(타이머 불가로 자동 폴백 생략)")
                    end
                else
                    ns.Api.SafeAPI.Print("길드 수리 요청이 차단되었거나 실패했습니다.")
                end
            elseif decision == "PERSONAL" then
                local attr = ns.Features.LedgerPage and ns.Features.LedgerPage:EnqueueAttribution("repair", -cost, "개인 수리") or nil
                if ns.Api.GameAdapters.RepairAll(false) then
                    summaryParts[#summaryParts + 1] = "개인 수리 요청 -" .. ns.Domain.LedgerModel.FormatCopper(cost)
                elseif attr and ns.Features.LedgerPage then
                    ns.Features.LedgerPage:CancelAttribution(attr)
                end
            elseif decision == "INSUFFICIENT_FUNDS" then
                ns.Api.SafeAPI.Print("수리 골드 부족: 필요 " .. ns.Domain.LedgerModel.FormatCopper(cost))
            end
        end
    end

    -- 2. Buyback-budgeted junk auto-sell (fail-closed if protectedItems or buybackCount unreadable)
    if ns.Api.ProfileStore:Get("merchant", "autoSellJunk") then
        local protected = ns.Api.ProfileStore.db and ns.Api.ProfileStore.db.v2 and ns.Api.ProfileStore.db.v2.protectedItems
        local existingBuyback = ns.Api.GameAdapters.GetNumBuybackItems()
        if type(protected) == "table" and type(existingBuyback) == "number" then
            local items = ns.Api.GameAdapters.ScanBagItems()
            local batch, _, residual = ns.Domain.MerchantModel.SelectJunkToSell(items, protected, 12, existingBuyback)
            local soldCount = 0
            local soldCopper = 0
            for _, it in ipairs(batch) do
                local attr = ns.Features.LedgerPage and ns.Features.LedgerPage:EnqueueAttribution("vendorSell", it.totalPrice, "잡템 판매") or nil
                if ns.Api.GameAdapters.SellContainerItem(it.bag, it.slot) then
                    soldCount = soldCount + 1
                    soldCopper = soldCopper + it.totalPrice
                elseif attr and ns.Features.LedgerPage then
                    ns.Features.LedgerPage:CancelAttribution(attr)
                end
            end
            if soldCount > 0 then
                local msg = "잡템 " .. tostring(soldCount) .. "개 요청 (~" .. ns.Domain.LedgerModel.FormatCopper(soldCopper) .. ")"
                if residual > 0 then
                    msg = msg .. " (잔여 " .. tostring(residual) .. "개)"
                end
                summaryParts[#summaryParts + 1] = msg
            elseif #batch == 0 and residual > 0 then
                ns.Api.SafeAPI.Print("재구매 창(12칸)이 가득 차 잡템 " .. tostring(residual) .. "개 자동 판매를 보류했습니다.")
            elseif #batch > 0 and soldCount == 0 then
                ns.Api.SafeAPI.Print("잡템 자동 판매 요청이 차단되었거나 실패했습니다.")
            end
        end
    end

    if #summaryParts > 0 then
        local body = table.concat(summaryParts, "  ·  ")
        ns.Api.SafeAPI.Print("상점 자동화: " .. body)
        self.lastToast = ns.UI.Widgets.Toast("상점 자동화", body, "SUCCESS")
    end
    return true, "DONE"
end

function MerchantModule:OnMerchantClosed()
    self.merchantOpen = false
    self.awaitingGuildRepair = nil
    if self.quickStrip then
        self.quickStrip:Hide()
    end
    if ns.Features.LedgerPage then
        ns.Features.LedgerPage:ClearPendingAttributions()
    end
    if self.lastToast then
        self.lastToast:Hide()
    end
end

function MerchantModule:ToggleProtectItem(rawArg)
    local itemID = ns.Domain.MerchantModel.ParseItemIDArg(tostring(rawArg or ""))
    if not itemID or itemID <= 0 then
        ns.Api.SafeAPI.Print("사용법: /fs protect <아이템ID 또는 아이템링크>")
        return false
    end
    if not ns.Api.ProfileStore:CanWrite() then
        ns.Api.SafeAPI.Print("읽기 전용 프로필에서는 보호 목록을 변경할 수 없습니다.")
        return false
    end
    local prot = ns.Api.ProfileStore.db.v2.protectedItems
    if prot[itemID] then
        prot[itemID] = nil
        ns.Api.SafeAPI.Print("아이템 보호 해제: #" .. tostring(itemID))
    else
        prot[itemID] = true
        ns.Api.SafeAPI.Print("아이템 판매 보호 등록: #" .. tostring(itemID))
    end
    return true
end

function MerchantModule:PrintCheapestItems()
    local protected = ns.Api.ProfileStore.db and ns.Api.ProfileStore.db.v2 and ns.Api.ProfileStore.db.v2.protectedItems
    if type(protected) ~= "table" then
        return {}
    end
    local items = ns.Api.GameAdapters.ScanBagItems()
    local cheapest = ns.Domain.MerchantModel.SelectCheapestItems(items, protected, 5)
    if #cheapest == 0 then
        ns.Api.SafeAPI.Print("정리 추천 가능한 저가 아이템이 없습니다.")
        return cheapest
    end
    ns.Api.SafeAPI.Print("가방 정리 추천 최저가 아이템 Top " .. tostring(#cheapest) .. ":")
    for i, it in ipairs(cheapest) do
        ns.Api.SafeAPI.Print("  " .. tostring(i) .. ". " .. it.name .. " (" .. ns.Domain.LedgerModel.FormatCopper(it.totalPrice) .. ")")
    end
    return cheapest
end
