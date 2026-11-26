-- Module: Features/ThreatMeterHud.lua
-- Responsibility: Zero-Taint Secret-Safe Threat Meter HUD (cancels ticker OOC -> 0% idle CPU; never touches nameplates).
-- Layer: Features (uses UI/Widgets + Domain/ThreatModel + Api/GameAdapters).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs

local MAX_ROWS = 6
local METER_WIDTH = 216

local ThreatMeterHud = {
    card = nil,
    headerLbl = nil,
    rows = {},
    ticker = nil,
    lastSnapshot = nil,
}
ns.Features.ThreatMeterHud = ThreatMeterHud

local function ToneColor(tone)
    if tone == "GOLD" then return T.TEXT.GOLD end
    if tone == "DANGER" then return T.SEMANTIC.DANGER end
    if tone == "WARN" then return T.SEMANTIC.WARN end
    if tone == "MUTED" then return T.TEXT.MUTED end
    return T.TEXT.PRIMARY
end

function ThreatMeterHud:Init()
    if self.card then
        return self.card
    end
    -- WoW 1.60.1 native damagemeters atlases (feature-detected) with translucent dark glass fallback
    local card = W.HudGlass(_G.UIParent, METER_WIDTH, 152, "ForeverSuiteThreatMeter", T.ELEVATION.L1_CARD, {
        bg = { 0.042, 0.038, 0.048, 0.64 },
        border = T.BORDER.HUD_GLASS,
    })
    if T.TrySetAtlas and card._fsBg and T.TrySetAtlas(card._fsBg, "damagemeters-background", false) then
        card._fsUsesNativeAtlas = true
    end
    local hdrBar = card:CreateTexture(nil, "BACKGROUND", nil, 0)
    hdrBar:SetHeight(22)
    hdrBar:SetPoint("TOPLEFT", card, "TOPLEFT", 1, -1)
    hdrBar:SetPoint("TOPRIGHT", card, "TOPRIGHT", -1, -1)
    if not (T.TrySetAtlas and T.TrySetAtlas(hdrBar, "ui-damagemeters-header-bar", false)) then
        hdrBar:SetColorTexture(0.11, 0.09, 0.07, 0.72)
    end
    local hdr = W.Label(card, "✦ 위협 수준 (Threat)", "small", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false, outline = "OUTLINE" })
    hdr:SetPoint("TOPLEFT", card, "TOPLEFT", 8, -6)
    hdr:SetPoint("TOPRIGHT", card, "TOPRIGHT", -8, -6)
    local hdrRule = card:CreateTexture(nil, "ARTWORK")
    hdrRule:SetHeight(T.PixelSize(card, 1))
    hdrRule:SetPoint("TOPLEFT", card, "TOPLEFT", 6, -21)
    hdrRule:SetPoint("TOPRIGHT", card, "TOPRIGHT", -6, -21)
    hdrRule:SetColorTexture(T.BORDER.GOLD_SOFT[1], T.BORDER.GOLD_SOFT[2], T.BORDER.GOLD_SOFT[3], 0.55)

    for i = 1, MAX_ROWS do
        local row = W.ListRow(card, 20, nil)
        row:SetPoint("TOPLEFT", card, "TOPLEFT", 4, -(24 + (i - 1) * 20))
        row:SetPoint("TOPRIGHT", card, "TOPRIGHT", -4, -(24 + (i - 1) * 20))
        row:Hide()
        self.rows[i] = row
    end

    card:Hide()
    self.card = card
    self.headerLbl = hdr

    ns.UI.HudLayout:Register("threatMeter", card, {
        point = "BOTTOMRIGHT",
        relPoint = "BOTTOMRIGHT",
        x = -12,
        y = 80,
    }, "위협 수준 미터")
    return card
end

function ThreatMeterHud:StopTicker()
    if self.ticker then
        ns.Api.GameAdapters.CancelTicker(self.ticker)
        self.ticker = nil
    end
end

function ThreatMeterHud:Refresh()
    self:Init()
    if ns.UI.HudLayout and ns.UI.HudLayout:IsUnlocked() then
        return nil
    end
    local enabled = ns.Api.ProfileStore:Get("combat", "showThreatMeter") ~= false
    if not enabled or not ns.Api.SafeAPI.InCombat() then
        self:StopTicker()
        self.card:Hide()
        return nil
    end
    -- Ensure live ticker even if enabled mid-combat or after mid-combat /reload (F4)
    if not self.ticker then
        self.ticker = ns.Api.GameAdapters.StartTicker(0.25, function()
            ThreatMeterHud:Refresh()
        end)
    end

    local units = ns.Api.GameAdapters.GetRosterUnitTokens()
    local samples = {}
    for _, u in ipairs(units) do
        local s = ns.Api.GameAdapters.GetUnitThreatSample(u, "target")
        if s then
            samples[#samples + 1] = s
        end
    end

    local snap = ns.Domain.ThreatModel.BuildSnapshot(samples, MAX_ROWS)
    self.lastSnapshot = snap

    if snap.mode == "EMPTY" then
        self.card:Hide()
        return snap
    end

    if snap.mode == "SECRET_LOCKED" then
        self.headerLbl:SetText("✦ 위협 수준 · 집계 불가")
        W.SetBorderColor(self.card, T.BORDER.HAIRLINE)
    elseif snap.warning then
        self.headerLbl:SetText("✦ 위협 수준 · 어그로 주의!")
        W.SetBorderColor(self.card, T.SEMANTIC.DANGER)
    else
        self.headerLbl:SetText("✦ 위협 수준 (Threat)")
        W.SetBorderColor(self.card, T.BORDER.GOLD_SOFT)
    end

    local count = #snap.rows
    for i = 1, MAX_ROWS do
        local row = self.rows[i]
        local r = snap.rows[i]
        if r then
            local col = ToneColor(r.tone)
            local barCol = (r.class and T.CLASS_COLORS and T.CLASS_COLORS[r.class]) or col
            row._left:SetText(r.name)
            row._left:SetTextColor(col[1], col[2], col[3], 1)
            row._right:SetText(r.rightText)
            row._right:SetTextColor(col[1], col[2], col[3], 1)
            row:SetRowStyle({ col[1] * 0.12, col[2] * 0.12, col[3] * 0.12, 0.25 }, col, 0, 3, nil, 8)
            if type(row.SetGauge) == "function" then
                local pct = (type(r.ratio) == "number") and (r.ratio * 100) or 0
                row:SetGauge(pct, { barCol[1], barCol[2], barCol[3], 0.62 }, METER_WIDTH - 8)
            end
            row:Show()
        else
            if type(row.SetGauge) == "function" then row:SetGauge(0, nil) end
            row:Hide()
        end
    end

    self.card:SetHeight(30 + count * 20)
    self.card:Show()
    return snap
end

function ThreatMeterHud:OnCombatStart()
    if ns.Api.ProfileStore:Get("combat", "showThreatMeter") == false then
        return
    end
    self:Refresh()
    if not self.ticker then
        self.ticker = ns.Api.GameAdapters.StartTicker(0.25, function()
            ThreatMeterHud:Refresh()
        end)
    end
end

function ThreatMeterHud:OnCombatEnd()
    self:StopTicker()
    if self.card then
        self.card:Hide()
    end
end
