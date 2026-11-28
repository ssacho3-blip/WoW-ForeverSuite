-- Module: UI/NineSlice.lua
-- Responsibility: Manual 9-texture high-DPI 9-slice frame renderer (DialogueUI TextureSlice pattern).
--                 Renders uncompressed 32-bit POT TGA frames with real baked outer drop shadows
--                 (zero SetBackdrop edgeFile smearing, zero taint, instant no-reload theme swapping).
-- Layer: UI
local _, ns = ...
ns.UI = ns.UI or {}

local T = ns.UI.Tokens
local math_max = math.max
local math_min = math.min
local pcall = pcall
local type = type

local NineSlice = {}
ns.UI.NineSlice = NineSlice

local ART_DIR = (_G.ForeverSuiteMedia and type(_G.ForeverSuiteMedia.uiRoot) == "string" and _G.ForeverSuiteMedia.uiRoot)
    or "Interface\\AddOns\\ForeverSuite_Media_Assets\\UI\\"

NineSlice.PRESETS = {
    window_gold = {
        path    = ART_DIR .. "FS-Frame-Gold.tga",
        texW    = 512,
        texH    = 512,
        sliceL  = 160,
        sliceR  = 160,
        sliceT  = 160,
        sliceB  = 160,
        cornerW = 36,
        cornerH = 36,
        shadow  = 10,
        layer   = "BACKGROUND",
        sublevel = -6,
    },
    window_dark = {
        path    = ART_DIR .. "FS-Frame-Dark.tga",
        texW    = 512,
        texH    = 512,
        sliceL  = 160,
        sliceR  = 160,
        sliceT  = 160,
        sliceB  = 160,
        cornerW = 36,
        cornerH = 36,
        shadow  = 10,
        layer   = "BACKGROUND",
        sublevel = -6,
    },
    popup_gold = {
        path    = ART_DIR .. "FS-Frame-Small.tga",
        texW    = 256,
        texH    = 256,
        sliceL  = 80,
        sliceR  = 80,
        sliceT  = 80,
        sliceB  = 80,
        cornerW = 24,
        cornerH = 24,
        shadow  = 6,
        layer   = "BACKGROUND",
        sublevel = -6,
    },
    popup_dark = {
        path    = ART_DIR .. "FS-Frame-Small-Dark.tga",
        texW    = 256,
        texH    = 256,
        sliceL  = 80,
        sliceR  = 80,
        sliceT  = 80,
        sliceB  = 80,
        cornerW = 24,
        cornerH = 24,
        shadow  = 6,
        layer   = "BACKGROUND",
        sublevel = -6,
    },
    button_normal = {
        path    = ART_DIR .. "FS-Button-Normal.tga",
        texW    = 256,
        texH    = 128,
        sliceL  = 32,
        sliceR  = 32,
        sliceT  = 32,
        sliceB  = 32,
        cornerW = 10,
        cornerH = 8,
        shadow  = 0,
        layer   = "BACKGROUND",
        sublevel = -4,
    },
    button_brass = {
        path    = ART_DIR .. "FS-Button-Brass.tga",
        texW    = 256,
        texH    = 128,
        sliceL  = 32,
        sliceR  = 32,
        sliceT  = 32,
        sliceB  = 32,
        cornerW = 10,
        cornerH = 8,
        shadow  = 0,
        layer   = "BACKGROUND",
        sublevel = -4,
    },
    button_crimson = {
        path    = ART_DIR .. "FS-Button-Crimson.tga",
        texW    = 256,
        texH    = 128,
        sliceL  = 32,
        sliceR  = 32,
        sliceT  = 32,
        sliceB  = 32,
        cornerW = 10,
        cornerH = 8,
        shadow  = 0,
        layer   = "BACKGROUND",
        sublevel = -4,
    },
}

local PIECE_KEYS = { "TL", "T", "TR", "L", "C", "R", "BL", "B", "BR" }

local function SafeSetTexCoord(tex, l, r, t, b)
    if tex and type(tex.SetTexCoord) == "function" then
        pcall(tex.SetTexCoord, tex, l, r, t, b)
    end
end

local function SafeSetTexture(tex, path)
    if tex and type(tex.SetTexture) == "function" then
        pcall(tex.SetTexture, tex, path)
    end
end

local function SafeSetVertexColor(tex, r, g, b, a)
    if tex and type(tex.SetVertexColor) == "function" then
        pcall(tex.SetVertexColor, tex, r, g, b, a or 1)
    end
end

function NineSlice.ResolvePreset(presetOrSpec)
    if type(presetOrSpec) == "string" then
        return NineSlice.PRESETS[presetOrSpec] or NineSlice.PRESETS.popup_gold
    end
    if type(presetOrSpec) == "table" then
        return presetOrSpec
    end
    return NineSlice.PRESETS.popup_gold
end

function NineSlice.Apply(frame, presetOrSpec, opts)
    if not frame then
        return nil
    end
    opts = type(opts) == "table" and opts or {}
    local spec = NineSlice.ResolvePreset(presetOrSpec)
    local layer = opts.layer or spec.layer or "BACKGROUND"
    local sublevel = opts.sublevel or spec.sublevel or -6

    local nsObj = frame._fsNineSlice
    if not nsObj then
        nsObj = {
            frame = frame,
            pieces = {},
            spec = spec,
            presetKey = type(presetOrSpec) == "string" and presetOrSpec or nil,
        }
        for i = 1, #PIECE_KEYS do
            local key = PIECE_KEYS[i]
            local tex = frame:CreateTexture(nil, layer, nil, sublevel)
            nsObj.pieces[key] = tex
        end
        frame._fsNineSlice = nsObj
    else
        nsObj.spec = spec
        if type(presetOrSpec) == "string" then
            nsObj.presetKey = presetOrSpec
        end
    end

    local function ConfigurePieces(activeSpec)
        local p = nsObj.pieces
        local texW = activeSpec.texW or 256
        local texH = activeSpec.texH or 256
        local uL = (activeSpec.sliceL or 64) / texW
        local uR = 1 - ((activeSpec.sliceR or 64) / texW)
        local vT = (activeSpec.sliceT or 64) / texH
        local vB = 1 - ((activeSpec.sliceB or 64) / texH)

        local path = activeSpec.path
        for i = 1, #PIECE_KEYS do
            SafeSetTexture(p[PIECE_KEYS[i]], path)
        end

        SafeSetTexCoord(p.TL, 0,  uL, 0,  vT)
        SafeSetTexCoord(p.T,  uL, uR, 0,  vT)
        SafeSetTexCoord(p.TR, uR, 1,  0,  vT)
        SafeSetTexCoord(p.L,  0,  uL, vT, vB)
        SafeSetTexCoord(p.C,  uL, uR, vT, vB)
        SafeSetTexCoord(p.R,  uR, 1,  vT, vB)
        SafeSetTexCoord(p.BL, 0,  uL, vB, 1)
        SafeSetTexCoord(p.B,  uL, uR, vB, 1)
        SafeSetTexCoord(p.BR, uR, 1,  vB, 1)

        local fw = (type(frame.GetWidth) == "function" and frame:GetWidth()) or 0
        local fh = (type(frame.GetHeight) == "function" and frame:GetHeight()) or 0
        local sOff = opts.shadow ~= nil and opts.shadow or (activeSpec.shadow or 0)
        local cw = opts.cornerW or activeSpec.cornerW or 24
        local ch = opts.cornerH or activeSpec.cornerH or 24
        if fw and fw > 0 then
            cw = math_min(cw, math_max(6, (fw + sOff * 2) * 0.45))
        end
        if fh and fh > 0 then
            ch = math_min(ch, math_max(6, (fh + sOff * 2) * 0.45))
        end

        for i = 1, #PIECE_KEYS do
            p[PIECE_KEYS[i]]:ClearAllPoints()
        end

        -- Corners extend outward by sOff so baked outer drop shadow floats cleanly outside content bounds
        p.TL:SetSize(cw, ch)
        p.TL:SetPoint("TOPLEFT", frame, "TOPLEFT", -sOff, sOff)

        p.TR:SetSize(cw, ch)
        p.TR:SetPoint("TOPRIGHT", frame, "TOPRIGHT", sOff, sOff)

        p.BL:SetSize(cw, ch)
        p.BL:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", -sOff, -sOff)

        p.BR:SetSize(cw, ch)
        p.BR:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", sOff, -sOff)

        -- Edges stretch smoothly between corners
        p.T:SetPoint("TOPLEFT", p.TL, "TOPRIGHT", 0, 0)
        p.T:SetPoint("BOTTOMRIGHT", p.TR, "BOTTOMLEFT", 0, 0)

        p.B:SetPoint("TOPLEFT", p.BL, "TOPRIGHT", 0, 0)
        p.B:SetPoint("BOTTOMRIGHT", p.BR, "BOTTOMLEFT", 0, 0)

        p.L:SetPoint("TOPLEFT", p.TL, "BOTTOMLEFT", 0, 0)
        p.L:SetPoint("BOTTOMRIGHT", p.BL, "TOPRIGHT", 0, 0)

        p.R:SetPoint("TOPLEFT", p.TR, "BOTTOMLEFT", 0, 0)
        p.R:SetPoint("BOTTOMRIGHT", p.BR, "TOPRIGHT", 0, 0)

        -- Center fills interior
        p.C:SetPoint("TOPLEFT", p.TL, "BOTTOMRIGHT", 0, 0)
        p.C:SetPoint("BOTTOMRIGHT", p.BR, "TOPLEFT", 0, 0)
    end

    function nsObj:SetPreset(key)
        local nextSpec = NineSlice.ResolvePreset(key)
        self.spec = nextSpec
        if type(key) == "string" then
            self.presetKey = key
        end
        ConfigurePieces(nextSpec)
        return self
    end

    function nsObj:SetTint(r, g, b, a)
        for i = 1, #PIECE_KEYS do
            SafeSetVertexColor(self.pieces[PIECE_KEYS[i]], r, g, b, a or 1)
        end
        return self
    end

    function nsObj:SetAlpha(a)
        for i = 1, #PIECE_KEYS do
            local tex = self.pieces[PIECE_KEYS[i]]
            if tex and type(tex.SetAlpha) == "function" then
                pcall(tex.SetAlpha, tex, a)
            end
        end
        return self
    end

    function nsObj:Layout()
        ConfigurePieces(self.spec)
        return self
    end

    ConfigurePieces(spec)
    if opts.tint then
        nsObj:SetTint(opts.tint[1], opts.tint[2], opts.tint[3], opts.tint[4] or 1)
    end
    if not frame._fsNineSliceHooked and type(frame.HookScript) == "function" then
        frame._fsNineSliceHooked = true
        pcall(frame.HookScript, frame, "OnSizeChanged", function()
            if frame._fsNineSlice then
                frame._fsNineSlice:Layout()
            end
        end)
    end

    return nsObj
end

function NineSlice.WindowPresetForTheme(themeId)
    local active = themeId or (T and T.ACTIVE_THEME) or "gold"
    return (active == "dark") and "window_dark" or "window_gold"
end

function NineSlice.PopupPresetForTheme(themeId)
    local active = themeId or (T and T.ACTIVE_THEME) or "gold"
    return (active == "dark") and "popup_dark" or "popup_gold"
end
