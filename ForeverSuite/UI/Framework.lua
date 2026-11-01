local _, ns = ...

local tostring = tostring

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
