-- Test 20: Automatic 4-Tier Quest Navigation Arrow (QuestTracker 1-click, SuperTrack sync,
--          Objective -> Turn-In auto-flip, LoD fallback, cross-zone Korean label, & manual /way protection)
local ns = _G.ForeverSuite
assert(type(ns) == "table", "ForeverSuite namespace must exist")

_G.__FS_MOCK.playerPos = { mapID = 1411, x = 0.40, y = 0.50, facing = 0 }
_G.__FS_MOCK.mapNames[1413] = "불모의 땅"
_G.__FS_MOCK.questLogSet = { [1001] = 1, [1002] = 2, [1003] = 3, [857] = 4 }
_G.__FS_MOCK.questEntries = {
    { questID = 1001, title = "듀로타 멧돼지 사냥", level = 6, isHeader = false },
    { questID = 1002, title = "오그리마 보고서 전달", level = 8, isHeader = false },
    { questID = 1003, title = "지도 POI 수색", level = 9, isHeader = false },
    { questID = 857,  title = "달의 눈물", level = 15, isHeader = false },
}
_G.__FS_MOCK.questWaypoints = {
    [1001] = { mapID = 1411, x = 0.52, y = 0.44, text = "칼바위 언덕 동쪽" },
}
_G.__FS_MOCK.questUiMapID = { [1002] = 1454 }
_G.__FS_MOCK.questPoiIcons = { [1002] = { completed = false, x = 0.49, y = 0.72 } }
_G.__FS_MOCK.questsOnMap = {
    [1411] = {
        { questID = 1003, isQuestStart = false, isQuestEnd = false, x = 0.61, y = 0.35 },
    },
}

local origLoad = C_AddOns.LoadAddOn
C_AddOns.LoadAddOn = function(name)
    if string.find(tostring(name), "^ForeverSuite_Data") or name == "ForeverSuite_Media_Assets" then
        local loaded = __FS_LOAD_DATA_ADDON(name)
        _G.__FS_MOCK.loadedAddOns[name] = loaded
        return loaded, loaded and nil or "LOAD_FAILED"
    end
    return origLoad(name)
end

__FS_FIRE_EVENT("PLAYER_LOGIN")

-- Login 0-MB LoD invariant must remain unbroken even with NavigationHud:SyncSuperTrackedQuest(false)
assert(_G.ForeverSuiteData == nil, "PLAYER_LOGIN must NEVER force-load LoD packs for quest nav")

local nav = ns.Features.NavigationHud
local tracker = ns.Features.QuestTrackerView

-- 1. Tier 1: Clicking quest #1001 in QuestTrackerView starts SuperTrack AND shows NavigationHud arrow!
tracker:OnRowClick({ _rowData = { kind = "quest", questID = 1001, rawTitle = "듀로타 멧돼지 사냥" } }, "LeftButton")
assert(C_SuperTrack.GetSuperTrackedQuestID() == 1001, "Left-click must SuperTrack quest #1001")
assert(nav.target ~= nil and nav.target.source == "quest" and nav.target.questID == 1001, "Left-click must activate NavigationHud for quest #1001")
assert(nav.card:IsShown() == true, "NavigationHud arrow card must be shown immediately on quest click")
assert(string.find(nav.titleLbl:GetText(), "듀로타 멧돼지 사냥", 1, true) ~= nil, "Title must display quest name")
assert(string.find(nav.distLbl:GetText(), "칼바위 언덕 동쪽", 1, true) ~= nil, "Distance subtitle must include native waypoint text")
-- Must NOT overwrite SuperTrackedQuest with UserWaypoint!
assert(_G.__FS_MOCK.userWaypoint == nil, "Quest tracking must NOT clobber SuperTrackedQuest with SetUserWaypoint")

-- 2. Objective -> Turn-In auto-flip on QUEST_LOG_UPDATE
_G.__FS_MOCK.questComplete[1001] = true
_G.__FS_MOCK.questWaypoints[1001] = { mapID = 1411, x = 0.5195, y = 0.4350, text = "가르톡에게 보고" }
__FS_FIRE_EVENT("QUEST_LOG_UPDATE")
assert(nav.target.isComplete == true, "QUEST_LOG_UPDATE must flip quest nav to complete/turn-in phase")
assert(string.find(nav.titleLbl:GetText(), "완료·보고", 1, true) ~= nil, "Completed quest arrow must display [완료·보고] badge")

-- 3. Clicking same quest again untoggles BOTH SuperTrack and Quest Arrow
tracker:OnRowClick({ _rowData = { kind = "quest", questID = 1001, rawTitle = "듀로타 멧돼지 사냥" } }, "LeftButton")
assert(C_SuperTrack.GetSuperTrackedQuestID() == 0, "Second click must clear SuperTrack")
assert(nav.target == nil and nav.card:IsShown() == false, "Second click must hide quest navigation arrow")

-- 4. Tier 2 (QuestPOIGetIconInfo + GetQuestUiMapID) + cross-zone Korean zone name display!
_G.__FS_MOCK.superTrackedQuestID = 1002
__FS_FIRE_EVENT("SUPER_TRACKING_CHANGED")
assert(nav.target ~= nil and nav.target.questID == 1002 and nav.target.mapID == 1454, "Tier 2 QuestPOI must resolve quest #1002 in Orgrimmar (1454)")
assert(string.find(nav.distLbl:GetText(), "오그리마", 1, true) ~= nil, "Cross-zone quest nav must show Korean zone name instead of raw Map #")

-- 5. Tier 3 (C_QuestLog.GetQuestsOnMap fallback)
_G.__FS_MOCK.superTrackedQuestID = 1003
__FS_FIRE_EVENT("SUPER_TRACKING_CHANGED")
assert(nav.target ~= nil and nav.target.questID == 1003 and math.abs(nav.target.x - 0.61) < 0.001, "Tier 3 GetQuestsOnMap must resolve quest #1003")

-- 6. Tier 4 (ForeverSuite compiled LoD DB fallback for quest #857 with no native Blizzard POI!)
tracker:OnRowClick({ _rowData = { kind = "quest", questID = 857, rawTitle = "달의 눈물" } }, "LeftButton")
assert(nav.target ~= nil and nav.target.questID == 857 and nav.target.mapID == 1413, "Tier 4 LoD quest_routes fallback must resolve quest #857 in Barrens (1413)")
assert(string.find(nav.distLbl:GetText(), "불모의 땅", 1, true) ~= nil, "Barrens cross-zone label must display 불모의 땅")

-- 7. Manual /way target must NOT be hijacked by passive SUPER_TRACKING_CHANGED!
nav:SetTarget(1411, 0.55, 0.42, "수동 광맥")
assert(nav.target.source == "manual" and nav.target.label == "수동 광맥")
_G.__FS_MOCK.superTrackedQuestID = 1003
__FS_FIRE_EVENT("SUPER_TRACKING_CHANGED")
assert(nav.target.source == "manual" and nav.target.label == "수동 광맥", "Passive SUPER_TRACKING_CHANGED must NOT hijack active manual /way target")

-- 8. Quest arrival stays visible with completion hint (doesn't vanish while quest is still in progress)
nav:Clear()
_G.__FS_MOCK.questComplete[1001] = false
_G.__FS_MOCK.questWaypoints[1001] = { mapID = 1411, x = 0.4005, y = 0.5005, text = "목표 지점" }
nav:TrackQuest(1001, "듀로타 멧돼지 사냥", { allowLoadPacks = false, explicit = true })
assert(nav.card:IsShown() == true, "Quest arrow should show arrival status rather than vanishing abruptly")
assert(string.find(nav.distLbl:GetText(), "도착", 1, true) ~= nil, "Arrival label must indicate arrival at quest objective")

-- 9. Clicking X (Clear) must stay dismissed across passive QUEST_LOG_UPDATE ticks until explicitly re-selected!
_G.__FS_MOCK.superTrackedQuestID = 1001
nav:Clear()
assert(nav.target == nil and nav.card:IsShown() == false, "Clear must hide quest arrow")
__FS_FIRE_EVENT("QUEST_LOG_UPDATE")
assert(nav.target == nil and nav.card:IsShown() == false, "Dismissed quest arrow must NOT re-pop on passive QUEST_LOG_UPDATE")
-- Explicit click in QuestTrackerView re-enables it
nav:TrackQuest(1001, "듀로타 멧돼지 사냥", { allowLoadPacks = false, explicit = true })
assert(nav.target ~= nil and nav.card:IsShown() == true, "Explicit re-selection must restore quest arrow")

-- 10. Abandoned / turned-in quest (removed from quest log) must immediately clear stale quest arrow!
_G.__FS_MOCK.questLogSet[1001] = nil
__FS_FIRE_EVENT("QUEST_LOG_UPDATE")
assert(nav.target == nil and nav.card:IsShown() == false, "Abandoned/turned-in quest must immediately clear stale arrow")

-- 11. Deferred SuperTrack during combat flushes & activates quest arrow on PLAYER_REGEN_ENABLED!
_G.__FS_MOCK.questLogSet[1002] = 2
_G.__FS_MOCK.inCombat = true
ns.Api.NavPort.RequestSuperTrack(1002)
assert(C_SuperTrack.GetSuperTrackedQuestID() ~= 1002, "In-combat SuperTrack must defer")
_G.__FS_MOCK.inCombat = false
__FS_FIRE_EVENT("PLAYER_REGEN_ENABLED")
assert(C_SuperTrack.GetSuperTrackedQuestID() == 1002, "PLAYER_REGEN_ENABLED must flush deferred SuperTrack")
assert(nav.target ~= nil and nav.target.questID == 1002 and nav.card:IsShown() == true, "Post-combat flush must activate quest arrow for deferred quest #1002")

-- 12. C_Secrets fuzzing safety: secret questID or secret waypoint coords must fail closed cleanly
local secNum = FS_MakeSecret("qid", "number")
assert(ns.Api.GameAdapters.ResolveQuestWaypoint(secNum, false) == nil, "Secret questID must return nil without error")

print("Test 20 PASS: 4-tier quest navigation arrow, 1-click tracker wiring, auto objective->turn-in flip, and C_Secrets safety verified!")
