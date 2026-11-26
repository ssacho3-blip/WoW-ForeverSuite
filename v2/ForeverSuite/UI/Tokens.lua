-- Module: UI/Tokens.lua
-- Responsibility: Single Source of Truth design tokens for ForeverSuite v5.0
--                 ("Classic Gold RPG" default + instant no-reload "Clean Dark Minimal" switcher).
--                 REA-aligned with GodJohnsonGoldBorder 5.312, DialogueUI, ElvUI, Details!, and Baganator.
-- Layer: UI
local _, ns = ...
ns.UI = ns.UI or {}

local math_max = math.max
local math_floor = math.floor
local pairs = pairs
local ipairs = ipairs
local pcall = pcall

local UI_ART_DIR = "Interface\\AddOns\\ForeverSuite_Media_Assets\\UI\\"

local THEME_PALETTES = {
    gold = {
        id = "gold",
        label = "클래식 골드 RPG",
        SURFACE = {
            CANVAS      = { 0.047, 0.043, 0.055, 0.97 }, -- #0C0B0E Warm Azeroth Obsidian
            SUNKEN      = { 0.027, 0.025, 0.033, 0.97 }, -- #070608 Recessed rail / track well
            QUIET       = { 0.055, 0.050, 0.062, 0.86 }, -- #0E0D10 Quiet recessed section
            CARD        = { 0.078, 0.071, 0.084, 0.92 }, -- #141215 L1 flat card (no puffy border)
            CARD_ALT    = { 0.104, 0.094, 0.108, 0.94 }, -- #1B181C Zebra / sub-card
            ELEVATED    = { 0.138, 0.122, 0.128, 0.96 }, -- #231F21 Forged metal button surface
            HOVER       = { 0.228, 0.180, 0.104, 0.98 }, -- #3A2E1B Warm antique bronze hover glow
            GOLD_TINT   = { 0.255, 0.188, 0.070, 0.96 }, -- #413012 Burnished gold active surface
            GOLD_ACTIVE = { 0.314, 0.231, 0.082, 0.98 },
            HEADER      = { 0.118, 0.095, 0.068, 0.96 }, -- Warm sculpted bronze-obsidian header
            HUD_GLASS   = { 0.045, 0.041, 0.052, 0.60 }, -- Translucent dark glass HUD
            HUD_SCRIM   = { 0.032, 0.030, 0.038, 0.24 }, -- Airy transparent quest tracker scrim
        },
        BORDER = {
            HAIRLINE    = { 0.355, 0.286, 0.162, 0.82 }, -- #5B4929 Antique bronze hairline
            SUBTLE      = { 0.235, 0.192, 0.122, 0.62 }, -- Soft warm bronze divider
            GOLD        = { 0.855, 0.694, 0.255, 0.96 }, -- #DAB141 Burnished gold accent
            GOLD_SOFT   = { 0.620, 0.490, 0.205, 0.72 },
            HUD_GLASS   = { 0.390, 0.312, 0.172, 0.50 }, -- Featherweight bronze glass rim
            THUMB_IDLE  = { 0.470, 0.372, 0.205, 0.88 }, -- Warm antique bronze scrollbar thumb
        },
        TEXT = {
            PRIMARY     = { 0.945, 0.918, 0.855, 1.00 }, -- #F1EADA Warm parchment ivory (DialogueUI)
            SECONDARY   = { 0.706, 0.675, 0.612, 1.00 }, -- #B4AC9C Warm muted parchment
            MUTED       = { 0.486, 0.463, 0.420, 1.00 }, -- #7C766B
            GOLD        = { 0.980, 0.910, 0.620, 1.00 }, -- #FAE89E Refined DialogueUI warm gold
        },
    },
    dark = {
        id = "dark",
        label = "클린 다크 미니멀",
        SURFACE = {
            CANVAS      = { 0.043, 0.049, 0.063, 0.97 }, -- #0B0D10 Clean Dark Graphite (ElvUI/ToxiUI)
            SUNKEN      = { 0.025, 0.029, 0.039, 0.97 }, -- #06070A Deep recessed well
            QUIET       = { 0.055, 0.063, 0.078, 0.88 }, -- #0E1014 Quiet dark panel
            CARD        = { 0.075, 0.084, 0.102, 0.93 }, -- #13151A Clean graphite card
            CARD_ALT    = { 0.098, 0.110, 0.133, 0.94 }, -- #191C22
            ELEVATED    = { 0.125, 0.141, 0.172, 0.96 }, -- #20242C Brushed slate button
            HOVER       = { 0.176, 0.204, 0.255, 0.98 }, -- #2D3441 Cool steel hover
            GOLD_TINT   = { 0.165, 0.208, 0.275, 0.96 }, -- #2A3546 Refined slate-accent active
            GOLD_ACTIVE = { 0.204, 0.255, 0.337, 0.98 },
            HEADER      = { 0.072, 0.082, 0.102, 0.96 }, -- Sleek dark header bar
            HUD_GLASS   = { 0.039, 0.045, 0.058, 0.60 }, -- Translucent graphite HUD
            HUD_SCRIM   = { 0.028, 0.032, 0.042, 0.22 }, -- Airy dark tracker scrim
        },
        BORDER = {
            HAIRLINE    = { 0.245, 0.285, 0.355, 0.80 }, -- #3F495B Brushed slate hairline
            SUBTLE      = { 0.170, 0.198, 0.248, 0.62 },
            GOLD        = { 0.820, 0.700, 0.360, 0.94 }, -- Restrained champagne-gold focus accent
            GOLD_SOFT   = { 0.490, 0.450, 0.310, 0.72 },
            HUD_GLASS   = { 0.275, 0.320, 0.400, 0.50 },
            THUMB_IDLE  = { 0.330, 0.378, 0.455, 0.86 }, -- Brushed steel scrollbar thumb
        },
        TEXT = {
            PRIMARY     = { 0.925, 0.941, 0.969, 1.00 }, -- #ECF0F7 Crisp ivory-white
            SECONDARY   = { 0.667, 0.706, 0.769, 1.00 }, -- #AAB4C4
            MUTED       = { 0.459, 0.494, 0.557, 1.00 }, -- #757E8E
            GOLD        = { 0.965, 0.882, 0.580, 1.00 }, -- #F6E194 Soft champagne gold
        },
    },
}

local function DeepCopyColorTable(dst, src)
    for k, col in pairs(src) do
        if type(dst[k]) ~= "table" then
            dst[k] = { col[1], col[2], col[3], col[4] }
        else
            dst[k][1] = col[1]
            dst[k][2] = col[2]
            dst[k][3] = col[3]
            dst[k][4] = col[4]
        end
    end
end

local Tokens = {
    ACTIVE_THEME = "gold",
    THEMES = THEME_PALETTES,
    _themeListeners = {},
    SURFACE = {},
    BORDER = {},
    TEXT = {},
    UI_ART = {
        frameGold       = UI_ART_DIR .. "FS-Frame-Gold.tga",
        frameDark       = UI_ART_DIR .. "FS-Frame-Dark.tga",
        frameSmall      = UI_ART_DIR .. "FS-Frame-Small.tga",
        frameSmallDark  = UI_ART_DIR .. "FS-Frame-Small-Dark.tga",
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
        SUCCESS = { 0.290, 0.871, 0.502, 1.00 },     -- #4ADE80
        INFO    = { 0.376, 0.647, 0.980, 1.00 },     -- #60A5FA
        WARN    = { 0.984, 0.749, 0.141, 1.00 },     -- #FBBF24
        DANGER  = { 0.973, 0.443, 0.443, 1.00 },     -- #F87171
    },
    QUALITY = {
        [0] = { 0.616, 0.616, 0.616, 1.00 },         -- Poor (Gray)
        [1] = { 0.929, 0.941, 0.961, 1.00 },         -- Common (White)
        [2] = { 0.118, 1.000, 0.000, 1.00 },         -- Uncommon (Green)
        [3] = { 0.220, 0.600, 0.980, 1.00 },         -- Rare (Blue)
        [4] = { 0.722, 0.341, 0.961, 1.00 },         -- Epic (Purple)
        [5] = { 1.000, 0.502, 0.000, 1.00 },         -- Legendary (Orange)
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
        L3_OVERLAY = "FULLSCREEN_DIALOG",
    },
}

-- Seed default theme tables in-place
DeepCopyColorTable(Tokens.SURFACE, THEME_PALETTES.gold.SURFACE)
DeepCopyColorTable(Tokens.BORDER,  THEME_PALETTES.gold.BORDER)
DeepCopyColorTable(Tokens.TEXT,    THEME_PALETTES.gold.TEXT)

ns.UI.Tokens = Tokens

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

function Tokens.SetTheme(themeId)
    local key = (themeId == "dark") and "dark" or "gold"
    local pal = THEME_PALETTES[key] or THEME_PALETTES.gold
    Tokens.ACTIVE_THEME = key
    DeepCopyColorTable(Tokens.SURFACE, pal.SURFACE)
    DeepCopyColorTable(Tokens.BORDER,  pal.BORDER)
    DeepCopyColorTable(Tokens.TEXT,    pal.TEXT)
    for _, fn in ipairs(Tokens._themeListeners) do
        pcall(fn, key, pal)
    end
    return key
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
