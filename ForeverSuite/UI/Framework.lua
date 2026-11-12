-- Module: UI/Framework.lua
-- Responsibility: Lightweight dark-slate & gold UI widget factory (panels, labels, buttons, pill buttons, checkboxes, badges).
-- Dependencies: Core/Init.lua (ns).
-- Public API: ns.UI (COLORS, STATE_HEX, CreatePanel, CreateLabel, CreateButton, CreatePillButton, StylePillButton, CreateCheckbox, FormatStateBadge).
-- Combat/Secret Safety: Creates only non-secure Frame/Button widgets; zero legacy UIDropDownMenu or taint-prone templates.
local _, ns = ...

local tostring = tostring

local ACTIVE_PILL_BG = { 0.30, 0.24, 0.08, 0.98 }
local ACTIVE_PILL_BORDER = { 0.88, 0.73, 0.25, 1.00 }
local INACTIVE_PILL_BG = { 0.13, 0.16, 0.20, 0.95 }
local INACTIVE_PILL_BORDER = { 0.30, 0.35, 0.43, 0.90 }

local UI = {
    COLORS = {
        BG = { 0.07, 0.08, 0.10, 0.95 },
        CARD = { 0.11, 0.13, 0.16, 0.92 },
        BORDER = { 0.78, 0.65, 0.25, 0.80 },
        ACCENT = { 0.83, 0.69, 0.22, 1.00 },
        TEXT = { 0.93, 0.94, 0.96, 1.00 },
        MUTED = { 0.62, 0.66, 0.72, 1.00 },
        BTN = { 0.16, 0.19, 0.24, 1.00 },
        BTN_HOVER = { 0.24, 0.28, 0.35, 1.00 },
    },
    STATE_HEX = {
        ENABLED = "|cff4ade80ENABLED|r",
        DISABLED = "|cff94a3b8DISABLED|r",
        YIELDED = "|cff60a5faYIELDED|r",
        FAULTED = "|cfff87171FAULTED|r",
        INITIALIZED = "|cffcbd5e1READY|r",
        REGISTERED = "|cffcbd5e1INIT|r",
    },
}
ns.UI = UI

local function ApplySolidBox(frame, bgCol, borderCol)
    if not frame or not frame.CreateTexture then
        return
    end
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(frame)
    bg:SetColorTexture(bgCol[1], bgCol[2], bgCol[3], bgCol[4])
    frame._fsBg = bg

    if borderCol then
        local top = frame:CreateTexture(nil, "BORDER")
        top:SetHeight(1)
        top:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        top:SetColorTexture(borderCol[1], borderCol[2], borderCol[3], borderCol[4])

        local bottom = frame:CreateTexture(nil, "BORDER")
        bottom:SetHeight(1)
        bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
        bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        bottom:SetColorTexture(borderCol[1], borderCol[2], borderCol[3], borderCol[4])

        local left = frame:CreateTexture(nil, "BORDER")
        left:SetWidth(1)
        left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
        left:SetColorTexture(borderCol[1], borderCol[2], borderCol[3], borderCol[4])

        local right = frame:CreateTexture(nil, "BORDER")
        right:SetWidth(1)
        right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        right:SetColorTexture(borderCol[1], borderCol[2], borderCol[3], borderCol[4])

        frame._fsBorders = { top, bottom, left, right }
    end
end

function UI.CreatePanel(name, parent, width, height, isCard)
    if not _G.CreateFrame then
        return nil
    end
    local f = _G.CreateFrame("Frame", name, parent or _G.UIParent)
    f:SetSize(width, height)
    ApplySolidBox(f, isCard and UI.COLORS.CARD or UI.COLORS.BG, isCard and { 0.24, 0.28, 0.34, 0.9 } or UI.COLORS.BORDER)
    return f
end

function UI.CreateLabel(parent, text, fontObject, color)
    if not parent or not parent.CreateFontString then
        return nil
    end
    local fs = parent:CreateFontString(nil, "OVERLAY", fontObject or "GameFontNormal")
    fs:SetText(tostring(text or ""))
    local c = color or UI.COLORS.TEXT
    if fs.SetTextColor then
        fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
    end
    return fs
end

function UI.CreateButton(parent, label, width, height, onClick)
    if not _G.CreateFrame then
        return nil
    end
    local btn = _G.CreateFrame("Button", nil, parent)
    btn:SetSize(width or 96, height or 24)
    ApplySolidBox(btn, UI.COLORS.BTN, { 0.36, 0.41, 0.49, 0.95 })
    local txt = UI.CreateLabel(btn, label, "GameFontHighlightSmall", UI.COLORS.TEXT)
    if txt then
        txt:SetPoint("CENTER", btn, "CENTER", 0, 0)
        btn._fsLabel = txt
    end
    btn:SetScript("OnEnter", function(self)
        if self._fsBg then
            self._fsBg:SetColorTexture(UI.COLORS.BTN_HOVER[1], UI.COLORS.BTN_HOVER[2], UI.COLORS.BTN_HOVER[3], 1)
        end
    end)
    btn:SetScript("OnLeave", function(self)
        if self._fsBg then
            self._fsBg:SetColorTexture(UI.COLORS.BTN[1], UI.COLORS.BTN[2], UI.COLORS.BTN[3], 1)
        end
    end)
    btn:SetScript("OnClick", function(self, mouseBtn)
        if onClick then
            onClick(self, mouseBtn)
        end
    end)
    return btn
end

function UI.StylePillButton(btn, isSelected)
    if not btn then
        return
    end
    btn._fsSelected = isSelected and true or false
    local bg = isSelected and ACTIVE_PILL_BG or INACTIVE_PILL_BG
    local bd = isSelected and ACTIVE_PILL_BORDER or INACTIVE_PILL_BORDER
    if btn._fsBg and btn._fsBg.SetColorTexture then
        btn._fsBg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
    end
    if btn._fsBorders then
        for i = 1, #btn._fsBorders do
            local tex = btn._fsBorders[i]
            if tex and tex.SetColorTexture then
                tex:SetColorTexture(bd[1], bd[2], bd[3], bd[4])
            end
        end
    end
    if btn._fsLabel and btn._fsLabel.SetTextColor then
        if isSelected then
            btn._fsLabel:SetTextColor(1.00, 0.88, 0.42, 1.00)
        else
            btn._fsLabel:SetTextColor(0.80, 0.84, 0.90, 1.00)
        end
    end
end

function UI.CreatePillButton(parent, label, width, height, tooltipTitle, tooltipBody, onClick)
    if not _G.CreateFrame then
        return nil
    end
    local btn = _G.CreateFrame("Button", nil, parent)
    btn:SetSize(width, height)
    if btn.RegisterForClicks then
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    end
    ApplySolidBox(btn, INACTIVE_PILL_BG, INACTIVE_PILL_BORDER)
    local txt = UI.CreateLabel(btn, label, "GameFontHighlightSmall", UI.COLORS.TEXT)
    if txt then
        txt:SetPoint("CENTER", btn, "CENTER", 0, 0)
        btn._fsLabel = txt
    end
    UI.StylePillButton(btn, false)

    btn:SetScript("OnEnter", function(self)
        if self._fsBg and self._fsBg.SetColorTexture then
            if self._fsSelected then
                self._fsBg:SetColorTexture(0.38, 0.30, 0.10, 1.00)
            else
                self._fsBg:SetColorTexture(0.22, 0.26, 0.33, 1.00)
            end
        end
        if tooltipTitle and _G.GameTooltip and _G.GameTooltip.SetOwner then
            _G.GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
            _G.GameTooltip:AddLine(tooltipTitle, 1.0, 0.85, 0.35)
            if tooltipBody then
                _G.GameTooltip:AddLine(tooltipBody, 0.82, 0.86, 0.92)
            end
            _G.GameTooltip:Show()
        end
    end)
    btn:SetScript("OnLeave", function(self)
        UI.StylePillButton(self, self._fsSelected)
        if _G.GameTooltip and _G.GameTooltip.Hide then
            _G.GameTooltip:Hide()
        end
    end)
    btn:SetScript("OnClick", function(self, mouseBtn)
        if onClick then
            onClick(self, mouseBtn)
        end
    end)
    return btn
end

function UI.CreateCheckbox(parent, labelText, initialChecked, onToggle)
    if not _G.CreateFrame then
        return nil
    end
    local box = _G.CreateFrame("Button", nil, parent)
    box:SetSize(18, 18)
    ApplySolidBox(box, { 0.09, 0.11, 0.14, 1 }, { 0.55, 0.60, 0.68, 1 })

    local mark = UI.CreateLabel(box, initialChecked and "✓" or "", "GameFontNormalSmall", UI.COLORS.ACCENT)
    if mark then
        mark:SetPoint("CENTER", box, "CENTER", 0, 0)
    end
    local lbl = UI.CreateLabel(box, labelText, "GameFontHighlightSmall", UI.COLORS.TEXT)
    if lbl then
        lbl:SetPoint("LEFT", box, "RIGHT", 8, 0)
        box._fsLabel = lbl
    end

    box._checked = initialChecked and true or false
    function box:SetChecked(flag)
        self._checked = flag and true or false
        if mark then
            mark:SetText(self._checked and "✓" or "")
        end
    end
    function box:GetChecked()
        return self._checked
    end

    box:SetScript("OnClick", function(self)
        self:SetChecked(not self._checked)
        if onToggle then
            onToggle(self._checked)
        end
    end)
    return box
end

function UI.FormatStateBadge(state, yieldedBy)
    local badge = UI.STATE_HEX[state] or tostring(state or "UNKNOWN")
    if state == "YIELDED" and yieldedBy then
        return badge .. " |cff93c5fd(" .. tostring(yieldedBy) .. ")|r"
    end
    return badge
end
