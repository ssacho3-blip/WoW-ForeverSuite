-- Module: UI/Draw.lua
-- Responsibility: ForeverSuite v6.1.0 L2 Rendering Primitives:
--                 1) 7-texture FS-Round.tga arbitrary-radius rounded rect (WhatTheWhisper pattern, zero BackdropTemplate)
--                 2) Single 1px __fsHairline double-border guard
--                 3) Outer non-mouse sibling SurfaceRim (GodJohnson depth guarantee, ZERO GetChildren/coroutine walk)
--                 4) 512px FS-SoftInk.tga seamless InkUV charcoal grain anchoring
--                 5) Cached HSL Lighten() & WCAG ContrastRatio / AdjustTextColor helpers
-- Layer: UI (L2; depends only on UI/Tokens & UI/PixelUtil).
local _, ns = ...
ns.UI = ns.UI or {}

local T = ns.UI.Tokens
local PU = ns.UI.PixelUtil
local math_max = math.max
local math_min = math.min
local math_floor = math.floor
local string_format = string.format
local type = type
local pcall = pcall

local Draw = {}
ns.UI.Draw = Draw

local function DisableSnap(tex)
    if PU and type(PU.DisablePixelSnap) == "function" then
        PU.DisablePixelSnap(tex)
    end
end

local function SetColorSafe(tex, col)
    if not (tex and col) then return end
    if type(tex.SetVertexColor) == "function" then
        pcall(tex.SetVertexColor, tex, col[1], col[2], col[3], col[4] or 1)
    elseif type(tex.SetColorTexture) == "function" then
        pcall(tex.SetColorTexture, tex, col[1], col[2], col[3], col[4] or 1)
    end
end

-- 1. 7-Texture Round.tga arbitrary-radius rounded rectangle (4 quadrants + 3 interior bands)
function Draw.CreateRoundedFill(frame, radius, color, opts)
    if not frame then return nil end
    opts = type(opts) == "table" and opts or {}
    local layer = opts.layer or "BACKGROUND"
    local sublevel = opts.sublevel or -3
    local col = color or T.SURFACE.CARD
    local discPath = (T.UI_ART and T.UI_ART.roundDisc) or T.MEDIA.WHITE

    local fw = (type(frame.GetWidth) == "function" and frame:GetWidth()) or 0
    local fh = (type(frame.GetHeight) == "function" and frame:GetHeight()) or 0
    local r = tonumber(radius) or (T.RADIUS and T.RADIUS.PANEL) or 6
    if fw > 0 and fh > 0 then
        r = math_min(r, math_min(fw, fh) * 0.5)
    end
    r = math_max(1, r)

    local existing = frame._fsRoundedFill
    if existing then
        existing.radius = tonumber(radius) or existing.radius
        existing.clampedRadius = r
        existing:SetColor(col)
        existing:Layout()
        return existing
    end

    local function MakePiece(isCorner, l, rr, t, b)
        local tex = frame:CreateTexture(nil, layer, nil, sublevel)
        if isCorner then
            if type(tex.SetTexture) == "function" then
                pcall(tex.SetTexture, tex, discPath)
            end
            if type(tex.SetTexCoord) == "function" then
                pcall(tex.SetTexCoord, tex, l, rr, t, b)
            end
            SetColorSafe(tex, col)
        else
            tex:SetColorTexture(col[1], col[2], col[3], col[4] or 1)
        end
        DisableSnap(tex)
        return tex
    end

    local tl = MakePiece(true, 0.0, 0.5, 0.0, 0.5)
    local tr = MakePiece(true, 0.5, 1.0, 0.0, 0.5)
    local bl = MakePiece(true, 0.0, 0.5, 0.5, 1.0)
    local br = MakePiece(true, 0.5, 1.0, 0.5, 1.0)
    local topBand = MakePiece(false)
    local midBand = MakePiece(false)
    local botBand = MakePiece(false)

    local obj = {
        frame = frame,
        radius = tonumber(radius) or 6,
        clampedRadius = r,
        color = { col[1], col[2], col[3], col[4] or 1 },
        textures = { tl, tr, bl, br, topBand, midBand, botBand },
        tl = tl, tr = tr, bl = bl, br = br,
        topBand = topBand, midBand = midBand, botBand = botBand,
    }

    function obj:Layout()
        local w = (type(self.frame.GetWidth) == "function" and self.frame:GetWidth()) or 0
        local h = (type(self.frame.GetHeight) == "function" and self.frame:GetHeight()) or 0
        local cr = self.radius
        if w > 0 and h > 0 then
            cr = math_min(cr, math_min(w, h) * 0.5)
        end
        cr = math_max(1, cr)
        self.clampedRadius = cr

        for i = 1, #self.textures do
            self.textures[i]:ClearAllPoints()
        end
        self.tl:SetSize(cr, cr)
        self.tl:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, 0)
        self.tr:SetSize(cr, cr)
        self.tr:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", 0, 0)
        self.bl:SetSize(cr, cr)
        self.bl:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", 0, 0)
        self.br:SetSize(cr, cr)
        self.br:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", 0, 0)

        self.topBand:SetPoint("TOPLEFT", self.tl, "TOPRIGHT", 0, 0)
        self.topBand:SetPoint("BOTTOMRIGHT", self.tr, "BOTTOMLEFT", 0, 0)

        self.botBand:SetPoint("TOPLEFT", self.bl, "TOPRIGHT", 0, 0)
        self.botBand:SetPoint("BOTTOMRIGHT", self.br, "BOTTOMLEFT", 0, 0)

        self.midBand:SetPoint("TOPLEFT", self.tl, "BOTTOMLEFT", 0, 0)
        self.midBand:SetPoint("BOTTOMRIGHT", self.br, "TOPRIGHT", 0, 0)
        return self
    end

    function obj:SetColor(c)
        if not c then return self end
        local a = c[4] or 1
        self.color[1], self.color[2], self.color[3], self.color[4] = c[1], c[2], c[3], a
        SetColorSafe(self.tl, self.color)
        SetColorSafe(self.tr, self.color)
        SetColorSafe(self.bl, self.color)
        SetColorSafe(self.br, self.color)
        self.topBand:SetColorTexture(c[1], c[2], c[3], a)
        self.midBand:SetColorTexture(c[1], c[2], c[3], a)
        self.botBand:SetColorTexture(c[1], c[2], c[3], a)
        return self
    end

    obj:Layout()
    frame._fsRoundedFill = obj
    if not frame._fsRoundSized and type(frame.HookScript) == "function" then
        frame._fsRoundSized = true
        pcall(frame.HookScript, frame, "OnSizeChanged", function(self)
            if self._fsRoundedFill then
                self._fsRoundedFill:Layout()
            end
        end)
    end
    return obj
end

-- 1b. 7-Texture Rounded 1px Outer Border (guarded by __fsHairline; zero 90-degree protruding corners!)
function Draw.CreateRoundedBorder(frame, radius, borderColor, opts)
    if not frame then return nil end
    opts = type(opts) == "table" and opts or {}
    local col = borderColor or T.BORDER.HAIRLINE
    local existing = frame.__fsHairline
    if existing then
        existing:SetColor(col)
        return existing
    end

    local layer = opts.layer or "BACKGROUND"
    local sublevel = opts.sublevel or -4
    local discPath = (T.UI_ART and T.UI_ART.roundDisc) or T.MEDIA.WHITE
    local baseR = tonumber(radius) or (T.RADIUS and T.RADIUS.PANEL) or 6
    local pad = T.PixelSize(frame, 1)

    local function MakePiece(isCorner, l, rr, t, b)
        local tex = frame:CreateTexture(nil, layer, nil, sublevel)
        if isCorner then
            if type(tex.SetTexture) == "function" then
                pcall(tex.SetTexture, tex, discPath)
            end
            if type(tex.SetTexCoord) == "function" then
                pcall(tex.SetTexCoord, tex, l, rr, t, b)
            end
            SetColorSafe(tex, col)
        else
            tex:SetColorTexture(col[1], col[2], col[3], col[4] or 1)
        end
        DisableSnap(tex)
        return tex
    end

    local tl = MakePiece(true, 0.0, 0.5, 0.0, 0.5)
    local tr = MakePiece(true, 0.5, 1.0, 0.0, 0.5)
    local bl = MakePiece(true, 0.0, 0.5, 0.5, 1.0)
    local br = MakePiece(true, 0.5, 1.0, 0.5, 1.0)
    local topBand = MakePiece(false)
    local midBand = MakePiece(false)
    local botBand = MakePiece(false)

    local hl = {
        frame = frame,
        isRounded = true,
        radius = baseR,
        pad = pad,
        edges = { tl, tr, bl, br, topBand, midBand, botBand },
        tl = tl, tr = tr, bl = bl, br = br,
        topBand = topBand, midBand = midBand, botBand = botBand,
    }

    function hl:Layout()
        local w = (type(self.frame.GetWidth) == "function" and self.frame:GetWidth()) or 0
        local h = (type(self.frame.GetHeight) == "function" and self.frame:GetHeight()) or 0
        local p = self.pad or 1
        local cr = self.radius + p
        if w > 0 and h > 0 then
            cr = math_min(cr, (math_min(w, h) + p * 2) * 0.5)
        end
        cr = math_max(1, cr)
        for i = 1, #self.edges do
            self.edges[i]:ClearAllPoints()
        end
        self.tl:SetSize(cr, cr)
        self.tl:SetPoint("TOPLEFT", self.frame, "TOPLEFT", -p, p)
        self.tr:SetSize(cr, cr)
        self.tr:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", p, p)
        self.bl:SetSize(cr, cr)
        self.bl:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", -p, -p)
        self.br:SetSize(cr, cr)
        self.br:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", p, -p)

        self.topBand:SetPoint("TOPLEFT", self.tl, "TOPRIGHT", 0, 0)
        self.topBand:SetPoint("BOTTOMRIGHT", self.tr, "BOTTOMLEFT", 0, 0)
        self.botBand:SetPoint("TOPLEFT", self.bl, "TOPRIGHT", 0, 0)
        self.botBand:SetPoint("BOTTOMRIGHT", self.br, "BOTTOMLEFT", 0, 0)
        self.midBand:SetPoint("TOPLEFT", self.tl, "BOTTOMLEFT", 0, 0)
        self.midBand:SetPoint("BOTTOMRIGHT", self.br, "TOPRIGHT", 0, 0)
        return self
    end

    function hl:SetColor(c)
        if not c then return end
        local a = c[4] or 1
        local col4 = { c[1], c[2], c[3], a }
        SetColorSafe(self.tl, col4)
        SetColorSafe(self.tr, col4)
        SetColorSafe(self.bl, col4)
        SetColorSafe(self.br, col4)
        self.topBand:SetColorTexture(c[1], c[2], c[3], a)
        self.midBand:SetColorTexture(c[1], c[2], c[3], a)
        self.botBand:SetColorTexture(c[1], c[2], c[3], a)
    end

    hl:Layout()
    frame.__fsHairline = hl
    frame._fsBorders = hl.edges
    if not frame._fsRoundBorderSized and type(frame.HookScript) == "function" then
        frame._fsRoundBorderSized = true
        pcall(frame.HookScript, frame, "OnSizeChanged", function(self)
            if self.__fsHairline and self.__fsHairline.isRounded then
                self.__fsHairline:Layout()
            end
        end)
    end
    return hl
end

-- 2. Single 1px Hairline with __fsHairline double-border guard
function Draw.CreateHairline(frame, borderColor)
    if not frame then return nil end
    local col = borderColor or T.BORDER.HAIRLINE
    local existing = frame.__fsHairline
    if existing then
        existing:SetColor(col)
        return existing
    end

    local px = T.PixelSize(frame, 1)
    local bAlpha = col[4] or 1
    local top = frame:CreateTexture(nil, "BORDER")
    top:SetHeight(px)
    top:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    top:SetColorTexture(col[1], col[2], col[3], bAlpha)

    local bottom = frame:CreateTexture(nil, "BORDER")
    bottom:SetHeight(px)
    bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    bottom:SetColorTexture(col[1], col[2], col[3], bAlpha)

    local left = frame:CreateTexture(nil, "BORDER")
    left:SetWidth(px)
    left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    left:SetColorTexture(col[1], col[2], col[3], bAlpha)

    local right = frame:CreateTexture(nil, "BORDER")
    right:SetWidth(px)
    right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    right:SetColorTexture(col[1], col[2], col[3], bAlpha)

    local edges = { top, bottom, left, right }
    local hl = { edges = edges }
    function hl:SetColor(c)
        if not c then return end
        local a = c[4] or 1
        for i = 1, #self.edges do
            self.edges[i]:SetColorTexture(c[1], c[2], c[3], a)
        end
    end

    frame.__fsHairline = hl
    frame._fsBorders = edges
    return hl
end

-- 3. Outer non-mouse sibling SurfaceRim (never clipped by child ScrollBoxes, zero GetChildren walk)
function Draw.CreateSurfaceRim(target, borderColor)
    if not target then return nil end
    local col = borderColor or T.BORDER.GOLD
    if target._fsSurfaceRim then
        local r = target._fsSurfaceRim
        if r.__fsHairline then r.__fsHairline:SetColor(col) end
        return r
    end
    local parent = (type(target.GetParent) == "function" and target:GetParent()) or _G.UIParent
    local rim = CreateFrame("Frame", nil, parent)
    rim:SetAllPoints(target)
    rim:EnableMouse(false)
    if type(target.GetFrameStrata) == "function" and type(rim.SetFrameStrata) == "function" then
        local st = target:GetFrameStrata()
        if st then rim:SetFrameStrata(st) end
    end
    local lvl = (type(target.GetFrameLevel) == "function" and target:GetFrameLevel()) or 1
    rim:SetFrameLevel(lvl + 1)
    Draw.CreateHairline(rim, col)

    if type(target.HookScript) == "function" then
        pcall(target.HookScript, target, "OnShow", function()
            local curLvl = (type(target.GetFrameLevel) == "function" and target:GetFrameLevel()) or 1
            rim:SetFrameLevel(curLvl + 1)
            rim:Show()
        end)
        pcall(target.HookScript, target, "OnHide", function() rim:Hide() end)
    end
    if type(target.IsShown) == "function" and not target:IsShown() then
        rim:Hide()
    end

    target._fsSurfaceRim = rim
    return rim
end

-- 4. Seamless 512px FS-SoftInk.tga charcoal grain UV anchoring (recalcs once on OnSizeChanged)
function Draw.ApplyInkUV(frame, rootFrame, tintColor)
    if not frame then return nil end
    local tex = frame._fsInkTex
    if not tex then
        tex = frame:CreateTexture(nil, "BACKGROUND", nil, -2)
        tex:SetAllPoints(frame)
        if type(tex.SetTexture) == "function" then
            pcall(tex.SetTexture, tex, (T.UI_ART and T.UI_ART.softInk) or T.MEDIA.WHITE, "REPEAT", "REPEAT")
        end
        DisableSnap(tex)
        frame._fsInkTex = tex
    end

    local function UpdateUV()
        local root = rootFrame or (type(frame.GetParent) == "function" and frame:GetParent()) or frame
        local rLeft = (type(root.GetLeft) == "function" and root:GetLeft()) or 0
        local rTop  = (type(root.GetTop) == "function" and root:GetTop()) or 512
        local fLeft = (type(frame.GetLeft) == "function" and frame:GetLeft()) or rLeft
        local fTop  = (type(frame.GetTop) == "function" and frame:GetTop()) or rTop
        local fw = (type(frame.GetWidth) == "function" and frame:GetWidth()) or 256
        local fh = (type(frame.GetHeight) == "function" and frame:GetHeight()) or 256
        if fw <= 0 then fw = 256 end
        if fh <= 0 then fh = 256 end
        local tile = 512.0
        local u1 = (fLeft - rLeft) / tile
        local u2 = u1 + (fw / tile)
        local v1 = (rTop - fTop) / tile
        local v2 = v1 + (fh / tile)
        if type(tex.SetTexCoord) == "function" then
            pcall(tex.SetTexCoord, tex, u1, u2, v1, v2)
        end
        local tc = tintColor or (T.SURFACE and T.SURFACE.INK_TINT) or { 0.16, 0.14, 0.13, 0.24 }
        SetColorSafe(tex, tc)
    end

    UpdateUV()
    if not frame._fsInkHooked and type(frame.HookScript) == "function" then
        frame._fsInkHooked = true
        pcall(frame.HookScript, frame, "OnSizeChanged", UpdateUV)
        pcall(frame.HookScript, frame, "OnShow", UpdateUV)
    end
    return tex
end

function Draw.RefreshInkTint(frame, tintColor)
    if not (frame and frame._fsInkTex) then return false end
    local tc = tintColor or (T.SURFACE and T.SURFACE.INK_TINT) or { 0.16, 0.14, 0.13, 0.24 }
    SetColorSafe(frame._fsInkTex, tc)
    return true
end

-- 5. Cached HSL Lighten() (bounded <= 256 entries) & WCAG Contrast helpers
local lightenCache = {}
local lightenCacheCount = 0

local function RGBToHSL(r, g, b)
    local mx = math_max(r, g, b)
    local mn = math_min(r, g, b)
    local h, s
    local l = (mx + mn) * 0.5
    if mx == mn then
        h, s = 0, 0
    else
        local d = mx - mn
        s = (l > 0.5) and (d / (2 - mx - mn)) or (d / (mx + mn))
        if mx == r then
            h = (g - b) / d + (g < b and 6 or 0)
        elseif mx == g then
            h = (b - r) / d + 2
        else
            h = (r - g) / d + 4
        end
        h = h / 6
    end
    return h, s, l
end

local function Hue2RGB(p, q, t)
    if t < 0 then t = t + 1 end
    if t > 1 then t = t - 1 end
    if t < 1 / 6 then return p + (q - p) * 6 * t end
    if t < 1 / 2 then return q end
    if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
    return p
end

local function HSLToRGB(h, s, l)
    if s == 0 then return l, l, l end
    local q = (l < 0.5) and (l * (1 + s)) or (l + s - l * s)
    local p = 2 * l - q
    return Hue2RGB(p, q, h + 1 / 3), Hue2RGB(p, q, h), Hue2RGB(p, q, h - 1 / 3)
end

function Draw.Lighten(col, shift)
    if type(col) ~= "table" then return { 1, 1, 1, 1 } end
    local r, g, b, a = col[1] or 0, col[2] or 0, col[3] or 0, col[4] or 1
    local sh = tonumber(shift) or 0
    local key = string_format("%.3f:%.3f:%.3f:%.3f:%.3f", r, g, b, a, sh)
    local cached = lightenCache[key]
    if cached then
        return cached
    end
    local h, s, l = RGBToHSL(r, g, b)
    local nl = math_max(0, math_min(1, l + sh))
    local nr, ng, nb = HSLToRGB(h, s, nl)
    local out = { nr, ng, nb, a }
    if lightenCacheCount >= 256 then
        lightenCache = {}
        lightenCacheCount = 0
    end
    lightenCache[key] = out
    lightenCacheCount = lightenCacheCount + 1
    return out
end

local function Linearize(c)
    if c <= 0.03928 then return c / 12.92 end
    return ((c + 0.055) / 1.055) ^ 2.4
end

function Draw.RelativeLuminance(col)
    if type(col) ~= "table" then return 0 end
    return 0.2126 * Linearize(col[1] or 0) + 0.7152 * Linearize(col[2] or 0) + 0.0722 * Linearize(col[3] or 0)
end

function Draw.AlphaComposite(over, base)
    local a = (type(over) == "table" and tonumber(over[4])) or 1
    if a < 0 then a = 0 elseif a > 1 then a = 1 end
    local inv = 1 - a
    local br = (type(base) == "table" and base[1]) or 0
    local bg = (type(base) == "table" and base[2]) or 0
    local bb = (type(base) == "table" and base[3]) or 0
    return {
        (over[1] or 0) * a + br * inv,
        (over[2] or 0) * a + bg * inv,
        (over[3] or 0) * a + bb * inv,
        1.0,
    }
end

function Draw.ContrastRatio(fg, bg)
    local l1 = Draw.RelativeLuminance(fg)
    local l2 = Draw.RelativeLuminance(bg)
    if l1 < l2 then l1, l2 = l2, l1 end
    return (l1 + 0.05) / (l2 + 0.05)
end

function Draw.AdjustTextColor(fg, bg, minRatio)
    local target = tonumber(minRatio) or 4.5
    local cur = { fg[1] or 0.9, fg[2] or 0.9, fg[3] or 0.9, fg[4] or 1 }
    if Draw.ContrastRatio(cur, bg) >= target then
        return cur
    end
    local bgLum = Draw.RelativeLuminance(bg)
    local dir = (bgLum < 0.5) and 0.06 or -0.06
    for _ = 1, 16 do
        cur = Draw.Lighten(cur, dir)
        if Draw.ContrastRatio(cur, bg) >= target then
            return cur
        end
    end
    return (bgLum < 0.5) and { 0.98, 0.96, 0.90, cur[4] } or { 0.05, 0.05, 0.06, cur[4] }
end
