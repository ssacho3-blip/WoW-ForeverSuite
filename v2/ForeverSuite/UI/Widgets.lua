-- Module: UI/Widgets.lua
-- Responsibility: ForeverSuite v5.0 Unified Widget Factory ("Classic Gold RPG" & "Clean Dark Minimal").
--                 Zero raw CreateFrame styling in Features/; Surface Doctrine (L0 Floating HUD,
--                 L1 Quiet Card, L2 Sculpted 9-Slice Window/Popup); zero UI-Tooltip-Border smearing;
--                 12-layer 3D extruded Rounded418 satin arrow.
-- Layer: UI
local _, ns = ...
ns.UI = ns.UI or {}

local T = ns.UI.Tokens
local NS = ns.UI.NineSlice
local ipairs = ipairs
local tostring = tostring
local math_min = math.min
local math_max = math.max
local math_floor = math.floor
local math_cos = math.cos
local math_sin = math.sin
local math_pi = math.pi
local table_insert = table.insert
local pcall = pcall
local type = type

local Widgets = {}
ns.UI.Widgets = Widgets

local function ApplyGradientSafe(tex, orientation, minCol, maxCol)
    if not (tex and type(tex.SetGradient) == "function" and type(_G.CreateColor) == "function") then
        return false
    end
    local okC1, c1 = pcall(_G.CreateColor, minCol[1], minCol[2], minCol[3], minCol[4] or 1)
    local okC2, c2 = pcall(_G.CreateColor, maxCol[1], maxCol[2], maxCol[3], maxCol[4] or 1)
    if okC1 and okC2 and c1 and c2 then
        return pcall(tex.SetGradient, tex, orientation or "VERTICAL", c1, c2)
    end
    return false
end

-- Fixed B1: ALWAYS prime texture with pure white (1,1,1,1) before SetGradient so WoW does NOT square dark RGB values!
local function PaintGradientBg(tex, baseCol, loMult, hiMult)
    if not (tex and baseCol) then return false end
    local a = baseCol[4] or 1
    if a <= 0.02 then
        tex:SetColorTexture(baseCol[1], baseCol[2], baseCol[3], a)
        return false
    end
    local lo = loMult or 0.80
    local hi = hiMult or 1.24
    tex:SetColorTexture(1, 1, 1, 1)
    local ok = ApplyGradientSafe(tex, "VERTICAL",
        { baseCol[1] * lo, baseCol[2] * lo, baseCol[3] * lo, a },
        { math_min(1, baseCol[1] * hi), math_min(1, baseCol[2] * hi), math_min(1, baseCol[3] * hi), a }
    )
    if not ok then
        tex:SetColorTexture(baseCol[1], baseCol[2], baseCol[3], a)
    end
    return ok
end

local function PaintBox(frame, bgColor, borderColor, opts)
    opts = type(opts) == "table" and opts or {}
    local bg = frame:CreateTexture(nil, "BACKGROUND", nil, opts.bgSublevel or -2)
    bg:SetAllPoints(frame)
    if opts.gradient and (bgColor[4] or 1) > 0.05 then
        PaintGradientBg(bg, bgColor, opts.loMult or 0.82, opts.hiMult or 1.22)
    else
        bg:SetColorTexture(bgColor[1], bgColor[2], bgColor[3], bgColor[4] or 1)
    end
    frame._fsBg = bg

    if borderColor then
        local px = T.PixelSize(frame, 1)
        local bAlpha = borderColor[4] or 1
        local top = frame:CreateTexture(nil, "BORDER")
        top:SetHeight(px)
        top:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        top:SetColorTexture(borderColor[1], borderColor[2], borderColor[3], bAlpha)

        local bottom = frame:CreateTexture(nil, "BORDER")
        bottom:SetHeight(px)
        bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
        bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        bottom:SetColorTexture(borderColor[1], borderColor[2], borderColor[3], bAlpha)

        local left = frame:CreateTexture(nil, "BORDER")
        left:SetWidth(px)
        left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
        left:SetColorTexture(borderColor[1], borderColor[2], borderColor[3], bAlpha)

        local right = frame:CreateTexture(nil, "BORDER")
        right:SetWidth(px)
        right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        right:SetColorTexture(borderColor[1], borderColor[2], borderColor[3], bAlpha)

        frame._fsBorders = { top, bottom, left, right }
    end
end

function Widgets.SetBorderColor(frame, col)
    if not (frame and col) then
        return
    end
    if frame._fsBorders then
        local a = col[4] or 1
        for i = 1, #frame._fsBorders do
            frame._fsBorders[i]:SetColorTexture(col[1], col[2], col[3], a)
        end
    end
end

Widgets.ApplyGradient = ApplyGradientSafe
Widgets.PaintGradientBg = PaintGradientBg

-- Crisp double-bevel burnished gold corner trim (lightweight accent helper, zero SetBackdrop!)
function Widgets.ApplyGoldBorderChrome(frame, opts)
    if not frame or frame._fsGoldChrome then
        return frame
    end
    opts = type(opts) == "table" and opts or {}
    local cornerLen = opts.cornerSize or 7
    local gold = T.BORDER.GOLD
    local soft = T.BORDER.GOLD_SOFT
    local px = T.PixelSize(frame, 1)
    local px2 = T.PixelSize(frame, 2)

    Widgets.SetBorderColor(frame, { gold[1], gold[2], gold[3], opts.borderAlpha or 0.78 })

    local sheen = frame:CreateTexture(nil, "ARTWORK")
    sheen:SetHeight(px)
    sheen:SetPoint("TOPLEFT", frame, "TOPLEFT", px, -px)
    sheen:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -px, -px)
    sheen:SetColorTexture(1.0, 0.90, 0.56, 0.34)

    local innerB = frame:CreateTexture(nil, "ARTWORK")
    innerB:SetHeight(px)
    innerB:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", px, px)
    innerB:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -px, px)
    innerB:SetColorTexture(0.02, 0.02, 0.03, 0.70)

    local corners = {}
    local defs = {
        { "TOPLEFT",     cornerLen, px2, 0, 0 },
        { "TOPLEFT",     px2, cornerLen, 0, 0 },
        { "TOPRIGHT",    cornerLen, px2, 0, 0 },
        { "TOPRIGHT",    px2, cornerLen, 0, 0 },
        { "BOTTOMLEFT",  cornerLen, px2, 0, 0 },
        { "BOTTOMLEFT",  px2, cornerLen, 0, 0 },
        { "BOTTOMRIGHT", cornerLen, px2, 0, 0 },
        { "BOTTOMRIGHT", px2, cornerLen, 0, 0 },
    }
    for i = 1, #defs do
        local d = defs[i]
        local c = frame:CreateTexture(nil, "OVERLAY")
        c:SetSize(d[2], d[3])
        c:SetPoint(d[1], frame, d[1], d[4], d[5])
        c:SetColorTexture(gold[1], gold[2], gold[3], opts.cornerAlpha or 0.94)
        corners[i] = c
    end

    frame._fsGoldChrome = {
        sheen = sheen,
        innerB = innerB,
        corners = corners,
        soft = soft,
    }
    return frame
end

-- Legacy fallback 3-layer procedural rotating 360° arrow (kept for gold_classic style & backwards compatibility)
function Widgets.GoldArrow(parent, size)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(size or 30, size or 30)
    local parts = {}
    local scale = (size or 30) / 64
    local segments = {
        { 0,  -7, 9, 38, 0 },
        { -9, 12, 9, 30, -math_pi / 4 },
        { 9,  12, 9, 30,  math_pi / 4 },
    }
    for layer = 1, 3 do
        local pad = (layer == 1 and 7) or (layer == 2 and 4) or 0
        for _, p in ipairs(segments) do
            local t = holder:CreateTexture(nil, "ARTWORK", nil, layer - 1)
            t:SetTexture("Interface\\Buttons\\WHITE8X8")
            t:SetSize((p[3] + pad) * scale, (p[4] + pad) * scale)
            parts[#parts + 1] = {
                texture = t,
                x = p[1] * scale,
                y = p[2] * scale,
                rotation = p[5],
                layer = layer,
            }
        end
    end
    holder._parts = parts
    holder._angle = 0

    function holder:SetDirection(angle)
        local a = (type(angle) == "number") and angle or 0
        self._angle = a
        local ca, sa = math_cos(a), math_sin(a)
        for _, p in ipairs(self._parts) do
            local tx = p.x * ca - p.y * sa
            local ty = p.x * sa + p.y * ca
            p.texture:ClearAllPoints()
            p.texture:SetPoint("CENTER", self, "CENTER", tx, ty)
            if type(p.texture.SetRotation) == "function" then
                pcall(p.texture.SetRotation, p.texture, p.rotation + a)
            end
        end
    end

    function holder:SetFillColor(r, g, b)
        for _, p in ipairs(self._parts) do
            if type(p.texture.SetVertexColor) == "function" then
                if p.layer == 1 then
                    p.texture:SetVertexColor(0.035, 0.028, 0.018, 1)
                elseif p.layer == 2 then
                    p.texture:SetVertexColor(0.831, 0.686, 0.216, 1)
                else
                    p.texture:SetVertexColor(r or 0.20, g or 0.96, b or 0.25, 1)
                end
            end
        end
    end

    holder:SetFillColor(0.20, 0.96, 0.25)
    holder:SetDirection(0)
    holder:Hide()
    return holder
end

-- 12-Layer 3D Extruded Satin Rounded418 Navigation Arrow (GodJohnson RoundedArrowArt418 algorithm, zero taint)
local ARROW_418_DIR = "Interface\\AddOns\\ForeverSuite_Media_Assets\\Arrows\\Rounded418\\"
local ARROW_418_DESIGNS = {
    roundedClassic = true,
    roundedWedge   = true,
    roundedCompass = true,
}
local ARROW_418_CORNERS = {
    { -0.5,  0.5 },
    { -0.5, -0.5 },
    {  0.5,  0.5 },
    {  0.5, -0.5 },
}
local ARROW_418_ORIGINS = {
    { -1,  1 },
    { -1, -1 },
    {  1,  1 },
    {  1, -1 },
}

function Widgets.Rounded3DArrow(parent, size)
    local sz = size or 74
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(sz, sz)
    holder._size = sz
    holder._design = "roundedClassic"
    holder._angle = 0
    holder._r, holder._g, holder._b = 0.22, 0.96, 0.34
    holder._tilt = 0.52
    holder._depthRatio = 0.055
    holder._layers = {}

    local function AddLayer(part, z, scale, shade, sublevel, drawLayer)
        local tex = holder:CreateTexture(nil, drawLayer or "ARTWORK", nil, sublevel)
        tex:SetSize(sz, sz)
        tex:SetPoint("CENTER", holder, "CENTER", 0, 0)
        holder._layers[#holder._layers + 1] = {
            tex   = tex,
            part  = part,
            z     = z,
            scale = scale,
            shade = shade,
        }
    end

    -- 10 depth-extruded side slices (bottom -> top)
    for k = 0, 9 do
        local t = k / 10
        local scale = 0.986 + 0.014 * math_sin(t * math_pi * 0.73)
        local shade = 0.29 + 0.18 * (t ^ 0.8)
        AddLayer("side", -1 + t, scale, shade, k - 5, "ARTWORK")
    end
    -- Layer 11: Satin face
    AddLayer("face", 0, 1.0, 1.0, 6, "ARTWORK")
    -- Layer 12: Specular shine highlight
    AddLayer("shine", 0, 1.0, 1.0, 7, "OVERLAY")

    function holder:SetDesign(designKey)
        local key = ARROW_418_DESIGNS[designKey] and designKey or "roundedClassic"
        self._design = key
        for i = 1, #self._layers do
            local L = self._layers[i]
            local path = ARROW_418_DIR .. key .. "-" .. L.part .. ".tga"
            if type(L.tex.SetTexture) == "function" then
                pcall(L.tex.SetTexture, L.tex, path)
            end
        end
        return key
    end

    function holder:SetColor(r, g, b)
        self._r = r or 0.22
        self._g = g or 0.96
        self._b = b or 0.34
        for i = 1, #self._layers do
            local L = self._layers[i]
            if type(L.tex.SetVertexColor) == "function" then
                if L.part == "shine" then
                    pcall(L.tex.SetVertexColor, L.tex, 0.95, 0.99, 0.99, 0.92)
                else
                    local s = L.shade or 1
                    pcall(L.tex.SetVertexColor, L.tex, self._r * s, self._g * s, self._b * s, 1)
                end
            end
        end
    end

    function holder:SetDirection(angle)
        local a = (type(angle) == "number") and angle or 0
        self._angle = a
        local ca, sa = math_cos(a), math_sin(a)
        local curSz = self._size or 74
        local tilt = self._tilt or 0.52
        local depth = curSz * (self._depthRatio or 0.055)
        for i = 1, #self._layers do
            local L = self._layers[i]
            local tex = L.tex
            local half = curSz * 0.5 * (L.scale or 1)
            local zOff = depth * (L.z or 0)
            if type(tex.SetVertexOffset) == "function" then
                for j = 1, 4 do
                    local c = ARROW_418_CORNERS[j]
                    local o = ARROW_418_ORIGINS[j]
                    local x = c[1] * curSz * (L.scale or 1)
                    local y = c[2] * curSz * (L.scale or 1)
                    local rx = x * ca - y * sa
                    local ry = (x * sa + y * ca) * tilt + zOff
                    pcall(tex.SetVertexOffset, tex, j, rx - (o[1] * curSz * 0.5), ry - (o[2] * curSz * 0.5))
                end
            else
                -- Graceful planar fallback for headless mocks / engines without SetVertexOffset
                tex:ClearAllPoints()
                tex:SetSize(half * 2, half * 2)
                tex:SetPoint("CENTER", self, "CENTER", 0, zOff)
                if type(tex.SetRotation) == "function" then
                    pcall(tex.SetRotation, tex, a)
                end
            end
        end
    end

    function holder:Render(angle, r, g, b)
        if r and g and b then
            self:SetColor(r, g, b)
        end
        self:SetDirection(angle)
    end

    holder:SetDesign("roundedClassic")
    holder:SetColor(0.22, 0.96, 0.34)
    holder:SetDirection(0)
    holder:Hide()
    return holder
end

function Widgets.Label(parent, text, role, color, opts)
    local fs = parent:CreateFontString(nil, "OVERLAY", T.GetFont(role or "body"))
    fs:SetText(tostring(text or ""))
    local c = color or T.TEXT.PRIMARY
    fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
    if type(fs.SetShadowColor) == "function" then
        fs:SetShadowColor(0, 0, 0, 0.95)
    end
    if type(fs.SetShadowOffset) == "function" then
        fs:SetShadowOffset(1, -1)
    end
    if type(opts) == "table" then
        if opts.justifyH and type(fs.SetJustifyH) == "function" then
            fs:SetJustifyH(opts.justifyH)
        end
        if opts.wordWrap ~= nil and type(fs.SetWordWrap) == "function" then
            fs:SetWordWrap(opts.wordWrap)
        end
        if opts.outline and type(fs.GetFont) == "function" and type(fs.SetFont) == "function" then
            local okF, path, sz = pcall(fs.GetFont, fs)
            if okF and type(path) == "string" and type(sz) == "number" and sz > 0 then
                pcall(fs.SetFont, fs, path, opts.fontSize or sz, type(opts.outline) == "string" and opts.outline or "OUTLINE")
            end
        end
    end
    return fs
end

-- 1. Window (L2 sculpted 9-slice window with real baked 16px outer drop shadow & instant theme switching)
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

    -- Real high-DPI 9-slice sculpted border + baked outer drop shadow (zero UI-Tooltip-Border!)
    if NS and type(NS.Apply) == "function" then
        NS.Apply(f, NS.WindowPresetForTheme(), { layer = "BACKGROUND", sublevel = -6 })
    end
    PaintBox(f, T.SURFACE.CANVAS, nil, { bgSublevel = -5 })

    local header = CreateFrame("Frame", nil, f)
    header:SetHeight(40)
    header:SetPoint("TOPLEFT", f, "TOPLEFT", 3, -3)
    header:SetPoint("TOPRIGHT", f, "TOPRIGHT", -3, -3)
    PaintBox(header, T.SURFACE.HEADER or { 0.118, 0.095, 0.068, 0.96 }, nil, { gradient = true, loMult = 0.80, hiMult = 1.28 })

    local goldRule = header:CreateTexture(nil, "ARTWORK")
    goldRule:SetHeight(T.PixelSize(header, 1))
    goldRule:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 0)
    goldRule:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0)
    goldRule:SetColorTexture(T.BORDER.GOLD[1], T.BORDER.GOLD[2], T.BORDER.GOLD[3], 0.85)

    local title = Widgets.Label(header, titleText or "ForeverSuite", "title", T.TEXT.GOLD, { outline = "OUTLINE" })
    title:SetPoint("LEFT", header, "LEFT", T.SPACE.LG, 0)

    local closeBtn = Widgets.Button(header, "×", 26, 24, function() f:Hide() end)
    closeBtn:SetPoint("RIGHT", header, "RIGHT", -T.SPACE.SM, 0)

    f._header = header
    f._headerRule = goldRule
    f._title = title
    f._closeBtn = closeBtn

    if T and type(T.RegisterThemeListener) == "function" then
        T.RegisterThemeListener(function(themeId)
            if f._fsNineSlice and NS then
                f._fsNineSlice:SetPreset(NS.WindowPresetForTheme(themeId))
            end
            if f._fsBg then
                f._fsBg:SetColorTexture(T.SURFACE.CANVAS[1], T.SURFACE.CANVAS[2], T.SURFACE.CANVAS[3], T.SURFACE.CANVAS[4])
            end
            if header._fsBg then
                PaintGradientBg(header._fsBg, T.SURFACE.HEADER, 0.80, 1.28)
            end
            if goldRule then
                goldRule:SetColorTexture(T.BORDER.GOLD[1], T.BORDER.GOLD[2], T.BORDER.GOLD[3], 0.85)
            end
            if title then
                title:SetTextColor(T.TEXT.GOLD[1], T.TEXT.GOLD[2], T.TEXT.GOLD[3], 1)
            end
        end)
    end

    if type(name) == "string" and type(_G.UISpecialFrames) == "table" then
        table_insert(_G.UISpecialFrames, name)
    end
    f:Hide()
    return f
end

-- 1b. PopupCard (L2 sculpted floating popup/overlay using high-DPI 9-slice small frame + baked shadow)
function Widgets.PopupCard(parent, width, height, name, strata)
    local f = CreateFrame("Frame", name, parent or _G.UIParent)
    if width and height then
        f:SetSize(width, height)
    end
    if strata then
        f:SetFrameStrata(strata)
    end
    if NS and type(NS.Apply) == "function" then
        NS.Apply(f, NS.PopupPresetForTheme(), { layer = "BACKGROUND", sublevel = -6 })
    end
    PaintBox(f, T.SURFACE.CANVAS, nil, { bgSublevel = -5 })
    if T and type(T.RegisterThemeListener) == "function" then
        T.RegisterThemeListener(function(themeId)
            if f._fsNineSlice and NS then
                f._fsNineSlice:SetPreset(NS.PopupPresetForTheme(themeId))
            end
            if f._fsBg then
                f._fsBg:SetColorTexture(T.SURFACE.CANVAS[1], T.SURFACE.CANVAS[2], T.SURFACE.CANVAS[3], T.SURFACE.CANVAS[4])
            end
        end)
    end
    f._fsSurfaceLevel = "L2_POPUP"
    return f
end

-- 2. Card (L1 Quiet Surface: flat recessed obsidian + crisp 1px hairline + subtle top sheen; ZERO UI-Tooltip-Border!)
function Widgets.Card(parent, width, height, name, strata)
    local f = CreateFrame("Frame", name, parent or _G.UIParent)
    if width and height then
        f:SetSize(width, height)
    end
    if strata then
        f:SetFrameStrata(strata)
    end
    PaintBox(f, T.SURFACE.CARD, T.BORDER.HAIRLINE, { gradient = true, loMult = 0.90, hiMult = 1.08 })
    local topSheen = f:CreateTexture(nil, "ARTWORK")
    topSheen:SetHeight(T.PixelSize(f, 1))
    topSheen:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
    topSheen:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
    topSheen:SetColorTexture(0.96, 0.88, 0.68, 0.12)
    f._fsTopSheen = topSheen
    f._fsSurfaceLevel = "L1_QUIET"
    if T and type(T.RegisterThemeListener) == "function" then
        T.RegisterThemeListener(function()
            if f._fsBg then
                PaintGradientBg(f._fsBg, T.SURFACE.CARD, 0.90, 1.08)
            end
            Widgets.SetBorderColor(f, T.BORDER.HAIRLINE)
        end)
    end
    return f
end

-- 2b. HudGlass (ElvUI / Details!-style sleek translucent dark-glass HUD; zero clunky walls!)
function Widgets.HudGlass(parent, width, height, name, strata, opts)
    opts = type(opts) == "table" and opts or {}
    local f = CreateFrame("Frame", name, parent or _G.UIParent)
    if width and height then
        f:SetSize(width, height)
    end
    if strata then
        f:SetFrameStrata(strata)
    end
    local bg = opts.bg or T.SURFACE.HUD_GLASS
    local bd = opts.border or T.BORDER.HUD_GLASS
    PaintBox(f, bg, bd, { gradient = true, loMult = 0.88, hiMult = 1.14 })

    local sheen = f:CreateTexture(nil, "ARTWORK")
    sheen:SetHeight(T.PixelSize(f, 1))
    sheen:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
    sheen:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
    sheen:SetColorTexture(0.95, 0.86, 0.62, 0.22)
    f._fsGlassSheen = sheen

    if opts.accentBar then
        local bar = f:CreateTexture(nil, "ARTWORK")
        bar:SetWidth(3)
        bar:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
        bar:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, 1)
        bar:SetColorTexture(T.BORDER.GOLD[1], T.BORDER.GOLD[2], T.BORDER.GOLD[3], 0.90)
        f._fsAccentBar = bar
    end
    f._fsHudStyle = "glass"
    return f
end

-- 2c. HudFloating (100% borderless L0 floating HUD with optional fade ribbon OR radial readability scrim)
function Widgets.HudFloating(parent, width, height, name, strata)
    local f = CreateFrame("Frame", name, parent or _G.UIParent)
    if width and height then
        f:SetSize(width, height)
    end
    if strata then
        f:SetFrameStrata(strata)
    end
    f:SetClampedToScreen(true)

    local radial = f:CreateTexture(nil, "BACKGROUND", nil, -4)
    if type(radial.SetTexture) == "function" then
        pcall(radial.SetTexture, radial, (T.UI_ART and T.UI_ART.scrimRadial) or T.MEDIA.WHITE)
    end
    radial:SetAllPoints(f)
    radial:Hide()
    f._radialScrim = radial

    local leftHalf = f:CreateTexture(nil, "BACKGROUND", nil, -3)
    leftHalf:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    leftHalf:SetPoint("BOTTOMRIGHT", f, "BOTTOM", 0, 0)
    leftHalf:Hide()

    local rightHalf = f:CreateTexture(nil, "BACKGROUND", nil, -3)
    rightHalf:SetPoint("TOPLEFT", f, "TOP", 0, 0)
    rightHalf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    rightHalf:Hide()

    f._ribbonL = leftHalf
    f._ribbonR = rightHalf
    f._fsHudStyle = "floating"

    function f:SetRadialScrim(alpha, r, g, b)
        local a = tonumber(alpha) or 0
        if a <= 0 then
            self._radialScrim:Hide()
            return
        end
        if type(self._radialScrim.SetVertexColor) == "function" then
            pcall(self._radialScrim.SetVertexColor, self._radialScrim, r or 0.04, g or 0.03, b or 0.05, a)
        end
        self._radialScrim:Show()
    end

    function f:SetRibbon(col, centerAlpha, edgeYTop, edgeYBot)
        if not col or (centerAlpha or 0) <= 0 then
            self._ribbonL:Hide()
            self._ribbonR:Hide()
            return
        end
        local topOff = edgeYTop or 0
        local botOff = edgeYBot or 0
        self._ribbonL:ClearAllPoints()
        self._ribbonL:SetPoint("TOPLEFT", self, "TOPLEFT", 0, topOff)
        self._ribbonL:SetPoint("BOTTOMRIGHT", self, "BOTTOM", 0, botOff)
        self._ribbonR:ClearAllPoints()
        self._ribbonR:SetPoint("TOPLEFT", self, "TOP", 0, topOff)
        self._ribbonR:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", 0, botOff)
        self._ribbonL:SetColorTexture(1, 1, 1, 1)
        self._ribbonR:SetColorTexture(1, 1, 1, 1)
        local ca = centerAlpha or 0.55
        if not ApplyGradientSafe(self._ribbonL, "HORIZONTAL", { col[1], col[2], col[3], 0 }, { col[1], col[2], col[3], ca }) then
            self._ribbonL:SetColorTexture(col[1], col[2], col[3], ca * 0.7)
        end
        if not ApplyGradientSafe(self._ribbonR, "HORIZONTAL", { col[1], col[2], col[3], ca }, { col[1], col[2], col[3], 0 }) then
            self._ribbonR:SetColorTexture(col[1], col[2], col[3], ca * 0.7)
        end
        self._ribbonL:Show()
        self._ribbonR:Show()
    end

    return f
end

-- 2d. StatusBarTrack (Custom sculpted groove + glossy satin fill bar + bright leading spark)
function Widgets.StatusBarTrack(parent, width, height)
    local holder = CreateFrame("Frame", nil, parent)
    if width and height then
        holder:SetSize(width, height)
    end
    local track = holder:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints(holder)
    if T.UI_ART and T.UI_ART.statusGroove and type(track.SetTexture) == "function" then
        pcall(track.SetTexture, track, T.UI_ART.statusGroove)
        if type(track.SetVertexColor) == "function" then
            pcall(track.SetVertexColor, track, 0.85, 0.82, 0.80, 0.88)
        end
    else
        track:SetColorTexture(0.03, 0.03, 0.04, 0.78)
    end

    local fill = holder:CreateTexture(nil, "ARTWORK")
    fill:SetTexture((T.UI_ART and T.UI_ART.statusFill) or (T.MEDIA and T.MEDIA.STATUSBAR_BLIZ) or "Interface\\TargetingFrame\\UI-StatusBar")
    fill:SetPoint("TOPLEFT", holder, "TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 1, 1)
    fill:SetWidth(1)
    fill:Hide()

    local spark = holder:CreateTexture(nil, "OVERLAY")
    spark:SetWidth(2)
    spark:SetPoint("TOPRIGHT", fill, "TOPRIGHT", 0, 0)
    spark:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT", 0, 0)
    spark:SetColorTexture(1, 0.96, 0.82, 0.88)
    spark:Hide()

    holder._track = track
    holder._fill = fill
    holder._spark = spark

    function holder:SetProgress(ratio, col, maxW)
        local r = (type(ratio) == "number") and ratio or 0
        if r <= 0 then
            self._fill:Hide()
            self._spark:Hide()
            return
        end
        if r > 1 then r = 1 end
        local bw = maxW or (type(self.GetWidth) == "function" and self:GetWidth()) or 160
        if not bw or bw < 10 then bw = 160 end
        local w = math_max(2, math_floor((bw - 2) * r + 0.5))
        local c = col or T.BORDER.GOLD
        self._fill:SetWidth(w)
        if type(self._fill.SetVertexColor) == "function" then
            self._fill:SetVertexColor(c[1], c[2], c[3], c[4] or 0.94)
        end
        self._fill:Show()
        self._spark:Show()
    end

    return holder
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
    local lbl = Widgets.Label(holder, text, "heading", T.TEXT.GOLD)
    lbl:SetPoint("LEFT", holder, "LEFT", 0, 0)
    local line = holder:CreateTexture(nil, "ARTWORK")
    line:SetHeight(T.PixelSize(holder, 1))
    line:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 0, 0)
    line:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", 0, 0)
    line:SetColorTexture(T.BORDER.SUBTLE[1], T.BORDER.SUBTLE[2], T.BORDER.SUBTLE[3], T.BORDER.SUBTLE[4])
    holder._label = lbl
    holder._line = line
    return holder
end

-- 5. Button (Forged obsidian/gold metallic gradient bevel + top sheen + tactile press feedback; fixed B1!)
function Widgets.Button(parent, label, width, height, onClick, isGoldAccent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(width or 96, height or 26)
    btn._isGoldAccent = isGoldAccent and true or false
    local function GetBaseBg()
        return btn._isGoldAccent and T.SURFACE.GOLD_TINT or T.SURFACE.ELEVATED
    end
    local function GetBaseBorder()
        return btn._isGoldAccent and T.BORDER.GOLD or T.BORDER.HAIRLINE
    end
    PaintBox(btn, GetBaseBg(), GetBaseBorder(), { gradient = true, loMult = 0.78, hiMult = 1.26 })
    local sheen = btn:CreateTexture(nil, "ARTWORK")
    sheen:SetHeight(T.PixelSize(btn, 1))
    sheen:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
    sheen:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -1, -1)
    sheen:SetColorTexture(1, 0.92, 0.68, isGoldAccent and 0.42 or 0.18)
    local lbl = Widgets.Label(btn, label, "small", isGoldAccent and T.TEXT.GOLD or T.TEXT.PRIMARY)
    lbl:SetPoint("CENTER", btn, "CENTER", 0, 0)
    btn._label = lbl
    btn._sheen = sheen

    btn:SetScript("OnEnter", function(self)
        PaintGradientBg(self._fsBg, T.SURFACE.HOVER, 0.84, 1.24)
        Widgets.SetBorderColor(self, T.BORDER.GOLD)
    end)
    btn:SetScript("OnLeave", function(self)
        PaintGradientBg(self._fsBg, GetBaseBg(), 0.78, 1.26)
        Widgets.SetBorderColor(self, GetBaseBorder())
        self._label:ClearAllPoints()
        self._label:SetPoint("CENTER", self, "CENTER", 0, 0)
    end)
    btn:SetScript("OnMouseDown", function(self)
        PaintGradientBg(self._fsBg, T.SURFACE.SUNKEN, 0.85, 1.05)
        self._label:ClearAllPoints()
        self._label:SetPoint("CENTER", self, "CENTER", 0, -1)
    end)
    btn:SetScript("OnMouseUp", function(self)
        PaintGradientBg(self._fsBg, T.SURFACE.HOVER, 0.84, 1.24)
        self._label:ClearAllPoints()
        self._label:SetPoint("CENTER", self, "CENTER", 0, 0)
    end)
    btn:SetScript("OnClick", function(self, mouseBtn)
        if onClick then onClick(self, mouseBtn) end
    end)
    return btn
end

-- 5b. MiniButton (sleek forged/ghost compact button with hover & press states)
function Widgets.MiniButton(parent, label, width, height, onClick, tooltipText, opts)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(width or 42, height or 20)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn._active = false
    btn._ghost = type(opts) == "table" and opts.ghost == true
    btn._tooltipText = tooltipText
    PaintBox(btn, btn._ghost and { 0.08, 0.07, 0.08, 0.40 } or T.SURFACE.ELEVATED,
        btn._ghost and { 0.42, 0.34, 0.18, 0.30 } or T.BORDER.HAIRLINE, { gradient = not btn._ghost })
    local lbl = Widgets.Label(btn, label, "small", T.TEXT.PRIMARY, { justifyH = "CENTER", wordWrap = false })
    lbl:SetPoint("CENTER", btn, "CENTER", 0, 0)
    btn._label = lbl

    local function SyncStyle(self)
        local bg = self._active and T.SURFACE.GOLD_TINT
            or (self._ghost and { 0.08, 0.07, 0.08, 0.40 } or T.SURFACE.ELEVATED)
        local bd = self._active and T.BORDER.GOLD
            or (self._ghost and { 0.42, 0.34, 0.18, 0.30 } or T.BORDER.HAIRLINE)
        local tc = self._active and T.TEXT.GOLD or T.TEXT.SECONDARY
        if self._ghost and not self._active then
            self._fsBg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
        else
            PaintGradientBg(self._fsBg, bg, 0.80, 1.22)
        end
        Widgets.SetBorderColor(self, bd)
        self._label:SetTextColor(tc[1], tc[2], tc[3], tc[4])
    end

    function btn:SetActive(flag)
        self._active = flag and true or false
        SyncStyle(self)
    end

    function btn:SetLabel(text)
        self._label:SetText(tostring(text or ""))
    end

    btn:SetScript("OnEnter", function(self)
        PaintGradientBg(self._fsBg, T.SURFACE.HOVER, 0.86, 1.20)
        Widgets.SetBorderColor(self, T.BORDER.GOLD)
        if self._tooltipText and _G.GameTooltip and type(_G.GameTooltip.SetOwner) == "function" then
            pcall(function()
                _G.GameTooltip:SetOwner(self, "ANCHOR_TOP")
                _G.GameTooltip:ClearLines()
                _G.GameTooltip:AddLine(self._tooltipText, T.TEXT.GOLD[1], T.TEXT.GOLD[2], T.TEXT.GOLD[3])
                _G.GameTooltip:Show()
            end)
        end
    end)
    btn:SetScript("OnLeave", function(self)
        SyncStyle(self)
        if _G.GameTooltip and type(_G.GameTooltip.Hide) == "function" then
            pcall(_G.GameTooltip.Hide, _G.GameTooltip)
        end
    end)
    btn:SetScript("OnClick", function(self, mouseBtn)
        if onClick then onClick(self, mouseBtn) end
    end)
    SyncStyle(btn)
    return btn
end

-- 6. ListRow (interactive clipped flat row with left status accent, bottom separator, custom satin gauge, hover & tooltip)
function Widgets.ListRow(parent, height, onClick)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(height or 24)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row._baseBg = { 0, 0, 0, 0 }
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

    local gauge = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    gauge:SetTexture((T.UI_ART and T.UI_ART.statusFill) or (T.MEDIA and T.MEDIA.STATUSBAR_BLIZ) or "Interface\\TargetingFrame\\UI-StatusBar")
    gauge:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -1)
    gauge:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 1)
    gauge:SetWidth(1)
    gauge:Hide()
    row._gauge = gauge

    local spark = row:CreateTexture(nil, "ARTWORK")
    spark:SetWidth(2)
    spark:SetPoint("TOPRIGHT", gauge, "TOPRIGHT", 0, 0)
    spark:SetPoint("BOTTOMRIGHT", gauge, "BOTTOMRIGHT", 0, 0)
    spark:SetColorTexture(1, 0.96, 0.85, 0.70)
    spark:Hide()
    row._gaugeSpark = spark

    row._right = Widgets.Label(row, "", "mono", T.TEXT.SECONDARY, { justifyH = "RIGHT", wordWrap = false })
    row._right:SetPoint("RIGHT", row, "RIGHT", -T.SPACE.SM, 0)

    row._left = Widgets.Label(row, "", "body", T.TEXT.PRIMARY, { justifyH = "LEFT", wordWrap = false })
    row._left:SetPoint("LEFT", row, "LEFT", T.SPACE.SM, 0)
    row._left:SetPoint("RIGHT", row._right, "LEFT", -6, 0)

    function row:SetGauge(pct, col, maxWidth)
        if type(pct) ~= "number" or pct <= 0 or not col then
            self._gauge:Hide()
            if self._gaugeSpark then self._gaugeSpark:Hide() end
            return
        end
        local clamped = (pct > 100) and 100 or pct
        local baseW = maxWidth or (type(self.GetWidth) == "function" and self:GetWidth()) or 220
        if not baseW or baseW < 20 then baseW = 220 end
        local w = math_floor((clamped / 100) * baseW + 0.5)
        if w < 2 then w = 2 end
        self._gauge:SetWidth(w)
        if type(self._gauge.SetVertexColor) == "function" then
            self._gauge:SetVertexColor(col[1], col[2], col[3], col[4] or 0.65)
        else
            self._gauge:SetColorTexture(col[1], col[2], col[3], col[4] or 0.65)
        end
        self._gauge:Show()
        if self._gaugeSpark then self._gaugeSpark:Show() end
    end

    function row:SetRowStyle(bgCol, accentCol, accentX, accentW, sepCol, leftPad, fadeRight, ribbonTex)
        self._baseBg = bgCol or { 0, 0, 0, 0 }
        self._fadeRight = fadeRight == true
        self._ribbonTex = ribbonTex
        if ribbonTex and type(self._fsBg.SetTexture) == "function" then
            pcall(self._fsBg.SetTexture, self._fsBg, ribbonTex)
            if type(self._fsBg.SetVertexColor) == "function" then
                pcall(self._fsBg.SetVertexColor, self._fsBg, self._baseBg[1] or 1, self._baseBg[2] or 1, self._baseBg[3] or 1, self._baseBg[4] or 0.90)
            end
        elseif self._fadeRight and (self._baseBg[4] or 0) > 0.01 then
            self._fsBg:SetColorTexture(1, 1, 1, 1)
            if not ApplyGradientSafe(self._fsBg, "HORIZONTAL",
                { self._baseBg[1], self._baseBg[2], self._baseBg[3], self._baseBg[4] or 0.5 },
                { self._baseBg[1], self._baseBg[2], self._baseBg[3], 0.0 }
            ) then
                self._fsBg:SetColorTexture(self._baseBg[1], self._baseBg[2], self._baseBg[3], self._baseBg[4] or 0)
            end
        else
            self._fsBg:SetColorTexture(self._baseBg[1], self._baseBg[2], self._baseBg[3], self._baseBg[4] or 0)
        end
        if accentCol and (accentW or 3) > 0 then
            self._accent:ClearAllPoints()
            self._accent:SetWidth(accentW or 3)
            self._accent:SetPoint("TOPLEFT", self, "TOPLEFT", accentX or 0, -2)
            self._accent:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", accentX or 0, 2)
            self._accent:SetColorTexture(accentCol[1], accentCol[2], accentCol[3], accentCol[4] or 1)
            self._accent:Show()
        else
            self._accent:Hide()
        end
        if sepCol then
            self._sep:SetColorTexture(sepCol[1], sepCol[2], sepCol[3], sepCol[4] or 0.5)
            self._sep:Show()
        else
            self._sep:Hide()
        end
        if type(leftPad) == "number" then
            self._left:ClearAllPoints()
            self._left:SetPoint("LEFT", self, "LEFT", leftPad, 0)
            self._left:SetPoint("RIGHT", self._right, "LEFT", -6, 0)
        end
    end

    function row:SetTooltipHandler(onEnterFn, onLeaveFn)
        self._onTooltipEnter = onEnterFn
        self._onTooltipLeave = onLeaveFn
    end

    row:SetScript("OnEnter", function(self)
        if not self._ribbonTex then
            self._fsBg:SetColorTexture(T.SURFACE.HOVER[1], T.SURFACE.HOVER[2], T.SURFACE.HOVER[3], 0.65)
        elseif type(self._fsBg.SetVertexColor) == "function" then
            pcall(self._fsBg.SetVertexColor, self._fsBg, 1.0, 0.94, 0.78, 1.0)
        end
        if type(self._onTooltipEnter) == "function" then
            self._onTooltipEnter(self)
        end
    end)
    row:SetScript("OnLeave", function(self)
        local bg = self._baseBg or { 0, 0, 0, 0 }
        if self._ribbonTex and type(self._fsBg.SetVertexColor) == "function" then
            pcall(self._fsBg.SetVertexColor, self._fsBg, bg[1] or 1, bg[2] or 1, bg[3] or 1, bg[4] or 0.90)
        elseif self._fadeRight and (bg[4] or 0) > 0.01 then
            self._fsBg:SetColorTexture(1, 1, 1, 1)
            if not ApplyGradientSafe(self._fsBg, "HORIZONTAL",
                { bg[1], bg[2], bg[3], bg[4] or 0.5 },
                { bg[1], bg[2], bg[3], 0.0 }
            ) then
                self._fsBg:SetColorTexture(bg[1], bg[2], bg[3], bg[4] or 0)
            end
        else
            self._fsBg:SetColorTexture(bg[1], bg[2], bg[3], bg[4] or 0)
        end
        if type(self._onTooltipLeave) == "function" then
            self._onTooltipLeave(self)
        end
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
    PaintBox(rail, T.SURFACE.SUNKEN, T.BORDER.SUBTLE)
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
        btn:SetHeight(26)
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
        y = y - 29
    end
    return rail
end

-- 8. PillBar (preserves metallic gradient cleanly across selection & hover)
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
            PaintGradientBg(p.btn._fsBg, bg, 0.80, 1.24)
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
        btn:SetScript("OnLeave", function(self)
            self._label:ClearAllPoints()
            self._label:SetPoint("CENTER", self, "CENTER", 0, 0)
            Refresh()
        end)
        btn:SetScript("OnMouseUp", function(self)
            self._label:ClearAllPoints()
            self._label:SetPoint("CENTER", self, "CENTER", 0, 0)
            Refresh()
        end)
        table_insert(bar._pills, { value = opt.value, btn = btn })
        x = x + (opt.width or 84) + T.SPACE.SM
    end
    function bar:SetValue(v)
        self._value = v
        Refresh()
    end
    Refresh()
    return bar
end

-- 9. Toggle (Fixed B4: full-row hover feedback, authentic gold checkmark icon, right-bounded label)
function Widgets.Toggle(parent, label, initialVal, onChange)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(26)
    row._checked = initialVal and true or false
    PaintBox(row, { 0, 0, 0, 0 }, nil)

    local box = CreateFrame("Frame", nil, row)
    box:SetSize(16, 16)
    box:SetPoint("LEFT", row, "LEFT", 4, 0)
    PaintBox(box, T.SURFACE.SUNKEN, T.BORDER.HAIRLINE)

    local check = box:CreateTexture(nil, "OVERLAY")
    check:SetSize(18, 18)
    check:SetPoint("CENTER", box, "CENTER", 1, 1)
    if type(check.SetTexture) == "function" then
        pcall(check.SetTexture, check, (T.MEDIA and T.MEDIA.CHECKMARK) or "Interface\\Buttons\\UI-CheckBox-Check")
    end
    if type(check.SetVertexColor) == "function" then
        pcall(check.SetVertexColor, check, T.TEXT.GOLD[1], T.TEXT.GOLD[2], T.TEXT.GOLD[3], 1)
    end

    local lbl = Widgets.Label(row, label, "body", T.TEXT.PRIMARY, { justifyH = "LEFT", wordWrap = false })
    lbl:SetPoint("LEFT", box, "RIGHT", T.SPACE.SM, 0)
    lbl:SetPoint("RIGHT", row, "RIGHT", -8, 0)

    local function Sync()
        if row._checked then
            check:Show()
            Widgets.SetBorderColor(box, T.BORDER.GOLD)
            box._fsBg:SetColorTexture(T.SURFACE.GOLD_TINT[1], T.SURFACE.GOLD_TINT[2], T.SURFACE.GOLD_TINT[3], 0.90)
        else
            check:Hide()
            Widgets.SetBorderColor(box, T.BORDER.HAIRLINE)
            box._fsBg:SetColorTexture(T.SURFACE.SUNKEN[1], T.SURFACE.SUNKEN[2], T.SURFACE.SUNKEN[3], 0.95)
        end
    end

    function row:SetChecked(v)
        self._checked = v and true or false
        Sync()
    end

    row:SetScript("OnEnter", function(self)
        self._fsBg:SetColorTexture(T.SURFACE.HOVER[1], T.SURFACE.HOVER[2], T.SURFACE.HOVER[3], 0.45)
        Widgets.SetBorderColor(box, T.BORDER.GOLD)
    end)
    row:SetScript("OnLeave", function(self)
        self._fsBg:SetColorTexture(0, 0, 0, 0)
        Sync()
    end)
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
    row._box = box
    row._check = check
    row._label = lbl
    return row
end

-- 10. Slider (Fixed B3: recessed groove track + live gold progress fill + visible thumb via SetThumbTexture!)
function Widgets.Slider(parent, label, minVal, maxVal, step, initialVal, onChange)
    local lo = minVal or 0
    local hi = maxVal or 100
    local init = initialVal or lo
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetHeight(38)
    local lbl = Widgets.Label(holder, label, "small", T.TEXT.SECONDARY)
    lbl:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
    local valTxt = Widgets.Label(holder, tostring(init), "mono", T.TEXT.GOLD)
    valTxt:SetPoint("TOPRIGHT", holder, "TOPRIGHT", 0, 0)

    local slider = CreateFrame("Slider", nil, holder)
    slider:SetOrientation("HORIZONTAL")
    slider:SetHeight(16)
    slider:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 0, 2)
    slider:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", 0, 2)
    PaintBox(slider, T.SURFACE.SUNKEN, T.BORDER.HAIRLINE)

    -- Recessed groove texture
    local groove = slider:CreateTexture(nil, "BACKGROUND", nil, 0)
    groove:SetPoint("TOPLEFT", slider, "TOPLEFT", 1, -1)
    groove:SetPoint("BOTTOMRIGHT", slider, "BOTTOMRIGHT", -1, 1)
    if T.UI_ART and T.UI_ART.statusGroove and type(groove.SetTexture) == "function" then
        pcall(groove.SetTexture, groove, T.UI_ART.statusGroove)
    else
        groove:SetColorTexture(0.03, 0.03, 0.04, 0.90)
    end

    -- Live filled gold progress bar
    local fill = slider:CreateTexture(nil, "ARTWORK", nil, 1)
    fill:SetTexture((T.UI_ART and T.UI_ART.statusFill) or T.MEDIA.STATUSBAR_BLIZ)
    fill:SetPoint("TOPLEFT", slider, "TOPLEFT", 1, -2)
    fill:SetPoint("BOTTOMLEFT", slider, "BOTTOMLEFT", 1, 2)
    fill:SetWidth(2)
    if type(fill.SetVertexColor) == "function" then
        fill:SetVertexColor(T.BORDER.GOLD[1], T.BORDER.GOLD[2], T.BORDER.GOLD[3], 0.92)
    end

    -- Real Blizzard Slider thumb texture (fixes invisible thumb!)
    local thumbPath = (T.UI_ART and T.UI_ART.iconRing) or T.MEDIA.WHITE
    if type(slider.SetThumbTexture) == "function" then
        pcall(slider.SetThumbTexture, slider, thumbPath)
        local tObj = type(slider.GetThumbTexture) == "function" and slider:GetThumbTexture() or nil
        if tObj then
            if type(tObj.SetSize) == "function" then tObj:SetSize(16, 16) end
            if type(tObj.SetVertexColor) == "function" then
                tObj:SetVertexColor(T.TEXT.GOLD[1], T.TEXT.GOLD[2], T.TEXT.GOLD[3], 1)
            end
            slider._thumbTex = tObj
        end
    end

    -- Crisp gold visual thumb knob synced with ratio (guarantees visibility on all WoW clients & headless mocks)
    local knob = slider:CreateTexture(nil, "OVERLAY")
    knob:SetSize(12, 16)
    knob:SetColorTexture(T.TEXT.GOLD[1], T.TEXT.GOLD[2], T.TEXT.GOLD[3], 0.98)
    knob:SetPoint("CENTER", slider, "LEFT", 6, 0)
    slider._thumbKnob = knob
    slider._fillBar = fill

    local function SyncVisual(v)
        local span = hi - lo
        local ratio = (span > 0) and ((v - lo) / span) or 0
        if ratio < 0 then ratio = 0 end
        if ratio > 1 then ratio = 1 end
        local sw = (type(slider.GetWidth) == "function" and slider:GetWidth()) or 220
        if not sw or sw < 24 then sw = 220 end
        local usable = math_max(12, sw - 2)
        local fillW = math_max(2, math_floor(usable * ratio + 0.5))
        fill:SetWidth(fillW)
        local kx = 6 + math_floor((sw - 12) * ratio + 0.5)
        knob:ClearAllPoints()
        knob:SetPoint("CENTER", slider, "LEFT", kx, 0)
    end

    slider:SetMinMaxValues(lo, hi)
    slider:SetValueStep(step or 1)
    slider:SetObeyStepOnDrag(true)
    slider:SetValue(init)
    SyncVisual(init)

    slider:SetScript("OnValueChanged", function(_, v)
        local displayV = (step and step < 1) and string.format("%.2f", v) or tostring(math_floor(v + 0.5))
        valTxt:SetText(displayV)
        SyncVisual(v)
        if onChange then onChange(v) end
    end)
    slider:SetScript("OnEnter", function(self)
        Widgets.SetBorderColor(self, T.BORDER.GOLD)
    end)
    slider:SetScript("OnLeave", function(self)
        Widgets.SetBorderColor(self, T.BORDER.HAIRLINE)
    end)
    if type(slider.HookScript) == "function" then
        pcall(slider.HookScript, slider, "OnSizeChanged", function(self)
            local cur = (type(self.GetValue) == "function" and self:GetValue()) or init
            SyncVisual(cur)
        end)
    end

    holder._slider = slider
    holder._valTxt = valTxt
    holder._fill = fill
    holder._thumbKnob = knob
    return holder
end

-- 11. SearchBox (Magnifying glass icon + inline clear X + gold focus ring)
function Widgets.SearchBox(parent, width, placeholder, onChange)
    local box = CreateFrame("EditBox", nil, parent)
    box:SetSize(width or 180, 24)
    box:SetAutoFocus(false)
    box:SetTextInsets(24, 20, 0, 0)
    box:SetFontObject(T.GetFont("small"))
    PaintBox(box, T.SURFACE.SUNKEN, T.BORDER.HAIRLINE)

    local icon = box:CreateTexture(nil, "ARTWORK")
    icon:SetSize(13, 13)
    icon:SetPoint("LEFT", box, "LEFT", 6, 0)
    if type(icon.SetTexture) == "function" then
        pcall(icon.SetTexture, icon, (T.MEDIA and T.MEDIA.SEARCH_ICON) or "Interface\\Common\\UI-Searchbox-Icon")
    end
    if type(icon.SetVertexColor) == "function" then
        pcall(icon.SetVertexColor, icon, T.TEXT.SECONDARY[1], T.TEXT.SECONDARY[2], T.TEXT.SECONDARY[3], 0.85)
    end

    local ph = Widgets.Label(box, placeholder or "검색...", "small", T.TEXT.MUTED)
    ph:SetPoint("LEFT", box, "LEFT", 24, 0)

    local clearBtn = CreateFrame("Button", nil, box)
    clearBtn:SetSize(16, 16)
    clearBtn:SetPoint("RIGHT", box, "RIGHT", -4, 0)
    local clearLbl = Widgets.Label(clearBtn, "×", "small", T.TEXT.SECONDARY, { justifyH = "CENTER" })
    clearLbl:SetPoint("CENTER", clearBtn, "CENTER", 0, 0)
    clearBtn:Hide()
    clearBtn:SetScript("OnClick", function()
        box:SetText("")
        box:ClearFocus()
    end)

    box:SetScript("OnTextChanged", function(self)
        local txt = self:GetText() or ""
        if txt == "" then
            ph:Show()
            clearBtn:Hide()
        else
            ph:Hide()
            clearBtn:Show()
        end
        if onChange then onChange(txt) end
    end)
    box:SetScript("OnEditFocusGained", function(self)
        Widgets.SetBorderColor(self, T.BORDER.GOLD)
    end)
    box:SetScript("OnEditFocusLost", function(self)
        Widgets.SetBorderColor(self, T.BORDER.HAIRLINE)
    end)
    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    box._placeholder = ph
    box._searchIcon = icon
    box._clearBtn = clearBtn
    return box
end

-- 12. Badge & Toast (Sculpted 9-slice PopupCard Toast with real shadow)
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
local toastGen = 0

function Widgets.Toast(titleText, bodyText, semanticKey, durationSec)
    local col = T.SEMANTIC[semanticKey] or T.BORDER.GOLD
    if not sharedToast then
        local card = Widgets.PopupCard(_G.UIParent, 348, 60, "ForeverSuiteV5Toast", T.ELEVATION.L1_CARD)
        card:SetPoint("TOP", _G.UIParent, "TOP", 0, -96)
        local accent = card:CreateTexture(nil, "ARTWORK")
        accent:SetWidth(3)
        accent:SetPoint("TOPLEFT", card, "TOPLEFT", 3, -3)
        accent:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 3, 3)
        local t = Widgets.Label(card, "", "heading", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
        t:SetPoint("TOPLEFT", card, "TOPLEFT", 14, -10)
        t:SetPoint("TOPRIGHT", card, "TOPRIGHT", -14, -10)
        local b = Widgets.Label(card, "", "small", T.TEXT.SECONDARY, { justifyH = "LEFT", wordWrap = false })
        b:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -4)
        b:SetPoint("TOPRIGHT", card, "TOPRIGHT", -14, -32)
        card._accent = accent
        card._title = t
        card._body = b
        sharedToast = card
    end
    toastGen = toastGen + 1
    local myGen = toastGen
    sharedToast._accent:SetColorTexture(col[1], col[2], col[3], 1)
    sharedToast._title:SetText(tostring(titleText or ""))
    sharedToast._body:SetText(tostring(bodyText or ""))
    sharedToast:Show()
    local sec = (type(durationSec) == "number" and durationSec > 0) and durationSec or 4.5
    if ns.Api and ns.Api.GameAdapters and type(ns.Api.GameAdapters.RunAfter) == "function" then
        ns.Api.GameAdapters.RunAfter(sec, function()
            if toastGen == myGen and sharedToast then
                sharedToast:Hide()
            end
        end)
    end
    return sharedToast
end

-- 13. MinimapButton (Authentic WoW Circular Minimap Medallion with Blizzard Tracking Gold Ring!)
function Widgets.MinimapButton(name, initialAngle, onClick, onTooltip, onAngleChanged)
    local anchorParent = _G.Minimap or _G.UIParent
    local btn = CreateFrame("Button", name, anchorParent)
    btn:SetSize(31, 31)
    btn:SetFrameStrata(T.ELEVATION.L0_HUD)
    btn:SetClampedToScreen(true)
    btn:EnableMouse(true)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(21, 21)
    bg:SetPoint("CENTER", btn, "CENTER", 0, 0)
    bg:SetColorTexture(T.SURFACE.CANVAS[1], T.SURFACE.CANVAS[2], T.SURFACE.CANVAS[3], 0.94)
    if type(btn.CreateMaskTexture) == "function" and type(bg.AddMaskTexture) == "function" then
        pcall(function()
            local mask = btn:CreateMaskTexture()
            mask:SetTexture((T.MEDIA and T.MEDIA.PORTRAIT_MASK) or "Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            mask:SetAllPoints(bg)
            bg:AddMaskTexture(mask)
        end)
    end
    btn._fsBg = bg

    local ring = btn:CreateTexture(nil, "OVERLAY")
    ring:SetSize(52, 52)
    ring:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
    ring:SetTexture((T.MEDIA and T.MEDIA.MINIMAP_RING) or "Interface\\Minimap\\MiniMap-TrackingBorder")
    if type(ring.SetVertexColor) == "function" then
        ring:SetVertexColor(0.95, 0.80, 0.36, 1)
    end
    btn._fsRing = ring

    local glyph = Widgets.Label(btn, "★", "heading", T.TEXT.GOLD, { outline = "OUTLINE" })
    glyph:SetPoint("CENTER", btn, "CENTER", 0, 1)
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
    btn:SetScript("OnHide", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    btn:SetAngle(btn._angle)
    return btn
end

-- 14. MakeDraggable (Zero-Taint screen-clamped drag + 4px-snapped ProfileStore layout persistence)
function Widgets.MakeDraggable(frame, layoutKey, defaultAnchor)
    if not frame then return frame end
    if type(frame.SetClampedToScreen) == "function" then frame:SetClampedToScreen(true) end
    if type(frame.SetMovable) == "function" then frame:SetMovable(true) end
    if type(frame.EnableMouse) == "function" then frame:EnableMouse(true) end
    if type(frame.RegisterForDrag) == "function" then frame:RegisterForDrag("LeftButton") end

    if layoutKey and ns.Api and ns.Api.ProfileStore then
        local saved = ns.Api.ProfileStore:GetLayout(layoutKey)
        local a = (type(saved) == "table" and type(saved.point) == "string") and saved or defaultAnchor
        if type(a) == "table" and type(a.point) == "string" then
            frame:ClearAllPoints()
            frame:SetPoint(a.point, _G.UIParent, a.relPoint or a.point, a.x or 0, a.y or 0)
        end
    end

    frame:SetScript("OnDragStart", function(self)
        if type(self.StartMoving) == "function" then
            self:StartMoving()
        end
    end)
    frame:SetScript("OnDragStop", function(self)
        if type(self.StopMovingOrSizing) == "function" then
            self:StopMovingOrSizing()
        end
        if layoutKey and ns.Api and ns.Api.ProfileStore and type(self.GetPoint) == "function" then
            local p, _, rp, x, y = self:GetPoint(1)
            if p then
                local sx = math_floor(((x or 0) / 4) + 0.5) * 4
                local sy = math_floor(((y or 0) / 4) + 0.5) * 4
                self:ClearAllPoints()
                self:SetPoint(p, _G.UIParent, rp or p, sx, sy)
                ns.Api.ProfileStore:SetLayout(layoutKey, {
                    point = p,
                    relPoint = rp or p,
                    x = sx,
                    y = sy,
                })
            end
        end
    end)
    frame._fsDraggableKey = layoutKey
    return frame
end
