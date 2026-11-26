-- Module: Domain/FontModel.lua
-- Responsibility: Pure Korean Font preset catalog, size-offset clamping, and outline mode normalizer
--                 (replaces 14 GodJohnsonFontChoice_* folders cleanly with zero global font pollution).
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local ipairs = ipairs
local math_floor = math.floor

local FontModel = {
    PRESETS = {
        { id = "default_kr", label = "기본 고딕 (2002)", path = "Fonts\\2002.TTF", monoPath = "Fonts\\2002B.TTF" },
        { id = "bold_kr", label = "굵은 고딕 (2002B)", path = "Fonts\\2002B.TTF", monoPath = "Fonts\\2002B.TTF" },
        { id = "pagetext_kr", label = "클래식 명조 (K_Pagetext)", path = "Fonts\\K_Pagetext.TTF", monoPath = "Fonts\\2002B.TTF" },
        { id = "damage_kr", label = "전투 강조체 (K_Damage)", path = "Fonts\\K_Damage.TTF", monoPath = "Fonts\\2002B.TTF" },
        { id = "clean_en", label = "클린 숫자 (한글+ARIALN)", path = "Fonts\\2002.TTF", monoPath = "Fonts\\ARIALN.TTF" },
    },
    BASE_SIZES = {
        title = 16,
        heading = 14,
        body = 12,
        small = 11,
        mono = 12,
    },
    OUTLINES = {
        none = "",
        outline = "OUTLINE",
        thick = "THICKOUTLINE",
    },
    SAMPLE_TEXT = "한글 완성형 가나다라 · 자모 ㄱㄴㄷ · 숫자 123,456g · 기호 ✦ ★ •",
}
ns.Domain.FontModel = FontModel

function FontModel.GetPreset(presetId)
    for _, p in ipairs(FontModel.PRESETS) do
        if p.id == presetId then
            return p
        end
    end
    return FontModel.PRESETS[1]
end

function FontModel.NormalizeSizeDelta(delta)
    if type(delta) ~= "number" or delta ~= delta then
        return 0
    end
    local d = math_floor(delta)
    if d < -2 then return -2 end
    if d > 4 then return 4 end
    return d
end

function FontModel.NormalizeOutline(key)
    if key == "outline" or key == "thick" then
        return key
    end
    return "none"
end

function FontModel.BuildRoleSpecs(presetId, sizeDelta, outlineKey)
    local preset = FontModel.GetPreset(presetId)
    local delta = FontModel.NormalizeSizeDelta(sizeDelta)
    local oKey = FontModel.NormalizeOutline(outlineKey)
    local flags = FontModel.OUTLINES[oKey] or ""
    return {
        { obj = "FS_Font_Title", path = preset.path, size = FontModel.BASE_SIZES.title + delta, flags = (flags == "" and "OUTLINE" or flags) },
        { obj = "FS_Font_Heading", path = preset.path, size = FontModel.BASE_SIZES.heading + delta, flags = flags },
        { obj = "FS_Font_Body", path = preset.path, size = FontModel.BASE_SIZES.body + delta, flags = flags },
        { obj = "FS_Font_Small", path = preset.path, size = FontModel.BASE_SIZES.small + delta, flags = flags },
        { obj = "FS_Font_Mono", path = preset.monoPath, size = FontModel.BASE_SIZES.mono + delta, flags = flags },
    }
end
