-- Module: UI/Tokens.lua
-- Responsibility: Single Source of Truth design tokens for ForeverSuite v6.1.0
--                 2 Skins ("Forever Gold" default + "Midnight Dark" secondary), live textureBrightness (0.35..1.0)
--                 & goldBrightness (0.40..1.0) multipliers, 5-step Korean typography + SetSpacing(3/2),
--                 4px grid, white-alpha interaction overlays (6%/12%/18%), and weak-key 1-pass surface registry.
-- Layer: UI (L1 pure tokens; zero CreateFrame; zero ProfileStore import).
local _, ns = ...
ns.UI = ns.UI or {}

local math_max = math.max
local math_min = math.min
local math_floor = math.floor
local pairs = pairs
local ipairs = ipairs
local pcall = pcall
local type = type
local setmetatable = setmetatable

local UI_ART_DIR = "Interface\\AddOns\\ForeverSuite_Media_Assets\\UI\\"

local DEFAULT_TEXTURE_BRIGHTNESS = 0.78
local DEFAULT_GOLD_BRIGHTNESS = 0.88

local THEME_PALETTES = {
    gold = {
        id = "gold",
        label = "Forever Gold",
        SURFACE = {
            CANVAS      = { 0.047, 0.043, 0.055, 0.97 },
            SUNKEN      = { 0.027, 0.025, 0.033, 0.97 },
            QUIET       = { 0.055, 0.050, 0.062, 0.88 },
            CARD        = { 0.072, 0.066, 0.078, 0.94 },
            CARD_ALT    = { 0.090, 0.082, 0.094, 0.95 },
            ELEVATED    = { 0.102, 0.092, 0.098, 0.96 },
            HOVER       = { 0.228, 0.180, 0.104, 0.98 },
            GOLD_TINT   = { 0.255, 0.188, 0.070, 0.96 },
            GOLD_ACTIVE = { 0.314, 0.231, 0.082, 0.98 },
            HEADER      = { 0.118, 0.095, 0.068, 0.96 },
            HUD_GLASS   = { 0.045, 0.041, 0.052, 0.64 },
            HUD_SCRIM   = { 0.032, 0.030, 0.038, 0.24 },
            INK_TINT    = { 0.165, 0.148, 0.138, 0.26 },
        },
        BORDER = {
            HAIRLINE    = { 0.355, 0.286, 0.162, 0.82 },
            SUBTLE      = { 0.235, 0.192, 0.122, 0.62 },
            GOLD        = { 0.855, 0.694, 0.255, 0.96 },
            GOLD_SOFT   = { 0.620, 0.490, 0.205, 0.74 },
            HUD_GLASS   = { 0.390, 0.312, 0.172, 0.52 },
            THUMB_IDLE  = { 0.470, 0.372, 0.205, 0.88 },
        },
        TEXT = {
            PRIMARY     = { 0.945, 0.918, 0.855, 1.00 },
            SECONDARY   = { 0.725, 0.694, 0.631, 1.00 },
            MUTED       = { 0.520, 0.495, 0.450, 1.00 },
            GOLD        = { 0.980, 0.910, 0.620, 1.00 },
        },
    },
    dark = {
        id = "dark",
        label = "Midnight Dark",
        SURFACE = {
            CANVAS      = { 0.043, 0.049, 0.063, 0.97 },
            SUNKEN      = { 0.025, 0.029, 0.039, 0.97 },
            QUIET       = { 0.055, 0.063, 0.078, 0.88 },
            CARD        = { 0.068, 0.076, 0.092, 0.94 },
            CARD_ALT    = { 0.086, 0.096, 0.114, 0.95 },
            ELEVATED    = { 0.096, 0.106, 0.124, 0.96 },
            HOVER       = { 0.176, 0.204, 0.255, 0.98 },
            GOLD_TINT   = { 0.165, 0.208, 0.275, 0.96 },
            GOLD_ACTIVE = { 0.204, 0.255, 0.337, 0.98 },
            HEADER      = { 0.072, 0.082, 0.102, 0.96 },
            HUD_GLASS   = { 0.039, 0.045, 0.058, 0.64 },
            HUD_SCRIM   = { 0.028, 0.032, 0.042, 0.22 },
            INK_TINT    = { 0.135, 0.155, 0.188, 0.22 },
        },
        BORDER = {
            HAIRLINE    = { 0.245, 0.285, 0.355, 0.80 },
            SUBTLE      = { 0.170, 0.198, 0.248, 0.62 },
            GOLD        = { 0.820, 0.700, 0.360, 0.94 },
            GOLD_SOFT   = { 0.490, 0.450, 0.310, 0.72 },
            HUD_GLASS   = { 0.275, 0.320, 0.400, 0.50 },
            THUMB_IDLE  = { 0.330, 0.378, 0.455, 0.86 },
        },
        TEXT = {
            PRIMARY     = { 0.925, 0.941, 0.969, 1.00 },
            SECONDARY   = { 0.690, 0.728, 0.790, 1.00 },
            MUTED       = { 0.500, 0.535, 0.595, 1.00 },
            GOLD        = { 0.965, 0.882, 0.580, 1.00 },
        },
    },
}

local function ClampFinite(v, lo, hi, fallback)
    if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
        return fallback
    end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function ScaleColor(dst, src, mult, floorR, floorG, floorB)
    for k, col in pairs(src) do
        local m = mult
        if k == "HUD_SCRIM" or k == "HUD_GLASS" then
            m = 1.0
        end
        local r = math_min(1.0, math_max(floorR or 0, col[1] * m))
        local g = math_min(1.0, math_max(floorG or 0, col[2] * m))
        local b = math_min(1.0, math_max(floorB or 0, col[3] * m))
        if type(dst[k]) ~= "table" then
            dst[k] = { r, g, b, col[4] }
        else
            dst[k][1], dst[k][2], dst[k][3], dst[k][4] = r, g, b, col[4]
        end
    end
end

local Tokens = {
    ACTIVE_THEME = "gold",
    THEMES = THEME_PALETTES,
    DEFAULT_TEXTURE_BRIGHTNESS = DEFAULT_TEXTURE_BRIGHTNESS,
    DEFAULT_GOLD_BRIGHTNESS = DEFAULT_GOLD_BRIGHTNESS,
    TEXTURE_BRIGHTNESS = DEFAULT_TEXTURE_BRIGHTNESS,
    GOLD_BRIGHTNESS = DEFAULT_GOLD_BRIGHTNESS,
    _themeListeners = {},
    _surfaces = setmetatable({}, { __mode = "k" }),
    SURFACE = {},
    BORDER = {},
    TEXT = {},
    OVERLAY = {
        HOVER    = 0.06,
        SELECTED = 0.12,
        PRESSED  = 0.18,
    },
    SPACING = {
        BODY  = 3,
        TITLE = 2,
    },
    RADIUS = {
        PANEL  = 6,
        BUTTON = 4,
        PILL   = 11,
    },
    TYPO = {
        CAPTION = 10,
        SMALL   = 12,
        BODY    = 13,
        HEADING = 15,
        TITLE   = 18,
    },
    UI_ART = {
        frameGold       = UI_ART_DIR .. "FS-Frame-Gold.tga",
        frameDark       = UI_ART_DIR .. "FS-Frame-Dark.tga",
        frameSmall      = UI_ART_DIR .. "FS-Frame-Small.tga",
        frameSmallDark  = UI_ART_DIR .. "FS-Frame-Small-Dark.tga",
        roundDisc       = UI_ART_DIR .. "FS-Round.tga",
        softInk         = UI_ART_DIR .. "FS-SoftInk.tga",
        buttonNormal    = UI_ART_DIR .. "FS-Button-Normal.tga",
        buttonBrass     = UI_ART_DIR .. "FS-Button-Brass.tga",
        buttonCrimson   = UI_ART_DIR .. "FS-Button-Crimson.tga",
        statusFill      = UI_ART_DIR .. "FS-StatusBar-Fill.tga",
        statusGroove    = UI_ART_DIR .. "FS-StatusBar-Groove.tga",
        statusBorder    = UI_ART_DIR .. "FS-StatusBar-Border.tga",
        iconRing        = UI_ART_DIR .. "FS-IconRing.tga",
        scrimRadial     = UI_ART_DIR .. "FS-Scrim-Radial.tga",
        gemLit          = UI_ART_DIR .. "FS-Gem-Lit.tga",
        gemEmpty        = UI_ART_DIR .. "FS-Gem-Empty.tga",
        gemGlow         = UI_ART_DIR .. "FS-Gem-Glow.tga",
        zoneRibbon      = UI_ART_DIR .. "FS-ZoneRibbon.tga",
    },
    MEDIA = {
        STATUSBAR      = UI_ART_DIR .. "FS-StatusBar-Fill.tga",
        STATUSBAR_BLIZ = "Interface\\TargetingFrame\\UI-StatusBar",
        DIALOG_BG      = "Interface\\DialogFrame\\UI-DialogBox-Background",
        GOLD_BORDER    = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
        MINIMAP_RING   = "Interface\\Minimap\\MiniMap-TrackingBorder",
        PORTRAIT_MASK  = "Interface\\CharacterFrame\\TempPortraitAlphaMask",
        CHECKMARK      = "Interface\\Buttons\\UI-CheckBox-Check",
        SEARCH_ICON    = "Interface\\Common\\UI-Searchbox-Icon",
        WHITE          = "Interface\\Buttons\\WHITE8X8",
    },
    SEMANTIC = {
        SUCCESS = { 0.290, 0.871, 0.502, 1.00 },
        INFO    = { 0.376, 0.647, 0.980, 1.00 },
        WARN    = { 0.984, 0.749, 0.141, 1.00 },
        DANGER  = { 0.973, 0.443, 0.443, 1.00 },
    },
    QUALITY = {
        [0] = { 0.616, 0.616, 0.616, 1.00 },
        [1] = { 0.929, 0.941, 0.961, 1.00 },
        [2] = { 0.118, 1.000, 0.000, 1.00 },
        [3] = { 0.220, 0.600, 0.980, 1.00 },
        [4] = { 0.722, 0.341, 0.961, 1.00 },
        [5] = { 1.000, 0.502, 0.000, 1.00 },
    },
    CLASS_COLORS = {
        WARRIOR = { 0.78, 0.61, 0.43, 1.00 },
        PALADIN = { 0.96, 0.55, 0.73, 1.00 },
        HUNTER  = { 0.67, 0.83, 0.45, 1.00 },
        ROGUE   = { 1.00, 0.96, 0.41, 1.00 },
        PRIEST  = { 0.95, 0.95, 0.98, 1.00 },
        SHAMAN  = { 0.00, 0.44, 0.87, 1.00 },
        MAGE    = { 0.41, 0.80, 0.94, 1.00 },
        WARLOCK = { 0.58, 0.51, 0.79, 1.00 },
        DRUID   = { 1.00, 0.49, 0.04, 1.00 },
    },
    ICON = {
        XS = 16,
        SM = 20,
        MD = 26,
        LG = 34,
        TRIM = { 0.08, 0.92, 0.08, 0.92 },
        FALLBACK = "Interface\\Icons\\INV_Misc_QuestionMark",
        CLASS_TEX = {
            WARRIOR = "Interface\\Icons\\ClassIcon_Warrior",
            PALADIN = "Interface\\Icons\\ClassIcon_Paladin",
            HUNTER  = "Interface\\Icons\\ClassIcon_Hunter",
            ROGUE   = "Interface\\Icons\\ClassIcon_Rogue",
            PRIEST  = "Interface\\Icons\\ClassIcon_Priest",
            SHAMAN  = "Interface\\Icons\\ClassIcon_Shaman",
            MAGE    = "Interface\\Icons\\ClassIcon_Mage",
            WARLOCK = "Interface\\Icons\\ClassIcon_Warlock",
            DRUID   = "Interface\\Icons\\ClassIcon_Druid",
        },
        PROF_TEX = {
            ["대장기술"] = "Interface\\Icons\\Trade_BlackSmithing",
            ["연금술"] = "Interface\\Icons\\Trade_Alchemy",
            ["기계공학"] = "Interface\\Icons\\Trade_Engineering",
            ["마법부여"] = "Interface\\Icons\\Trade_Engraving",
            ["가죽세공"] = "Interface\\Icons\\Trade_LeatherWorking",
            ["재봉술"] = "Interface\\Icons\\Trade_Tailoring",
            ["약초채집"] = "Interface\\Icons\\Trade_Herbalism",
            ["채광"] = "Interface\\Icons\\Trade_Mining",
            ["무두질"] = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01",
            ["요리"] = "Interface\\Icons\\INV_Misc_Food_15",
            ["응급치료"] = "Interface\\Icons\\Spell_Holy_SealOfSacrifice",
            ["낚시"] = "Interface\\Icons\\Trade_Fishing",
            ["보석세공"] = "Interface\\Icons\\INV_Misc_Gem_01",
        },
    },
    SPACE = {
        XS = 4,
        SM = 8,
        MD = 12,
        LG = 16,
        XL = 24,
    },
    ELEVATION = {
        L0_HUD = "LOW",
        L1_CARD = "MEDIUM",
        L1_PANEL = "MEDIUM",
        L2_HUB = "DIALOG",
        L2_WORKSPACE = "DIALOG",
        L3_OVERLAY = "FULLSCREEN_DIALOG",
    },
}

function Tokens.ClampTextureBrightness(v)
    return ClampFinite(v, 0.35, 1.00, DEFAULT_TEXTURE_BRIGHTNESS)
end

function Tokens.ClampGoldBrightness(v)
    return ClampFinite(v, 0.40, 1.00, DEFAULT_GOLD_BRIGHTNESS)
end

local function RecomputeActivePalette()
    local key = (Tokens.ACTIVE_THEME == "dark") and "dark" or "gold"
    local pal = THEME_PALETTES[key] or THEME_PALETTES.gold
    -- Surface brightness scales subtly relative to default 0.78 (range ~0.72x .. 1.18x) so low brightness never crushes dark UI
    local texScale = 0.72 + ((Tokens.TEXTURE_BRIGHTNESS - 0.35) / 0.65) * 0.46
    -- Gold brightness scales border accents while keeping TEXT.GOLD strictly above 7:1 WCAG AAA contrast
    local goldScale = 0.78 + ((Tokens.GOLD_BRIGHTNESS - 0.40) / 0.60) * 0.28
    ScaleColor(Tokens.SURFACE, pal.SURFACE, texScale, 0.015, 0.015, 0.020)
    ScaleColor(Tokens.BORDER,  pal.BORDER,  goldScale, 0.14, 0.11, 0.07)
    ScaleColor(Tokens.TEXT,    pal.TEXT,    1.0, 0, 0, 0)
    -- Apply gentle gold warmth scaling to TEXT.GOLD with hard luminance floor so composited contrast >= 7:1 even under 18% pressed overlay
    local gBase = pal.TEXT.GOLD
    local gTextScale = 0.94 + ((Tokens.GOLD_BRIGHTNESS - 0.40) / 0.60) * 0.06
    Tokens.TEXT.GOLD[1] = math_min(1.0, math_max(0.96, gBase[1] * gTextScale))
    Tokens.TEXT.GOLD[2] = math_min(1.0, math_max(0.90, gBase[2] * gTextScale))
    Tokens.TEXT.GOLD[3] = math_min(1.0, math_max(0.60, gBase[3] * gTextScale))
    Tokens.TEXT.GOLD[4] = 1.0
    return key, pal
end

RecomputeActivePalette()
ns.UI.Tokens = Tokens

function Tokens.RegisterSurface(frame, applyFn)
    if type(frame) ~= "table" or type(applyFn) ~= "function" then
        return false
    end
    Tokens._surfaces[frame] = applyFn
    return true
end

function Tokens.UnregisterSurface(frame)
    if frame ~= nil then
        Tokens._surfaces[frame] = nil
    end
end

function Tokens.RefreshSurfaces()
    local count = 0
    local key = Tokens.ACTIVE_THEME or "gold"
    local pal = THEME_PALETTES[key] or THEME_PALETTES.gold
    for frame, applyFn in pairs(Tokens._surfaces) do
        if type(applyFn) == "function" then
            count = count + 1
            pcall(applyFn, frame, key, pal)
        end
    end
    return count
end

function Tokens.RegisterThemeListener(fn)
    if type(fn) ~= "function" then return end
    for i = 1, #Tokens._themeListeners do
        if Tokens._themeListeners[i] == fn then
            return
        end
    end
    Tokens._themeListeners[#Tokens._themeListeners + 1] = fn
end

function Tokens.GetTheme()
    return Tokens.ACTIVE_THEME or "gold"
end

function Tokens.SetBrightness(texBrightness, goldBrightness)
    if texBrightness ~= nil then
        Tokens.TEXTURE_BRIGHTNESS = Tokens.ClampTextureBrightness(texBrightness)
    end
    if goldBrightness ~= nil then
        Tokens.GOLD_BRIGHTNESS = Tokens.ClampGoldBrightness(goldBrightness)
    end
    local key, pal = RecomputeActivePalette()
    for _, fn in ipairs(Tokens._themeListeners) do
        pcall(fn, key, pal)
    end
    Tokens.RefreshSurfaces()
    return Tokens.TEXTURE_BRIGHTNESS, Tokens.GOLD_BRIGHTNESS
end

function Tokens.SetTheme(themeId)
    local key = (themeId == "dark") and "dark" or "gold"
    Tokens.ACTIVE_THEME = key
    local activeKey, pal = RecomputeActivePalette()
    for _, fn in ipairs(Tokens._themeListeners) do
        pcall(fn, activeKey, pal)
    end
    Tokens.RefreshSurfaces()
    return activeKey
end

function Tokens.TrySetAtlas(tex, atlasName, useAtlasSize)
    if not (tex and type(atlasName) == "string" and atlasName ~= "") then
        return false
    end
    if type(tex.SetAtlas) ~= "function" then
        return false
    end
    local ok = pcall(tex.SetAtlas, tex, atlasName, useAtlasSize == true)
    if not ok then
        return false
    end
    if type(tex.GetAtlas) == "function" then
        local okG, cur = pcall(tex.GetAtlas, tex)
        return okG and cur == atlasName
    end
    return true
end

function Tokens.PixelSize(frame, logicalPx)
    if ns.UI and ns.UI.PixelUtil and type(ns.UI.PixelUtil.Snap) == "function" then
        return ns.UI.PixelUtil.Snap(frame, logicalPx)
    end
    local px = logicalPx or 1
    local scale = 1.0
    if frame and type(frame.GetEffectiveScale) == "function" then
        local ok, s = pcall(frame.GetEffectiveScale, frame)
        if ok and type(s) == "number" and s > 0 then
            scale = s
        end
    end
    local unit = 1 / scale
    return math_max(unit, math_floor((px / unit) + 0.5) * unit)
end

function Tokens.GetFont(role)
    local map = {
        title = "FS_Font_Title",
        heading = "FS_Font_Heading",
        body = "FS_Font_Body",
        small = "FS_Font_Small",
        mono = "FS_Font_Mono",
    }
    local preferred = map[role] or "FS_Font_Body"
    if _G[preferred] then
        return preferred
    end
    if role == "title" then return "GameFontNormalLarge" end
    if role == "heading" then return "GameFontNormal" end
    return "GameFontHighlightSmall"
end
