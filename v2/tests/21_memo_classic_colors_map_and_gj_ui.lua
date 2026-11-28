-- Test 21: Memo 4-Item Regression Suite
--   1) WoW Classic Original 5-tier quest difficulty colors (Red/Orange/Yellow/Green/Gray + PLAYER_LEVEL_UP refresh)
--   2) Zero default Blizzard quest tracker overlap (schema 4->5 migration + ObjectiveTrackerFrame/QuestObjectiveTracker/QuestWatchFrame hiding)
--   3) GodJohnsonGoldBorder UI polish (ApplyGoldBorderChrome + 3-layer procedural GoldArrow rotating 360° in NavigationHud)
--   4) WorldMap fixes (canvasScale/uiScale conversion, ScrollContainer viewport clipping, FULLSCREEN_DIALOG strata sync,
--      power-of-two reveal UV coords, reversed pet heatmap bounds normalization, GetNormalizedCursorPosition)
local ns = _G.ForeverSuiteV2

-- =========================================================================
-- 1. WoW Classic Original Quest Difficulty Colors
-- =========================================================================
local QTM = ns.Domain.QuestTrackerModel
assert(QTM.GetQuestGreenRange(1) == 4)
assert(QTM.GetQuestGreenRange(13) == 6)
assert(QTM.GetQuestGreenRange(60) == 12)

-- Player Lv.13 (exact Classic delta bands):
-- >= +5 (18+) = red, +3..+4 (16..17) = orange, -2..+2 (11..15) = yellow, -5..-3 (8..10) = green, <= -6 (<=7) = gray
local tRed, cRed = QTM.GetClassicDifficulty(18, 13)
local tOrg, cOrg = QTM.GetClassicDifficulty(16, 13)
local tYel, cYel = QTM.GetClassicDifficulty(13, 13)
local tGrn, cGrn = QTM.GetClassicDifficulty(9, 13)
local tGry, cGry = QTM.GetClassicDifficulty(7, 13)
assert(tRed == "red" and cRed[1] == 1.00 and cRed[2] < 0.2)
assert(tOrg == "orange" and cOrg[1] == 1.00 and cOrg[2] == 0.50)
assert(tYel == "yellow" and cYel[1] == 1.00 and cYel[2] == 1.00 and cYel[3] == 0.00, "current-level quest must be Classic yellow #FFFF00")
assert(tGrn == "green" and cGrn[2] == 0.75)
assert(tGry == "gray" and cGry[1] == cGry[2] and cGry[2] == cGry[3])

-- Live QuestTrackerView uses GetPlayerLevel() and applies Classic yellow to current-level quests
_G.__FS_MOCK.level = 13
_G.__FS_MOCK.zoneText = "서부 몰락지대"
_G.__FS_MOCK.questEntries = {
    { isHeader = true, title = "서부 몰락지대" },
    { isHeader = false, questID = 601, title = "현 레벨 적정 퀘스트", level = 13 },
    { isHeader = false, questID = 602, title = "매우 어려운 퀘스트", level = 19 },
    { isHeader = false, questID = 603, title = "회색 저레벨 퀘스트", level = 5 },
}
_G.__FS_MOCK.questObjectives = {}
__FS_FIRE_EVENT("PLAYER_LOGIN")

local qtv = ns.Features.QuestTrackerView
assert(qtv.lastSnapshot ~= nil and qtv.lastSnapshot.rows[2].difficultyTone == "yellow")
assert(qtv.lastSnapshot.rows[3].difficultyTone == "red")
assert(qtv.lastSnapshot.rows[4].difficultyTone == "gray")

-- Level up to 19 -> quest #602 turns from red to yellow immediately on PLAYER_LEVEL_UP
_G.__FS_MOCK.level = 19
__FS_FIRE_EVENT("PLAYER_LEVEL_UP")
assert(qtv.lastSnapshot.rows[3].difficultyTone == "yellow", "PLAYER_LEVEL_UP must recalculate Classic difficulty colors")

-- =========================================================================
-- 2. Default Blizzard Quest Tracker Overlap Elimination
-- =========================================================================
-- Schema 4 -> 5 migration upgrades legacy "coexist" to "hide" unless user explicitly opted in
local legacyV4 = {
    schemaVersion = 4,
    v2 = {
        settings = {
            quest = { defaultTrackerMode = "coexist" },
            ui = { navArrowStyle = "classic" },
        },
        state = {},
    },
}
local migrated5, _, st5 = ns.Domain.ProfileMigrationModel.Migrate(legacyV4, {})
assert(st5 == "OK" and migrated5.schemaVersion == 6)
assert(migrated5.v2.settings.quest.defaultTrackerMode == "hide", "schema 4 coexist must auto-upgrade to hide")
assert(migrated5.v2.settings.ui.navArrowStyle == "gold_classic", "schema 4 classic arrow upgrades to gold_classic")

local explicitV4 = {
    schemaVersion = 4,
    v2 = {
        settings = { quest = { defaultTrackerMode = "coexist" } },
        state = { userExplicitTrackerMode = true },
    },
}
local keptCoexist = ns.Domain.ProfileMigrationModel.Migrate(explicitV4, {})
assert(keptCoexist.v2.settings.quest.defaultTrackerMode == "coexist", "explicit user coexist choice must be respected")

-- ObjectiveTrackerAdapter hides ALL Blizzard tracker frames (ObjectiveTrackerFrame + QuestObjectiveTracker + QuestWatchFrame)
local qot = CreateFrame("Frame", "QuestObjectiveTracker", _G.UIParent)
local qwf = CreateFrame("Frame", "QuestWatchFrame", _G.UIParent)
qot:Show()
qwf:Show()
_G.QuestObjectiveTracker = qot
_G.QuestWatchFrame = qwf

ns.Blizzard.ObjectiveTrackerAdapter:ApplyMode("hide")
assert(_G.ObjectiveTrackerFrame:IsShown() == false and _G.ObjectiveTrackerFrame:GetAlpha() == 0)
assert(qot:IsShown() == false and qot:GetAlpha() == 0, "QuestObjectiveTracker must be hidden")
assert(qwf:IsShown() == false and qwf:GetAlpha() == 0, "QuestWatchFrame must be hidden")

-- Blizzard trying to re-show QuestWatchFrame is immediately re-suppressed by OnShow hook
qwf:Show()
qwf:FireScript("OnShow")
assert(qwf:IsShown() == false and qwf:GetAlpha() == 0, "OnShow hook must keep Blizzard tracker hidden")

-- =========================================================================
-- 3. GodJohnson / DialogueUI / ElvUI / Details! REA UI Overhaul (v5.0)
-- =========================================================================
local T = ns.UI.Tokens
assert(T.MEDIA and T.MEDIA.STATUSBAR and T.MEDIA.MINIMAP_RING and T.UI_ART and T.UI_ART.frameGold, "v5.0 UI art & WoW native media tokens must exist")
assert(qtv.container._fsHudStyle == "floating", "QuestTrackerView must use airy borderless floating scrim")
assert(qtv.btnGroupMode._ghost == true and qtv.btnZoneFilter._ghost == true, "QuestTracker header buttons must use sleek ghost style")
local hub = ns.UI.CommandHub:EnsureWindow()
assert(hub ~= nil and hub._fsNineSlice ~= nil, "CommandHub window must use high-DPI 9-slice sculpted border")

local nav = ns.Features.NavigationHud
nav:Init()
assert(nav.card._fsHudStyle == "floating", "NavigationHud must be a borderless floating arrow HUD (zero boxy card)")
assert(nav.rounded3D ~= nil and #nav.rounded3D._layers == 12, "12-layer 3D Satin Rounded418 arrow must have 10 side + face + shine layers")
assert(nav.goldArrow ~= nil and #nav.goldArrow._parts == 9, "GodJohnson 3-layer fallback arrow must have 3x3 = 9 procedural parts")

-- Translucent dark glass & borderless floating HUD checks (StatusPill, ThreatMeter, CombatHudPack, ProcCooldown, Minimap)
assert(ns.Features.StatusPillHud.card._fsHudStyle == "floating", "StatusPill must use borderless HudFloating ribbon")
assert(ns.Features.ThreatMeterHud.card._fsHudStyle == "glass", "ThreatMeter must use Details!-style HudGlass / native atlas")
assert(ns.Features.ProcCooldownHud.procCard._fsHudStyle == "floating", "ProcAlert must use WeakAuras-style borderless floating ribbon")
assert(ns.Features.MinimapButton.button ~= nil and ns.Features.MinimapButton.button._fsRing ~= nil, "MinimapButton must use circular Blizzard gold ring")

_G.__FS_MOCK.playerPos = { mapID = 1429, x = 0.40, y = 0.60, facing = 0 }
nav:SetTarget(1429, 0.70, 0.60, "[퀘스트] 동쪽 목표", { source = "quest", questID = 601, isComplete = false })
assert(nav.rounded3D:IsShown() == true, "default roundedClassic style must render 12-layer 3D satin arrow")
assert(math.abs(nav.rounded3D._angle) > 0.1, "3D satin arrow must rotate toward target bearing")
nav:Clear()

-- =========================================================================
-- 4. WorldMap Fixes (Scale Conversion, Viewport Clipping, Strata, Reveal UVs)
-- =========================================================================
local WMM = ns.Domain.WorldMapModel

-- 4A. Viewport clipping prevents zoomed pins from floating outside ScrollContainer
local zoomedMetrics = {
    left = -200,
    bottom = -100,
    width = 1600,
    height = 1200,
    scale = 1.0,
    clip = { left = 100, right = 900, bottom = 100, top = 700 },
}
local inX, inY = WMM.ProjectMapToScreen(0.5, 0.5, zoomedMetrics)
assert(inX == 600 and inY == 500, "inside-viewport pin must project accurately")
local outX, outY = WMM.ProjectMapToScreen(0.02, 0.02, zoomedMetrics)
assert(outX == nil and outY == nil, "outside-viewport zoomed pin must be clipped to nil")

-- 4B. Overlay rect + UV clipping trims oversized zoomed textures cleanly
local cl, cb, cw, ch, nu1, nu2, nv1, nv2 = WMM.ClipOverlayRect(0, 0, 1000, 800, 0, 1, 0, 1, zoomedMetrics.clip)
assert(cl == 100 and cb == 100 and cw == 800 and ch == 600)
assert(math.abs(nu1 - 0.1) < 0.001 and math.abs(nu2 - 0.9) < 0.001)
assert(math.abs(nv1 - 0.125) < 0.001 and math.abs(nv2 - 0.875) < 0.001)
local fullyOut = WMM.ClipOverlayRect(950, 100, 1100, 500, 0, 1, 0, 1, zoomedMetrics.clip)
assert(fullyOut == nil, "fully out-of-clip overlay must return nil")

-- 4C. Power-of-two reveal UV coordinates prevent edge-tile stretch distortion
local subs = WMM.ExpandRevealSubTiles({ filesCsv = "8074089", x = 549, y = 427, w = 256, h = 241 }, {})
assert(#subs == 1 and math.abs(subs[1].u2 - 1.0) < 0.001 and math.abs(subs[1].v2 - (241 / 256)) < 0.001)

-- 4D. WorldMapAdapter converts canvas coordinates via canvasScale / uiParentScale & syncs FULLSCREEN_DIALOG strata
local scroll = _G.WorldMapFrame.ScrollContainer
local origChild = scroll.Child
local origUiScale = _G.UIParent.GetEffectiveScale
scroll.Child = {
    GetLeft = function() return 100 end,
    GetBottom = function() return 100 end,
    GetWidth = function() return 800 end,
    GetHeight = function() return 600 end,
    GetEffectiveScale = function() return 2.0 end,
}
_G.UIParent.GetEffectiveScale = function() return 1.0 end
local mScaled = ns.Blizzard.WorldMapAdapter:GetCanvasMetrics()
assert(mScaled ~= nil and mScaled.scale == 1.0 and mScaled.canvasScale == 2.0)
assert(mScaled.left == 200 and mScaled.width == 1600, "canvas metrics must convert from canvasScale to UIParent space")
assert(mScaled.clip ~= nil, "ScrollContainer clip rectangle must be populated")
scroll.Child = origChild
_G.UIParent.GetEffectiveScale = origUiScale

local wmo = ns.Features.WorldMapOverlay
wmo:EnsureCard()
wmo:EnsurePinLayer()
wmo:SyncMapStrata({ strata = "FULLSCREEN_DIALOG", level = 25 })
assert(wmo.card._fsNineSlice ~= nil, "WorldMapOverlay card must use high-DPI 9-slice PopupCard")
assert(wmo.pinLayer._strata == "FULLSCREEN_DIALOG")
assert(wmo.card._strata == "FULLSCREEN_DIALOG")
print("Test 21 PASS: Classic difficulty colors, default tracker overlap fix, GodJohnson UI chrome & arrow, and WorldMap fixes verified!")
