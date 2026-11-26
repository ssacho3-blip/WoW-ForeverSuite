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
    local ring = W.Card(_G.UIParent, 28, 28, "ForeverSuiteCursorRing", T.ELEVATION.L2_HUB)
    ring:EnableMouse(false)
    ring._fsBg:SetColorTexture(T.SURFACE.GOLD_TINT[1], T.SURFACE.GOLD_TINT[2], T.SURFACE.GOLD_TINT[3], 0.14)
    W.SetBorderColor(ring, T.BORDER.GOLD)
    local dot = W.Label(ring, "◦", "small", T.TEXT.GOLD, { justifyH = "CENTER", wordWrap = false })
    dot:SetPoint("CENTER", ring, "CENTER", 0, 0)
    ring:Hide()

    for i = 1, TRAIL_COUNT do
        local sz = 14 - (i * 2)
        if sz < 6 then sz = 6 end
        local node = W.Card(_G.UIParent, sz, sz, nil, T.ELEVATION.L2_HUB)
        node:EnableMouse(false)
        node._fsBg:SetColorTexture(T.BORDER.GOLD[1], T.BORDER.GOLD[2], T.BORDER.GOLD[3], 0.45 - (i * 0.06))
        W.SetBorderColor(node, T.BORDER.GOLD_SOFT)
        node:Hide()
        self.trails[i] = node
    end

    self.ring = ring
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

function CursorTrailHud:ApplyVisibility(inCombatOverride)
    if not self.ring then
        return
    end
    local enabled = ns.Api.ProfileStore:Get("ui", "showCursorRing") == true
    local combatOnly = ns.Api.ProfileStore:Get("ui", "cursorCombatOnly") == true
    local style = ns.Api.ProfileStore:Get("ui", "cursorStyle") or "ring"
    local colorKey = ns.Api.ProfileStore:Get("ui", "cursorColor") or "gold"
    local col = CURSOR_COLORS[colorKey] or T.BORDER.GOLD
    local sizePref = tonumber(ns.Api.ProfileStore:GetState("cursorSize")) or 28
    if sizePref < 18 then sizePref = 18 elseif sizePref > 52 then sizePref = 52 end
    local alphaPref = tonumber(ns.Api.ProfileStore:GetState("cursorAlpha")) or 0.9
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
    W.SetBorderColor(self.ring, col)
    self.ring:SetAlpha(alphaPref)
    self.dot:SetTextColor(col[1], col[2], col[3], 1)
    for i = 1, #self.trails do
        self.trails[i]._fsBg:SetColorTexture(col[1], col[2], col[3], math.max(0.12, (0.48 - i * 0.06) * alphaPref))
        W.SetBorderColor(self.trails[i], col)
    end
    if style == "crosshair" then
        self.ring:SetSize(sizePref + 6, sizePref + 6)
        self.dot:SetText("┼")
    elseif style == "trail" then
        self.ring:SetSize(math.max(18, sizePref - 6), math.max(18, sizePref - 6))
        self.dot:SetText("✦")
    else
        self.ring:SetSize(sizePref, sizePref)
        self.dot:SetText("◦")
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
