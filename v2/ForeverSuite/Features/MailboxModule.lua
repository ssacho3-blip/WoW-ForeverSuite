-- Module: Features/MailboxModule.lua
-- Responsibility: Lightweight Zero-Taint Mailbox QoL bar (UIParent-owned, never mutates MailFrame fields,
--                 yields cleanly if Postal is loaded, strictly skips COD mails on batch collect).
-- Layer: Features (uses UI/Widgets + Domain/MailboxModel + Api/SafeAPI/GameAdapters/AddonProbe).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local tostring = tostring
local type = type
local pcall = pcall

local MailboxModule = {
    bar = nil,
    infoLbl = nil,
    collectBtn = nil,
    isOpen = false,
}
ns.Features.MailboxModule = MailboxModule

function MailboxModule:ShouldYieldToPostal()
    if ns.Api and ns.Api.AddonProbe and type(ns.Api.AddonProbe.IsLoaded) == "function" then
        return ns.Api.AddonProbe.IsLoaded("Postal") == true
    end
    return false
end

function MailboxModule:ScanInbox()
    local items = {}
    if type(_G.GetInboxNumItems) ~= "function" or type(_G.GetInboxHeaderInfo) ~= "function" then
        return items
    end
    local okN, numItems = pcall(_G.GetInboxNumItems)
    if not okN or ns.Api.SafeAPI.IsSecret(numItems) or type(numItems) ~= "number" or numItems <= 0 then
        return items
    end
    for i = 1, numItems do
        local okH, _, _, sender, subject, money, cod, _, hasItem = pcall(_G.GetInboxHeaderInfo, i)
        if okH then
            -- Fail-closed COD check: secret or non-number CODAmount is treated as unknown COD and skipped
            local codUnknown = ns.Api.SafeAPI.IsSecret(cod) or (type(cod) ~= "number")
            items[#items + 1] = {
                index = i,
                sender = (not ns.Api.SafeAPI.IsSecret(sender) and type(sender) == "string") and sender or "",
                subject = (not ns.Api.SafeAPI.IsSecret(subject) and type(subject) == "string") and subject or "",
                money = (not ns.Api.SafeAPI.IsSecret(money) and type(money) == "number") and money or 0,
                cod = (not codUnknown) and cod or 0,
                codUnknown = codUnknown,
                hasItem = (not ns.Api.SafeAPI.IsSecret(hasItem) and type(hasItem) == "number") and hasItem or 0,
            }
        else
            items[#items + 1] = {
                index = i,
                sender = "",
                subject = "",
                money = 0,
                cod = 0,
                codUnknown = true,
                hasItem = 0,
            }
        end
    end
    return items
end

local function EnsureBar()
    if MailboxModule.bar then return MailboxModule.bar end
    local bar = W.PopupCard(_G.UIParent, 360, 42, "ForeverSuiteMailboxBar", T.ELEVATION.L2_WORKSPACE)
    bar:SetPoint("TOP", _G.UIParent, "TOP", 0, -96)

    local lbl = W.Label(bar, "우편함 대기 중", "small", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    lbl:SetPoint("LEFT", bar, "LEFT", 12, 0)

    local btn = W.Button(bar, "안전 일괄 수령 (COD 제외)", 158, 24, function()
        MailboxModule:CollectAllSafe()
    end, true)
    btn:SetPoint("RIGHT", bar, "RIGHT", -10, 0)
    lbl:SetPoint("RIGHT", btn, "LEFT", -8, 0)

    MailboxModule.bar = bar
    MailboxModule.infoLbl = lbl
    MailboxModule.collectBtn = btn
    bar:Hide()
    return bar
end

function MailboxModule:Refresh()
    if not self.isOpen then
        if self.bar then self.bar:Hide() end
        return nil
    end
    if self:ShouldYieldToPostal() then
        if self.bar then self.bar:Hide() end
        return nil, "YIELDED_POSTAL"
    end
    if ns.Api.ProfileStore and ns.Api.ProfileStore:Get("qol", "mailboxSafeOpen") == false then
        if self.bar then self.bar:Hide() end
        return nil, "DISABLED"
    end
    EnsureBar()
    local summary = ns.Domain.MailboxModel.SummarizeInbox(self:ScanInbox())
    local goldTxt = (summary.totalCopper > 0 and ns.Domain.LedgerModel)
        and (" · " .. ns.Domain.LedgerModel.FormatCopper(summary.totalCopper)) or ""
    local codTxt = (summary.codCount > 0) and (" · COD " .. tostring(summary.codCount) .. "건 보호") or ""
    self.infoLbl:SetText("우편 " .. tostring(summary.total) .. "건 (수령 가능 " .. tostring(summary.lootableCount) .. "건)" .. goldTxt .. codTxt)
    self.bar:Show()
    return summary, "OK"
end

function MailboxModule:CollectAllSafe()
    if self:ShouldYieldToPostal() then
        ns.Api.SafeAPI.Print("Postal 애드온이 활성화되어 있어 우편 일괄 수령을 Postal에 양보합니다.")
        return false, "YIELDED_POSTAL"
    end
    if ns.Api.SafeAPI.InCombat() then
        ns.Api.SafeAPI.Print("전투 중에는 우편을 일괄 수령할 수 없습니다.")
        return false, "IN_COMBAT"
    end
    if not self.isOpen then
        return false, "NOT_OPEN"
    end
    local summary = ns.Domain.MailboxModel.SummarizeInbox(self:ScanInbox())
    if summary.lootableCount == 0 then
        ns.Api.SafeAPI.Print("수령 가능한 일반 우편이 없습니다 (COD 우편은 안전을 위해 제외됨).")
        return false, "EMPTY"
    end
    local takenMoney = 0
    local takenMails = 0
    -- Iterate in reverse order so inbox index shifts do not skip entries
    for idx = #summary.lootableIndices, 1, -1 do
        local entry = summary.lootableIndices[idx]
        local tookAny = false
        if entry.money > 0 and type(_G.TakeInboxMoney) == "function" then
            local okM = pcall(_G.TakeInboxMoney, entry.index)
            if okM then
                takenMoney = takenMoney + entry.money
                tookAny = true
            end
        end
        if entry.hasItem > 0 and type(_G.AutoLootMailItem) == "function" then
            local okI = pcall(_G.AutoLootMailItem, entry.index)
            if okI then tookAny = true end
        elseif entry.hasItem > 0 and type(_G.TakeInboxItem) == "function" then
            for att = 1, entry.hasItem do
                local okA = pcall(_G.TakeInboxItem, entry.index, att)
                if okA then tookAny = true end
            end
        end
        if tookAny then
            takenMails = takenMails + 1
        end
    end
    local moneyTxt = (takenMoney > 0 and ns.Domain.LedgerModel)
        and (" · 골드 " .. ns.Domain.LedgerModel.FormatCopper(takenMoney)) or ""
    local codTxt = (summary.codCount > 0) and (" · COD " .. tostring(summary.codCount) .. "건 안전 제외") or ""
    ns.Api.SafeAPI.Print("[우편 안전 수령] " .. tostring(takenMails) .. "건 처리" .. moneyTxt .. codTxt)
    self:Refresh()
    return true, { takenMails = takenMails, takenMoney = takenMoney, skippedCod = summary.codCount }
end

function MailboxModule:OnMailShow()
    self.isOpen = true
    return self:Refresh()
end

function MailboxModule:OnMailInboxUpdate()
    if self.isOpen then
        return self:Refresh()
    end
end

function MailboxModule:OnMailClosed()
    self.isOpen = false
    if self.bar then
        self.bar:Hide()
    end
end
