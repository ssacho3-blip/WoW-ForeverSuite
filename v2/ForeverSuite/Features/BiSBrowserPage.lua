-- Module: Features/BiSBrowserPage.lua
-- Responsibility: Dedicated KPI-2 BiS & Live 1:1 Equipped Gear Comparison Browser (slot filters, upgrade-only toggle,
--                 live GetInventoryItemID + GetDetailedItemLevelInfo delta badge, and Acquisitions408 sources).
-- Layer: Features (uses UI/Widgets + Domain/BiSBrowserModel + Api/SafeAPI/GameAdapters).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs
local tostring = tostring
local type = type
local math_max = math.max
local math_min = math.min

local VISIBLE_ROWS = 11

local QUALITY_COLORS = {
    [1] = T.TEXT.PRIMARY,
    [2] = { 0.12, 0.90, 0.25, 1.0 },
    [3] = { 0.28, 0.64, 1.00, 1.0 },
    [4] = { 0.72, 0.36, 0.98, 1.0 },
    [5] = { 1.00, 0.54, 0.10, 1.0 },
}

local BiSBrowserPage = {
    id = "bis",
    label = "BiS · 비교",
    host = nil,
    slotFilter = "all",
    upgradeOnly = false,
    scrollOffset = 0,
    lastQuery = "",
    rows = {},
    detailLbl = nil,
    statusLbl = nil,
}
ns.Features.BiSBrowserPage = BiSBrowserPage

local function ToneColor(tone)
    if tone == "SUCCESS" then return T.SEMANTIC.SUCCESS end
    if tone == "GOLD" then return T.TEXT.GOLD end
    if tone == "DANGER" then return T.SEMANTIC.DANGER end
    if tone == "SECONDARY" then return T.TEXT.SECONDARY end
    return T.TEXT.MUTED
end

local function ShowBiSTooltip(btn)
    local rec = btn and btn._rec
    if type(rec) ~= "table" or not (_G.GameTooltip and type(_G.GameTooltip.SetOwner) == "function") then return end
    local it = rec.item
    pcall(function()
        _G.GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        _G.GameTooltip:ClearLines()
        if type(it.itemID) == "number" and it.itemID > 0 and type(_G.GameTooltip.SetHyperlink) == "function" then
            pcall(_G.GameTooltip.SetHyperlink, _G.GameTooltip, "item:" .. tostring(it.itemID))
        end
        local col = QUALITY_COLORS[it.quality or 1] or T.TEXT.GOLD
        _G.GameTooltip:AddLine(tostring(it.title), col[1], col[2], col[3])
        if rec.equippedIlvl then
            _G.GameTooltip:AddLine("착용 장비 비교: 내 iLvl " .. tostring(rec.equippedIlvl) .. " → " .. tostring(rec.badge), T.TEXT.GOLD[1], T.TEXT.GOLD[2], T.TEXT.GOLD[3])
        end
        if type(it.note) == "string" and it.note ~= "" then
            _G.GameTooltip:AddLine("능력치: " .. it.note, T.TEXT.PRIMARY[1], T.TEXT.PRIMARY[2], T.TEXT.PRIMARY[3])
        end
        if type(it.acq) == "string" and it.acq ~= "" then
            _G.GameTooltip:AddLine("획득처: " .. it.acq, T.SEMANTIC.SUCCESS[1], T.SEMANTIC.SUCCESS[2], T.SEMANTIC.SUCCESS[3])
        end
        _G.GameTooltip:Show()
    end)
end

local function HideBiSTooltip()
    if _G.GameTooltip and type(_G.GameTooltip.Hide) == "function" then
        pcall(_G.GameTooltip.Hide, _G.GameTooltip)
    end
end

function BiSBrowserPage:Render(query)
    if not (self.host and self.rows[1]) then return end
    self.lastQuery = query or ""
    local ok, st = ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_BiS")
    local pack = _G.ForeverSuiteData and _G.ForeverSuiteData.packs and _G.ForeverSuiteData.packs.bis
    if not (ok and type(pack) == "table" and type(pack.entries) == "table") then
        for i = 1, VISIBLE_ROWS do self.rows[i]:Hide() end
        if self.statusLbl then self.statusLbl:SetText("BiS 데이터팩을 불러오지 못했습니다 (" .. tostring(st) .. ").") end
        return
    end

    local equipped = ns.Api.GameAdapters.GetEquippedItemLevelMap()
    local list = ns.Domain.BiSBrowserModel.FilterAndCompare(pack.entries, {
        slotFilter = self.slotFilter,
        upgradeOnly = self.upgradeOnly,
        query = self.lastQuery,
        equippedBySlot = equipped,
    })

    local maxOff = math_max(0, #list - VISIBLE_ROWS)
    self.scrollOffset = math_max(0, math_min(maxOff, self.scrollOffset))

    for i = 1, VISIBLE_ROWS do
        local row = self.rows[i]
        local rec = list[self.scrollOffset + i]
        if rec then
            local it = rec.item
            row._rec = rec
            local qCol = QUALITY_COLORS[it.quality or 1] or T.TEXT.PRIMARY
            local acqTag = (type(it.acq) == "string" and it.acq ~= "") and (" · " .. it.acq) or ""
            row._left:SetText("[" .. tostring(it.slot or "장비") .. "] " .. tostring(it.title) .. acqTag)
            row._left:SetTextColor(qCol[1], qCol[2], qCol[3], 1)
            local bCol = ToneColor(rec.tone)
            row._right:SetText(rec.badge)
            row._right:SetTextColor(bCol[1], bCol[2], bCol[3], 1)
            row:Show()
        else
            row._rec = nil
            row:Hide()
        end
    end

    if self.statusLbl then
        self.statusLbl:SetText(
            "BiS 후보 " .. tostring(#list) .. "건 (부위: " .. tostring(self.slotFilter)
            .. (self.upgradeOnly and " · 업그레이드 전용" or "") .. " · 휠 스크롤 지원)"
        )
    end
end

function BiSBrowserPage:Build(parent)
    self.host = parent
    if type(parent.EnableMouseWheel) == "function" then
        parent:EnableMouseWheel(true)
        local prevWheel = type(parent.GetScript) == "function" and parent:GetScript("OnMouseWheel") or nil
        parent:SetScript("OnMouseWheel", function(f, delta)
            if type(prevWheel) == "function" then pcall(prevWheel, f, delta) end
            if not delta or delta == 0 then return end
            BiSBrowserPage.scrollOffset = BiSBrowserPage.scrollOffset + (delta > 0 and -3 or 3)
            BiSBrowserPage:Render(BiSBrowserPage.lastQuery)
        end)
    end

    local hdr = W.SectionHeader(parent, "BiS 후보 · 착용 장비 실시간 iLvl 비교 · 획득처")
    hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    -- 2 neat rows of slot filter pills
    local row1Opts = {}
    local row2Opts = {}
    for i, opt in ipairs(ns.Domain.BiSBrowserModel.SLOT_FILTERS) do
        if i <= 8 then row1Opts[#row1Opts + 1] = opt else row2Opts[#row2Opts + 1] = opt end
    end
    local bar1 = W.PillBar(parent, row1Opts, self.slotFilter, function(v)
        BiSBrowserPage.slotFilter = v
        BiSBrowserPage.scrollOffset = 0
        BiSBrowserPage:Render(BiSBrowserPage.lastQuery)
    end)
    bar1:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -28)
    bar1:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -28)

    local bar2 = W.PillBar(parent, row2Opts, self.slotFilter, function(v)
        BiSBrowserPage.slotFilter = v
        BiSBrowserPage.scrollOffset = 0
        BiSBrowserPage:Render(BiSBrowserPage.lastQuery)
    end)
    bar2:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -56)
    bar2:SetWidth(380)

    local upgToggle = W.Toggle(parent, "착용 장비보다 높은 iLvl만 보기", self.upgradeOnly, function(v)
        BiSBrowserPage.upgradeOnly = v
        BiSBrowserPage.scrollOffset = 0
        BiSBrowserPage:Render(BiSBrowserPage.lastQuery)
        return true
    end)
    upgToggle:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -56)
    upgToggle:SetWidth(220)

    for i = 1, VISIBLE_ROWS do
        local row = W.ListRow(parent, 26, function(btn)
            if btn._rec and btn._rec.item then
                local it = btn._rec.item
                ns.Api.SafeAPI.Print(
                    "[BiS] " .. tostring(it.title) .. " (" .. tostring(btn._rec.badge) .. ") — "
                    .. tostring(it.acq ~= "" and it.acq or it.note or "획득처 정보")
                )
            end
        end)
        row:SetTooltipHandler(ShowBiSTooltip, HideBiSTooltip)
        row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(88 + (i - 1) * 28))
        row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(88 + (i - 1) * 28))
        self.rows[i] = row
    end

    self.statusLbl = W.Label(parent, "", "small", T.TEXT.MUTED)
    self.statusLbl:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 4)
end

function BiSBrowserPage:OnShow()
    self:Render(ns.UI.CommandHub.lastQuery or "")
    ns.UI.CommandHub:RefreshStatusBar()
end

function BiSBrowserPage:OnSearch(query)
    self.scrollOffset = 0
    self:Render(query)
end
