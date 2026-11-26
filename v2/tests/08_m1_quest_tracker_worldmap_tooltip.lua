-- Test 08: M1 Full QuestTracker (DDT 0/1/18/19/100 rows, scroll clamp, collapse, 6 visual states, Ctrl detail card,
--          combat fade & Dock isolation), WorldMapOverlay (cursor coords, stop on hide), Widgets shadow/clipping & Tooltip iLvl.
local ns = _G.ForeverSuiteV2

-- 1. Pure QuestTrackerModel DDT: 0, 1, 18, 19, 100 rows + scroll clamping + 6 visual states
local snap0 = ns.Domain.QuestTrackerModel.BuildSnapshot({}, { currentZone = "엘윈 숲" })
assert(snap0.questCount == 0 and #snap0.visibleRows == 1 and snap0.visibleRows[1].visualState == "empty")

local manyQuests = {}
for i = 1, 35 do
    manyQuests[i] = {
        questID = 1000 + i,
        title = "매우 긴 한글 퀘스트 제목 테스트 #" .. tostring(i),
        zone = (i <= 5) and "엘윈 숲" or "서부 몰락지대",
        level = 10 + i,
        isComplete = (i == 2),
        isFailed = (i == 3),
        objectives = {
            { text = "코볼트 처치: 3/8", finished = false },
            { text = "양초 수집: 5/5", finished = true },
        },
    }
end

local snapMany = ns.Domain.QuestTrackerModel.BuildSnapshot(manyQuests, {
    superTrackedQuestID = 1001,
    currentZone = "엘윈 숲",
    maxVisibleRows = 18,
    scrollOffset = 999,
})
assert(snapMany.questCount == 35)
assert(snapMany.totalRows > 100, "expected >100 rows, got " .. tostring(snapMany.totalRows))
assert(#snapMany.visibleRows == 18, "viewport must cap at 18 rows")
assert(snapMany.scrollOffset == snapMany.maxScroll, "scrollOffset must clamp to maxScroll")
assert(snapMany.rows[1].visualState == "group_current", "current zone pinned first")
assert(snapMany.rows[2].visualState == "quest_super")
assert(snapMany.rows[3].visualState == "obj_progress")
assert(snapMany.rows[4].visualState == "obj_done")
assert(snapMany.rows[5].visualState == "quest_complete")
assert(snapMany.rows[8].visualState == "quest_failed")

-- Level grouping mode & corrupted mode recovery
local snapLevel = ns.Domain.QuestTrackerModel.BuildSnapshot(manyQuests, { groupMode = "level" })
assert(snapLevel.groupMode == "level" and string.find(snapLevel.rows[1].text, "Lv.", 1, true))
local snapBadMode = ns.Domain.QuestTrackerModel.BuildSnapshot(manyQuests, { groupMode = "CORRUPTED_VALUE" })
assert(snapBadMode.groupMode == "zone", "corrupted groupMode must recover safely to zone")

-- Filter + collapse adjusts scrollOffset cleanly without out-of-bounds
local snapZoneOnly = ns.Domain.QuestTrackerModel.BuildSnapshot(manyQuests, {
    currentZone = "엘윈 숲",
    currentZoneOnly = true,
    scrollOffset = 80,
})
assert(snapZoneOnly.questCount == 5 and snapZoneOnly.hiddenCount == 30)
assert(snapZoneOnly.scrollOffset == snapZoneOnly.maxScroll)

-- Minimized mode produces 0 body rows
local snapMin = ns.Domain.QuestTrackerModel.BuildSnapshot(manyQuests, { minimized = true })
assert(snapMin.minimized == true and #snapMin.visibleRows == 0)

-- 2. Pure WorldMapModel cursor math & zero-fabrication formatter
local nx, ny = ns.Domain.WorldMapModel.ComputeCursorCoords(500, 400, 1.0, 100, 100, 800, 600)
assert(math.abs(nx - 0.5) < 0.001 and math.abs(ny - 0.5) < 0.001)
local ox, oy = ns.Domain.WorldMapModel.ComputeCursorCoords(50, 400, 1.0, 100, 100, 800, 600)
assert(ox == nil and oy == nil, "cursor outside canvas must return nil")
assert(ns.Domain.WorldMapModel.FormatCoordPair(nil, nil) == "—")
assert(ns.Domain.WorldMapModel.FormatCoordPair(0.425, 0.661) == "42.5, 66.1")

-- 3. Live QuestTrackerView UI: crisp shadows, clipped ListRow, Ctrl detail card, combat fade (zero Dock mutation in combat)
_G.__FS_MOCK.zoneText = "엘윈 숲"
_G.__FS_MOCK.questEntries = {
    { isHeader = true, title = "엘윈 숲" },
    { isHeader = false, questID = 201, title = "골드샤이어 코볼트 토벌 작전 아주 긴 퀘스트 이름", level = 12 },
}
_G.__FS_MOCK.questObjectives = {
    [201] = { { text = "코볼트 노동자 처치: 4/10", finished = false } },
}
_G.__FS_MOCK.questSpecialItems = { [2] = { "|Hitem:5501|h[신호탄]|h", 133710 } }
__FS_FIRE_EVENT("PLAYER_LOGIN")

local qtv = ns.Features.QuestTrackerView
assert(qtv.container ~= nil and qtv.titleLbl ~= nil)
assert(qtv.titleLbl._shadowOffset ~= nil, "Widgets.Label must apply crisp drop shadow")
local questRow = qtv.rowPool[2]
assert(questRow ~= nil and questRow._left._wordWrap == false, "ListRow _left must disable wordWrap to prevent overlap")
assert(#questRow._left._points >= 2, "ListRow _left must anchor both LEFT and RIGHT to _right")

-- Ctrl-click opens own Zero-Taint detail card (never SetSelectedQuest)
_G.__FS_MOCK.ctrlDown = true
questRow:FireScript("OnClick", "LeftButton")
_G.__FS_MOCK.ctrlDown = false
assert(qtv.detailCard ~= nil and qtv.detailCard:IsShown() == true)
assert(string.find(qtv.detailCard._meta:GetText(), "#201", 1, true))
qtv.detailCard:Hide()

-- Combat fade mutates ONLY card alpha; scrolling/minimizing/dock-anchor in combat defer cleanly & flush OOC
_G.__FS_MOCK.inCombat = true
__FS_FIRE_EVENT("PLAYER_REGEN_DISABLED")
assert(qtv.container:GetAlpha() < 0.5, "combatFade must lower card alpha in combat")
qtv:UpdateCombatVisuals(false)
assert(qtv.container:GetAlpha() == 1.0, "explicit false override must restore alpha")
qtv:UpdateCombatVisuals(true)
assert(qtv.container:GetAlpha() < 0.5)
qtv:SyncDockAnchor({ point = "TOPLEFT", x = 32, y = -32 })
assert(qtv._pendingDockAnchor ~= nil, "dock anchor must queue during combat")
qtv:ToggleMinimized()
assert(qtv.lastSnapshot.minimized == true)
qtv:ToggleMinimized()
_G.__FS_MOCK.inCombat = false
__FS_FIRE_EVENT("PLAYER_REGEN_ENABLED")
assert(qtv.container:GetAlpha() == 1.0, "alpha must restore after combat")
assert(qtv._pendingDockAnchor == nil, "queued dock anchor must flush OOC")

-- Objective row inherits isComplete/isWatched + comma-number progress does not falsely become obj_done
local snapComma = ns.Domain.QuestTrackerModel.BuildSnapshot({
    { questID = 301, title = "대규모 수집", zone = "엘윈 숲", level = 20, isComplete = true, isWatched = true,
      objectives = { { text = "자원: 1,200/5,000", finished = false } } },
}, {})
assert(snapComma.rows[3].visualState == "obj_progress", "1,200/5,000 with finished=false must be obj_progress")
assert(snapComma.rows[3].isComplete == true and snapComma.rows[3].isWatched == true)

-- 4. WorldMapOverlay: live coords while map shown, ticker cancelled & hidden on map close
_G.__FS_MOCK.playerPos = { mapID = 1453, x = 0.503, y = 0.662 }
_G.__FS_MOCK.worldMapID = 1453
_G.__FS_MOCK.cursorX = 500
_G.__FS_MOCK.cursorY = 400
_G.__FS_MOCK.worldMapShown = true
_G.WorldMapFrame:FireScript("OnShow")
local wmo = ns.Features.WorldMapOverlay
assert(wmo.card ~= nil and wmo.card:IsShown() == true)
assert(string.find(wmo.coordLabel:GetText(), "50.3, 66.2", 1, true))
assert(string.find(wmo.coordLabel:GetText(), "50.0, 50.0", 1, true))
assert(wmo.ticker ~= nil and wmo.ticker._cancelled == false)
assert(wmo.poiRows[1]:IsShown() == true, "Stormwind POIs must populate")

_G.__FS_MOCK.worldMapShown = false
_G.WorldMapFrame:FireScript("OnHide")
assert(wmo.card:IsShown() == false and wmo.ticker == nil, "WorldMapOverlay must stop ticker & hide on OnHide")

-- 5. Tooltip iLvl: omitted on cache miss, exact 1 line when present
_G.GameTooltip:SetOwner(_G.UIParent, "ANCHOR_NONE")
__FS_FIRE_TOOLTIP(_G.Enum.TooltipDataType.Item, _G.GameTooltip, { id = 272406 })
local foundIlvlMiss = false
for _, ln in ipairs(_G.GameTooltip._lines) do
    if ln.left == "아이템 레벨" then foundIlvlMiss = true end
end
assert(foundIlvlMiss == false, "iLvl line must be omitted on cache miss")

_G.__FS_MOCK.itemLevels[272406] = 65
_G.GameTooltip:SetOwner(_G.UIParent, "ANCHOR_NONE")
__FS_FIRE_TOOLTIP(_G.Enum.TooltipDataType.Item, _G.GameTooltip, { id = 272406 })
local ilvlCount = 0
for _, ln in ipairs(_G.GameTooltip._lines) do
    if ln.left == "아이템 레벨" and ln.right == "iLvl 65" then ilvlCount = ilvlCount + 1 end
end
assert(ilvlCount == 1, "iLvl line must appear exactly once when available")
