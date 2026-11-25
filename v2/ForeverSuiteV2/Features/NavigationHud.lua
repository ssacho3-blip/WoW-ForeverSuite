-- Module: Features/NavigationHud.lua
-- Responsibility: Zero-Taint L0 onscreen directional arrow + honest map-unit distance HUD, 0.15s active-only ticker, and /way2.
-- Layer: Features (uses UI/Widgets + Domain/NavigationModel + Api/NavPort; zero WorldMap pin mutation).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local tostring = tostring

local NavigationHud = {
    card = nil,
    arrowLbl = nil,
    titleLbl = nil,
    distLbl = nil,
    target = nil,
    ticker = nil,
}
ns.Features.NavigationHud = NavigationHud

local function StopTicker()
    if NavigationHud.ticker then
        ns.Api.GameAdapters.CancelTicker(NavigationHud.ticker)
        NavigationHud.ticker = nil
    end
end

function NavigationHud:Init()
    if self.card then
        return self.card
    end
    local card = W.Card(nil, 224, 48, "ForeverSuiteV2NavArrow", T.ELEVATION.L0_HUD)
    local arrow = W.Label(card, "•", "title", T.TEXT.GOLD)
    arrow:SetPoint("LEFT", card, "LEFT", 12, 0)

    local title = W.Label(card, "", "body", T.TEXT.PRIMARY)
    title:SetPoint("TOPLEFT", card, "TOPLEFT", 38, -8)

    local dist = W.Label(card, "", "mono", T.TEXT.SECONDARY)
    dist:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 38, 8)

    self.card = card
    self.arrowLbl = arrow
    self.titleLbl = title
    self.distLbl = dist

    ns.UI.HudLayout:Register("navArrow", card, {
        point = "TOP",
        relPoint = "TOP",
        x = 0,
        y = -112,
    }, "내비게이션 화살표")

    card:Hide()
    return card
end

function NavigationHud:SetTarget(mapID, x, y, label)
    self:Init()
    StopTicker()
    self.target = {
        mapID = mapID,
        x = x,
        y = y,
        label = label or "목적지",
    }

    -- Check arrival BEFORE creating native waypoint so already-arrived targets don't leave a stale pin!
    local g = self:Refresh()
    if g and g.arrived then
        return true, "ARRIVED"
    end

    self.card:Show()
    self.ticker = ns.Api.GameAdapters.StartTicker(0.15, function()
        NavigationHud:Refresh()
    end)

    local ok, status = ns.Api.NavPort.SetWaypoint(mapID, x, y)
    return ok, status
end

function NavigationHud:Clear()
    StopTicker()
    self.target = nil
    if self.card then
        self.card:Hide()
    end
    ns.Api.NavPort.ClearWaypoint()
    return true
end

function NavigationHud:Refresh()
    if not self.target then
        StopTicker()
        if self.card then self.card:Hide() end
        return nil
    end
    self:Init()
    local pos = ns.Api.GameAdapters.GetPlayerPosition()
    if not pos then
        self.arrowLbl:SetText("•")
        self.titleLbl:SetText(self.target.label)
        self.distLbl:SetText("좌표 집계 없음")
        return nil
    end
    if pos.mapID ~= self.target.mapID then
        self.arrowLbl:SetText("<>")
        self.titleLbl:SetText(self.target.label)
        self.distLbl:SetText("다른 지역 (Map #" .. tostring(self.target.mapID) .. ")")
        return nil
    end
    local g = ns.Domain.NavigationModel.ComputeGuidance(pos.x, pos.y, pos.facing, self.target.x, self.target.y)
    if not g then
        return nil
    end
    if g.arrived then
        local arrivedLabel = self.target.label
        self:Clear()
        ns.Api.SafeAPI.Print("목적지 도착: " .. arrivedLabel)
        return g
    end
    self.arrowLbl:SetText(g.arrow)
    self.titleLbl:SetText(self.target.label)
    self.distLbl:SetText(g.distText)
    return g
end

function NavigationHud:HandleWaySlash(raw)
    local parsed = ns.Domain.NavigationModel.ParseWayArgs(raw)
    if not parsed then
        ns.Api.SafeAPI.Print("사용법: /way2 <X> <Y> [라벨]  또는  /way2 clear")
        return false
    end
    if parsed.cmd == "clear" then
        self:Clear()
        ns.Api.SafeAPI.Print("내비게이션 목적지를 해제했습니다.")
        return true
    elseif parsed.cmd == "status" then
        if self.target then
            ns.Api.SafeAPI.Print("현재 목적지: " .. self.target.label)
        else
            ns.Api.SafeAPI.Print("활성 목적지가 없습니다. 예: /way2 55.2 41.8 광맥")
        end
        return true
    end
    local pos = ns.Api.GameAdapters.GetPlayerPosition()
    if not (pos and type(pos.mapID) == "number" and pos.mapID > 0) then
        ns.Api.SafeAPI.Print("현재 지역 좌표를 확인할 수 없어 목적지를 설정할 수 없습니다.")
        return false
    end
    local ok, status = self:SetTarget(pos.mapID, parsed.x, parsed.y, parsed.label)
    if status == "ARRIVED" then
        return true
    elseif ok then
        ns.Api.SafeAPI.Print("내비게이션 설정: " .. parsed.label)
    elseif status == "DEFERRED" then
        ns.Api.SafeAPI.Print("내비게이션 표시 중 (기본 핀은 전투/지도 종료 후 적용): " .. parsed.label)
    else
        ns.Api.SafeAPI.Print("내비게이션 화살표 활성화 (기본 핀 미지원 지역): " .. parsed.label)
    end
    return true
end
