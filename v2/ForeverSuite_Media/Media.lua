-- Module: ForeverSuite_Media/Media.lua
-- Responsibility: Registers unified ForeverSuite v5.0 typography objects (FS_Font_*) and verified Art Kit paths.
--                 Zero nonexistent paths (replaces dead GoldChrome512.blp with verified UI/*.tga registry).
local _, ns = ...

local BASE_FONT = "Fonts\\2002.TTF"
-- Must support Korean Hangul glyphs (Fonts\ARIALN.TTF has 0 Hangul glyphs and renders Korean as tofu boxes!)
local MONO_FONT = "Fonts\\2002.TTF"

local function ResolveMediaRoot()
    if _G.C_AddOns and type(_G.C_AddOns.DoesAddOnExist) == "function" then
        local ok, exists = pcall(_G.C_AddOns.DoesAddOnExist, "ForeverSuite_Media_Assets")
        if ok and exists == false then
            return "Interface\\AddOns\\ForeverSuite_Media\\"
        end
    end
    return "Interface\\AddOns\\ForeverSuite_Media_Assets\\"
end

local MEDIA_ROOT = ResolveMediaRoot()
local UI_ROOT = MEDIA_ROOT .. "UI\\"
local ICON_ROOT = MEDIA_ROOT .. "Icons\\"

local Media = {
    version = "6.4.0",
    fonts = {
        bodyPath = BASE_FONT,
        monoPath = MONO_FONT,
    },
    mediaRoot = MEDIA_ROOT,
    uiRoot = UI_ROOT,
    iconRoot = ICON_ROOT,
    atlas = {
        frameGold = UI_ROOT .. "FS-Frame-Gold.tga",
        frameDark = UI_ROOT .. "FS-Frame-Dark.tga",
        frameSmall = UI_ROOT .. "FS-Frame-Small.tga",
        frameSmallDark = UI_ROOT .. "FS-Frame-Small-Dark.tga",
        roundDisc = UI_ROOT .. "FS-Round.tga",
        softInk = UI_ROOT .. "FS-SoftInk.tga",
        buttonNormal = UI_ROOT .. "FS-Button-Normal.tga",
        buttonBrass = UI_ROOT .. "FS-Button-Brass.tga",
        buttonCrimson = UI_ROOT .. "FS-Button-Crimson.tga",
        statusFill = UI_ROOT .. "FS-StatusBar-Fill.tga",
        statusGroove = UI_ROOT .. "FS-StatusBar-Groove.tga",
        statusBorder = UI_ROOT .. "FS-StatusBar-Border.tga",
        iconRing = UI_ROOT .. "FS-IconRing.tga",
        scrimRadial = UI_ROOT .. "FS-Scrim-Radial.tga",
        gemLit = UI_ROOT .. "FS-Gem-Lit.tga",
        gemEmpty = UI_ROOT .. "FS-Gem-Empty.tga",
        gemGlow = UI_ROOT .. "FS-Gem-Glow.tga",
        zoneRibbon = UI_ROOT .. "FS-ZoneRibbon.tga",
        fallbackSolid = "Interface\\Buttons\\WHITE8X8",
    },
}

local function EnsureFont(name, path, size, flags)
    if type(_G.CreateFont) ~= "function" then
        return nil
    end
    local f = _G[name] or _G.CreateFont(name)
    if f and type(f.SetFont) == "function" then
        local ok, ret = pcall(f.SetFont, f, path, size, flags or "")
        if (not ok) or ret == false then
            pcall(f.SetFont, f, BASE_FONT, size, flags or "")
        end
    end
    return f
end

Media.fontObjects = {
    title = EnsureFont("FS_Font_Title", BASE_FONT, 18, "OUTLINE"),
    heading = EnsureFont("FS_Font_Heading", BASE_FONT, 15, ""),
    body = EnsureFont("FS_Font_Body", BASE_FONT, 13, ""),
    small = EnsureFont("FS_Font_Small", BASE_FONT, 11, ""),
    mono = EnsureFont("FS_Font_Mono", MONO_FONT, 12, ""),
}

_G.ForeverSuiteMedia = Media
ns.Media = Media
