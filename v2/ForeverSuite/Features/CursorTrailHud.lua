-- Module: Features/CursorTrailHud.lua
-- Responsibility: KPI-8 Multi-Style Cursor FX (Gold Ring / Crosshair / 30Hz Multi-Dot Trail + Combat-Only option;
--                 zero click interception, zero steady-state table allocations, OnUpdate cleared immediately when OFF -> 0% CPU).
-- Layer: Features (uses UI/Widgets only; zero raw CreateFrame).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens

local TRAIL_COUNT = 5
local TRAIL_INTERVAL = 1 / 30

local CursorTrailHud = {
    ring = nil,
    dot = nil,
    trails = {},
    trailIdx = 1,
    trailAccum = 0,
    active = false,
}
ns.Features.CursorTrailHud = CursorTrailHud

local function UpdateCursorPosition(frame, dt)
    local cx, cy = ns.Api.GameAdapters.GetCursorScreenPosition()
    if not (cx and cy) then
        return
    end
    local scale = (_G.UIParent and type(_G.UIParent.GetEffectiveScale) == "function" and _G.UIParent:GetEffectiveScale()) or 1
    if type(scale) ~= "number" or scale <= 0 then
        scale = 1
    end
    local sx, sy = cx / scale, cy / scale
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", _G.UIParent, "BOTTOMLEFT", sx, sy)

    if frame._fxStyle == "trail" then
        CursorTrailHud.trailAccum = CursorTrailHud.trailAccum + (type(dt) == "number" and dt or 0.033)
        if CursorTrailHud.trailAccum >= TRAIL_INTERVAL then
            CursorTrailHud.trailAccum = 0
            local node = CursorTrailHud.trails[CursorTrailHud.trailIdx]
            if node then
                node:ClearAllPoints()
                node:SetPoint("CENTER", _G.UIParent, "BOTTOMLEFT", sx, sy)
                node:Show()
            end
            CursorTrailHud.trailIdx = (CursorTrailHud.trailIdx % TRAIL_COUNT) + 1
        end
    end
end

function CursorTrailHud:Init()
    if self.ring then
        return self.ring
    end
    local ring = W.HudContainer("ForeverSuiteCursorRing", 32, 32)
    ring:SetFrameStrata(T.ELEVATION.L2_HUB)
    ring:EnableMouse(false)
    local ringTex = ring:CreateTexture(nil, "ARTWORK")
    ringTex:SetAllPoints(ring)
    ringTex:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    ringTex:SetTexCoord(0.05, 0.60, 0.05, 0.60)
    local dot = W.Label(ring, "○", "small", T.TEXT.GOLD, { justifyH = "CENTER", wordWrap = false })
    dot:SetPoint("CENTER", ring, "CENTER", 0, 0)
    ring:Hide()

    for i = 1, TRAIL_COUNT do
        local sz = 14 - (i * 2)
        if sz < 6 then sz = 6 end
        local node = W.HudContainer(nil, sz, sz)
        node:SetFrameStrata(T.ELEVATION.L2_HUB)
        node:EnableMouse(false)
        local nt = node:CreateTexture(nil, "ARTWORK")
        nt:SetAllPoints(node)
        nt:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
        nt:SetVertexColor(T.BORDER.GOLD[1], T.BORDER.GOLD[2], T.BORDER.GOLD[3], 0.45 - (i * 0.06))
        node._fsTex = nt
        node:Hide()
        self.trails[i] = node
    end

    self.ring = ring
    self.ringTex = ringTex
    self.dot = dot
    self:ApplyVisibility()
    return ring
end

local CURSOR_COLORS = {
    gold    = T.BORDER.GOLD,
    cyan    = { 0.25, 0.85, 0.98, 1 },
    emerald = { 0.24, 0.88, 0.52, 1 },
    crimson = { 0.94, 0.30, 0.30, 1 },
}

local CURSOR_SIZE_MAP = { small = 24, medium = 34, large = 46 }
local CURSOR_ALPHA_MAP = { ["50"] = 0.50, ["75"] = 0.75, ["100"] = 1.00 }

function CursorTrailHud:ApplyVisibility(inCombatOverride)
    if not self.ring then
        return
    end
    local enabled = ns.Api.ProfileStore:Get("ui", "showCursorRing") == true
    local combatOnly = ns.Api.ProfileStore:Get("ui", "cursorCombatOnly") == true
    local style = ns.Api.ProfileStore:Get("ui", "cursorStyle") or "ring"
    local colorKey = ns.Api.ProfileStore:Get("ui", "cursorColor") or "gold"
    local col = CURSOR_COLORS[colorKey] or T.BORDER.GOLD
    local sizeKey = ns.Api.ProfileStore:Get("ui", "cursorSize")
    local sizePref = (sizeKey and CURSOR_SIZE_MAP[sizeKey]) or tonumber(ns.Api.ProfileStore:GetState("cursorSize")) or 34
    if sizePref < 18 then sizePref = 18 elseif sizePref > 56 then sizePref = 56 end
    local alphaKey = ns.Api.ProfileStore:Get("ui", "cursorAlpha")
    local alphaPref = (alphaKey and CURSOR_ALPHA_MAP[alphaKey]) or tonumber(ns.Api.ProfileStore:GetState("cursorAlpha")) or 0.9
    if alphaPref < 0.25 then alphaPref = 0.25 elseif alphaPref > 1.0 then alphaPref = 1.0 end
    local inCombat
    if inCombatOverride ~= nil then
        inCombat = (inCombatOverride == true)
    else
        inCombat = ns.Api.SafeAPI.InCombat()
    end
    local shouldShow = enabled and ((not combatOnly) or inCombat)

    self.active = shouldShow
    self.ring._fxStyle = style
    if self.ringTex and type(self.ringTex.SetVertexColor) == "function" then
        self.ringTex:SetVertexColor(col[1], col[2], col[3], alphaPref)
    end
    self.ring:SetAlpha(alphaPref)
    self.dot:SetTextColor(col[1], col[2], col[3], 1)
    for i = 1, #self.trails do
        local nt = self.trails[i]._fsTex
        if nt and type(nt.SetVertexColor) == "function" then
            nt:SetVertexColor(col[1], col[2], col[3], math.max(0.14, (0.50 - i * 0.07) * alphaPref))
        end
    end
    if style == "crosshair" then
        self.ring:SetSize(sizePref + 6, sizePref + 6)
        if self.ringTex then self.ringTex:Hide() end
        self.dot:SetText("┼")
    elseif style == "trail" then
        self.ring:SetSize(math.max(20, sizePref - 4), math.max(20, sizePref - 4))
        if self.ringTex then self.ringTex:Show() end
        self.dot:SetText("★")
    else
        self.ring:SetSize(sizePref, sizePref)
        if self.ringTex then self.ringTex:Show() end
        self.dot:SetText("○")
    end

    if shouldShow then
        self.ring:Show()
        self.ring:SetScript("OnUpdate", UpdateCursorPosition)
        UpdateCursorPosition(self.ring, 0)
        if style ~= "trail" then
            for i = 1, #self.trails do self.trails[i]:Hide() end
        end
    else
        self.ring:SetScript("OnUpdate", nil)
        self.ring:Hide()
        for i = 1, #self.trails do self.trails[i]:Hide() end
    end
end
