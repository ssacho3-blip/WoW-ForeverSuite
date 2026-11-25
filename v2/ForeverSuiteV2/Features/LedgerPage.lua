-- Module: Features/LedgerPage.lua
-- Responsibility: Gold Ledger page inside L2 /fs2 Command Hub (PLAYER_MONEY single writer, sign-matched attribution queue, MERCHANT_CLOSED expiry).
-- Layer: Features (zero raw CreateFrame; uses UI/Widgets + Domain/LedgerModel).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local tostring = tostring
local table_insert = table.insert
local table_remove = table.remove

local MAX_LEDGER_ENTRIES = 100
local MAX_VISIBLE_ROWS = 10

local LedgerPage = {
    id = "ledger",
    label = "골드 원장",
    host = nil,
    summaryLbl = nil,
    rowPool = {},
    visibleRows = 0,
    lastMoney = nil,
    pendingQueue = {},
    sessionIncome = 0,
    sessionExpense = 0,
    sessionCount = 0,
}
ns.Features.LedgerPage = LedgerPage

function LedgerPage:EnqueueAttribution(category, expectedDelta, note)
    local entry = {
        category = category,
        expectedDelta = expectedDelta, -- exact signed copper delta (e.g. -4200 repair, +500 sell)
        note = note,
    }
    table_insert(self.pendingQueue, entry)
    return entry
end

function LedgerPage:CancelAttribution(entry)
    if not entry then
        return
    end
    for i = #self.pendingQueue, 1, -1 do
        if self.pendingQueue[i] == entry then
            table_remove(self.pendingQueue, i)
            return
        end
    end
end

function LedgerPage:ClearPendingAttributions()
    self.pendingQueue = {}
end

local function ConsumeMatchingAttribution(queue, delta)
    for i = 1, #queue do
        if queue[i].expectedDelta == delta then
            local hit = queue[i]
            table_remove(queue, i)
            return hit.category, hit.note
        end
    end
    return nil, nil
end

function LedgerPage:RecordEntry(category, deltaCopper, note)
    if type(deltaCopper) ~= "number" or deltaCopper == 0 then
        return false
    end
    self.sessionCount = self.sessionCount + 1
    if deltaCopper > 0 then
        self.sessionIncome = self.sessionIncome + deltaCopper
    else
        self.sessionExpense = self.sessionExpense + (-deltaCopper)
    end
    if ns.Api.ProfileStore:CanWrite() then
        local list = ns.Api.ProfileStore.db.v2.ledger
        local ts = ns.Api.GameAdapters.GetEpochTimestamp()
        table_insert(list, {
            category = category or "other",
            delta = deltaCopper,
            note = tostring(note or category or "기타"),
            ts = (ts and ts > 0) and ts or nil,
        })
        while #list > MAX_LEDGER_ENTRIES do
            table_remove(list, 1)
        end
    end
    if self.host and self.host:IsShown() then
        self:RefreshView()
    end
    return true
end

function LedgerPage:SyncFromPlayerMoney()
    local cur = ns.Api.SafeAPI.GetPlayerMoney()
    if type(cur) ~= "number" then
        return nil
    end
    if self.lastMoney == nil then
        self.lastMoney = cur
        return 0
    end
    local delta = cur - self.lastMoney
    self.lastMoney = cur
    if delta ~= 0 then
        local cat, note = ConsumeMatchingAttribution(self.pendingQueue, delta)
        if not cat then
            local inMerchant = ns.Features.MerchantModule and ns.Features.MerchantModule.merchantOpen
            cat = inMerchant and "merchant" or "other"
            note = inMerchant and "상점 거래" or "골드 변동"
        end
        self:RecordEntry(cat, delta, note)
    end
    return delta
end

function LedgerPage:EnsureRow(idx)
    if self.rowPool[idx] then
        return self.rowPool[idx]
    end
    local row = W.ListRow(self.host, 24)
    self.rowPool[idx] = row
    return row
end

function LedgerPage:Build(parent)
    self.host = parent
    local hdr = W.SectionHeader(parent, "세션 & 최근 100건 골드 원장")
    hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    local card = W.Card(parent, 540, 56)
    card:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -32)
    local lbl = W.Label(card, "", "mono", T.TEXT.GOLD)
    lbl:SetPoint("LEFT", card, "LEFT", 12, 0)
    self.summaryLbl = lbl

    self:RefreshView()
end

function LedgerPage:RefreshView()
    if not self.host then
        return
    end
    for i = 1, #self.rowPool do
        self.rowPool[i]:Hide()
    end
    self.visibleRows = 0

    local list = (ns.Api.ProfileStore.db and ns.Api.ProfileStore.db.v2 and ns.Api.ProfileStore.db.v2.ledger) or {}
    local recent = ns.Domain.LedgerModel.Summarize(list)
    local sessionNet = self.sessionIncome - self.sessionExpense
    if self.summaryLbl then
        self.summaryLbl:SetText(
            "세션 " .. ns.Domain.LedgerModel.FormatCopper(sessionNet) ..
            " (+" .. ns.Domain.LedgerModel.FormatCopper(self.sessionIncome) ..
            " / -" .. ns.Domain.LedgerModel.FormatCopper(self.sessionExpense) ..
            ")  |  최근 " .. tostring(recent.count) .. "건 순수익 " .. ns.Domain.LedgerModel.FormatCopper(recent.net)
        )
    end

    local y = 98
    local shown = 0
    for i = #list, 1, -1 do
        local e = list[i]
        shown = shown + 1
        local row = self:EnsureRow(shown)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", self.host, "TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", self.host, "TOPRIGHT", 0, -y)
        row._left:SetText("[" .. tostring(e.category) .. "] " .. tostring(e.note))
        local col = (e.delta >= 0) and T.SEMANTIC.SUCCESS or T.SEMANTIC.DANGER
        row._right:SetText((e.delta >= 0 and "+" or "") .. ns.Domain.LedgerModel.FormatCopper(e.delta))
        row._right:SetTextColor(col[1], col[2], col[3], 1)
        row:Show()
        y = y + 26
        if shown >= MAX_VISIBLE_ROWS then
            break
        end
    end
    self.visibleRows = shown
end

function LedgerPage:OnShow()
    self:RefreshView()
end
