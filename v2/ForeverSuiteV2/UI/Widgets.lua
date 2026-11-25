-- Module: UI/Widgets.lua
-- Responsibility: Unified Obsidian & Burnished Gold 12-widget factory (zero raw CreateFrame styling in Features/).
-- Layer: UI
local _, ns = ...
ns.UI = ns.UI or {}

local T = ns.UI.Tokens
local ipairs = ipairs
local tostring = tostring
local table_insert = table.insert

local Widgets = {}
ns.UI.Widgets = Widgets

local function PaintBox(frame, bgColor, borderColor)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(frame)
    bg:SetColorTexture(bgColor[1], bgColor[2], bgColor[3], bgColor[4] or 1)
    frame._fsBg = bg

    if borderColor then
        local px = T.PixelSize(frame, 1)
        local top = frame:CreateTexture(nil, "BORDER")
        top:SetHeight(px)
        top:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        top:SetColorTexture(borderColor[1], borderColor[2], borderColor[3], borderColor[4] or 1)

        local bottom = frame:CreateTexture(nil, "BORDER")
        bottom:SetHeight(px)
        bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
        bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        bottom:SetColorTexture(borderColor[1], borderColor[2], borderColor[3], borderColor[4] or 1)

        local left = frame:CreateTexture(nil, "BORDER")
        left:SetWidth(px)
        left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
        left:SetColorTexture(borderColor[1], borderColor[2], borderColor[3], borderColor[4] or 1)

        local right = frame:CreateTexture(nil, "BORDER")
        right:SetWidth(px)
        right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        right:SetColorTexture(borderColor[1], borderColor[2], borderColor[3], borderColor[4] or 1)

        frame._fsBorders = { top, bottom, left, right }
    end
end

function Widgets.SetBorderColor(frame, col)
    if not (frame and frame._fsBorders and col) then
        return
    end
    for i = 1, #frame._fsBorders do
        frame._fsBorders[i]:SetColorTexture(col[1], col[2], col[3], col[4] or 1)
    end
end

function Widgets.Label(parent, text, role, color)
    local fs = parent:CreateFontString(nil, "OVERLAY", T.GetFont(role or "body"))
    fs:SetText(tostring(text or ""))
    local c = color or T.TEXT.PRIMARY
    fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
    return fs
end

-- 1. Window (L2 panel: Obsidian canvas + Burnished Gold title chrome + ESC close)
function Widgets.Window(name, width, height, titleText)
    local f = CreateFrame("Frame", name, _G.UIParent)
    f:SetSize(width, height)
    f:SetFrameStrata(T.ELEVATION.L2_HUB)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    PaintBox(f, T.SURFACE.CANVAS, T.BORDER.HAIRLINE)

    local header = CreateFrame("Frame", nil, f)
    header:SetHeight(40)
    header:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
    PaintBox(header, T.SURFACE.CARD, nil)

    local goldRule = header:CreateTexture(nil, "ARTWORK")
    goldRule:SetHeight(T.PixelSize(header, 1))
    goldRule:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 0)
    goldRule:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0)
    goldRule:SetColorTexture(T.BORDER.GOLD[1], T.BORDER.GOLD[2], T.BORDER.GOLD[3], T.BORDER.GOLD[4])

    local title = Widgets.Label(header, titleText or "ForeverSuite v2", "title", T.TEXT.GOLD)
    title:SetPoint("LEFT", header, "LEFT", T.SPACE.LG, 0)

    local closeBtn = Widgets.Button(header, "×", 26, 24, function() f:Hide() end)
    closeBtn:SetPoint("RIGHT", header, "RIGHT", -T.SPACE.SM, 0)

    f._header = header
    f._title = title
    f._closeBtn = closeBtn

    if type(name) == "string" and type(_G.UISpecialFrames) == "table" then
        table_insert(_G.UISpecialFrames, name)
    end
    f:Hide()
    return f
end

-- 2. Card (L1/L2 container: Slate card + 1px hairline border, optional explicit elevation strata)
function Widgets.Card(parent, width, height, name, strata)
    local f = CreateFrame("Frame", name, parent or _G.UIParent)
    if width and height then
        f:SetSize(width, height)
    end
    if strata then
        f:SetFrameStrata(strata)
    end
    PaintBox(f, T.SURFACE.CARD, T.BORDER.HAIRLINE)
    return f
end

-- 3. Surface (L0 chrome-free HUD container)
function Widgets.HudContainer(name, width, height)
    local f = CreateFrame("Frame", name, _G.UIParent)
    f:SetSize(width, height)
    f:SetFrameStrata(T.ELEVATION.L0_HUD)
    f:SetClampedToScreen(true)
    return f
end

-- 4. SectionHeader
function Widgets.SectionHeader(parent, text)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetHeight(24)
    local lbl = Widgets.Label(holder, text, "heading", T.TEXT.PRIMARY)
    lbl:SetPoint("LEFT", holder, "LEFT", 0, 0)
    local line = holder:CreateTexture(nil, "ARTWORK")
    line:SetHeight(T.PixelSize(holder, 1))
    line:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 0, 0)
    line:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", 0, 0)
    line:SetColorTexture(T.BORDER.SUBTLE[1], T.BORDER.SUBTLE[2], T.BORDER.SUBTLE[3], T.BORDER.SUBTLE[4])
    holder._label = lbl
    return holder
end

-- 5. Button
function Widgets.Button(parent, label, width, height, onClick, isGoldAccent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(width or 96, height or 26)
    local baseBg = isGoldAccent and T.SURFACE.GOLD_TINT or T.SURFACE.ELEVATED
    local baseBorder = isGoldAccent and T.BORDER.GOLD or T.BORDER.HAIRLINE
    PaintBox(btn, baseBg, baseBorder)
    local lbl = Widgets.Label(btn, label, "small", isGoldAccent and T.TEXT.GOLD or T.TEXT.PRIMARY)
    lbl:SetPoint("CENTER", btn, "CENTER", 0, 0)
    btn._label = lbl
    btn:SetScript("OnEnter", function(self)
        self._fsBg:SetColorTexture(T.SURFACE.HOVER[1], T.SURFACE.HOVER[2], T.SURFACE.HOVER[3], 1)
    end)
    btn:SetScript("OnLeave", function(self)
        self._fsBg:SetColorTexture(baseBg[1], baseBg[2], baseBg[3], baseBg[4])
    end)
    btn:SetScript("OnClick", function(self, mouseBtn)
        if onClick then onClick(self, mouseBtn) end
    end)
    return btn
end

-- 6. ListRow (interactive flat row with hover highlight)
function Widgets.ListRow(parent, height, onClick)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(height or 24)
    PaintBox(row, { 0, 0, 0, 0 }, nil)
    row._left = Widgets.Label(row, "", "body", T.TEXT.PRIMARY)
    row._left:SetPoint("LEFT", row, "LEFT", T.SPACE.SM, 0)
    row._right = Widgets.Label(row, "", "mono", T.TEXT.SECONDARY)
    row._right:SetPoint("RIGHT", row, "RIGHT", -T.SPACE.SM, 0)
    row:SetScript("OnEnter", function(self)
        self._fsBg:SetColorTexture(T.SURFACE.HOVER[1], T.SURFACE.HOVER[2], T.SURFACE.HOVER[3], 0.55)
    end)
    row:SetScript("OnLeave", function(self)
        self._fsBg:SetColorTexture(0, 0, 0, 0)
    end)
    row:SetScript("OnClick", function(self, mouseBtn)
        if onClick then onClick(self, mouseBtn) end
    end)
    return row
end

-- 7. TabRail (Left vertical navigation rail with gold active indicator)
function Widgets.TabRail(parent, width, items, onSelect)
    local rail = CreateFrame("Frame", nil, parent)
    rail:SetWidth(width or 152)
    PaintBox(rail, T.SURFACE.CARD, T.BORDER.SUBTLE)
    rail._buttons = {}
    rail._activeId = nil

    function rail:SetActive(id)
        self._activeId = id
        for _, item in ipairs(self._buttons) do
            local active = (item.id == id)
            local bg = active and T.SURFACE.GOLD_TINT or { 0, 0, 0, 0 }
            item.btn._fsBg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
            local tc = active and T.TEXT.GOLD or T.TEXT.SECONDARY
            item.btn._label:SetTextColor(tc[1], tc[2], tc[3], tc[4])
            if active then item.accent:Show() else item.accent:Hide() end
        end
    end

    local y = -T.SPACE.SM
    for _, def in ipairs(items or {}) do
        local btn = CreateFrame("Button", nil, rail)
        btn:SetHeight(30)
        btn:SetPoint("TOPLEFT", rail, "TOPLEFT", T.SPACE.XS, y)
        btn:SetPoint("TOPRIGHT", rail, "TOPRIGHT", -T.SPACE.XS, y)
        PaintBox(btn, { 0, 0, 0, 0 }, nil)
        local accent = btn:CreateTexture(nil, "ARTWORK")
        accent:SetWidth(2)
        accent:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, -4)
        accent:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 4)
        accent:SetColorTexture(T.BORDER.GOLD[1], T.BORDER.GOLD[2], T.BORDER.GOLD[3], 1)
        accent:Hide()
        local lbl = Widgets.Label(btn, def.label, "body", T.TEXT.SECONDARY)
        lbl:SetPoint("LEFT", btn, "LEFT", T.SPACE.MD, 0)
        btn._label = lbl
        btn:SetScript("OnClick", function()
            rail:SetActive(def.id)
            if onSelect then onSelect(def.id) end
        end)
        table_insert(rail._buttons, { id = def.id, btn = btn, accent = accent })
        y = y - 34
    end
    return rail
end

-- 8. PillBar
function Widgets.PillBar(parent, options, initialValue, onChange)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(26)
    bar._pills = {}
    bar._value = initialValue

    local function Refresh()
        for _, p in ipairs(bar._pills) do
            local sel = (p.value == bar._value)
            local bg = sel and T.SURFACE.GOLD_TINT or T.SURFACE.ELEVATED
            local bd = sel and T.BORDER.GOLD or T.BORDER.HAIRLINE
            local tc = sel and T.TEXT.GOLD or T.TEXT.SECONDARY
            p.btn._fsBg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
            Widgets.SetBorderColor(p.btn, bd)
            p.btn._label:SetTextColor(tc[1], tc[2], tc[3], tc[4])
        end
    end

    local x = 0
    for _, opt in ipairs(options or {}) do
        local btn = Widgets.Button(bar, opt.label, opt.width or 84, 24, function()
            local prev = bar._value
            bar._value = opt.value
            Refresh()
            if onChange then
                local res = onChange(opt.value)
                if res == false then
                    bar._value = prev
                    Refresh()
                end
            end
        end)
        btn:SetPoint("LEFT", bar, "LEFT", x, 0)
        table_insert(bar._pills, { value = opt.value, btn = btn })
        x = x + (opt.width or 84) + T.SPACE.SM
    end
    Refresh()
    return bar
end

-- 9. Toggle
function Widgets.Toggle(parent, label, initialVal, onChange)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(26)
    row._checked = initialVal and true or false
    local box = CreateFrame("Frame", nil, row)
    box:SetSize(16, 16)
    box:SetPoint("LEFT", row, "LEFT", 0, 0)
    PaintBox(box, T.SURFACE.ELEVATED, T.BORDER.HAIRLINE)
    local fill = box:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", box, "TOPLEFT", 3, -3)
    fill:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -3, 3)
    fill:SetColorTexture(T.BORDER.GOLD[1], T.BORDER.GOLD[2], T.BORDER.GOLD[3], 1)

    local lbl = Widgets.Label(row, label, "body", T.TEXT.PRIMARY)
    lbl:SetPoint("LEFT", box, "RIGHT", T.SPACE.SM, 0)

    local function Sync()
        if row._checked then
            fill:Show()
            Widgets.SetBorderColor(box, T.BORDER.GOLD)
        else
            fill:Hide()
            Widgets.SetBorderColor(box, T.BORDER.HAIRLINE)
        end
    end

    function row:SetChecked(v)
        self._checked = v and true or false
        Sync()
    end

    row:SetScript("OnClick", function(self)
        local prev = self._checked
        self._checked = not prev
        Sync()
        if onChange then
            local res = onChange(self._checked)
            if res == false then
                self._checked = prev
                Sync()
            end
        end
    end)
    Sync()
    row._label = lbl
    return row
end

-- 10. Slider
function Widgets.Slider(parent, label, minVal, maxVal, step, initialVal, onChange)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetHeight(34)
    local lbl = Widgets.Label(holder, label, "small", T.TEXT.SECONDARY)
    lbl:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
    local valTxt = Widgets.Label(holder, tostring(initialVal or minVal), "mono", T.TEXT.GOLD)
    valTxt:SetPoint("TOPRIGHT", holder, "TOPRIGHT", 0, 0)
    local slider = CreateFrame("Slider", nil, holder)
    slider:SetOrientation("HORIZONTAL")
    slider:SetHeight(14)
    slider:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 0, 0)
    slider:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", 0, 0)
    PaintBox(slider, T.SURFACE.ELEVATED, T.BORDER.HAIRLINE)
    slider:SetMinMaxValues(minVal or 0, maxVal or 100)
    slider:SetValueStep(step or 1)
    slider:SetObeyStepOnDrag(true)
    slider:SetValue(initialVal or minVal or 0)
    slider:SetScript("OnValueChanged", function(_, v)
        valTxt:SetText(tostring(v))
        if onChange then onChange(v) end
    end)
    holder._slider = slider
    holder._valTxt = valTxt
    return holder
end

-- 11. SearchBox
function Widgets.SearchBox(parent, width, placeholder, onChange)
    local box = CreateFrame("EditBox", nil, parent)
    box:SetSize(width or 180, 24)
    box:SetAutoFocus(false)
    box:SetTextInsets(8, 8, 0, 0)
    box:SetFontObject(T.GetFont("small"))
    PaintBox(box, T.SURFACE.ELEVATED, T.BORDER.HAIRLINE)
    local ph = Widgets.Label(box, placeholder or "검색...", "small", T.TEXT.MUTED)
    ph:SetPoint("LEFT", box, "LEFT", 8, 0)
    box:SetScript("OnTextChanged", function(self)
        local txt = self:GetText() or ""
        if txt == "" then ph:Show() else ph:Hide() end
        if onChange then onChange(txt) end
    end)
    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    box._placeholder = ph
    return box
end

-- 12. Badge & Toast
function Widgets.Badge(parent, text, semanticKey)
    local col = T.SEMANTIC[semanticKey] or T.TEXT.GOLD
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(68, 18)
    PaintBox(f, T.SURFACE.ELEVATED, col)
    local lbl = Widgets.Label(f, text, "small", col)
    lbl:SetPoint("CENTER", f, "CENTER", 0, 0)
    f._label = lbl
    return f
end

local sharedToast = nil

function Widgets.Toast(titleText, bodyText, semanticKey)
    local col = T.SEMANTIC[semanticKey] or T.BORDER.GOLD
    if not sharedToast then
        local card = Widgets.Card(_G.UIParent, 300, 58)
        card:SetFrameStrata(T.ELEVATION.L1_CARD)
        card:SetPoint("TOP", _G.UIParent, "TOP", 0, -96)
        local accent = card:CreateTexture(nil, "ARTWORK")
        accent:SetWidth(3)
        accent:SetPoint("TOPLEFT", card, "TOPLEFT", 1, -1)
        accent:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 1, 1)
        local t = Widgets.Label(card, "", "heading", T.TEXT.PRIMARY)
        t:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -10)
        local b = Widgets.Label(card, "", "small", T.TEXT.SECONDARY)
        b:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -4)
        card._accent = accent
        card._title = t
        card._body = b
        sharedToast = card
    end
    sharedToast._accent:SetColorTexture(col[1], col[2], col[3], 1)
    sharedToast._title:SetText(tostring(titleText or ""))
    sharedToast._body:SetText(tostring(bodyText or ""))
    sharedToast:Show()
    return sharedToast
end

-- 13. MinimapButton (Obsidian & Burnished Gold draggable rim medallion)
function Widgets.MinimapButton(name, initialAngle, onClick, onTooltip, onAngleChanged)
    local anchorParent = _G.Minimap or _G.UIParent
    local btn = CreateFrame("Button", name, anchorParent)
    btn:SetSize(28, 28)
    btn:SetFrameStrata(T.ELEVATION.L0_HUD)
    btn:SetClampedToScreen(true)
    btn:EnableMouse(true)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    PaintBox(btn, T.SURFACE.CANVAS, T.BORDER.GOLD)

    local glyph = Widgets.Label(btn, "✦", "heading", T.TEXT.GOLD)
    glyph:SetPoint("CENTER", btn, "CENTER", 0, 0)
    btn._glyph = glyph
    btn._angle = ns.Domain.MinimapModel.NormalizeAngle(initialAngle)

    function btn:SetAngle(deg)
        self._angle = ns.Domain.MinimapModel.NormalizeAngle(deg)
        local dx, dy = ns.Domain.MinimapModel.AngleToOffset(self._angle)
        self:ClearAllPoints()
        self:SetPoint("CENTER", anchorParent, "CENTER", dx, dy)
    end

    btn:SetScript("OnEnter", function(self)
        self._fsBg:SetColorTexture(T.SURFACE.GOLD_TINT[1], T.SURFACE.GOLD_TINT[2], T.SURFACE.GOLD_TINT[3], 1)
        if onTooltip then onTooltip(self) end
    end)
    btn:SetScript("OnLeave", function(self)
        self._fsBg:SetColorTexture(T.SURFACE.CANVAS[1], T.SURFACE.CANVAS[2], T.SURFACE.CANVAS[3], T.SURFACE.CANVAS[4])
        if _G.GameTooltip and type(_G.GameTooltip.Hide) == "function" then
            pcall(_G.GameTooltip.Hide, _G.GameTooltip)
        end
    end)
    btn:SetScript("OnClick", function(self, mouseBtn)
        if onClick then onClick(self, mouseBtn) end
    end)
    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function(f)
            if type(_G.GetCursorPosition) == "function" and type(anchorParent.GetCenter) == "function" then
                local okC, cx, cy = pcall(_G.GetCursorPosition)
                local okM, mx, my = pcall(anchorParent.GetCenter, anchorParent)
                local scale = (type(anchorParent.GetEffectiveScale) == "function" and anchorParent:GetEffectiveScale()) or 1
                if okC and okM and type(cx) == "number" and type(cy) == "number" and type(mx) == "number" and type(my) == "number" and scale > 0 then
                    local ang = ns.Domain.MinimapModel.CursorToAngle(cx / scale, cy / scale, mx, my)
                    if ang then
                        f:SetAngle(ang)
                    end
                end
            end
        end)
    end)
    btn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        if onAngleChanged then onAngleChanged(self._angle) end
    end)

    btn:SetAngle(btn._angle)
    return btn
end
