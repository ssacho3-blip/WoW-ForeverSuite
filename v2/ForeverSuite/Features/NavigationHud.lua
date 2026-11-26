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
    arrowTex = nil,
    goldArrow = nil,
    rounded3D = nil,
    titleLbl = nil,
    distLbl = nil,
    target = nil,
    ticker = nil,
    smoothAngle = nil,
    targetAngle = 0,
    arrowColor = { 0.22, 0.96, 0.34 },
}
ns.Features.NavigationHud = NavigationHud

local function StopTicker()
    if NavigationHud.ticker then
        ns.Api.GameAdapters.CancelTicker(NavigationHud.ticker)
        NavigationHud.ticker = nil
    end
    if NavigationHud.card then
        NavigationHud.card:SetScript("OnUpdate", nil)
    end
    NavigationHud._smoothActive = false
    NavigationHud.smoothAngle = nil
end

local function ShortestAngleDelta(fromRad, toRad)
    local diff = (toRad - fromRad) % (2 * math.pi)
    if diff > math.pi then
        diff = diff - 2 * math.pi
    end
    return diff
end

local function SmoothArrowOnUpdate(_, elapsed)
    if not (NavigationHud.target and NavigationHud.rounded3D and NavigationHud.rounded3D:IsShown()) then
        return
    end
    local dt = (type(elapsed) == "number" and elapsed > 0 and elapsed < 0.25) and elapsed or 0.016
    local tgt = NavigationHud.targetAngle or 0
    if NavigationHud.smoothAngle == nil then
        NavigationHud.smoothAngle = tgt
    else
        local delta = ShortestAngleDelta(NavigationHud.smoothAngle, tgt)
        NavigationHud.smoothAngle = NavigationHud.smoothAngle + delta * math.min(1, dt * 14)
    end
    NavigationHud.rounded3D:SetDirection(NavigationHud.smoothAngle)
end

function NavigationHud:StartSmoothUpdater()
    if not self.card or self._smoothActive then return end
    self._smoothActive = true
    self.card:SetScript("OnUpdate", SmoothArrowOnUpdate)
end

function NavigationHud:Init()
    if self.card then
        return self.card
    end
    -- ForeverSuite v5.0: 100% borderless floating 12-layer 3D Satin Rounded418 arrow HUD!
    local card = W.HudFloating(_G.UIParent, 248, 90, "ForeverSuiteV2NavArrow", T.ELEVATION.L0_HUD)
    card:SetRadialScrim(0.46, 0.03, 0.03, 0.04)
    card:SetRibbon({ 0.032, 0.028, 0.038 }, 0.56, -54, 4)

    local arrow = W.Label(card, "•", "title", T.TEXT.GOLD, { justifyH = "CENTER", outline = "OUTLINE", fontSize = 22 })
    arrow:SetPoint("TOP", card, "TOP", 0, -14)

    -- 12-layer 3D extruded satin arrow (ForeverSuite_Media_Assets/Arrows/Rounded418/*.tga)
    local rounded3D = W.Rounded3DArrow(card, 64)
    rounded3D:SetPoint("TOP", card, "TOP", 0, 4)

    -- Legacy 3-layer procedural gold-rimmed rotating 360° arrow (gold_classic option)
    local goldArrow = W.GoldArrow(card, 42)
    goldArrow:SetPoint("TOP", card, "TOP", 0, -4)

    -- Selectable 2D/Ornate Arrow Texture (ForeverSuite_Media_Assets/Arrows/)
    local arrowTex = card:CreateTexture(nil, "ARTWORK")
    arrowTex:SetSize(44, 44)
    arrowTex:SetPoint("TOP", card, "TOP", 0, -4)
    arrowTex:Hide()

    local closeBtn = W.MiniButton(card, "×", 18, 18, function()
        NavigationHud:Clear()
        ns.Api.SafeAPI.Print("내비게이션 목적지를 해제했습니다.")
    end, "웨이포인트 해제", { ghost = true })
    closeBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", -2, -4)

    local title = W.Label(card, "", "body", T.TEXT.GOLD, { justifyH = "CENTER", wordWrap = false, outline = "OUTLINE" })
    title:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -55)
    title:SetPoint("TOPRIGHT", card, "TOPRIGHT", -12, -55)

    local dist = W.Label(card, "", "mono", T.TEXT.PRIMARY, { justifyH = "CENTER", wordWrap = false, outline = "OUTLINE" })
    dist:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -71)
    dist:SetPoint("TOPRIGHT", card, "TOPRIGHT", -12, -71)

    local bar = W.StatusBarTrack(card, 168, 3)
    bar:SetPoint("BOTTOM", card, "BOTTOM", 0, 0)
    bar:Hide()

    card:SetScript("OnHide", function(self)
        self:SetScript("OnUpdate", nil)
        NavigationHud._smoothActive = false
    end)

    self.card = card
    self.arrowLbl = arrow
    self.arrowTex = arrowTex
    self.goldArrow = goldArrow
    self.rounded3D = rounded3D
    self.titleLbl = title
    self.distLbl = dist
    self.distBar = bar
    self.closeBtn = closeBtn

    ns.UI.HudLayout:Register("navArrow", card, {
        point = "TOP",
        relPoint = "TOP",
        x = 0,
        y = -98,
    }, "내비게이션 화살표")

    card:Hide()
    return card
end

function NavigationHud:SetTarget(mapID, x, y, label, opts)
    self:Init()
    StopTicker()
    local source = (type(opts) == "table" and opts.source) or "manual"
    self.target = {
        mapID = mapID,
        x = x,
        y = y,
        label = label or "목적지",
        source = source,
        questID = type(opts) == "table" and opts.questID or nil,
        isComplete = type(opts) == "table" and opts.isComplete == true or false,
        waypointText = type(opts) == "table" and opts.waypointText or nil,
    }

    -- Check arrival BEFORE creating native waypoint so already-arrived manual targets don't leave a stale pin!
    local g = self:Refresh()
    if g and g.arrived and source ~= "quest" then
        return true, "ARRIVED"
    end

    self.card:Show()
    self.ticker = ns.Api.GameAdapters.StartTicker(0.15, function()
        NavigationHud:Refresh()
    end)

    -- For quest tracking, Blizzard's C_SuperTrack.SetSuperTrackedQuestID already places the native yellow quest pin;
    -- calling SetUserWaypoint would overwrite the SuperTracked quest!
    if source == "quest" then
        return true, "QUEST_ACTIVE"
    end
    local ok, status = ns.Api.NavPort.SetWaypoint(mapID, x, y)
    return ok, status
end

function NavigationHud:TrackQuest(questID, fallbackTitle, opts)
    local explicit = type(opts) == "table" and opts.explicit == true
    if type(questID) ~= "number" or questID <= 0 then
        if self.target and self.target.source == "quest" then
            self:Clear()
        end
        return false, "CLEARED"
    end
    -- Abandon / Turn-in guard: if quest is no longer in the player's quest log, clear stale quest arrow immediately!
    if not ns.Api.SafeAPI.IsQuestInLog(questID) then
        if self.target and self.target.source == "quest" and self.target.questID == questID then
            StopTicker()
            self.target = nil
            if self.card and not (ns.UI.HudLayout and ns.UI.HudLayout:IsUnlocked()) then
                self.card:Hide()
            end
        end
        return false, "NOT_IN_LOG"
    end
    if explicit then
        self.dismissedQuestID = nil
    elseif self.dismissedQuestID == questID then
        return false, "DISMISSED"
    end
    local allowLoad = type(opts) == "table" and opts.allowLoadPacks == true
    local wp = ns.Api.GameAdapters.ResolveQuestWaypoint(questID, allowLoad)
    if not wp then
        if self.target and self.target.source == "quest" then
            StopTicker()
            self.target = nil
            if self.card and not (ns.UI.HudLayout and ns.UI.HudLayout:IsUnlocked()) then
                self.card:Hide()
            end
        end
        return false, "NO_COORDS"
    end
    local baseTitle = (type(wp.title) == "string" and wp.title ~= "" and wp.title)
        or (type(fallbackTitle) == "string" and fallbackTitle ~= "" and fallbackTitle)
        or ("퀘스트 #" .. tostring(questID))
    local prefix = wp.isComplete and "[완료·보고] " or "[퀘스트] "
    return self:SetTarget(wp.mapID, wp.x, wp.y, prefix .. baseTitle, {
        source = "quest",
        questID = questID,
        isComplete = wp.isComplete,
        waypointText = wp.waypointText,
    })
end

function NavigationHud:SyncSuperTrackedQuest(force)
    if self._syncingQuest then return false, "REENTRANT" end
    -- Never hijack an active manual /way, dungeon, bookmark, or corpse arrow unless explicitly forced
    if self.target and self.target.source ~= "quest" and not force then
        return false, "MANUAL_ACTIVE"
    end
    self._syncingQuest = true
    local ok, st = false, "NONE"
    local qid = ns.Api.SafeAPI.GetSuperTrackedQuestID()
    if type(qid) == "number" and qid > 0 then
        if self.dismissedQuestID and self.dismissedQuestID ~= qid then
            self.dismissedQuestID = nil
        end
        ok, st = self:TrackQuest(qid, nil, { allowLoadPacks = force == true, explicit = force == true })
    else
        self.dismissedQuestID = nil
        if self.target and self.target.source == "quest" then
            StopTicker()
            self.target = nil
            if self.card and not (ns.UI.HudLayout and ns.UI.HudLayout:IsUnlocked()) then
                self.card:Hide()
            end
        end
    end
    self._syncingQuest = false
    return ok, st
end

function NavigationHud:OnQuestLogUpdate()
    if self.target and self.target.source == "quest" and type(self.target.questID) == "number" then
        return self:TrackQuest(self.target.questID, nil, { allowLoadPacks = false })
    end
    if not self.target then
        return self:SyncSuperTrackedQuest(false)
    end
    return false, "SKIPPED"
end

function NavigationHud:Clear()
    local wasQuest = (self.target and self.target.source == "quest")
    if wasQuest and type(self.target.questID) == "number" then
        -- Suppress passive re-pop on subsequent QUEST_LOG_UPDATE ticks until user explicitly selects a quest again
        self.dismissedQuestID = self.target.questID
    end
    StopTicker()
    self.target = nil
    if self.card then
        self.card:Hide()
    end
    if not wasQuest then
        ns.Api.NavPort.ClearWaypoint()
    end
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
        if self.arrowTex then self.arrowTex:Hide() end
        if self.goldArrow then self.goldArrow:Hide() end
        if self.rounded3D then self.rounded3D:Hide() end
        self.arrowLbl:Show()
        self.titleLbl:SetText(self.target.label)
        self.distLbl:SetText("좌표 집계 없음")
        return nil
    end
    if pos.mapID ~= self.target.mapID then
        self.arrowLbl:SetText("↗")
        if self.arrowTex then self.arrowTex:Hide() end
        if self.goldArrow then self.goldArrow:Hide() end
        if self.rounded3D then self.rounded3D:Hide() end
        self.arrowLbl:Show()
        self.titleLbl:SetText(self.target.label)
        local zoneName = ns.Api.GameAdapters.GetMapName(self.target.mapID) or ("Map #" .. tostring(self.target.mapID))
        local coordTxt = (ns.Domain.WorldMapModel and ns.Domain.WorldMapModel.FormatCoordPair(self.target.x, self.target.y))
            or string.format("%.1f, %.1f", (self.target.x or 0) * 100, (self.target.y or 0) * 100)
        self.distLbl:SetText(zoneName .. " (" .. coordTxt .. ")")
        if self.distBar then self.distBar:Hide() end
        return nil
    end
    local g = ns.Domain.NavigationModel.ComputeGuidance(pos.x, pos.y, pos.facing, self.target.x, self.target.y)
    if not g then
        return nil
    end
    if g.arrived then
        if self.target.source == "quest" then
            self.arrowLbl:SetText("★")
            if self.arrowTex then self.arrowTex:Hide() end
            if self.goldArrow then self.goldArrow:Hide() end
            if self.rounded3D then self.rounded3D:Hide() end
            self.arrowLbl:Show()
            self.titleLbl:SetText(self.target.label)
            self.distLbl:SetText(self.target.isComplete and "완료 보고 NPC 도착" or "퀘스트 목표 지점 도착")
            if self.distBar then
                if type(self.distBar.SetProgress) == "function" then
                    self.distBar:SetProgress(1.0, T.SEMANTIC.SUCCESS, 168)
                end
                self.distBar:Show()
            end
            return g
        end
        local arrivedLabel = self.target.label
        self:Clear()
        ns.Api.SafeAPI.Print("목적지 도착: " .. arrivedLabel)
        return g
    end
    local styleId = ns.Api.ProfileStore and ns.Api.ProfileStore:Get("ui", "navArrowStyle") or "roundedClassic"
    local is3DStyle = (styleId == "roundedClassic" or styleId == "roundedWedge" or styleId == "roundedCompass")
    local ar, ag, ab
    if self.target.isComplete then
        ar, ag, ab = 1.00, 0.85, 0.24
    elseif self.target.source == "quest" then
        ar, ag, ab = 0.24, 0.96, 0.34
    else
        ar, ag, ab = 0.36, 0.84, 1.00
    end
    self.targetAngle = -(g.relAngle or 0)
    self.arrowLbl:SetText(g.arrow)
    if is3DStyle and self.rounded3D then
        if self.arrowTex then self.arrowTex:Hide() end
        if self.goldArrow then self.goldArrow:Hide() end
        if self.rounded3D._design ~= styleId then
            self.rounded3D:SetDesign(styleId)
        end
        self.rounded3D:SetColor(ar, ag, ab)
        if self.smoothAngle == nil then
            self.smoothAngle = self.targetAngle
        end
        self.rounded3D:SetDirection(self.smoothAngle)
        self.rounded3D:Show()
        self.arrowLbl:Hide()
        self:StartSmoothUpdater()
    elseif styleId == "gold_classic" and self.goldArrow then
        if self.arrowTex then self.arrowTex:Hide() end
        if self.rounded3D then self.rounded3D:Hide() end
        self.goldArrow:SetFillColor(ar, ag, ab)
        self.goldArrow:SetDirection(self.targetAngle)
        self.goldArrow:Show()
        self.arrowLbl:Hide()
    elseif styleId == "minimal" then
        if self.arrowTex then self.arrowTex:Hide() end
        if self.goldArrow then self.goldArrow:Hide() end
        if self.rounded3D then self.rounded3D:Hide() end
        self.arrowLbl:Show()
    else
        local texPath = ns.Domain.WorldMapModel and ns.Domain.WorldMapModel.ResolveArrowTexture(styleId) or nil
        if self.arrowTex and texPath then
            if self.goldArrow then self.goldArrow:Hide() end
            if self.rounded3D then self.rounded3D:Hide() end
            self.arrowTex:SetTexture(texPath)
            if type(self.arrowTex.SetRotation) == "function" and type(g.relAngle) == "number" then
                self.arrowTex:SetRotation(-g.relAngle)
            end
            self.arrowTex:Show()
            self.arrowLbl:Hide()
        elseif self.rounded3D then
            if self.arrowTex then self.arrowTex:Hide() end
            if self.goldArrow then self.goldArrow:Hide() end
            self.rounded3D:Render(self.targetAngle, ar, ag, ab)
            self.rounded3D:Show()
            self.arrowLbl:Hide()
        else
            if self.arrowTex then self.arrowTex:Hide() end
            self.arrowLbl:Show()
        end
    end
    self.titleLbl:SetText(self.target.label)
    local extra = (type(self.target.waypointText) == "string" and self.target.waypointText ~= "")
        and (" · " .. self.target.waypointText) or ""
    self.distLbl:SetText(g.distText .. extra)
    if self.distBar and type(g.distance) == "number" then
        local ratio = 1 - math.min(1, g.distance / 0.25)
        if ratio < 0.08 then ratio = 0.08 end
        local col = self.target.isComplete and T.BORDER.GOLD or T.SEMANTIC.SUCCESS
        if type(self.distBar.SetProgress) == "function" then
            self.distBar:SetProgress(ratio, col, 168)
        end
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
