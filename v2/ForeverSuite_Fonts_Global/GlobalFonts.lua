-- Module: ForeverSuite_Fonts_Global/GlobalFonts.lua
-- Responsibility: Opt-in WoW Forever 1.60.1 global world/damage/chat Korean font & combat-text scale applicator.
--                 Defaults to disabled (enabled=false) until explicitly enabled in ForeverSuite /fs -> FontsPage.
--                 Applies strictly OOC (never touches combat-protected frames).
local _, ns = ...

local ASSET_ROOT = "Interface\\AddOns\\ForeverSuite_Media_Assets\\Fonts\\"

local FONT_FILES = {
    default_blizz = "Fonts\\2002.TTF",
    gmarket       = ASSET_ROOT .. "GmarketSansTTFBold.ttf",
    gyeonggi      = ASSET_ROOT .. "GyeonggiTitle-Bold.ttf",
    gothic_a1     = ASSET_ROOT .. "GothicA1-Black.ttf",
    dnf_blade     = ASSET_ROOT .. "DNFForgedBlade-Bold.ttf",
    dnf_bitbit    = ASSET_ROOT .. "DNFBitBitv2.ttf",
    galmuri11     = ASSET_ROOT .. "Galmuri11-Bold.ttf",
    kcc_ganpan    = ASSET_ROOT .. "KCC-Ganpan.ttf",
    levelup       = ASSET_ROOT .. "LevelUp-BoldItalic.ttf",
    font01        = ASSET_ROOT .. "font01.ttf",
    font03        = ASSET_ROOT .. "font03.ttf",
    font04        = ASSET_ROOT .. "font04.ttf",
    font05        = ASSET_ROOT .. "font05.ttf",
    font10        = ASSET_ROOT .. "font10.ttf",
    font21        = ASSET_ROOT .. "font21.ttf",
    font32        = ASSET_ROOT .. "font32.ttf",
    font36        = ASSET_ROOT .. "font36.ttf",
    font39        = ASSET_ROOT .. "font39.ttf",
    font47        = ASSET_ROOT .. "font47.ttf",
}

local FONT_LABELS = {
    { id = "default_blizz", label = "블리자드 기본 (2002)" },
    { id = "gmarket",       label = "지마켓 산스 Bold" },
    { id = "gyeonggi",      label = "경기천년제목 Bold" },
    { id = "gothic_a1",     label = "고딕 A1 Black" },
    { id = "dnf_blade",     label = "던파 포지드블레이드" },
    { id = "dnf_bitbit",    label = "던파 비트비트 v2" },
    { id = "galmuri11",     label = "갈무리 11 Bold" },
    { id = "kcc_ganpan",    label = "KCC 간판체" },
    { id = "levelup",       label = "레벨업 볼드 이탤릭" },
    { id = "font01",        label = "커스텀 폰트 01" },
    { id = "font03",        label = "커스텀 폰트 03" },
    { id = "font04",        label = "커스텀 폰트 04" },
    { id = "font05",        label = "커스텀 폰트 05" },
    { id = "font10",        label = "커스텀 폰트 10" },
    { id = "font21",        label = "커스텀 폰트 21" },
    { id = "font32",        label = "커스텀 폰트 32" },
    { id = "font36",        label = "커스텀 폰트 36" },
    { id = "font39",        label = "커스텀 폰트 39" },
    { id = "font47",        label = "커스텀 폰트 47" },
}

local GlobalFonts = {
    FONT_FILES = FONT_FILES,
    FONT_LABELS = FONT_LABELS,
    appliedWorld = nil,
    appliedDamage = nil,
    appliedChatSize = nil,
    appliedDamageScale = nil,
}
_G.ForeverSuiteGlobalFonts = GlobalFonts
ns.GlobalFonts = GlobalFonts

local function EnsureDB()
    if type(_G.ForeverSuiteGlobalFontsDB) ~= "table" then
        _G.ForeverSuiteGlobalFontsDB = {}
    end
    local db = _G.ForeverSuiteGlobalFontsDB
    if db.enabled == nil then db.enabled = false end
    if type(db.worldFont) ~= "string" then db.worldFont = "default_blizz" end
    if type(db.damageFont) ~= "string" then db.damageFont = "default_blizz" end
    if type(db.damageScale) ~= "number" then db.damageScale = 1.0 end
    if type(db.chatFontSize) ~= "number" then db.chatFontSize = 0 end -- 0 = untouched
    return db
end

function GlobalFonts.ResolvePath(fontId)
    return FONT_FILES[fontId] or FONT_FILES.default_blizz
end

function GlobalFonts.ApplyNow()
    if type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown() then
        return false, "IN_COMBAT"
    end
    local db = EnsureDB()
    if db.enabled ~= true then
        return false, "DISABLED"
    end
    local worldPath = GlobalFonts.ResolvePath(db.worldFont)
    local dmgPath = GlobalFonts.ResolvePath(db.damageFont)

    if db.worldFont ~= "default_blizz" then
        _G.STANDARD_TEXT_FONT = worldPath
        _G.UNIT_NAME_FONT = worldPath
        -- Respect Platynator (excluded enemy nameplate addon): never overwrite NAMEPLATE_FONT unless explicitly opted in
        if db.includeNameplateFont == true then
            _G.NAMEPLATE_FONT = worldPath
        end
        GlobalFonts.appliedWorld = worldPath
    end
    if db.damageFont ~= "default_blizz" then
        _G.DAMAGE_TEXT_FONT = dmgPath
        GlobalFonts.appliedDamage = dmgPath
    end

    if type(db.damageScale) == "number" and db.damageScale >= 0.5 and db.damageScale <= 2.5 then
        if C_CVar and type(C_CVar.SetCVar) == "function" then
            pcall(C_CVar.SetCVar, "WorldTextScale", tostring(db.damageScale))
        elseif type(_G.SetCVar) == "function" then
            pcall(_G.SetCVar, "WorldTextScale", tostring(db.damageScale))
        end
        GlobalFonts.appliedDamageScale = db.damageScale
    end

    if type(db.chatFontSize) == "number" and db.chatFontSize >= 10 and db.chatFontSize <= 24 then
        local maxWins = _G.NUM_CHAT_WINDOWS or 10
        for i = 1, maxWins do
            local cf = _G["ChatFrame" .. tostring(i)]
            if cf and type(_G.FCF_SetChatWindowFontSize) == "function" then
                pcall(_G.FCF_SetChatWindowFontSize, nil, cf, db.chatFontSize)
            elseif cf and type(cf.SetFont) == "function" and type(cf.GetFont) == "function" then
                local ok, curP, _, curFl = pcall(cf.GetFont, cf)
                if ok and type(curP) == "string" then
                    pcall(cf.SetFont, cf, (db.worldFont ~= "default_blizz") and worldPath or curP, db.chatFontSize, curFl or "")
                end
            end
        end
        GlobalFonts.appliedChatSize = db.chatFontSize
    end
    return true, "APPLIED"
end

function GlobalFonts.Configure(opts)
    local db = EnsureDB()
    if type(opts) == "table" then
        if opts.enabled ~= nil then db.enabled = opts.enabled == true end
        if type(opts.worldFont) == "string" and FONT_FILES[opts.worldFont] then db.worldFont = opts.worldFont end
        if type(opts.damageFont) == "string" and FONT_FILES[opts.damageFont] then db.damageFont = opts.damageFont end
        if type(opts.damageScale) == "number" then
            db.damageScale = math.max(0.5, math.min(2.5, opts.damageScale))
        end
        if type(opts.chatFontSize) == "number" then
            db.chatFontSize = math.floor(math.max(0, math.min(24, opts.chatFontSize)))
        end
    end
    if db.enabled then
        return GlobalFonts.ApplyNow()
    end
    return true, "SAVED_DISABLED"
end

function GlobalFonts.GetConfig()
    local db = EnsureDB()
    return {
        enabled = db.enabled == true,
        worldFont = db.worldFont,
        damageFont = db.damageFont,
        damageScale = db.damageScale,
        chatFontSize = db.chatFontSize,
    }
end

if type(_G.CreateFrame) == "function" then
    local f = _G.CreateFrame("Frame")
    f:RegisterEvent("ADDON_LOADED")
    f:RegisterEvent("PLAYER_LOGIN")
    f:SetScript("OnEvent", function(_, event, arg1)
        if event == "ADDON_LOADED" and arg1 == "ForeverSuite_Fonts_Global" then
            GlobalFonts.ApplyNow()
        elseif event == "PLAYER_LOGIN" then
            GlobalFonts.ApplyNow()
        end
    end)
end
