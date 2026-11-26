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
local MAX_VISIBLE_ROWS = 12

local LedgerPage = {
    id = "ledger",
    label = "골드 원장",
    group = "life",
    host = nil,
    summaryLbl = nil,
    scrollLbl = nil,
    scrollBar = nil,
    emptyState = nil,
    scrollOffset = 0,
    lastQuery = "",
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
    if type(parent.EnableMouseWheel) == "function" then
        parent:EnableMouseWheel(true)
        local prevWheel = type(parent.GetScript) == "function" and parent:GetScript("OnMouseWheel") or nil
        parent:SetScript("OnMouseWheel", function(f, delta)
            if type(prevWheel) == "function" then pcall(prevWheel, f, delta) end
            if not delta or delta == 0 then return end
            LedgerPage.scrollOffset = LedgerPage.scrollOffset + (delta > 0 and -3 or 3)
            LedgerPage:RefreshView()
        end)
    end

    local hdr = W.SectionHeader(parent, "세션 & 최근 100건 골드 원장")
    hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    local card = W.Card(parent, 640, 56)
    card:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -32)
    card:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -32)
    local lbl = W.Label(card, "", "mono", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    lbl:SetPoint("LEFT", card, "LEFT", 12, 0)
    lbl:SetPoint("RIGHT", card, "RIGHT", -12, 0)
    self.summaryLbl = lbl

    local sb = W.ScrollBar(parent, 320, function(newOff)
        LedgerPage.scrollOffset = newOff
        LedgerPage:RefreshView()
    end)
    sb:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -2, -98)
    sb:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -2, 24)
    self.scrollBar = sb

    local empty = W.EmptyState(parent, {
        icon = "Interface\\Icons\\INV_Misc_Coin_01",
        title = "기록된 골드 변동이 없습니다",
        desc = "상점 수리·잡템 판매·루팅·퀘스트 보상 등으로 골드가 변동되면 자동으로 여기에 기록됩니다.",
    })
    empty:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -98)
    empty:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 24)
    self.emptyState = empty

    local sLbl = W.Label(parent, "", "small", T.TEXT.MUTED)
    sLbl:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 4)
    self.scrollLbl = sLbl

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

    local rawList = (ns.Api.ProfileStore.db and ns.Api.ProfileStore.db.v2 and ns.Api.ProfileStore.db.v2.ledger) or {}
    local recent = ns.Domain.LedgerModel.Summarize(rawList)
    local sessionNet = self.sessionIncome - self.sessionExpense
    if self.summaryLbl then
        self.summaryLbl:SetText(
            "세션 " .. ns.Domain.LedgerModel.FormatCopper(sessionNet) ..
            " (+" .. ns.Domain.LedgerModel.FormatCopper(self.sessionIncome) ..
            " / -" .. ns.Domain.LedgerModel.FormatCopper(self.sessionExpense) ..
            ")  |  최근 " .. tostring(recent.count) .. "건 순수익 " .. ns.Domain.LedgerModel.FormatCopper(recent.net)
        )
    end

    local q = string.lower(tostring(self.lastQuery or ""))
    local list = {}
    for i = 1, #rawList do
        local e = rawList[i]
        if q == "" then
            list[#list + 1] = e
        else
            local hay = string.lower(tostring(e.category or "") .. " " .. tostring(e.note or ""))
            if string.find(hay, q, 1, true) then
                list[#list + 1] = e
            end
        end
    end

    if #list == 0 then
        if self.emptyState then self.emptyState:Show() end
        if self.scrollBar then self.scrollBar:SetMetrics(0, MAX_VISIBLE_ROWS, 0) end
        if self.scrollLbl then
            self.scrollLbl:SetText(q ~= "" and "검색 조건과 일치하는 원장 항목이 없습니다." or "기록된 골드 변동: 0 / 100건")
        end
        return
    end
    if self.emptyState then self.emptyState:Hide() end

    local maxOff = (#list > MAX_VISIBLE_ROWS) and (#list - MAX_VISIBLE_ROWS) or 0
    if self.scrollOffset < 0 then self.scrollOffset = 0 end
    if self.scrollOffset > maxOff then self.scrollOffset = maxOff end

    local rightMargin = (#list > MAX_VISIBLE_ROWS) and -14 or 0
    local y = 98
    local shown = 0
    local startIdx = #list - self.scrollOffset
    for i = startIdx, 1, -1 do
        local e = list[i]
        shown = shown + 1
        local row = self:EnsureRow(shown)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", self.host, "TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", self.host, "TOPRIGHT", rightMargin, -y)
        row._left:SetText("[" .. tostring(e.category) .. "] " .. tostring(e.note))
        local col = (e.delta >= 0) and T.SEMANTIC.SUCCESS or T.SEMANTIC.DANGER
        row._right:SetText((e.delta >= 0 and "+" or "") .. ns.Domain.LedgerModel.FormatCopper(e.delta))
        row._right:SetTextColor(col[1], col[2], col[3], 1)
        row:SetRowStyle(nil, col, 0, 2, T.BORDER.SUBTLE, 8)
        row:Show()
        y = y + 26
        if shown >= MAX_VISIBLE_ROWS then
            break
        end
    end
    self.visibleRows = shown
    if self.scrollBar then
        self.scrollBar:SetMetrics(self.scrollOffset, MAX_VISIBLE_ROWS, #list)
    end
    if self.scrollLbl then
        if #list > MAX_VISIBLE_ROWS then
            local fromN = self.scrollOffset + 1
            local toN = self.scrollOffset + shown
            self.scrollLbl:SetText("스크롤: 최근 " .. tostring(fromN) .. "–" .. tostring(toN) .. " / " .. tostring(#list) .. "건")
        else
            self.scrollLbl:SetText("기록된 골드 변동: " .. tostring(#list) .. " / 100건")
        end
    end
end

function LedgerPage:OnShow()
    self.lastQuery = ""
    self:RefreshView()
end

function LedgerPage:OnSearch(query)
    self.lastQuery = query or ""
    self.scrollOffset = 0
    self:RefreshView()
end
