-- Module: UI/Tokens.lua
-- Responsibility: Single Source of Truth design tokens for ForeverSuite v2 ("Obsidian & Burnished Gold").
-- Layer: UI
local _, ns = ...
ns.UI = ns.UI or {}

local math_max = math.max
local math_floor = math.floor

local Tokens = {
    SURFACE = {
        CANVAS = { 0.055, 0.067, 0.090, 0.94 },   -- #0E1117
        CARD = { 0.086, 0.106, 0.141, 0.92 },     -- #161B24
        ELEVATED = { 0.118, 0.145, 0.196, 0.96 }, -- #1E2532
        HOVER = { 0.153, 0.188, 0.251, 0.98 },    -- #273040
        GOLD_TINT = { 0.220, 0.176, 0.063, 0.96 },
    },
    BORDER = {
        HAIRLINE = { 0.180, 0.216, 0.275, 0.92 }, -- #2E3746 (default 1px border)
        SUBTLE = { 0.141, 0.169, 0.216, 0.78 },
        GOLD = { 0.831, 0.686, 0.216, 0.95 },     -- #D4AF37 (accent-only: title, active tab, currency)
        GOLD_SOFT = { 0.831, 0.686, 0.216, 0.45 },
    },
    TEXT = {
        PRIMARY = { 0.929, 0.941, 0.961, 1.00 },   -- #EDF0F5
        SECONDARY = { 0.608, 0.643, 0.706, 1.00 }, -- #9BA4B4
        MUTED = { 0.392, 0.439, 0.518, 1.00 },     -- #647084
        GOLD = { 0.953, 0.824, 0.369, 1.00 },
    },
    SEMANTIC = {
        SUCCESS = { 0.290, 0.871, 0.502, 1.00 }, -- #4ADE80
        INFO = { 0.376, 0.647, 0.980, 1.00 },    -- #60A5FA
        WARN = { 0.984, 0.749, 0.141, 1.00 },    -- #FBBF24
        DANGER = { 0.973, 0.443, 0.443, 1.00 },  -- #F87171
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
        L2_HUB = "DIALOG",
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
