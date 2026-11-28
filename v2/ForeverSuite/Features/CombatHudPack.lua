-- Module: Features/CombatHudPack.lua
-- Responsibility: KPI-10 Combat & Utility HUD Pack (Combo Points pips, Target Range Display, Short Buff Expiry Bar,
--                 and On-Screen Clock; all UIParent-owned, zero-taint, 0% idle CPU when inactive/disabled).
-- Layer: Features (uses UI/Widgets + Domain/CombatHudModel + Api/GameAdapters).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local string_format = string.format
local tostring = tostring

local CombatHudPack = {
    comboFrame = nil,
    comboPips = {},
    rangeFrame = nil,
    rangeLabel = nil,
    rangeTicker = nil,
    buffFrame = nil,
    buffLabels = {},
    buffTicker = nil,
    clockFrame = nil,
    clockLabel = nil,
    clockTicker = nil,
    initialized = false,
}
ns.Features.CombatHudPack = CombatHudPack

local function ToneColor(tone)
    if tone == "SUCCESS" then return T.SEMANTIC.SUCCESS end
    if tone == "GOLD" then return T.TEXT.GOLD end
    if tone == "WARN" then return T.SEMANTIC.WARN end
    if tone == "DANGER" then return T.SEMANTIC.DANGER end
    return T.TEXT.PRIMARY
end

function CombatHudPack:Init()
    if self.initialized then return end
    self.initialized = true

    -- 1. Combo Points HUD (v5.0 Borderless Floating 5 Sculpted Gem Orbs + Additive Halo on 5CP; fixes B7!)
    local cf = W.HudFloating(_G.UIParent, 186, 30, "ForeverSuiteComboHud", T.ELEVATION.L1_CARD)
    cf:SetRadialScrim(0.42, 0.03, 0.025, 0.04)
    cf:EnableMouse(false)
    for i = 1, 5 do
        local xOff = 8 + (i - 1) * 30
        local glow = cf:CreateTexture(nil, "BACKGROUND", nil, -1)
        glow:SetSize(36, 36)
        glow:SetPoint("LEFT", cf, "LEFT", xOff - 4, 0)
        if type(glow.SetTexture) == "function" then
            pcall(glow.SetTexture, glow, (T.UI_ART and T.UI_ART.gemGlow) or T.MEDIA.WHITE)
        end
        if type(glow.SetBlendMode) == "function" then
            pcall(glow.SetBlendMode, glow, "ADD")
        end
        glow:Hide()

        local gem = cf:CreateTexture(nil, "ARTWORK")
        gem:SetSize(28, 28)
        gem:SetPoint("LEFT", cf, "LEFT", xOff, 0)
        if type(gem.SetTexture) == "function" then
            pcall(gem.SetTexture, gem, (T.UI_ART and T.UI_ART.gemEmpty) or T.MEDIA.WHITE)
        end
        self.comboPips[i] = { tex = gem, glow = glow, lit = false }
    end
    local comboNum = W.Label(cf, "", "heading", T.TEXT.GOLD, { justifyH = "CENTER", outline = "OUTLINE" })
    comboNum:SetPoint("RIGHT", cf, "RIGHT", -6, 0)
    self.comboCountLbl = comboNum
    cf:Hide()
    self.comboFrame = cf
    ns.UI.HudLayout:Register("comboHud", cf, {
        point = "CENTER",
        relPoint = "CENTER",
        x = 0,
        y = -116,
    }, "콤보 포인트 HUD")

    -- 2. Target Range Display HUD (v5.0 Borderless Floating Typography + Soft Radial Scrim)
    local rf = W.HudFloating(_G.UIParent, 136, 24, "ForeverSuiteRangeHud", T.ELEVATION.L1_CARD)
    rf:SetRadialScrim(0.44, 0.03, 0.03, 0.04)
    rf:EnableMouse(false)
    local rLbl = W.Label(rf, "", "heading", T.TEXT.PRIMARY, { justifyH = "CENTER", wordWrap = false, outline = "OUTLINE" })
    rLbl:SetPoint("CENTER", rf, "CENTER", 0, 0)
    rf:Hide()
    self.rangeFrame = rf
    self.rangeLabel = rLbl
    ns.UI.HudLayout:Register("rangeHud", rf, {
        point = "CENTER",
        relPoint = "CENTER",
        x = 0,
        y = -148,
    }, "대상 사거리 HUD")

    -- 3. Short Buff Expiry Bar (v5.0 Borderless Floating WeakAuras-style Countdown Bars)
    local bf = W.HudFloating(_G.UIParent, 200, 96, "ForeverSuiteShortBuffHud", T.ELEVATION.L1_CARD)
    bf:SetRadialScrim(0.32, 0.03, 0.03, 0.04)
    bf:EnableMouse(false)
    self.buffBars = {}
    for i = 1, 4 do
        local track = W.StatusBarTrack(bf, 184, 16)
        track:SetPoint("TOPLEFT", bf, "TOPLEFT", 8, -(8 + (i - 1) * 20))
        track:Hide()
        self.buffBars[i] = track
        local lbl = W.Label(bf, "", "small", T.TEXT.PRIMARY, { justifyH = "LEFT", wordWrap = false, outline = "OUTLINE" })
        lbl:SetPoint("TOPLEFT", bf, "TOPLEFT", 12, -(9 + (i - 1) * 20))
        lbl:SetPoint("TOPRIGHT", bf, "TOPRIGHT", -10, -(9 + (i - 1) * 20))
        self.buffLabels[i] = lbl
    end
    bf:Hide()
    self.buffFrame = bf
    ns.UI.HudLayout:Register("shortBuffHud", bf, {
        point = "CENTER",
        relPoint = "CENTER",
        x = 206,
        y = -84,
    }, "단기 버프 만료 HUD")

    -- 4. On-Screen Compact Clock (v5.0 Borderless Floating Typography like GodJohnson ScreenClock208)
    local clf = W.HudFloating(_G.UIParent, 174, 24, "ForeverSuiteClockHud", T.ELEVATION.L0_HUD)
    clf:SetRadialScrim(0.42, 0.03, 0.03, 0.04)
    local cLbl = W.Label(clf, "", "mono", T.TEXT.GOLD, { justifyH = "CENTER", wordWrap = false, outline = "OUTLINE" })
    cLbl:SetPoint("CENTER", clf, "CENTER", 0, 0)
    clf:Hide()
    self.clockFrame = clf
    self.clockLabel = cLbl
    ns.UI.HudLayout:Register("clockHud", clf, {
        point = "TOPRIGHT",
        relPoint = "TOPRIGHT",
        x = -24,
        y = -216,
    }, "온스크린 시계")
    if type(ns.UI.HudLayout.EnableDirectDrag) == "function" then
        ns.UI.HudLayout:EnableDirectDrag("clockHud", clf, { requireShift = true })
    end

    self:RefreshAll()
end

function CombatHudPack:RefreshCombo()
    if not self.comboFrame then return end
    if ns.UI.HudLayout and ns.UI.HudLayout:IsUnlocked() then return end
    if ns.Api.ProfileStore:Get("combat", "showComboHud") == false then
        self.comboFrame:Hide()
        return
    end
    local pts, maxP = ns.Api.GameAdapters.GetComboPointsSafe()
    local st = ns.Domain.CombatHudModel.EvaluateComboPoints(pts, maxP)
    if not st.active then
        self.comboFrame:Hide()
        return
    end
    local litPath = (T.UI_ART and T.UI_ART.gemLit) or T.MEDIA.WHITE
    local emptyPath = (T.UI_ART and T.UI_ART.gemEmpty) or T.MEDIA.WHITE
    for i = 1, 5 do
        local pip = self.comboPips[i]
        local isLit = (i <= st.count)
        pip.lit = isLit
        if isLit then
            if type(pip.tex.SetTexture) == "function" then
                pcall(pip.tex.SetTexture, pip.tex, litPath)
            end
            if type(pip.tex.SetVertexColor) == "function" then
                if st.isFull then
                    pcall(pip.tex.SetVertexColor, pip.tex, 1.00, 0.42, 0.24, 1.00)
                else
                    pcall(pip.tex.SetVertexColor, pip.tex, 1.00, 0.92, 0.62, 1.00)
                end
            end
            if pip.glow then
                if st.isFull then
                    if type(pip.glow.SetVertexColor) == "function" then
                        pcall(pip.glow.SetVertexColor, pip.glow, 1.00, 0.55, 0.18, 0.85)
                    end
                    pip.glow:Show()
                else
                    pip.glow:Hide()
                end
            end
        else
            if type(pip.tex.SetTexture) == "function" then
                pcall(pip.tex.SetTexture, pip.tex, emptyPath)
            end
            if type(pip.tex.SetVertexColor) == "function" then
                pcall(pip.tex.SetVertexColor, pip.tex, 0.72, 0.68, 0.64, 0.85)
            end
            if pip.glow then pip.glow:Hide() end
        end
    end
    if self.comboCountLbl then
        self.comboCountLbl:SetText(tostring(st.count))
        local nc = st.isFull and T.SEMANTIC.DANGER or T.TEXT.GOLD
        self.comboCountLbl:SetTextColor(nc[1], nc[2], nc[3], 1)
    end
    self.comboFrame:Show()
end

local CLASS_RANGE_SPELLS = {
    MAGE = 133, WARLOCK = 686, PRIEST = 585, HUNTER = 75,
    DRUID = 5176, SHAMAN = 403, PALADIN = 20271, WARRIOR = 100, ROGUE = 2764,
}

function CombatHudPack:StopRangeTicker()
    if self.rangeTicker then
        ns.Api.GameAdapters.CancelTicker(self.rangeTicker)
        self.rangeTicker = nil
    end
end

function CombatHudPack:RefreshRange(inCombatOverride)
    if not self.rangeFrame then return end
    if ns.UI.HudLayout and ns.UI.HudLayout:IsUnlocked() then return end
    local inCombat = (inCombatOverride == true) or (inCombatOverride == nil and ns.Api.SafeAPI.InCombat())
    if ns.Api.ProfileStore:Get("combat", "showRangeHud") == false then
        self:StopRangeTicker()
        self.rangeFrame:Hide()
        return
    end
    -- I3: In combat (when CheckInteractDistance is skipped), use combat-safe C_Spell.IsSpellInRange!
    if inCombat then
        local cls = ns.Api.GameAdapters.GetPlayerClass()
        local spId = cls and CLASS_RANGE_SPELLS[cls] or nil
        local inRange = spId and ns.Api.GameAdapters.IsSpellInRangeSafe(spId, "target") or nil
        if inRange == nil then
            self:StopRangeTicker()
            self.rangeFrame:Hide()
            return
        end
        local c = inRange and T.SEMANTIC.SUCCESS or T.SEMANTIC.DANGER
        self.rangeLabel:SetText(inRange and "사거리 내 V" or "사거리 밖 X")
        self.rangeLabel:SetTextColor(c[1], c[2], c[3], 1)
        self.rangeFrame:Show()
        if not self.rangeTicker then
            self.rangeTicker = ns.Api.GameAdapters.StartTicker(0.25, function()
                CombatHudPack:RefreshRange()
            end)
        end
        return
    end
    local hasT, d10, d11, d28a, d28b = ns.Api.GameAdapters.GetTargetRangeFlags()
    local res = ns.Domain.CombatHudModel.ClassifyTargetRange(hasT, d10, d11, d28a, d28b)
    if not res then
        self:StopRangeTicker()
        self.rangeFrame:Hide()
        return
    end
    local c = ToneColor(res.tone)
    self.rangeLabel:SetText(res.label)
    self.rangeLabel:SetTextColor(c[1], c[2], c[3], 1)
    self.rangeFrame:Show()
    if not self.rangeTicker then
        self.rangeTicker = ns.Api.GameAdapters.StartTicker(0.25, function()
            CombatHudPack:RefreshRange()
        end)
    end
end

function CombatHudPack:StopBuffTicker()
    if self.buffTicker then
        ns.Api.GameAdapters.CancelTicker(self.buffTicker)
        self.buffTicker = nil
    end
end

function CombatHudPack:RefreshShortBuffs()
    if not self.buffFrame then return end
    if ns.UI.HudLayout and ns.UI.HudLayout:IsUnlocked() then return end
    if ns.Api.ProfileStore:Get("combat", "showShortBuffHud") == false then
        self:StopBuffTicker()
        self.buffFrame:Hide()
        return
    end
    local now = ns.Api.GameAdapters.GetMonotonicTime()
    local auras = ns.Api.GameAdapters.GetPlayerHelpfulAuras()
    local list = ns.Domain.CombatHudModel.FilterShortBuffs(auras, now, 30, 4)
    if #list == 0 then
        self:StopBuffTicker()
        self.buffFrame:Hide()
        return
    end
    for i = 1, 4 do
        local b = list[i]
        local lbl = self.buffLabels[i]
        local bar = self.buffBars and self.buffBars[i]
        if b then
            lbl:SetText(string_format("%s  %.1fs", tostring(b.name), b.remaining))
            local c = b.urgent and T.SEMANTIC.DANGER or T.TEXT.GOLD
            lbl:SetTextColor(c[1], c[2], c[3], 1)
            lbl:Show()
            if bar then
                bar:SetProgress(math.min(1, math.max(0.04, (b.remaining or 0) / 30)), { c[1], c[2], c[3], 0.42 }, 184)
                bar:Show()
            end
        else
            lbl:SetText("")
            lbl:Hide()
            if bar then bar:Hide() end
        end
    end
    self.buffFrame:SetHeight(16 + (#list * 20))
    self.buffFrame:Show()
    if not self.buffTicker then
        self.buffTicker = ns.Api.GameAdapters.StartTicker(0.25, function()
            CombatHudPack:RefreshShortBuffs()
        end)
    end
end

function CombatHudPack:StopClockTicker()
    if self.clockTicker then
        ns.Api.GameAdapters.CancelTicker(self.clockTicker)
        self.clockTicker = nil
    end
end

function CombatHudPack:RefreshClock()
    if not self.clockFrame then return end
    if ns.UI.HudLayout and ns.UI.HudLayout:IsUnlocked() then return end
    if ns.Api.ProfileStore:Get("ui", "showScreenClock") ~= true then
        self:StopClockTicker()
        self.clockFrame:Hide()
        return
    end
    local lh, lm, sh, sm = ns.Api.GameAdapters.GetClockInfo()
    self.clockLabel:SetText(ns.Domain.CombatHudModel.FormatClockText(lh, lm, sh, sm))
    self.clockFrame:Show()
    if not self.clockTicker then
        self.clockTicker = ns.Api.GameAdapters.StartTicker(1.0, function()
            CombatHudPack:RefreshClock()
        end)
    end
end

function CombatHudPack:RefreshAll()
    self:RefreshCombo()
    self:RefreshRange()
    self:RefreshShortBuffs()
    self:RefreshClock()
end
