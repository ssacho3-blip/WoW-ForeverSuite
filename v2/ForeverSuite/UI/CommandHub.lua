-- Module: UI/CommandHub.lua
-- Responsibility: Unified L2 /fs Command Hub (Left Nav Rail + Global Search + Status Bar + pluggable workspace pages).
-- Layer: UI
local _, ns = ...
ns.UI = ns.UI or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local pairs = pairs
local ipairs = ipairs
local table_insert = table.insert

local CommandHub = {
    window = nil,
    rail = nil,
    contentHost = nil,
    statusLabel = nil,
    pages = {},
    pageDefs = {},
    activePageId = nil,
    lastQuery = "",
}
ns.UI.CommandHub = CommandHub

function CommandHub:RegisterPage(def)
    if type(def) ~= "table" or type(def.id) ~= "string" then
        return false
    end
    table_insert(self.pageDefs, def)
    self.pages[def.id] = def
    return true
end

function CommandHub:EnsureWindow()
    if self.window then
        return self.window
    end
    local win = W.Window("ForeverSuiteV2CommandHub", 880, 580, "✦ ForeverSuite")
    win:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 20)

    local search = W.SearchBox(win._header, 210, "설정 · 도감 전역 검색...", function(q)
        CommandHub.lastQuery = q
        local cur = CommandHub.pages[CommandHub.activePageId]
        if cur and type(cur.OnSearch) == "function" then
            cur:OnSearch(q)
        end
    end)
    search:SetPoint("RIGHT", win._closeBtn, "LEFT", -96, 0)

    local moveBtn = W.Button(win._header, "HUD 이동", 78, 24, function()
        local unlocked = ns.UI.HudLayout:ToggleUnlock()
        ns.Api.SafeAPI.Print(unlocked and "HUD 이동 모드 활성화 (/fs move)" or "HUD 위치 잠금 완료")
    end, true)
    moveBtn:SetPoint("RIGHT", win._closeBtn, "LEFT", -T.SPACE.SM, 0)

    local rail = W.TabRail(win, 156, self.pageDefs, function(pageId)
        CommandHub:SelectPage(pageId)
    end)
    rail:SetPoint("TOPLEFT", win, "TOPLEFT", 1, -41)
    rail:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 1, 28)

    local host = CreateFrame("Frame", nil, win)
    host:SetPoint("TOPLEFT", rail, "TOPRIGHT", T.SPACE.MD, -T.SPACE.MD)
    host:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -T.SPACE.MD, 34)

    local footer = CreateFrame("Frame", nil, win)
    footer:SetHeight(27)
    footer:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 1, 1)
    footer:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -1, 1)
    local status = W.Label(footer, "", "small", T.TEXT.MUTED)
    status:SetPoint("LEFT", footer, "LEFT", T.SPACE.MD, 0)

    self.window = win
    self.rail = rail
    self.contentHost = host
    self.statusLabel = status
    self.searchBox = search

    if self.pageDefs[1] then
        self:SelectPage(self.pageDefs[1].id)
    end
    self:RefreshStatusBar()
    return win
end

function CommandHub:SelectPage(pageId)
    local def = self.pages[pageId]
    if not def then
        return false
    end
    self.activePageId = pageId
    if self.rail then
        self.rail:SetActive(pageId)
    end
    for id, page in pairs(self.pages) do
        if page._frame then
            if id == pageId then
                page._frame:Show()
            else
                page._frame:Hide()
            end
        end
    end
    if not def._frame and self.contentHost then
        local f = CreateFrame("Frame", nil, self.contentHost)
        f:SetAllPoints(self.contentHost)
        def._frame = f
        if type(def.Build) == "function" then
            def:Build(f)
        end
    end
    if def._frame then
        def._frame:Show()
    end
    if type(def.OnShow) == "function" then
        def:OnShow()
    end
    if self.lastQuery ~= "" and type(def.OnSearch) == "function" then
        def:OnSearch(self.lastQuery)
    end
    self:RefreshStatusBar()
    return true
end

function CommandHub:RefreshStatusBar()
    if not self.statusLabel then
        return
    end
    local dataLoaded = type(_G.ForeverSuiteData) == "table"
    local realm = ns.Api.SafeAPI.GetCanonicalRealm()
    local taintText = "집계 없음"
    if ns.Api.ProfileStore.readOnly then
        taintText = "집계 없음 (읽기 전용)"
    elseif ns.Api.ProfileStore.db and ns.Api.ProfileStore.db.v2 and ns.Api.ProfileStore.db.v2.diagnostics then
        local blocked = ns.Api.ProfileStore.db.v2.diagnostics.taintTotal
        if type(blocked) == "number" then
            taintText = "Blocked " .. tostring(blocked) .. "건"
        end
    end
    self.statusLabel:SetText(
        "상태: " .. taintText .. " · Data팩 " ..
        (dataLoaded and "로드됨" or "미로드(0MB)") .. " · 렐름: " .. realm
    )
end

function CommandHub:Toggle()
    local win = self:EnsureWindow()
    if win:IsShown() then
        win:Hide()
    else
        win:Show()
        self:RefreshStatusBar()
    end
end
