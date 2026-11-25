-- Module: ForeverSuite_Media/Media.lua
-- Responsibility: Registers unified typography objects (FS_Font_Title/Body/Small/Mono) and 9-slice Gold Atlas tokens.
local _, ns = ...

local BASE_FONT = "Fonts\\2002.TTF"
local MONO_FONT = "Fonts\\2002B.TTF"

local Media = {
    version = "2.0.0-alpha.1",
    fonts = {
        bodyPath = BASE_FONT,
        monoPath = MONO_FONT,
    },
    atlas = {
        goldBorder = "Interface\\AddOns\\ForeverSuite_Media\\Assets\\GoldChrome512.blp",
        fallbackSolid = "Interface\\Buttons\\WHITE8x8",
    },
}

local function EnsureFont(name, path, size, flags)
    if type(_G.CreateFont) ~= "function" then
        return nil
    end
    local f = _G[name] or _G.CreateFont(name)
    if f and type(f.SetFont) == "function" then
        pcall(f.SetFont, f, path, size, flags or "")
    end
    return f
end

Media.fontObjects = {
    title = EnsureFont("FS_Font_Title", BASE_FONT, 16, "OUTLINE"),
    heading = EnsureFont("FS_Font_Heading", BASE_FONT, 14, ""),
    body = EnsureFont("FS_Font_Body", BASE_FONT, 12, ""),
    small = EnsureFont("FS_Font_Small", BASE_FONT, 11, ""),
    mono = EnsureFont("FS_Font_Mono", MONO_FONT, 12, ""),
}

_G.ForeverSuiteMedia = Media
ns.Media = Media
