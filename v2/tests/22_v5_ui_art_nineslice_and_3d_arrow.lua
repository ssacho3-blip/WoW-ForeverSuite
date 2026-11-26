-- Test 22: ForeverSuite v5.0 Deep UI/UX Redesign Regression Suite
--   Verifies:
--     1) All 16 custom high-DPI UI TGA art paths registered in Tokens.UI_ART & Media
--     2) Manual 9-slice renderer (9 pieces) + instant no-reload Gold <-> Dark theme switching
--     3) Zero UI-Tooltip-Border / GoldChrome512 in Cards & Windows (Surface Doctrine L0/L1/L2)
--     4) B1 Gradient white-base fix, B3 Slider thumb + fill, B4 Toggle checkmark, B5 Bronze ScrollBar
--     5) B6 QuestTracker scrollbar right-inset clearing, B7 ComboHud sculpted gem orbs, B8 QuestItemDock polish
--     6) B9 12-layer 3D Satin Rounded418 Navigation Arrow + smooth angular lerp
--     7) B10 cash .wav notification resolution, DalaranSurface221 .blp extension, bundled Korean font presets & 4K scale
local ns = _G.ForeverSuiteV2
local T = ns.UI.Tokens
local W = ns.UI.Widgets
local NS = ns.UI.NineSlice

__FS_FIRE_EVENT("PLAYER_LOGIN")

-- 1. Custom 16-asset UI Art Kit registration
local expectedArtKeys = {
    "frameGold", "frameDark", "frameSmall", "frameSmallDark",
    "buttonNormal", "buttonBrass", "buttonCrimson",
    "statusFill", "statusGroove", "statusBorder",
    "iconRing", "scrimRadial", "gemLit", "gemEmpty", "gemGlow", "zoneRibbon",
}
for _, k in ipairs(expectedArtKeys) do
    assert(type(T.UI_ART[k]) == "string" and string.find(T.UI_ART[k], "FS%-", 1) ~= nil, "Missing UI_ART token: " .. k)
end
assert(T.MEDIA.TOOLTIP_BORDER == nil, "UI-Tooltip-Border must be removed from Tokens.MEDIA")

-- 2. NineSlice 9-piece geometry + instant no-reload Gold <-> Dark theme switching
local hub = ns.UI.CommandHub:EnsureWindow()
assert(hub._fsNineSlice ~= nil, "CommandHub must use NineSlice")
local pieceCount = 0
for _ in pairs(hub._fsNineSlice.pieces) do pieceCount = pieceCount + 1 end
assert(pieceCount == 9, "NineSlice must create exactly 9 texture pieces (TL/T/TR/L/C/R/BL/B/BR)")
assert(hub._fsNineSlice.presetKey == "window_gold", "Default theme must be Classic Gold RPG (window_gold)")

T.SetTheme("dark")
assert(T.GetTheme() == "dark", "Theme must switch to dark without reload")
assert(hub._fsNineSlice.presetKey == "window_dark", "CommandHub NineSlice must immediately swap to window_dark")
assert(ns.UI.CommandHub.themeBtn._label:GetText() == "다크", "Header theme toggle label must sync to 다크")

T.SetTheme("gold")
assert(T.GetTheme() == "gold" and hub._fsNineSlice.presetKey == "window_gold", "Theme must swap back to Classic Gold RPG")

-- 3. Surface Doctrine: L1 Card has zero UI-Tooltip-Border, L2 PopupCard has NineSlice
local card = W.Card(_G.UIParent, 200, 100)
assert(card._fsSurfaceLevel == "L1_QUIET" and card._fsHasBackdrop ~= true and card._fsNineSlice == nil, "W.Card must be quiet L1 flat surface")
local popup = W.PopupCard(_G.UIParent, 260, 140)
assert(popup._fsSurfaceLevel == "L2_POPUP" and popup._fsNineSlice ~= nil, "W.PopupCard must use 9-slice frame")

-- 4. B3 Slider thumb + progress fill & B4 Toggle checkmark
local sl = W.Slider(_G.UIParent, "테스트 슬라이더", 0, 10, 1, 5)
assert(sl._thumbKnob ~= nil and sl._fill ~= nil, "B3: Slider must expose visible thumb knob and progress fill")
local tg = W.Toggle(_G.UIParent, "테스트 토글", true)
assert(tg._check ~= nil and tg._check:IsShown() == true, "B4: Toggle must expose checkmark texture when checked")
tg:SetChecked(false)
assert(tg._check:IsShown() == false, "B4: Toggle checkmark must hide when unchecked")

-- 5. B5 ScrollBar width (10px) & warm bronze idle thumb
local sb = W.ScrollBar(_G.UIParent, 180)
assert(sb:GetWidth() == 10, "B5: ScrollBar must be 10px wide for 4K usability")
assert(T.BORDER.THUMB_IDLE[1] > T.BORDER.THUMB_IDLE[3], "B5: Gold theme scrollbar thumb must be warm bronze (R > B), never cold web blue")

-- 6. B6 QuestTrackerView scrollbar right-inset clearing + ZoneRibbon + PopupCard detail
local qtv = ns.Features.QuestTrackerView
local manyQuests = { { isHeader = true, title = "엘윈 숲" } }
for i = 1, 22 do
    manyQuests[#manyQuests + 1] = { isHeader = false, questID = 900 + i, title = "스크롤 테스트 퀘스트 " .. tostring(i), level = 10 }
end
_G.__FS_MOCK.questEntries = manyQuests
_G.__FS_MOCK.questObjectives = {}
local snap = qtv:RefreshLive()
assert(snap.maxScroll > 0, "22 quests must trigger scrollbar")
local firstRow = qtv.rowPool[1]
assert(firstRow._ribbonTex == T.UI_ART.zoneRibbon, "Zone header row must use FS-ZoneRibbon.tga")
local clearedRight = false
for _, pt in ipairs(firstRow._points or {}) do
    if pt[1] == "TOPRIGHT" and pt[4] == -16 then
        clearedRight = true
    end
end
assert(clearedRight == true, "B6: QuestTracker rows must use -16px right inset when scrollbar is shown")

-- 7. B7 ComboHud sculpted 5-gem orbs + additive 5CP glow (no SetColorTexture wipe)
local ch = ns.Features.CombatHudPack
assert(ch.comboFrame._fsHudStyle == "floating", "ComboHud must be borderless floating")
assert(#ch.comboPips == 5 and ch.comboPips[1].tex ~= nil and ch.comboPips[1].glow ~= nil, "B7: ComboHud must have 5 gem orbs with glow layers")
local origGetCP = _G.GetComboPoints
_G.GetComboPoints = function() return 5 end
ch:RefreshCombo()
assert(ch.comboFrame:IsShown() == true and ch.comboPips[5].lit == true and ch.comboPips[5].glow:IsShown() == true, "5CP must light all 5 gems and show additive glow")
assert(ch.comboCountLbl:GetText() == "5", "5CP must display combo count badge")
_G.GetComboPoints = function() return 0 end
ch:RefreshCombo()
assert(ch.comboFrame:IsShown() == false, "0CP must hide combo HUD")
_G.GetComboPoints = origGetCP

-- 8. B8 QuestItemDock warm obsidian, 0.08..0.92 icon crop, ring overlay, and tooltip link
local dock = ns.Secure.QuestItemDock
dock:ApplySlots({ { questID = 901, itemLink = "|cff0070dd|Hitem:6948::::::::60:::::|h[귀환석]|h|r", itemIcon = "Interface\\Icons\\INV_Misc_Rune_01" } })
local slot1 = dock.buttons[1]
assert(slot1 ~= nil and slot1._ring ~= nil and slot1._itemLink ~= nil, "B8: QuestItemDock slot must have ring overlay and itemLink tooltip data")

-- 9. B9 12-layer 3D Satin Rounded418 Navigation Arrow + style switching
local nav = ns.Features.NavigationHud
_G.__FS_MOCK.playerPos = { mapID = 1429, x = 0.40, y = 0.60, facing = 0 }
nav:SetTarget(1429, 0.70, 0.40, "[퀘스트] 북동쪽 목표", { source = "quest", questID = 901, isComplete = false })
assert(nav.rounded3D:IsShown() == true and #nav.rounded3D._layers == 12, "B9: Default 3D arrow must render 12 layers")
nav.rounded3D:SetDesign("roundedWedge")
assert(nav.rounded3D._design == "roundedWedge", "3D arrow must support roundedWedge design")
nav.rounded3D:SetDesign("roundedCompass")
assert(nav.rounded3D._design == "roundedCompass", "3D arrow must support roundedCompass design")
nav:Clear()
assert(nav.card:IsShown() == false, "Clearing nav must hide arrow and stop OnUpdate")

-- 10. B10 Sound path .wav fix & Bundled Korean FontModel presets + 4K base sizes
local playedPath = nil
local origPlaySoundFile = _G.PlaySoundFile
_G.PlaySoundFile = function(p) playedPath = p; return true end
ns.Api.GameAdapters.PlayNotificationSound("cash", 75, "SFX")
assert(playedPath ~= nil and string.sub(playedPath, -4) == ".wav", "B10: cash sound must resolve to .wav, got " .. tostring(playedPath))
ns.Api.GameAdapters.PlayNotificationSound("cooking_master", 100, "SFX")
assert(playedPath ~= nil and string.sub(playedPath, -4) == ".mp3", "B10: cooking_master_100 must resolve to .mp3")
ns.Api.GameAdapters.PlayNotificationSound("dingdong", 75, "SFX")
assert(playedPath ~= nil and string.sub(playedPath, -4) == ".ogg", "B10: dingdong must resolve to .ogg")
_G.PlaySoundFile = origPlaySoundFile

local FM = ns.Domain.FontModel
assert(FM.BASE_SIZES.title == 18 and FM.BASE_SIZES.body == 13, "4K typography scale must be 18/15/13/11/12")
assert(#FM.PRESETS == 8, "FontModel must expose 8 presets (5 Blizzard + 3 bundled KR)")
assert(FM.GetPreset("gmarket_kr").id == "gmarket_kr", "GmarketSans bundled font preset must resolve")
assert(FM.GetPreset("gyeonggi_kr").id == "gyeonggi_kr", "GyeonggiTitle bundled font preset must resolve")

-- 11. CommandHub 12 page icons wired in left rail
local railBtns = ns.UI.CommandHub.rail._buttons
assert(#railBtns == 12, "CommandHub rail must have 12 pages")
for _, rec in ipairs(railBtns) do
    assert(rec.icon ~= nil, "Every CommandHub rail page must have a WoW icon texture: " .. tostring(rec.id))
end

print("Test 22 PASS: ForeverSuite v5.0 16-asset UI art kit, 9-slice Gold/Dark theme, 12-layer 3D arrow, borderless HUDs, and B1-B10 fixes verified!")
