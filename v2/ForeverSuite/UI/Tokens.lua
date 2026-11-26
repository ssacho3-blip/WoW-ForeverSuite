-- Module: UI/Tokens.lua
-- Responsibility: Single Source of Truth design tokens for ForeverSuite v2 ("Obsidian & Burnished Gold").
-- Layer: UI
local _, ns = ...
ns.UI = ns.UI or {}

local math_max = math.max
local math_floor = math.floor

local Tokens = {
    SURFACE = {
        CANVAS = { 0.055, 0.067, 0.090, 0.96 },      -- #0E1117
        SUNKEN = { 0.031, 0.039, 0.059, 0.97 },      -- #080A0F (rail / sunken well)
        CARD = { 0.086, 0.110, 0.153, 0.95 },        -- #161C27
        CARD_ALT = { 0.110, 0.137, 0.192, 0.95 },    -- #1C2331 (zebra row / sub-card)
        ELEVATED = { 0.137, 0.173, 0.239, 0.97 },    -- #232C3D
        HOVER = { 0.173, 0.216, 0.298, 0.98 },       -- #2C374C
        GOLD_TINT = { 0.220, 0.176, 0.063, 0.96 },
        GOLD_ACTIVE = { 0.267, 0.212, 0.078, 0.98 },
    },
    BORDER = {
        HAIRLINE = { 0.180, 0.216, 0.275, 0.92 },    -- #2E3746 (default 1px border)
        SUBTLE = { 0.141, 0.169, 0.216, 0.78 },
        GOLD = { 0.831, 0.686, 0.216, 0.95 },        -- #D4AF37 (accent-only: title, active tab, currency)
        GOLD_SOFT = { 0.831, 0.686, 0.216, 0.45 },
    },
    TEXT = {
        PRIMARY = { 0.929, 0.941, 0.961, 1.00 },     -- #EDF0F5
        SECONDARY = { 0.608, 0.643, 0.706, 1.00 },   -- #9BA4B4
        MUTED = { 0.392, 0.439, 0.518, 1.00 },       -- #647084
        GOLD = { 0.953, 0.824, 0.369, 1.00 },
    },
    SEMANTIC = {
        SUCCESS = { 0.290, 0.871, 0.502, 1.00 },     -- #4ADE80
        INFO = { 0.376, 0.647, 0.980, 1.00 },        -- #60A5FA
        WARN = { 0.984, 0.749, 0.141, 1.00 },        -- #FBBF24
        DANGER = { 0.973, 0.443, 0.443, 1.00 },      -- #F87171
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
ns.UI.Tokens = Tokens

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
