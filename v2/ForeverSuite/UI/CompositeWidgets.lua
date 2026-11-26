-- Module: UI/CompositeWidgets.lua
-- Responsibility: ForeverSuite v3.0 Obsidian & Burnished Gold composite widget library
--                 (IconFrame, IconRow, ScrollBar, ScrollText, StatCard, EmptyState,
--                  FlowPillGroup, DetailPanel, GroupedTabRail, ActionInputBar, CopyPasteModal).
-- Layer: UI (0-KB custom asset policy; built-in WoW icon UV trim; zero XML templates; zero taint).
local _, ns = ...
ns.UI = ns.UI or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local math_max = math.max
local math_min = math.min
local math_floor = math.floor
local table_insert = table.insert
local string_gsub = string.gsub
local string_sub = string.sub

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

-- 14. IconFrame: 1px bordered WoW icon with 0.08..0.92 UV trim & glyph fallback
function W.IconFrame(parent, size)
    local sz = size or T.ICON.SM
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(sz, sz)
    PaintBox(f, T.SURFACE.SUNKEN, T.BORDER.HAIRLINE)

    local tex = f:CreateTexture(nil, "ARTWORK")
    tex:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
    tex:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
    if type(tex.SetTexCoord) == "function" then
        local tr = T.ICON.TRIM
        tex:SetTexCoord(tr[1], tr[2], tr[3], tr[4])
    end
    tex:Hide()

    local glyph = W.Label(f, "", "small", T.TEXT.GOLD, { justifyH = "CENTER", wordWrap = false })
    glyph:SetPoint("CENTER", f, "CENTER", 0, 0)
    glyph:Hide()

    f._tex = tex
    f._glyph = glyph
    f._iconPath = nil

    function f:SetIcon(iconTex, borderCol, fallbackGlyph)
        local bd = borderCol or T.BORDER.HAIRLINE
        W.SetBorderColor(self, bd)
        if iconTex and iconTex ~= "" then
            self._iconPath = iconTex
            if type(self._tex.SetTexture) == "function" then
                self._tex:SetTexture(iconTex)
            end
            self._tex:Show()
            self._glyph:Hide()
        elseif fallbackGlyph and fallbackGlyph ~= "" then
            self._iconPath = nil
            self._tex:Hide()
            self._glyph:SetText(tostring(fallbackGlyph))
            self._glyph:SetTextColor(bd[1], bd[2], bd[3], 1)
            self._glyph:Show()
        else
            self._iconPath = T.ICON.FALLBACK
            if type(self._tex.SetTexture) == "function" then
                self._tex:SetTexture(T.ICON.FALLBACK)
            end
            self._tex:Show()
            self._glyph:Hide()
        end
    end

    function f:SetQualityBorder(quality)
        local q = (type(quality) == "number") and T.QUALITY[quality] or T.BORDER.HAIRLINE
        W.SetBorderColor(self, q)
    end

    return f
end

-- 15. IconRow: Interactive 1- or 2-line row with left IconFrame, title, optional subtitle, right value, hover & tooltip
function W.IconRow(parent, height, onClick)
    local h = height or 32
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(h)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row._baseBg = { 0, 0, 0, 0 }
    row._selected = false
    PaintBox(row, row._baseBg, nil)

    local accent = row:CreateTexture(nil, "ARTWORK")
    accent:SetWidth(3)
    accent:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)
    accent:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 2)
    accent:Hide()
    row._accent = accent

    local sep = row:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(T.PixelSize(row, 1))
    sep:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    sep:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    sep:Hide()
    row._sep = sep

    local iconSize = (h >= 34) and T.ICON.MD or T.ICON.SM
    local icon = W.IconFrame(row, iconSize)
    icon:SetPoint("LEFT", row, "LEFT", 6, 0)
    row._icon = icon

    local rightLbl = W.Label(row, "", "mono", T.TEXT.SECONDARY, { justifyH = "RIGHT", wordWrap = false })
    rightLbl:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row._right = rightLbl

    local titleLbl = W.Label(row, "", "body", T.TEXT.PRIMARY, { justifyH = "LEFT", wordWrap = false })
    titleLbl:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    titleLbl:SetPoint("RIGHT", rightLbl, "LEFT", -8, 0)
    row._left = titleLbl

    local subLbl = W.Label(row, "", "small", T.TEXT.MUTED, { justifyH = "LEFT", wordWrap = false })
    subLbl:Hide()
    row._sub = subLbl
    row._iconSize = iconSize

    function row:SetData(opts)
        opts = opts or {}
        -- Set right text FIRST so GetStringWidth() gives exact right-edge padding for 2-line layout
        self._right:SetText(tostring(opts.rightText or ""))
        local rc = opts.rightCol or T.TEXT.SECONDARY
        self._right:SetTextColor(rc[1], rc[2], rc[3], rc[4] or 1)

        local hasSub = (opts.subtitle and opts.subtitle ~= "") and true or false
        local leftX = 8
        if opts.showIcon == false then
            self._icon:Hide()
        else
            self._icon:Show()
            self._icon:SetIcon(opts.icon, opts.borderCol, opts.fallbackGlyph)
            leftX = 6 + (self._iconSize or T.ICON.SM) + 8
        end

        self._left:ClearAllPoints()
        self._sub:ClearAllPoints()
        local rowW = (type(self.GetWidth) == "function" and self:GetWidth()) or 360
        if type(rowW) ~= "number" or rowW <= 0 then rowW = 360 end
        local availForRight = math_max(20, rowW - leftX - 48)
        local maxRightW = math_min(180, math_floor(rowW * 0.40), availForRight)
        if type(self._right.SetWidth) == "function" then
            self._right:SetWidth(0)
        end
        local rw = (type(self._right.GetStringWidth) == "function" and self._right:GetStringWidth()) or 0
        if type(self._right.SetWidth) == "function" and rw > maxRightW then
            self._right:SetWidth(maxRightW)
        end
        local effRightW = (rw > 0) and math_min(rw, maxRightW) or ((opts.rightText and opts.rightText ~= "") and math_min(84, maxRightW) or 0)
        if hasSub then
            local rightPad = (effRightW > 0) and (effRightW + 16) or 10
            self._left:SetPoint("TOPLEFT", self, "TOPLEFT", leftX, -3)
            self._left:SetPoint("TOPRIGHT", self, "TOPRIGHT", -rightPad, -3)
            self._sub:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", leftX, 3)
            self._sub:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -rightPad, 3)
            self._sub:SetText(tostring(opts.subtitle))
            local sc = opts.subCol or T.TEXT.MUTED
            self._sub:SetTextColor(sc[1], sc[2], sc[3], sc[4] or 1)
            self._sub:Show()
        else
            self._left:SetPoint("LEFT", self, "LEFT", leftX, 0)
            self._left:SetPoint("RIGHT", self._right, "LEFT", -8, 0)
            self._sub:SetText("")
            self._sub:Hide()
        end

        self._left:SetText(tostring(opts.title or ""))
        local tc = opts.titleCol or T.TEXT.PRIMARY
        self._left:SetTextColor(tc[1], tc[2], tc[3], tc[4] or 1)

        self._selected = opts.selected == true
        local bg = opts.bgCol
        if not bg then
            bg = self._selected and T.SURFACE.GOLD_TINT or { 0, 0, 0, 0 }
        end
        self._baseBg = bg
        self._fsBg:SetColorTexture(bg[1], bg[2], bg[3], bg[4] or 0)

        local ac = opts.accentCol or (self._selected and T.BORDER.GOLD or nil)
        if ac then
            self._accent:SetColorTexture(ac[1], ac[2], ac[3], ac[4] or 1)
            self._accent:Show()
        else
            self._accent:Hide()
        end

        if opts.sepCol then
            self._sep:SetColorTexture(opts.sepCol[1], opts.sepCol[2], opts.sepCol[3], opts.sepCol[4] or 0.5)
            self._sep:Show()
        else
            self._sep:Hide()
        end

        if opts.onTooltipEnter ~= nil then
            self._onTooltipEnter = opts.onTooltipEnter
        end
        if opts.onTooltipLeave ~= nil then
            self._onTooltipLeave = opts.onTooltipLeave
        end
        self._payload = opts.payload
    end

    function row:SetTooltipHandler(onEnterFn, onLeaveFn)
        self._onTooltipEnter = onEnterFn
        self._onTooltipLeave = onLeaveFn
    end

    row:SetScript("OnEnter", function(self)
        self._fsBg:SetColorTexture(T.SURFACE.HOVER[1], T.SURFACE.HOVER[2], T.SURFACE.HOVER[3], 0.78)
        if type(self._onTooltipEnter) == "function" then
            self._onTooltipEnter(self)
        end
    end)
    row:SetScript("OnLeave", function(self)
        local bg = self._baseBg or { 0, 0, 0, 0 }
        self._fsBg:SetColorTexture(bg[1], bg[2], bg[3], bg[4] or 0)
        if type(self._onTooltipLeave) == "function" then
            self._onTooltipLeave(self)
        end
    end)
    row:SetScript("OnClick", function(self, mouseBtn)
        if onClick then onClick(self, mouseBtn) end
    end)
    return row
end

-- 16. ScrollBar: 100% procedural 8px Obsidian/Slate scrollbar with real drag & track click (zero XML template taint)
function W.ScrollBar(parent, height, onChange)
    local sb = CreateFrame("Frame", nil, parent)
    sb:SetSize(8, height or 200)
    sb:EnableMouse(true)
    PaintBox(sb, T.SURFACE.SUNKEN, T.BORDER.SUBTLE)

    local THUMB_IDLE = { 0.30, 0.36, 0.46, 0.85 }
    local thumb = CreateFrame("Button", nil, sb)
    thumb:SetSize(6, 36)
    thumb:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    if type(thumb.RegisterForDrag) == "function" then
        thumb:RegisterForDrag("LeftButton")
    end
    thumb:SetPoint("TOP", sb, "TOP", 0, -1)
    PaintBox(thumb, THUMB_IDLE, nil)

    sb._thumb = thumb
    sb._offset = 0
    sb._visible = 10
    sb._total = 0
    sb._height = height or 200
    sb._travel = 1
    sb._dragging = false

    local function UpdateThumb()
        local total = sb._total or 0
        local vis = math_max(1, sb._visible or 1)
        local maxOff = math_max(0, total - vis)
        if maxOff <= 0 then
            sb:Hide()
            return
        end
        sb:Show()
        local trackH = (type(sb.GetHeight) == "function" and sb:GetHeight()) or sb._height
        if not trackH or trackH < 24 then trackH = sb._height end
        local usableH = math_max(16, trackH - 2)
        local thumbH = math_max(22, math_floor((vis / total) * usableH))
        local travel = math_max(1, usableH - thumbH)
        sb._travel = travel
        local ratio = math_min(1, math_max(0, (sb._offset or 0) / maxOff))
        local topY = -1 - math_floor(ratio * travel)
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", sb, "TOP", 0, topY)
    end

    local function SetOffsetAndNotify(nextOff)
        local maxOff = math_max(0, (sb._total or 0) - math_max(1, sb._visible or 1))
        local clamped = math_min(maxOff, math_max(0, math_floor((nextOff or 0) + 0.5)))
        if clamped ~= sb._offset then
            sb._offset = clamped
            UpdateThumb()
            if onChange then onChange(sb._offset) end
        end
        return sb._offset
    end

    function sb:SetMetrics(offset, visible, total)
        self._visible = math_max(1, visible or 1)
        self._total = math_max(0, total or 0)
        local maxOff = math_max(0, self._total - self._visible)
        self._offset = math_min(maxOff, math_max(0, offset or 0))
        UpdateThumb()
        return self._offset
    end

    function sb:Step(delta)
        return SetOffsetAndNotify((self._offset or 0) + (delta or 0))
    end

    local function ReadScaledCursorY()
        if type(_G.GetCursorPosition) ~= "function" then return nil end
        local ok, _, cy = pcall(_G.GetCursorPosition)
        if not ok or type(cy) ~= "number" then return nil end
        local scale = (type(sb.GetEffectiveScale) == "function" and sb:GetEffectiveScale()) or 1
        if type(scale) ~= "number" or scale <= 0 then scale = 1 end
        return cy / scale
    end

    local function StopDrag()
        sb._dragging = false
        thumb:SetScript("OnUpdate", nil)
        thumb._fsBg:SetColorTexture(THUMB_IDLE[1], THUMB_IDLE[2], THUMB_IDLE[3], THUMB_IDLE[4])
    end

    thumb:SetScript("OnEnter", function(self)
        self._fsBg:SetColorTexture(T.BORDER.GOLD[1], T.BORDER.GOLD[2], T.BORDER.GOLD[3], 0.95)
    end)
    thumb:SetScript("OnLeave", function(self)
        if not sb._dragging then
            self._fsBg:SetColorTexture(THUMB_IDLE[1], THUMB_IDLE[2], THUMB_IDLE[3], THUMB_IDLE[4])
        end
    end)
    thumb:SetScript("OnDragStart", function()
        local startY = ReadScaledCursorY()
        if not startY then return end
        local maxOff = math_max(0, (sb._total or 0) - math_max(1, sb._visible or 1))
        if maxOff <= 0 then return end
        sb._dragging = true
        local startOff = sb._offset or 0
        thumb._fsBg:SetColorTexture(T.BORDER.GOLD[1], T.BORDER.GOLD[2], T.BORDER.GOLD[3], 1.0)
        thumb:SetScript("OnUpdate", function()
            local curY = ReadScaledCursorY()
            if not curY then return end
            local travel = math_max(1, sb._travel or 1)
            local dy = startY - curY
            local nextOff = startOff + (dy / travel) * maxOff
            SetOffsetAndNotify(nextOff)
        end)
    end)
    thumb:SetScript("OnDragStop", StopDrag)
    thumb:SetScript("OnHide", StopDrag)
    thumb:SetScript("OnClick", function(_, mouseBtn)
        if sb._dragging then return end
        local page = math_max(1, math_floor((sb._visible or 4) / 2))
        if mouseBtn == "RightButton" then
            sb:Step(-page)
        else
            sb:Step(page)
        end
    end)

    sb:SetScript("OnMouseDown", function(_, mouseBtn)
        local page = math_max(1, math_floor((sb._visible or 4) / 2))
        local curY = ReadScaledCursorY()
        if curY and type(thumb.GetTop) == "function" and type(thumb.GetBottom) == "function" then
            local top = thumb:GetTop()
            local bot = thumb:GetBottom()
            if type(top) == "number" and curY > top then
                sb:Step(-page)
                return
            elseif type(bot) == "number" and curY < bot then
                sb:Step(page)
                return
            end
        end
        if mouseBtn == "RightButton" then
            sb:Step(-page)
        else
            sb:Step(page)
        end
    end)

    sb:EnableMouseWheel(true)
    sb:SetScript("OnMouseWheel", function(_, delta)
        sb:Step((delta > 0) and -2 or 2)
    end)

    sb:Hide()
    return sb
end

-- 17. ScrollText: Visual-width UTF-8/Korean & WoW-color-code aware text viewer (zero truncation)
local function WrapLinesForViewport(rawText, unitsPerLine)
    local out = {}
    local cap = math_max(18, unitsPerLine or 60)
    local src = tostring(rawText or "")
    src = string_gsub(src, "\r\n", "\n")
    local pos = 1
    local len = #src
    while pos <= len do
        local nl = string.find(src, "\n", pos, true)
        local seg
        if nl then
            seg = string_sub(src, pos, nl - 1)
            pos = nl + 1
        else
            seg = string_sub(src, pos, len)
            pos = len + 1
        end
        if seg == "" then
            out[#out + 1] = ""
        else
            local curStart = 1
            local segLen = #seg
            local i = 1
            local lineW = 0
            local lastSpaceEnd = nil
            local lastSpaceW = 0
            local lastSpaceColor = nil
            local activeColor = nil
            local lineStartColor = nil
            local function EmitChunk(rawChunk, carryColor)
                local prefix = lineStartColor or ""
                local suffix = (carryColor ~= nil) and "|r" or ""
                out[#out + 1] = prefix .. rawChunk .. suffix
                lineStartColor = carryColor
            end
            while i <= segLen do
                local b = string.byte(seg, i)
                local adv = 1
                local charW = 1.0
                local nextColor = activeColor
                if b == 124 then -- '|' WoW escape code
                    local nxt = string.byte(seg, i + 1)
                    if nxt == 99 and (i + 9) <= segLen then -- |cXXXXXXXX
                        adv = 10
                        charW = 0
                        nextColor = string_sub(seg, i, i + 9)
                    elseif nxt == 114 and (i + 1) <= segLen then -- |r
                        adv = 2
                        charW = 0
                        nextColor = nil
                    end
                elseif b >= 240 then
                    adv = 4
                    charW = 2.0
                elseif b >= 224 then
                    adv = 3
                    charW = 1.85 -- Korean Hangul / CJK glyph width
                elseif b >= 192 then
                    adv = 2
                    charW = 1.15
                elseif b == 32 then
                    adv = 1
                    charW = 0.60
                end
                if (i + adv - 1) > segLen then
                    adv = segLen - i + 1
                end
                if lineW > 0 and (lineW + charW) > cap then
                    if lastSpaceEnd and lastSpaceW >= (cap * 0.50) then
                        EmitChunk(string_sub(seg, curStart, lastSpaceEnd - 1), lastSpaceColor)
                        activeColor = lastSpaceColor
                        curStart = lastSpaceEnd + 1
                        i = curStart
                    else
                        EmitChunk(string_sub(seg, curStart, i - 1), activeColor)
                        curStart = i
                    end
                    lineW = 0
                    lastSpaceEnd = nil
                    lastSpaceW = 0
                    lastSpaceColor = nil
                else
                    activeColor = nextColor
                    if b == 32 then
                        lastSpaceEnd = i
                        lastSpaceW = lineW
                        lastSpaceColor = activeColor
                    end
                    lineW = lineW + charW
                    i = i + adv
                end
            end
            if curStart <= segLen then
                EmitChunk(string_sub(seg, curStart, segLen), nil)
            end
        end
    end
    if #out == 0 then
        out[1] = ""
    end
    return out
end

function W.ScrollText(parent, width, height, opts)
    opts = opts or {}
    local lineH = opts.lineHeight or 17
    local h = height or 220
    local w = width or 380
    local visibleLines = math_max(3, math_floor((h - 12) / lineH))
    local charsPerLine = opts.charsPerLine or math_max(28, math_floor((w - 28) / 6.2))

    local box = CreateFrame("Frame", nil, parent)
    box:SetSize(w, h)
    if type(box.SetClipsChildren) == "function" then
        box:SetClipsChildren(true)
    end
    if opts.plain ~= true then
        PaintBox(box, opts.bgCol or T.SURFACE.SUNKEN, opts.borderCol or T.BORDER.SUBTLE)
    end
    box:EnableMouseWheel(true)

    box._lines = {}
    box._rawText = ""
    box._offset = 0
    box._visibleLines = visibleLines
    box._charsPerLine = charsPerLine
    box._rows = {}

    local sb = W.ScrollBar(box, h - 8, function(newOff)
        box._offset = newOff
        box:Render()
    end)
    sb:SetPoint("TOPRIGHT", box, "TOPRIGHT", -3, -4)
    sb:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -3, 4)
    box._scrollBar = sb

    for i = 1, visibleLines do
        local fs = W.Label(box, "", opts.fontRole or "small", opts.color or T.TEXT.PRIMARY, { justifyH = "LEFT", wordWrap = false })
        fs:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -(6 + (i - 1) * lineH))
        fs:SetPoint("TOPRIGHT", box, "TOPRIGHT", -16, -(6 + (i - 1) * lineH))
        box._rows[i] = fs
    end

    function box:Render()
        local total = #self._lines
        local maxOff = math_max(0, total - self._visibleLines)
        if self._offset > maxOff then self._offset = maxOff end
        if self._offset < 0 then self._offset = 0 end
        for i = 1, self._visibleLines do
            local line = self._lines[self._offset + i]
            local fs = self._rows[i]
            if line ~= nil then
                fs:SetText(line)
                fs:Show()
            else
                fs:SetText("")
                fs:Hide()
            end
        end
        self._scrollBar:SetMetrics(self._offset, self._visibleLines, total)
    end

    function box:SetText(text)
        self._rawText = tostring(text or "")
        self._lines = WrapLinesForViewport(self._rawText, self._charsPerLine)
        self._offset = 0
        self:Render()
    end

    function box:GetText()
        return self._rawText
    end

    function box:ScrollBy(delta)
        self._scrollBar:Step(delta)
    end

    box:SetScript("OnMouseWheel", function(self, delta)
        self:ScrollBy((delta > 0) and -3 or 3)
    end)

    return box
end

-- 18. StatCard: Compact clickable KPI/summary tile (icon + caption + value + subtitle)
function W.StatCard(parent, width, height, opts)
    opts = opts or {}
    local card = CreateFrame("Button", nil, parent)
    card:SetSize(width or 176, height or 68)
    card:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local baseBg = opts.bgCol or T.SURFACE.CARD
    local baseBd = opts.borderCol or T.BORDER.HAIRLINE
    PaintBox(card, baseBg, baseBd)

    local icon = W.IconFrame(card, T.ICON.MD)
    icon:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -10)
    icon:SetIcon(opts.icon, opts.iconBorderCol or T.BORDER.GOLD_SOFT, opts.glyph or "✦")

    local cap = W.Label(card, opts.caption or "", "small", T.TEXT.SECONDARY, { justifyH = "LEFT", wordWrap = false })
    cap:SetPoint("TOPLEFT", card, "TOPLEFT", 10 + T.ICON.MD + 8, -9)
    cap:SetPoint("TOPRIGHT", card, "TOPRIGHT", -8, -9)

    local val = W.Label(card, opts.value or "—", "heading", opts.valueCol or T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    val:SetPoint("TOPLEFT", card, "TOPLEFT", 10 + T.ICON.MD + 8, -25)
    val:SetPoint("TOPRIGHT", card, "TOPRIGHT", -8, -25)

    local sub = W.Label(card, opts.sub or "", "small", T.TEXT.MUTED, { justifyH = "LEFT", wordWrap = false })
    sub:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 10, 7)
    sub:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -10, 7)

    card._icon = icon
    card._caption = cap
    card._value = val
    card._sub = sub

    function card:SetMetrics(valueText, subText, valueCol, iconTex)
        if valueText ~= nil then self._value:SetText(tostring(valueText)) end
        if subText ~= nil then self._sub:SetText(tostring(subText)) end
        if valueCol then self._value:SetTextColor(valueCol[1], valueCol[2], valueCol[3], valueCol[4] or 1) end
        if iconTex then self._icon:SetIcon(iconTex, opts.iconBorderCol or T.BORDER.GOLD_SOFT) end
    end

    card:SetScript("OnEnter", function(self)
        if opts.onClick then
            self._fsBg:SetColorTexture(T.SURFACE.HOVER[1], T.SURFACE.HOVER[2], T.SURFACE.HOVER[3], 0.96)
            W.SetBorderColor(self, T.BORDER.GOLD_SOFT)
        end
    end)
    card:SetScript("OnLeave", function(self)
        self._fsBg:SetColorTexture(baseBg[1], baseBg[2], baseBg[3], baseBg[4] or 1)
        W.SetBorderColor(self, baseBd)
    end)
    card:SetScript("OnClick", function(self, mouseBtn)
        if opts.onClick then opts.onClick(self, mouseBtn) end
    end)

    return card
end

-- 19. EmptyState: Clean centered empty/unloaded state card with optional CTA button
function W.EmptyState(parent, opts)
    opts = opts or {}
    local f = CreateFrame("Frame", nil, parent)
    PaintBox(f, T.SURFACE.SUNKEN, T.BORDER.SUBTLE)

    local icon = W.IconFrame(f, T.ICON.LG)
    icon:SetPoint("CENTER", f, "CENTER", 0, 32)
    icon:SetIcon(opts.icon, T.BORDER.GOLD_SOFT, opts.glyph or "✦")

    local title = W.Label(f, opts.title or "표시할 항목이 없습니다", "heading", T.TEXT.PRIMARY, { justifyH = "CENTER", wordWrap = false })
    title:SetPoint("TOP", icon, "BOTTOM", 0, -10)

    local desc = W.Label(f, opts.desc or "", "small", T.TEXT.SECONDARY, { justifyH = "CENTER", wordWrap = true })
    desc:SetPoint("TOP", title, "BOTTOM", 0, -6)
    desc:SetWidth(320)

    f._icon = icon
    f._title = title
    f._desc = desc

    if opts.ctaLabel and opts.onCta then
        local btn = W.Button(f, opts.ctaLabel, opts.ctaWidth or 148, 26, opts.onCta, true)
        btn:SetPoint("TOP", desc, "BOTTOM", 0, -14)
        f._ctaBtn = btn
    end

    function f:SetMessage(titleText, descText)
        if titleText ~= nil then self._title:SetText(tostring(titleText)) end
        if descText ~= nil then self._desc:SetText(tostring(descText)) end
    end

    f:Hide()
    return f
end

-- 20. FlowPillGroup: Single-state multi-row wrapping pill bar (replaces dual PillBar hacks)
function W.FlowPillGroup(parent, options, initialValue, maxWidth, onChange)
    local group = CreateFrame("Frame", nil, parent)
    local wrapW = maxWidth or 740
    group._pills = {}
    group._value = initialValue

    local function Refresh()
        for _, p in ipairs(group._pills) do
            local sel = (p.value == group._value)
            local bg = sel and T.SURFACE.GOLD_TINT or T.SURFACE.ELEVATED
            local bd = sel and T.BORDER.GOLD or T.BORDER.HAIRLINE
            local tc = sel and T.TEXT.GOLD or T.TEXT.SECONDARY
            p.btn._fsBg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
            W.SetBorderColor(p.btn, bd)
            p.btn._label:SetTextColor(tc[1], tc[2], tc[3], tc[4])
        end
    end

    local x = 0
    local y = 0
    local gapX = 6
    local gapY = 6
    local pillH = 22

    for _, opt in ipairs(options or {}) do
        local pw = opt.width or 68
        if x > 0 and (x + pw) > wrapW then
            x = 0
            y = y - (pillH + gapY)
        end
        local btn = W.Button(group, opt.label, pw, pillH, function()
            local prev = group._value
            group._value = opt.value
            Refresh()
            if onChange then
                local res = onChange(opt.value)
                if res == false then
                    group._value = prev
                    Refresh()
                end
            end
        end)
        btn:SetPoint("TOPLEFT", group, "TOPLEFT", x, y)
        btn:SetScript("OnLeave", function()
            Refresh()
        end)
        table_insert(group._pills, { value = opt.value, btn = btn })
        x = x + pw + gapX
    end

    local totalH = (-y) + pillH
    group:SetSize(wrapW, totalH)
    group._totalHeight = totalH

    function group:SetValue(v, silent)
        self._value = v
        Refresh()
        if (not silent) and onChange then
            onChange(v)
        end
    end

    function group:GetValue()
        return self._value
    end

    Refresh()
    return group
end

-- 21. DetailPanel: Right-hand inspection panel (Header w/ Icon + ScrollText body + optional Footer CTA bar)
function W.DetailPanel(parent, width, height, opts)
    opts = opts or {}
    local w = width or 440
    local h = height or 420
    local panel = W.Card(parent, w, h)

    local header = CreateFrame("Frame", nil, panel)
    header:SetHeight(52)
    header:SetPoint("TOPLEFT", panel, "TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -1, -1)
    PaintBox(header, T.SURFACE.CARD_ALT, nil)

    local icon = W.IconFrame(header, T.ICON.LG)
    icon:SetPoint("LEFT", header, "LEFT", 10, 0)

    local title = W.Label(header, opts.title or "", "heading", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    title:SetPoint("TOPLEFT", header, "TOPLEFT", 10 + T.ICON.LG + 10, -10)
    title:SetPoint("TOPRIGHT", header, "TOPRIGHT", -10, -10)

    local sub = W.Label(header, opts.subtitle or "", "small", T.TEXT.SECONDARY, { justifyH = "LEFT", wordWrap = false })
    sub:SetPoint("TOPLEFT", header, "TOPLEFT", 10 + T.ICON.LG + 10, -29)
    sub:SetPoint("TOPRIGHT", header, "TOPRIGHT", -10, -29)

    local footerH = opts.hasFooter and 36 or 0
    local bodyH = math_max(80, h - 54 - footerH - 12)
    local body = W.ScrollText(panel, w - 16, bodyH, {
        bgCol = T.SURFACE.SUNKEN,
        borderCol = T.BORDER.SUBTLE,
        lineHeight = opts.lineHeight or 17,
    })
    body:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 8, -6)
    body:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, footerH + 6)

    panel._header = header
    panel._icon = icon
    panel._title = title
    panel._sub = sub
    panel._body = body

    if opts.hasFooter then
        local footer = CreateFrame("Frame", nil, panel)
        footer:SetHeight(footerH)
        footer:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 8, 4)
        footer:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 4)
        panel._footer = footer
    end

    function panel:SetHeader(titleText, subText, iconTex, borderCol, fallbackGlyph)
        self._title:SetText(tostring(titleText or ""))
        self._sub:SetText(tostring(subText or ""))
        self._icon:SetIcon(iconTex, borderCol or T.BORDER.GOLD_SOFT, fallbackGlyph or "✦")
    end

    function panel:SetBodyText(text)
        self._body:SetText(text)
    end

    return panel
end

-- 22. GroupedTabRail: 4-group purpose-driven navigation rail with gold active indicator & optional badges
function W.GroupedTabRail(parent, width, groups, onSelect)
    local rail = CreateFrame("Frame", nil, parent)
    rail:SetWidth(width or 168)
    PaintBox(rail, T.SURFACE.SUNKEN, T.BORDER.SUBTLE)
    rail._buttons = {}
    rail._byId = {}
    rail._activeId = nil

    function rail:SetActive(id)
        self._activeId = id
        for _, item in ipairs(self._buttons) do
            local active = (item.id == id)
            local bg = active and T.SURFACE.GOLD_ACTIVE or { 0, 0, 0, 0 }
            item.btn._fsBg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
            local tc = active and T.TEXT.GOLD or T.TEXT.SECONDARY
            item.btn._label:SetTextColor(tc[1], tc[2], tc[3], tc[4])
            if active then item.accent:Show() else item.accent:Hide() end
        end
    end

    function rail:SetBadge(id, count)
        local item = self._byId[id]
        if not (item and item.badge) then return end
        local n = tonumber(count) or 0
        if n > 0 then
            item.badge:SetText(n > 99 and "99+" or tostring(n))
            item.badge:Show()
        else
            item.badge:SetText("")
            item.badge:Hide()
        end
    end

    local y = -8
    for gIdx, grp in ipairs(groups or {}) do
        if gIdx > 1 then
            y = y - 6
            local div = rail:CreateTexture(nil, "ARTWORK")
            div:SetHeight(T.PixelSize(rail, 1))
            div:SetPoint("TOPLEFT", rail, "TOPLEFT", 10, y)
            div:SetPoint("TOPRIGHT", rail, "TOPRIGHT", -10, y)
            div:SetColorTexture(T.BORDER.SUBTLE[1], T.BORDER.SUBTLE[2], T.BORDER.SUBTLE[3], 0.6)
            y = y - 8
        end

        local gHdr = W.Label(rail, grp.title or "", "small", T.TEXT.MUTED, { justifyH = "LEFT", wordWrap = false })
        gHdr:SetPoint("TOPLEFT", rail, "TOPLEFT", 12, y)
        y = y - 18

        for _, def in ipairs(grp.items or {}) do
            local btn = CreateFrame("Button", nil, rail)
            btn:SetHeight(26)
            btn:SetPoint("TOPLEFT", rail, "TOPLEFT", 5, y)
            btn:SetPoint("TOPRIGHT", rail, "TOPRIGHT", -5, y)
            PaintBox(btn, { 0, 0, 0, 0 }, nil)

            local accent = btn:CreateTexture(nil, "ARTWORK")
            accent:SetWidth(3)
            accent:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, -4)
            accent:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 4)
            accent:SetColorTexture(T.BORDER.GOLD[1], T.BORDER.GOLD[2], T.BORDER.GOLD[3], 1)
            accent:Hide()

            local lbl = W.Label(btn, def.label or def.id, "body", T.TEXT.SECONDARY, { justifyH = "LEFT", wordWrap = false })
            lbl:SetPoint("LEFT", btn, "LEFT", 11, 0)
            btn._label = lbl

            local badge = W.Label(btn, "", "small", T.TEXT.GOLD, { justifyH = "RIGHT", wordWrap = false })
            badge:SetPoint("RIGHT", btn, "RIGHT", -8, 0)
            badge:Hide()

            btn:SetScript("OnEnter", function(self)
                if rail._activeId ~= def.id then
                    self._fsBg:SetColorTexture(T.SURFACE.HOVER[1], T.SURFACE.HOVER[2], T.SURFACE.HOVER[3], 0.55)
                end
            end)
            btn:SetScript("OnLeave", function(self)
                if rail._activeId ~= def.id then
                    self._fsBg:SetColorTexture(0, 0, 0, 0)
                end
            end)
            btn:SetScript("OnClick", function()
                rail:SetActive(def.id)
                if onSelect then onSelect(def.id) end
            end)

            local rec = { id = def.id, btn = btn, accent = accent, badge = badge }
            table_insert(rail._buttons, rec)
            rail._byId[def.id] = rec
            y = y - 28
        end
    end

    return rail
end

-- 23. ActionInputBar: Inline EditBox(es) + Gold submit button (Zero-Slash input workflows)
function W.ActionInputBar(parent, fields, submitLabel, onSubmit)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(28)
    bar._inputs = {}

    local function Submit()
        local vals = {}
        for _, rec in ipairs(bar._inputs) do
            vals[rec.key] = (rec.box:GetText() or "")
        end
        if onSubmit then
            local clear = onSubmit(vals, bar)
            if clear ~= false then
                for _, rec in ipairs(bar._inputs) do
                    if not rec.keepValue then
                        rec.box:SetText("")
                    end
                    rec.box:ClearFocus()
                end
            end
        end
    end

    local x = 0
    for _, fdef in ipairs(fields or {}) do
        local bw = fdef.width or 160
        local box = W.SearchBox(bar, bw, fdef.placeholder or "", nil)
        box:SetPoint("LEFT", bar, "LEFT", x, 0)
        box:SetScript("OnEnterPressed", function()
            Submit()
        end)
        table_insert(bar._inputs, { key = fdef.key or "text", box = box, keepValue = fdef.keepValue == true })
        x = x + bw + 6
    end

    local btn = W.Button(bar, submitLabel or "실행", 96, 24, Submit, true)
    btn:SetPoint("LEFT", bar, "LEFT", x, 0)
    bar._submitBtn = btn

    function bar:GetInput(key)
        for _, rec in ipairs(self._inputs) do
            if rec.key == key then return rec.box end
        end
        return self._inputs[1] and self._inputs[1].box or nil
    end

    function bar:SetValue(key, text)
        local box = self:GetInput(key)
        if box then box:SetText(tostring(text or "")) end
    end

    return bar
end

-- 24. CopyPasteModal: Singleton L3_OVERLAY modal for URL copy & Profile Export/Import (zero slash required)
local sharedCopyModal = nil

function W.CopyPasteModal()
    if sharedCopyModal then
        return sharedCopyModal
    end

    local modal = W.Window("ForeverSuiteV3CopyPasteModal", 520, 232, "✦ 복사 · 붙여넣기")
    modal:SetFrameStrata(T.ELEVATION.L3_OVERLAY)
    modal:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 40)

    local sub = W.Label(modal, "", "small", T.TEXT.SECONDARY, { justifyH = "LEFT", wordWrap = true })
    sub:SetPoint("TOPLEFT", modal, "TOPLEFT", 16, -50)
    sub:SetPoint("TOPRIGHT", modal, "TOPRIGHT", -16, -50)

    local box = CreateFrame("EditBox", nil, modal)
    box:SetSize(488, 76)
    box:SetPoint("TOPLEFT", modal, "TOPLEFT", 16, -84)
    box:SetPoint("TOPRIGHT", modal, "TOPRIGHT", -16, -84)
    box:SetAutoFocus(false)
    box:SetTextInsets(8, 8, 6, 6)
    box:SetFontObject(T.GetFont("mono"))
    if type(box.SetMultiLine) == "function" then box:SetMultiLine(true) end
    if type(box.SetMaxLetters) == "function" then box:SetMaxLetters(0) end
    PaintBox(box, T.SURFACE.SUNKEN, T.BORDER.GOLD_SOFT)

    local statusLbl = W.Label(modal, "", "small", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    statusLbl:SetPoint("BOTTOMLEFT", modal, "BOTTOMLEFT", 16, 48)
    statusLbl:SetPoint("BOTTOMRIGHT", modal, "BOTTOMRIGHT", -16, 48)

    local function ExecuteImportSubmit()
        if type(modal._onSubmit) == "function" then
            local raw = string_gsub(box:GetText() or "", "%s+", "")
            local ok, msg = modal._onSubmit(raw)
            if msg then
                statusLbl:SetText(tostring(msg))
                local c = ok and T.SEMANTIC.SUCCESS or T.SEMANTIC.DANGER
                statusLbl:SetTextColor(c[1], c[2], c[3], 1)
            end
            if ok then
                box:ClearFocus()
            end
        end
    end

    local actionBtn = W.Button(modal, "가져오기 적용", 116, 26, ExecuteImportSubmit, true)
    actionBtn:SetPoint("BOTTOMRIGHT", modal, "BOTTOMRIGHT", -96, 14)

    local closeBtn = W.Button(modal, "닫기", 72, 26, function()
        box:ClearFocus()
        modal:Hide()
    end)
    closeBtn:SetPoint("BOTTOMRIGHT", modal, "BOTTOMRIGHT", -16, 14)

    local selectAllBtn = W.Button(modal, "전체 선택", 84, 26, function()
        if type(box.SetFocus) == "function" then box:SetFocus() end
        if type(box.HighlightText) == "function" then box:HighlightText() end
    end)
    selectAllBtn:SetPoint("BOTTOMLEFT", modal, "BOTTOMLEFT", 16, 14)

    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        modal:Hide()
    end)
    box:SetScript("OnEnterPressed", function(self)
        if modal._mode == "import" then
            ExecuteImportSubmit()
        else
            self:ClearFocus()
        end
    end)

    modal._sub = sub
    modal._box = box
    modal._status = statusLbl
    modal._actionBtn = actionBtn
    modal._mode = "export"
    modal._onSubmit = nil

    function modal:OpenExport(titleText, subtitleText, text)
        self._mode = "export"
        self._onSubmit = nil
        self._title:SetText("✦ " .. tostring(titleText or "복사"))
        self._sub:SetText(tostring(subtitleText or "아래 텍스트를 선택한 뒤 Ctrl+C (Cmd+C) 로 복사하세요."))
        self._box:SetText(tostring(text or ""))
        self._status:SetText("Ctrl+C (또는 Cmd+C) 로 복사 후 닫기를 누르세요.")
        self._status:SetTextColor(T.TEXT.GOLD[1], T.TEXT.GOLD[2], T.TEXT.GOLD[3], 1)
        self._actionBtn:Hide()
        self:Show()
        if type(self._box.SetFocus) == "function" then self._box:SetFocus() end
        if type(self._box.HighlightText) == "function" then self._box:HighlightText() end
    end

    function modal:OpenImport(titleText, subtitleText, onImport, initialText)
        self._mode = "import"
        self._onSubmit = onImport
        self._title:SetText("✦ " .. tostring(titleText or "프로필 가져오기"))
        self._sub:SetText(tostring(subtitleText or "FS2: 로 시작하는 프로필 문자열을 붙여넣고 [가져오기 적용]을 누르세요."))
        self._box:SetText(tostring(initialText or ""))
        self._status:SetText("")
        self._actionBtn:Show()
        self:Show()
        if type(self._box.SetFocus) == "function" then self._box:SetFocus() end
    end

    sharedCopyModal = modal
    return modal
end
