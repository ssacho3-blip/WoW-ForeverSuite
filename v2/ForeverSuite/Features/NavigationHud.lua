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
    local card = W.Card(nil, 248, 48, "ForeverSuiteV2NavArrow", T.ELEVATION.L0_HUD)
    W.SetBorderColor(card, T.BORDER.GOLD_SOFT)
    local arrow = W.Label(card, "•", "title", T.TEXT.GOLD)
    arrow:SetPoint("LEFT", card, "LEFT", 12, 0)

    -- E3: Selectable 3D/Ornate Arrow Texture (ForeverSuite_Media_Assets/Arrows/)
    local arrowTex = card:CreateTexture(nil, "ARTWORK")
    arrowTex:SetSize(26, 26)
    arrowTex:SetPoint("LEFT", card, "LEFT", 8, 0)
    arrowTex:Hide()

    local closeBtn = W.MiniButton(card, "×", 20, 20, function()
        NavigationHud:Clear()
        ns.Api.SafeAPI.Print("내비게이션 목적지를 해제했습니다.")
    end, "웨이포인트 해제")
    closeBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", -6, -6)

    local title = W.Label(card, "", "body", T.TEXT.PRIMARY, { justifyH = "LEFT", wordWrap = false })
    title:SetPoint("TOPLEFT", card, "TOPLEFT", 38, -8)
    title:SetPoint("TOPRIGHT", closeBtn, "TOPLEFT", -4, -8)

    local dist = W.Label(card, "", "mono", T.TEXT.SECONDARY, { justifyH = "LEFT", wordWrap = false })
    dist:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 38, 9)
    dist:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -8, 9)

    local bar = W.Card(card, 240, 3)
    bar:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 4, 2)
    W.SetBorderColor(bar, T.BORDER.GOLD)
    if bar._fsBg then bar._fsBg:SetColorTexture(T.BORDER.GOLD[1], T.BORDER.GOLD[2], T.BORDER.GOLD[3], 0.9) end
    bar:Hide()

    self.card = card
    self.arrowLbl = arrow
    self.arrowTex = arrowTex
    self.titleLbl = title
    self.distLbl = dist
    self.distBar = bar
    self.closeBtn = closeBtn

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
        if self.distBar then self.distBar:Hide() end
        if self.card and not (ns.UI.HudLayout and ns.UI.HudLayout:IsUnlocked()) then
            self.card:Hide()
        end
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
    local styleId = ns.Api.ProfileStore and ns.Api.ProfileStore:Get("ui", "navArrowStyle") or "classic"
    local texPath = ns.Domain.WorldMapModel and ns.Domain.WorldMapModel.ResolveArrowTexture(styleId) or nil
    self.arrowLbl:SetText(g.arrow)
    if self.arrowTex and texPath then
        if not ns.Api.SafeAPI.InCombat() then
            ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Media_Assets")
        end
        self.arrowTex:SetTexture(texPath)
        if type(self.arrowTex.SetRotation) == "function" and type(g.relAngle) == "number" then
            self.arrowTex:SetRotation(-g.relAngle)
        end
        self.arrowTex:Show()
        self.arrowLbl:Hide()
    else
        if self.arrowTex then self.arrowTex:Hide() end
        self.arrowLbl:Show()
    end
    self.titleLbl:SetText(self.target.label)
    self.distLbl:SetText(g.distText)
    if self.distBar and type(g.distance) == "number" then
        local ratio = 1 - math.min(1, g.distance / 0.25)
        local w = math.max(12, math.floor(ratio * 240 + 0.5))
        self.distBar:SetWidth(w)
        self.distBar:Show()
    end
    return g
end

function NavigationHud:HandleWaySlash(raw)
    local parsed = ns.Domain.NavigationModel.ParseWayArgs(raw)
    if not parsed then
        ns.Api.SafeAPI.Print("사용법: /way <X> <Y> [라벨]  또는  /way clear")
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
            ns.Api.SafeAPI.Print("활성 목적지가 없습니다. 예: /way 55.2 41.8 광맥")
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
