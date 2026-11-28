-- Test 27: Asset Integrity & Zero-Missing-Texture (Zero Green-Checkerboard) Gate
-- Verifies every bespoke UI & Icon TGA asset in ForeverSuite_Media_Assets exists on disk
-- with valid power-of-two 32-bit BGRA TGA headers, and enforces zero Retail-only Blizzard
-- Interface\Icons\* paths (ClassIcon_*, INV_Misc_GroupLooking, UI_Chat, Spell_Crystal, etc.).
local ns = _G.ForeverSuite
__FS_FIRE_EVENT("PLAYER_LOGIN")

local T = ns.UI.Tokens
local W = ns.UI.Widgets

local MEDIA_PREFIX = "Interface\\AddOns\\ForeverSuite_Media_Assets\\"
local DISK_ROOT = "v2/ForeverSuite_Media_Assets/"

local function isPowerOfTwo(n)
    if type(n) ~= "number" or n < 16 then return false end
    local v = n
    while v > 1 do
        if v % 2 ~= 0 then return false end
        v = v / 2
    end
    return true
end

local function verifyTgaAsset(wowPath, label)
    assert(type(wowPath) == "string" and wowPath ~= "", label .. ": path must be non-empty string")
    assert(string.sub(wowPath, 1, #MEDIA_PREFIX) == MEDIA_PREFIX,
        label .. ": expected ForeverSuite_Media_Assets path, got " .. tostring(wowPath))
    local rel = string.gsub(string.sub(wowPath, #MEDIA_PREFIX + 1), "\\", "/")
    local diskPath = DISK_ROOT .. rel
    local f = io.open(diskPath, "rb")
    assert(f ~= nil, label .. ": missing TGA file on disk: " .. diskPath)
    local hdr = f:read(18)
    local size = f:seek("end")
    f:close()
    assert(hdr and #hdr == 18, label .. ": truncated TGA header in " .. diskPath)
    local imgType = string.byte(hdr, 3)
    local w = string.byte(hdr, 13) + string.byte(hdr, 14) * 256
    local h = string.byte(hdr, 15) + string.byte(hdr, 16) * 256
    local bpp = string.byte(hdr, 17)
    assert(imgType == 2 or imgType == 10, label .. ": invalid TGA type=" .. tostring(imgType) .. " in " .. diskPath)
    assert(bpp == 32, label .. ": expected 32bpp TGA, got " .. tostring(bpp) .. " in " .. diskPath)
    assert(isPowerOfTwo(w) and isPowerOfTwo(h),
        label .. ": non-power-of-two dimensions " .. tostring(w) .. "x" .. tostring(h) .. " in " .. diskPath)
    if imgType == 2 then
        assert(size >= 18 + (w * h * 4), label .. ": uncompressed TGA truncated in " .. diskPath)
    else
        assert(size > 18, label .. ": RLE TGA empty in " .. diskPath)
    end
end

-- 1. Verify all 18 UI_ART TGA textures on disk
local uiArtCount = 0
for k, path in pairs(T.UI_ART) do
    verifyTgaAsset(path, "T.UI_ART." .. tostring(k))
    uiArtCount = uiArtCount + 1
end
assert(uiArtCount >= 18, "Expected >= 18 UI_ART assets, got " .. tostring(uiArtCount))

-- 2. Verify all 9 CLASS_TEX bespoke RPG icons on disk (zero Retail ClassIcon_*!)
local expectedClasses = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
for _, cls in ipairs(expectedClasses) do
    local p = T.ICON.CLASS_TEX[cls]
    verifyTgaAsset(p, "T.ICON.CLASS_TEX." .. cls)
    assert(string.find(p, "ClassIcon_", 1, true) == nil, "Forbidden Retail ClassIcon_ path for " .. cls)
end

-- 3. Verify all 18 T.ICON.CUSTOM bespoke RPG icons + T.ICON.FALLBACK on disk
verifyTgaAsset(T.ICON.FALLBACK, "T.ICON.FALLBACK")
local customCount = 0
for k, path in pairs(T.ICON.CUSTOM) do
    verifyTgaAsset(path, "T.ICON.CUSTOM." .. tostring(k))
    customCount = customCount + 1
end
assert(customCount == 18, "Expected 18 T.ICON.CUSTOM icons, got " .. tostring(customCount))

-- 4. Verify HomeDashboardModel quick tiles & cards use zero forbidden paths and valid media assets
local FORBIDDEN_PATTERNS = {
    "ClassIcon_",
    "INV_Misc_GroupLooking",
    "\\UI_Chat",
    "Spell_Crystal",
    "INV_Misc_Bag_10_Blue",
    "Spell_Holy_MagicalSentry",
}

local function assertNotForbidden(path, ctx)
    if type(path) ~= "string" then return end
    for _, pat in ipairs(FORBIDDEN_PATTERNS) do
        assert(string.find(path, pat, 1, true) == nil,
            ctx .. ": forbidden Retail/missing icon pattern '" .. pat .. "' in " .. path)
    end
    if string.sub(path, 1, #MEDIA_PREFIX) == MEDIA_PREFIX then
        verifyTgaAsset(path, ctx)
    end
end

for i, tile in ipairs(ns.Domain.HomeDashboardModel.GetQuickTiles()) do
    assertNotForbidden(tile.icon, "HomeDashboardModel.QuickTile[" .. tostring(i) .. "]")
end
local ov = ns.Domain.HomeDashboardModel.BuildOverview({})
for i, card in ipairs(ov.cards) do
    assertNotForbidden(card.icon, "HomeDashboardModel.Card[" .. tostring(i) .. "]")
end

-- 5. Verify ProcCooldownHud watched procs all resolve to valid bespoke TGAs
for spellId, spec in pairs(ns.Features.ProcCooldownHud.WATCHED_PROCS) do
    verifyTgaAsset(spec.icon, "ProcCooldownHud.WATCHED_PROCS[" .. tostring(spellId) .. "]")
end

-- 6. Verify IconFrame nil fallback resolves to FS-Icon-Fallback.tga (never broken Blizzard path)
local testHolder = CreateFrame("Frame", nil, _G.UIParent)
local ico = W.IconFrame(testHolder, 24)
ico:SetIcon(nil, nil, nil)
assert(ico._iconPath == T.ICON.FALLBACK, "IconFrame nil fallback must use T.ICON.FALLBACK")
verifyTgaAsset(ico._iconPath, "IconFrame fallback")

-- 7. Static source scan of key UI & Feature files to guarantee zero regression to Retail-only paths
local FILES_TO_SCAN = {
    "v2/ForeverSuite/UI/Tokens.lua",
    "v2/ForeverSuite/UI/CommandHub.lua",
    "v2/ForeverSuite/Domain/HomeDashboardModel.lua",
    "v2/ForeverSuite/Features/PartyFinderPage.lua",
    "v2/ForeverSuite/Features/CodexPage.lua",
    "v2/ForeverSuite/Features/UtilitiesPage.lua",
    "v2/ForeverSuite/Features/LedgerPage.lua",
    "v2/ForeverSuite/Features/WorldMapOverlay.lua",
    "v2/ForeverSuite/Features/ProcCooldownHud.lua",
    "v2/ForeverSuite/Features/DungeonBrowserPage.lua",
}
for _, fpath in ipairs(FILES_TO_SCAN) do
    local fh = io.open(fpath, "rb")
    assert(fh ~= nil, "Missing expected Lua file: " .. fpath)
    local src = fh:read("*a")
    fh:close()
    for _, pat in ipairs(FORBIDDEN_PATTERNS) do
        assert(string.find(src, pat, 1, true) == nil,
            fpath .. ": forbidden Retail/missing Blizzard icon '" .. pat .. "' must not reappear")
    end
end

-- 8. Verify Icons/icons.manifest.json exists and lists all 27 icons
local mf = io.open(DISK_ROOT .. "Icons/icons.manifest.json", "rb")
assert(mf ~= nil, "Missing Icons/icons.manifest.json")
local mtxt = mf:read("*a")
mf:close()
assert(string.find(mtxt, '"count": 27', 1, true) ~= nil, "icons.manifest.json must declare count: 27")

-- 9. Verify all WorldMapModel arrow TGA textures exist on disk & T.ResolveMediaPath works
assert(type(T.ResolveMediaPath) == "function", "T.ResolveMediaPath must exist")
for _, st in ipairs(ns.Domain.WorldMapModel.ARROW_STYLES or {}) do
    if type(st.texture) == "string" and st.texture ~= "" then
        verifyTgaAsset(st.texture, "WorldMapModel.ARROW_STYLES." .. tostring(st.id))
        assert(type(T.ResolveMediaPath(st.texture)) == "string", "ResolveMediaPath must return string")
    end
end

print("PASS: 27_asset_integrity (18 UI_ART + 9 Class + 18 Custom + Arrows verified, 0 Retail/missing paths)")
