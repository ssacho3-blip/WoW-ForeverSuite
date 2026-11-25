-- Module: Features/CodexPage.lua
-- Responsibility: Unified Codex shell inside L2 /fs Command Hub (lazy LoD load + pooled rows + honest missing-pack state).
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs
local string_lower = string.lower
local string_find = string.find

local MAX_VISIBLE_ROWS = 14

local CodexPage = {
    id = "codex",
    label = "도감 (Codex)",
    host = nil,
    rowPool = {},
    visibleRows = 0,
    activePack = "fishing",
    statusLbl = nil,
}
ns.Features.CodexPage = CodexPage

function CodexPage:EnsureDataLoaded()
    if type(_G.ForeverSuiteData) == "table" then
        return true
    end
    return ns.Api.SafeAPI.LoadDataPack()
end

function CodexPage:EnsureRow(idx)
    if self.rowPool[idx] then
        return self.rowPool[idx]
    end
    local row = W.ListRow(self.host, 24, function(btn)
        local entry = btn._entry
        if type(entry) ~= "table" then
            return
        end
        if type(entry.mapID) == "number" and type(entry.x) == "number" and type(entry.y) == "number" then
            local title = tostring(entry.title or "항목")
            local ok, status
            if ns.Features.NavigationHud then
                ok, status = ns.Features.NavigationHud:SetTarget(entry.mapID, entry.x, entry.y, title)
            else
                ok, status = ns.Api.NavPort.SetWaypoint(entry.mapID, entry.x, entry.y)
            end
            if status == "ARRIVED" then
                return
            elseif ok and status == "APPLIED" then
                ns.Api.SafeAPI.Print("도감 내비게이션 연결: " .. title)
            elseif status == "DEFERRED" then
                ns.Api.SafeAPI.Print("화살표 활성화 (기본 핀은 전투/지도 종료 후 적용): " .. title)
            else
                ns.Api.SafeAPI.Print("화살표 활성화 (기본 핀 미지원 지역): " .. title)
            end
        end
    end)
    self.rowPool[idx] = row
    return row
end

function CodexPage:RenderPack(query)
    if not self.host then
        return
    end
    for i = 1, #self.rowPool do
        self.rowPool[i]:Hide()
    end
    self.visibleRows = 0

    local dataRoot = _G.ForeverSuiteData
    if type(dataRoot) ~= "table" or type(dataRoot.packs) ~= "table" then
        if self.statusLbl then
            self.statusLbl:SetText("ForeverSuite_Data (LoD) 팩을 불러오지 못했습니다.")
        end
        return
    end

    local pack = dataRoot.packs[self.activePack]
    if not pack then
        if self.statusLbl then
            self.statusLbl:SetText("선택한 도감 데이터팩(" .. tostring(self.activePack) .. ")이 아직 빌드되지 않았습니다.")
        end
        return
    end

    local q = string_lower(tostring(query or ""))
    local y = 66
    local shown = 0
    for _, entry in ipairs(pack.entries or {}) do
        local title = tostring(entry.title or entry.fish or entry.boss or entry.name or "항목")
        local sub = tostring(entry.zone or entry.slot or entry.category or "")
        local hay = string_lower(title .. " " .. sub)
        if q == "" or string_find(hay, q, 1, true) then
            shown = shown + 1
            local row = self:EnsureRow(shown)
            row._entry = entry
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", self.host, "TOPLEFT", 0, -y)
            row:SetPoint("TOPRIGHT", self.host, "TOPRIGHT", 0, -y)
            row._left:SetText(title)
            row._right:SetText(sub)
            row:Show()
            y = y + 26
            if shown >= MAX_VISIBLE_ROWS then
                break
            end
        end
    end
    self.visibleRows = shown

    if self.statusLbl then
        self.statusLbl:SetText(
            (pack.title or self.activePack) .. " · " .. tostring(shown) .. "건 표시 (출처: " ..
            tostring(pack.source or "Curated") .. " / " .. tostring(pack.license or "Personal") .. ")"
        )
    end
end

function CodexPage:Build(parent)
    self.host = parent
    local hdr = W.SectionHeader(parent, "ForeverSuite 통합 도감 (LoadOnDemand)")
    hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    local bar = W.PillBar(parent, {
        { value = "fishing", label = "낚시", width = 68 },
        { value = "professions", label = "전문기술", width = 82 },
        { value = "dungeons", label = "던전·드랍", width = 86 },
        { value = "bis", label = "BiS 장비", width = 82 },
        { value = "rewards", label = "포에버 보상", width = 92 },
    }, self.activePack, function(v)
        CodexPage.activePack = v
        CodexPage:RenderPack(ns.UI.CommandHub.lastQuery or "")
    end)
    bar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -30)
    bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -30)

    local st = W.Label(parent, "", "small", T.TEXT.MUTED)
    st:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 4)
    self.statusLbl = st
end

function CodexPage:OnShow()
    self:EnsureDataLoaded()
    self:RenderPack(ns.UI.CommandHub.lastQuery or "")
    ns.UI.CommandHub:RefreshStatusBar()
end

function CodexPage:OnSearch(query)
    self:RenderPack(query)
end
