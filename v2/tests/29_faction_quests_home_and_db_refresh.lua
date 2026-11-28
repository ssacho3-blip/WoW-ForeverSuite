-- Test 29: Horde/Alliance Quest Separation, Home Auto-Character Detection, and GodJohnson 5.344 DB Refresh
local ns = _G.ForeverSuite
__FS_FIRE_EVENT("PLAYER_LOGIN")

local function assertEq(actual, expected, msg)
    assert(actual == expected, (msg or "assertEq failed") .. " (got=" .. tostring(actual) .. ", expected=" .. tostring(expected) .. ")")
end

-- 0. Verify expanded 42-species Azeroth Fishing DB in ForeverSuite_Data
__FS_LOAD_DATA_ADDON("ForeverSuite_Data")
local fishPack = _G.ForeverSuiteData and _G.ForeverSuiteData.packs and _G.ForeverSuiteData.packs.fishing
assert(type(fishPack) == "table" and type(fishPack.entries) == "table" and #fishPack.entries >= 40,
    "Expanded Azeroth Fishing DB must contain >=40 species entries (got=" .. tostring(fishPack and fishPack.entries and #fishPack.entries or 0) .. ")")

------------------------------------------------------------------------
-- 1. QuestGuideModel: Horde/Alliance separation & <UNUSED> exclusion
------------------------------------------------------------------------
local QGM = ns.Domain.QuestGuideModel
local sampleClassQuests = {
    { questID = 26, title = "귀중한 교훈", altName = "A Lesson to Learn", classMask = 1024, side = 1, minLevel = 16, level = 16, walkthrough = "얼라 공략" },
    { questID = 27, title = "꼭 배워야 할 교훈", altName = "A Lesson to Learn", classMask = 1024, side = 2, minLevel = 16, level = 16, walkthrough = "호드 공략" },
    { questID = 50, title = "공용 드루이드 시험", altName = "Shared Trial", classMask = 1024, side = 3, minLevel = 20, level = 20, walkthrough = "공용" },
    { questID = 987, title = "<UNUSED>", altName = "<UNUSED>", classMask = 1024, side = 3, minLevel = 30, level = 30 },
}

local hordeQ = QGM.FilterClassQuests(sampleClassQuests, { playerClass = "DRUID", myClassOnly = true, faction = "Horde" })
assertEq(#hordeQ, 2, "Horde filter must include side=2 and side=3, excluding side=1 and <UNUSED>")
assertEq(hordeQ[1].questID, 27, "Horde filter keeps side=2 quest")
assertEq(hordeQ[2].questID, 50, "Horde filter keeps side=3 shared quest")

local allyQ = QGM.FilterClassQuests(sampleClassQuests, { playerClass = "DRUID", myClassOnly = true, faction = "Alliance" })
assertEq(#allyQ, 2, "Alliance filter must include side=1 and side=3, excluding side=2 and <UNUSED>")
assertEq(allyQ[1].questID, 26, "Alliance filter keeps side=1 quest")
assertEq(allyQ[2].questID, 50, "Alliance filter keeps side=3 shared quest")

local allQ = QGM.FilterClassQuests(sampleClassQuests, { playerClass = "DRUID", myClassOnly = true, faction = "All" })
assertEq(#allQ, 3, "All filter includes both factions but still excludes <UNUSED>")

assertEq(QGM.FormatSideBadge(1), "[얼라]", "side=1 badge")
assertEq(QGM.FormatSideBadge(2), "[호드]", "side=2 badge")
assertEq(QGM.FormatSideBadge(3), "[공용]", "side=3 badge")

-- Leveling zones strictly separate Horde vs Alliance
local hordeZones = QGM.RecommendLevelingZones(15, "Horde")
for _, z in ipairs(hordeZones) do
    assert(z.faction ~= "Alliance", "Horde leveling planner must never include Alliance-only zones")
end
local allyZones = QGM.RecommendLevelingZones(15, "Alliance")
for _, z in ipairs(allyZones) do
    assert(z.faction ~= "Horde", "Alliance leveling planner must never include Horde-only zones")
end

------------------------------------------------------------------------
-- 2. DungeonBrowserModel: Horde/Alliance dungeon quest separation
------------------------------------------------------------------------
local DBM = ns.Domain.DungeonBrowserModel
local sampleDung = { id = "st", title = "가라앉은 사원" }
local sampleDungQuests = {
    { questID = 1424, dungeonKey = "st", faction = "Horde",    title = "눈물의 연못" },
    { questID = 1448, dungeonKey = "st", faction = "Alliance", title = "신전을 찾아서" },
    { questID = 3520, dungeonKey = "st", faction = "Both",     title = "계곡천둥매의 영혼" },
}
local stMap = { completed = {}, inLog = {} }

local hRows, hCnt = DBM.BuildQuestReadiness(sampleDungQuests, sampleDung, stMap, "Horde")
assertEq(hCnt.total, 2, "Horde dungeon quest readiness must include Horde + Both only")
assertEq(hRows[1].quest.questID, 1424, "Horde dungeon quest preserved")
assertEq(hRows[2].quest.questID, 3520, "Shared dungeon quest preserved for Horde")

local aRows, aCnt = DBM.BuildQuestReadiness(sampleDungQuests, sampleDung, stMap, "Alliance")
assertEq(aCnt.total, 2, "Alliance dungeon quest readiness must include Alliance + Both only")
assertEq(aRows[1].quest.questID, 1448, "Alliance dungeon quest preserved")

local allRows, allCnt = DBM.BuildQuestReadiness(sampleDungQuests, sampleDung, stMap)
assertEq(allCnt.total, 3, "3-arg BuildQuestReadiness stays backwards-compatible (returns all)")

------------------------------------------------------------------------
-- 3. HomeDashboardModel & HomePage: Auto-Detect Character Profile & Faction Briefing
------------------------------------------------------------------------
local HDM = ns.Domain.HomeDashboardModel

local hOv = HDM.BuildOverview({
    name = "스랄",
    level = 16,
    classEng = "SHAMAN",
    faction = "Horde",
    raceLoc = "오크",
    zone = "불모의 땅",
    realm = "포에버",
})
assert(string.find(hOv.heroTitle, "스랄", 1, true), "Home hero title includes player name")
assert(string.find(hOv.heroTitle, "[호드]", 1, true), "Home hero title includes auto-detected Horde badge")
assert(string.find(hOv.heroTitle, "오크 주술사", 1, true), "Home hero title includes race + class")
assert(string.find(hOv.recommendedDungeon, "성난불길 협곡", 1, true), "Horde Lv.16 recommends Horde dungeon (RFC)")
assert(not string.find(hOv.recommendedDungeon, "죽음의 폐광", 1, true), "Horde Lv.16 must NOT recommend Alliance Deadmines")

local aOv = HDM.BuildOverview({
    name = "아르타스",
    level = 16,
    classEng = "PALADIN",
    faction = "Alliance",
    raceLoc = "인간",
    zone = "서부 몰락지대",
    realm = "포에버",
})
assert(string.find(aOv.heroTitle, "[얼라이언스]", 1, true), "Home hero title includes auto-detected Alliance badge")
assert(string.find(aOv.heroTitle, "인간 성기사", 1, true), "Home hero title includes race + class")
assert(string.find(aOv.recommendedDungeon, "죽음의 폐광", 1, true), "Alliance Lv.16 recommends Alliance dungeon (Deadmines)")
assert(not string.find(aOv.recommendedDungeon, "성난불길 협곡", 1, true), "Alliance Lv.16 must NOT recommend Horde RFC")

-- Live HomePage & QuestGuidePage UI auto-detection integration
local origFac = _G.UnitFactionGroup
local origRace = _G.UnitRace
_G.UnitFactionGroup = function() return "Horde", "호드" end
_G.UnitRace = function() return "오크", "Orc" end

local hub = ns.UI.CommandHub
hub:EnsureWindow()
hub:SelectPage("home")
assert(string.find(ns.Features.HomePage.heroTitle:GetText(), "[호드]", 1, true), "Live HomePage auto-detects Horde character")
assert(string.find(ns.Features.HomePage.heroTitle:GetText(), "오크", 1, true), "Live HomePage auto-detects character race")

hub:SelectPage("questguide")
assertEq(ns.Features.QuestGuidePage:GetEffectiveFaction(), "Horde", "QuestGuidePage auto-detects Horde faction")
ns.Features.QuestGuidePage.factionMode = "Alliance"
assertEq(ns.Features.QuestGuidePage:GetEffectiveFaction(), "Alliance", "QuestGuidePage allows manual Alliance switch")
ns.Features.QuestGuidePage.factionMode = "auto"

-- Negative path: unreadable/nil UnitFactionGroup degrades safely to "All" (never crashes or hides everything)
_G.UnitFactionGroup = function() return nil, nil end
assertEq(ns.Features.QuestGuidePage:GetEffectiveFaction(), "All", "Nil faction safely degrades to All")
assertEq(QGM.MatchesFactionSide(0, "Horde"), true, "side=0 neutral matches Horde")
assertEq(QGM.MatchesFactionSide(nil, "Alliance"), true, "side=nil matches Alliance")
assertEq(QGM.MatchesFactionSide(1, "Horde"), false, "side=1 Alliance strictly excluded for Horde")
assertEq(QGM.MatchesFactionSide(2, "Alliance"), false, "side=2 Horde strictly excluded for Alliance")

-- Verify Lv.40-60 leveling zones remain covered for both factions
local h60 = QGM.RecommendLevelingZones(58, "Horde")
local has5060 = false
for _, z in ipairs(h60) do
    if z.minL == 50 and z.recommended == true then has5060 = true end
end
assert(has5060, "RecommendLevelingZones must cover Lv.50-60 for high-level characters")

_G.UnitFactionGroup = origFac
_G.UnitRace = origRace

------------------------------------------------------------------------
-- 4. Low-Level & Forever Dungeon Bosses + Drops Coverage Regression
------------------------------------------------------------------------
__FS_LOAD_DATA_ADDON("ForeverSuite_Data_Dungeon")
local dPacks = _G.ForeverSuiteData and _G.ForeverSuiteData.packs
assert(type(dPacks) == "table" and type(dPacks.dungeons) == "table" and type(dPacks.dungeon_bosses) == "table" and type(dPacks.dungeon_loot) == "table",
    "ForeverSuite_Data_Dungeon packs must be loaded")
assert(#dPacks.dungeon_bosses.entries >= 360,
    "Full dungeon_bosses pack must include all low-level + Forever + Lv.60 bosses (>=360, got=" .. tostring(#dPacks.dungeon_bosses.entries) .. ")")

local lootIdx = DBM.IndexLootByItemID(dPacks.dungeon_loot.entries)
local lowLevelMustHave = {
    { id = "rfc",     inst = 389,  name = "성난불길 협곡",    minBosses = 4, minDrops = 10 },
    { id = "wc",      inst = 43,   name = "통곡의 동굴",      minBosses = 8, minDrops = 20 },
    { id = "dm",      inst = 36,   name = "폐광",             minBosses = 7, minDrops = 20 },
    { id = "hot",     inst = 3065, name = "영주의 전당",      minBosses = 4, minDrops = 10 },
    { id = "rol",     inst = 2999, name = "로데론의 폐허",    minBosses = 6, minDrops = 15 },
    { id = "sfk",     inst = 33,   name = "그림자송곳니 성채", minBosses = 8, minDrops = 15 },
    { id = "bfd",     inst = 48,   name = "검은심연 나락",    minBosses = 6, minDrops = 20 },
    { id = "stocks",  inst = 34,   name = "스톰윈드 지하감옥", minBosses = 5, minDrops = 10 },
    { id = "wetlands",inst = 2998, name = "저습지 발굴 현장",  minBosses = 4, minDrops = 10 },
    { id = "dalaran", inst = 2959, name = "달라란 시가지",    minBosses = 8, minDrops = 15 },
    { id = "gnomer",  inst = 90,   name = "놈리건",           minBosses = 5, minDrops = 20 },
    { id = "rfk",     inst = 47,   name = "가시덩굴 우리",    minBosses = 6, minDrops = 20 },
    { id = "rfd",     inst = 129,  name = "가시덩굴 구릉",    minBosses = 6, minDrops = 15 },
    { id = "sm",      inst = 189,  name = "붉은십자군 수도원", minBosses = 8, minDrops = 20 },
    { id = "uldaman", inst = 70,   name = "울다만",           minBosses = 8, minDrops = 20 },
    { id = "drowned_city",    inst = 2970, name = "가라앉은 도시", minBosses = 6,  minDrops = 15 },
    { id = "kroldok",         inst = 3039, name = "크롤도크 보루", minBosses = 5,  minDrops = 15 },
    { id = "alcaz",           inst = 2994, name = "알카즈 감옥",   minBosses = 5,  minDrops = 15 },
    { id = "blackmaw",        inst = 2974, name = "검은아귀 요새", minBosses = 7,  minDrops = 20 },
    { id = "shapers_terrace", inst = 3001, name = "구체자의 정원", minBosses = 11, minDrops = 20 },
}

local dungById = {}
local totalUnresolved = 0
for _, d in ipairs(dPacks.dungeons.entries) do
    dungById[d.id] = d
    assert(type(d.bossCount) == "number" and d.bossCount >= 1,
        "Every dungeon in Pack_dungeons must have >= 1 boss (zero-boss regression on: " .. tostring(d.title) .. ")")
    local bosses = DBM.GetBossesForDungeon(dPacks.dungeon_bosses.entries, d)
    assert(#bosses >= 1, "Every dungeon must resolve >= 1 boss entry: " .. tostring(d.title))
    local seenBoss = {}
    local dDrops = 0
    for _, b in ipairs(bosses) do
        assert(not seenBoss[b.title], "Duplicate boss in " .. tostring(d.title) .. ": " .. tostring(b.title))
        seenBoss[b.title] = true
        local drops = DBM.GetDropsForBoss(b, lootIdx)
        for _, it in ipairs(drops) do
            dDrops = dDrops + 1
            if it.placeholder then
                totalUnresolved = totalUnresolved + 1
            end
        end
    end
    assert(dDrops >= 1, "Every dungeon must have >= 1 drop entry: " .. tostring(d.title))
end
assert(totalUnresolved <= 6,
    "Unresolved placeholder drops across all 35 dungeons must not regress past 6 (got=" .. tostring(totalUnresolved) .. ")")

for _, req in ipairs(lowLevelMustHave) do
    local d = dungById[req.id]
    assert(type(d) == "table", "Dungeon missing from Pack_dungeons: " .. req.id)
    assert(type(d.bossCount) == "number" and d.bossCount >= req.minBosses,
        req.name .. " bossCount must be >= " .. tostring(req.minBosses) .. " (got=" .. tostring(d.bossCount) .. ")")
    local bosses = DBM.GetBossesForDungeon(dPacks.dungeon_bosses.entries, d)
    assert(#bosses >= req.minBosses,
        req.name .. " must have >= " .. tostring(req.minBosses) .. " bosses (got=" .. tostring(#bosses) .. ")")
    local resolvedDrops = 0
    for _, b in ipairs(bosses) do
        local drops = DBM.GetDropsForBoss(b, lootIdx)
        for _, it in ipairs(drops) do
            if not it.placeholder and type(it.title) == "string" and it.title ~= "" then
                resolvedDrops = resolvedDrops + 1
            end
        end
    end
    assert(resolvedDrops >= req.minDrops,
        req.name .. " must have >= " .. tostring(req.minDrops) .. " resolved non-placeholder drops (got=" .. tostring(resolvedDrops) .. ")")
end

------------------------------------------------------------------------
-- 5. QuestTracker "현지역" Current-Zone Filter Regression
------------------------------------------------------------------------
local QTM = ns.Domain.QuestTrackerModel
local mixedQuests = {
    { questID = 5001, title = "불모의 땅 평원 사냥", zone = "불모의땅", level = 14, mapID = 1413 },
    { questID = 5002, title = "전사 태세 퀘스트",     zone = "전사",     level = 14, mapID = 1413 },
    { questID = 5003, title = "오그리마 파견 보고",   zone = "오그리마", level = 15 },
    { questID = 5004, title = "타나리스 해적 토벌",   zone = "타나리스", level = 44, mapID = 1446 },
}

-- Matches via: (a) whitespace-normalized zone name ("불모의땅" == "불모의 땅"),
-- (b) native quest mapID (class quest 5002 on map 1413),
-- (c) native GetQuestsOnMap localQuestIDs POI (city quest 5003 whose objective is on current map),
-- while strictly excluding remote zone quest 5004 (타나리스, mapID 1446).
local zSnap = QTM.BuildSnapshot(mixedQuests, {
    currentZone = "불모의 땅",
    currentZoneAliases = { "불모의 땅", "십자로" },
    currentMapID = 1413,
    localQuestIDs = { [5003] = true },
    currentZoneOnly = true,
})
assertEq(zSnap.questCount, 3, "Current-zone filter must include whitespace-normalized, mapID, and native POI quests")
assertEq(zSnap.hiddenCount, 1, "Current-zone filter must exclude remote zone quest (Tanaris)")
assertEq(zSnap.currentZoneOnly, true, "Snapshot exposes currentZoneOnly flag")

-- Micro-map / cave parentMapID match (parentMapID = 1413 while player is inside cave map 9999)
local caveSnap = QTM.BuildSnapshot(mixedQuests, {
    currentZone = "통곡의 동굴 입구",
    currentMapID = 9999,
    parentMapID = 1413,
    currentZoneOnly = true,
})
assertEq(caveSnap.questCount, 2, "Cave/micro-map must still match parent zone (mapID=1413) quests")

-- Empty current zone with compactMode=true STILL emits clear actionable empty row (never blank box!)
local emptyZoneSnap = QTM.BuildSnapshot(mixedQuests, {
    currentZone = "운고로 분화구",
    currentMapID = 1449,
    currentZoneOnly = true,
    compactMode = true,
})
assertEq(emptyZoneSnap.questCount, 0, "No quests in Un'Goro")
assertEq(#emptyZoneSnap.rows, 1, "Empty current-zone compactMode must emit 1 clear empty-state row")
assertEq(emptyZoneSnap.rows[1].kind, "empty", "Row kind is empty")
assertEq(emptyZoneSnap.rows[1].clearZoneFilter, true, "Empty row supports 1-click clearZoneFilter")
assert(string.find(emptyZoneSnap.rows[1].text, "운고로 분화구", 1, true) ~= nil, "Empty row displays detected zone name")
assert(string.find(emptyZoneSnap.rows[1].text, "4개", 1, true) ~= nil, "Empty row displays total quest count")

-- Live QuestTrackerView ToggleCurrentZoneFilter & header/empty-row UX
local qtv = ns.Features.QuestTrackerView
local origGetRealZone = _G.GetRealZoneText
local origGetQuestsOnMap = _G.C_QuestLog and _G.C_QuestLog.GetQuestsOnMap
local origGetQuestUiMapID = _G.GetQuestUiMapID
local origGetBestMap = _G.C_Map and _G.C_Map.GetBestMapForUnit
local origGetMapInfo = _G.C_Map and _G.C_Map.GetMapInfo

_G.GetRealZoneText = function() return "불모의 땅" end
_G.GetQuestUiMapID = function(qid) return (qid == 5002) and 1413 or ((qid == 5004) and 1446 or 0) end
if _G.C_Map then
    _G.C_Map.GetBestMapForUnit = function() return 1413 end
    _G.C_Map.GetMapInfo = function(id)
        if id == 1413 then return { mapID = 1413, name = "불모의 땅", mapType = 3, parentMapID = 1414 } end
        if id == 1414 then return { mapID = 1414, name = "칼림도어", mapType = 2, parentMapID = 947 } end
        return nil
    end
end
if _G.C_QuestLog then
    _G.C_QuestLog.GetQuestsOnMap = function(mid)
        if mid == 1413 then
            return {
                { questID = 5003, mapID = 1413, childDepth = 0, isQuestStart = false },
                { questID = 9999, mapID = 1413, childDepth = 0, isQuestStart = true }, -- unaccepted starter must be ignored
            }
        end
        return {}
    end
end

local ctx = ns.Api.GameAdapters.GetPlayerZoneContext()
assertEq(ctx.zone, "불모의 땅", "GetPlayerZoneContext resolves primary zone")
assertEq(ctx.mapID, 1413, "GetPlayerZoneContext resolves numeric mapID")
assertEq(ctx.parentMapID, nil, "Continent parentMapID (mapType=2) must NOT leak into parentMapID")
assertEq(ctx.localQuestIDs[5003], true, "Active POI quest captured in localQuestIDs")
assertEq(ctx.localQuestIDs[9999], nil, "isQuestStart=true starter pin excluded from localQuestIDs")

-- Ensure ToggleCurrentZoneFilter auto-unminimizes & updates header title
ns.Api.ProfileStore:Set("quest", "trackerMinimized", true)
ns.Api.ProfileStore:Set("quest", "currentZoneOnly", false)
qtv:ToggleCurrentZoneFilter()
assertEq(ns.Api.ProfileStore:Get("quest", "currentZoneOnly"), true, "ToggleCurrentZoneFilter turns currentZoneOnly ON")
assertEq(ns.Api.ProfileStore:Get("quest", "trackerMinimized"), false, "Turning ON currentZoneOnly auto-unminimizes tracker")
assert(string.find(qtv.titleLbl:GetText() or "", "★ 현지역", 1, true) ~= nil, "Header switches to ★ 현지역 when filter active")

-- Clicking clearZoneFilter empty row resets currentZoneOnly to false
qtv:OnRowClick({ _rowData = { kind = "empty", clearZoneFilter = true } }, "LeftButton")
assertEq(ns.Api.ProfileStore:Get("quest", "currentZoneOnly"), false, "Clicking empty current-zone row clears filter")

_G.GetRealZoneText = origGetRealZone
_G.GetQuestUiMapID = origGetQuestUiMapID
if _G.C_Map then
    _G.C_Map.GetBestMapForUnit = origGetBestMap
    _G.C_Map.GetMapInfo = origGetMapInfo
end
if _G.C_QuestLog then
    _G.C_QuestLog.GetQuestsOnMap = origGetQuestsOnMap
end

------------------------------------------------------------------------
-- 6. Quest Completion / Turn-In "딩동" (dingdong) Chime Sound Regression
------------------------------------------------------------------------
do
    local qem = ns.Features.QuestExtraModule
    local playedFiles = {}
    local origPlaySoundFile = _G.PlaySoundFile
    local origGetMono = ns.Api.GameAdapters.GetMonotonicTime
    local mockNow = 100.0
    ns.Api.GameAdapters.GetMonotonicTime = function() return mockNow end
    _G.PlaySoundFile = function(path, ch)
        playedFiles[#playedFiles + 1] = { path = path, channel = ch }
        return true, 1
    end

    -- Reset default sound setting & state
    ns.Api.ProfileStore:Set("quest", "completionSound", true)
    ns.Api.ProfileStore:Set("ui", "alertSoundKey", "dingdong")
    qem.lastCompletionSoundAt = -999
    qem.notifiedCollections = {}

    -- (a) Turning in a quest via QUEST_TURNED_IN plays dingdong_75.ogg on Master
    __FS_FIRE_EVENT("QUEST_TURNED_IN", 7001, 500, 120)
    assertEq(#playedFiles, 1, "QUEST_TURNED_IN must play completion chime")
    assert(string.find(playedFiles[1].path, "dingdong_75.ogg", 1, true) ~= nil,
        "Default quest finish sound must play dingdong_75.ogg (got=" .. tostring(playedFiles[1].path) .. ")")
    assertEq(playedFiles[1].channel, "Master", "Quest finish chime plays on Master channel")

    -- (b) Burst throttle within 0.8s suppresses duplicate overlapping chimes
    mockNow = 100.2
    __FS_FIRE_EVENT("QUEST_TURNED_IN", 7002, 500, 120)
    assertEq(#playedFiles, 1, "Rapid burst within 0.8s must throttle duplicate chime")

    -- (c) After cooldown (>0.8s), next quest objective completion plays dingdong_75.ogg
    mockNow = 102.0
    local origCollect = ns.Api.SafeAPI.CollectQuestLog
    ns.Api.SafeAPI.CollectQuestLog = function()
        return { { questID = 7003, title = "테스트 퀘스트", isComplete = true } }
    end
    qem:CheckCollectionAlerts()
    assertEq(#playedFiles, 2, "Newly completed quest objective must play dingdong chime")
    assertEq(qem.notifiedCollections[7003], true, "Completed quest ID recorded to prevent repeat chimes")

    -- (d) Turning in quest 7003 clears notifiedCollections[7003] and plays turn-in chime
    mockNow = 104.0
    __FS_FIRE_EVENT("QUEST_TURNED_IN", 7003, 500, 120)
    assertEq(#playedFiles, 3, "Turning in quest 7003 plays dingdong chime")
    assertEq(qem.notifiedCollections[7003], nil, "Turning in clears notifiedCollections for repeatable quests")

    -- (e) Disabling quest.completionSound cleanly silences chime
    mockNow = 106.0
    ns.Api.ProfileStore:Set("quest", "completionSound", false)
    __FS_FIRE_EVENT("QUEST_TURNED_IN", 7004, 500, 120)
    assertEq(#playedFiles, 3, "Disabling quest.completionSound must silence chime")
    ns.Api.ProfileStore:Set("quest", "completionSound", true)

    ns.Api.SafeAPI.CollectQuestLog = origCollect
    ns.Api.GameAdapters.GetMonotonicTime = origGetMono
    _G.PlaySoundFile = origPlaySoundFile
end

------------------------------------------------------------------------
-- 7. Auto Buff Thank-You ("감사합니다!") & Lv<60 XP Buff Expiry Alerts
------------------------------------------------------------------------
do
    local ag = ns.Features.AutoGreetingModule
    local origNow = _G.__FS_MOCK.now
    local origInGroup = _G.__FS_MOCK.inGroup
    local origInRaid = _G.__FS_MOCK.inRaid
    local origUnitNames = _G.__FS_MOCK.unitNames
    local origAuraList = _G.__FS_MOCK.auraList
    local origUnitLevel = _G.UnitLevel
    local mockPlayerLevel = 24
    _G.UnitLevel = function() return mockPlayerLevel end

    -- (a) Auto buff thank-you sends "감사합니다!" in PARTY when in 5-man group
    ns.Api.ProfileStore:Set("social", "autoThankBuff", true)
    ag.state.cooldowns = {}
    ag.state.aurasPrimed = true
    ag.state.rosterSynced = true
    ag.state.knownMembers = { ["영웅"] = true, ["힐러사제"] = true }
    ag.state.seenAuras = {}
    _G.__FS_MOCK.now = 5000
    _G.__FS_MOCK.inGroup = true
    _G.__FS_MOCK.inRaid = false
    _G.__FS_MOCK.unitNames = { player = "영웅", party1 = "힐러사제" }
    _G.__FS_MOCK.sentChats = {}
    _G.__FS_MOCK.auraList = {
        { spellId = 1243, name = "신의 권능: 인내", sourceUnit = "party1", duration = 1800 },
    }
    __FS_FIRE_EVENT("UNIT_AURA", "player")
    assertEq(#_G.__FS_MOCK.sentChats, 1, "External buff in party must send thank-you chat")
    assertEq(_G.__FS_MOCK.sentChats[1].channel, "PARTY", "Party buff thank-you uses PARTY channel")
    assert(string.find(_G.__FS_MOCK.sentChats[1].msg, "감사합니다", 1, true) ~= nil,
        "Thank-you chat must contain '감사합니다' (got=" .. tostring(_G.__FS_MOCK.sentChats[1].msg) .. ")")
    assert(string.find(_G.__FS_MOCK.sentChats[1].msg, "신의 권능: 인내", 1, true) ~= nil,
        "Thank-you chat includes buff name")

    -- (b) Short combat HoT (<180s) must NOT trigger spammy thank-you
    _G.__FS_MOCK.now = 5100
    _G.__FS_MOCK.auraList = {
        { spellId = 1243, name = "신의 권능: 인내", sourceUnit = "party1", duration = 1800 },
        { spellId = 139,  name = "소생",             sourceUnit = "party1", duration = 15 },
    }
    __FS_FIRE_EVENT("UNIT_AURA", "player")
    assertEq(#_G.__FS_MOCK.sentChats, 1, "Short HoT (<180s) must NOT trigger thank-you spam")

    -- (c) Solo open-world external buff sends WHISPER to caster (hardware-event safe!)
    _G.__FS_MOCK.now = 5200
    _G.__FS_MOCK.inGroup = false
    _G.__FS_MOCK.inRaid = false
    _G.__FS_MOCK.unitNames = { player = "영웅", target = "지나가던법사" }
    _G.__FS_MOCK.auraList = {
        { spellId = 1459, name = "신비한 지능", sourceUnit = "target", duration = 1800 },
    }
    __FS_FIRE_EVENT("UNIT_AURA", "player")
    assertEq(#_G.__FS_MOCK.sentChats, 2, "Solo open-world buff must send whisper thank-you")
    assertEq(_G.__FS_MOCK.sentChats[2].channel, "WHISPER", "Solo open-world thank-you uses WHISPER (never blocked SAY)")
    assertEq(_G.__FS_MOCK.sentChats[2].target, "지나가던법사", "Whisper targets buff caster")
    assert(string.find(_G.__FS_MOCK.sentChats[2].msg, "감사합니다", 1, true) ~= nil, "Whisper contains '감사합니다'")

    -- (c2) Inside raids, auto buff thank-you is suppressed (no mass-buff whisper/chat spam)
    _G.__FS_MOCK.now = 5300
    _G.__FS_MOCK.inGroup = true
    _G.__FS_MOCK.inRaid = true
    local okRaidBuff, rRaidBuff = ag:OnExternalBuffReceived("공대사제", "신의 권능: 인내")
    assertEq(okRaidBuff, false, "Raid buff thank-you must be suppressed")
    assertEq(rRaidBuff, "RAID_SUPPRESSED", "Raid buff returns RAID_SUPPRESSED")
    assertEq(#_G.__FS_MOCK.sentChats, 2, "Raid suppression sends 0 chats")
    _G.__FS_MOCK.inRaid = false

    -- (d) Lv<60 XP Buff Expiry Alert (음식 "포만감", 침낭 "충분한 휴식")
    local CAM = ns.Domain.CombatAlertModel
    assertEq(CAM.IsXpBuffAura(433106, "충분한 휴식"), true, "Sleeping bag spell 433106 recognized as XP buff")
    assertEq(CAM.IsXpBuffAura(0, "포만감"), true, "Food '포만감' recognized as XP buff")
    assertEq(CAM.IsXpBuffAura(1243, "신의 권능: 인내"), false, "Ordinary stamina buff is NOT an XP buff")

    local qem = ns.Features.QuestExtraModule
    local xpSounds = {}
    local origPlaySoundFile = _G.PlaySoundFile
    _G.PlaySoundFile = function(path, ch)
        xpSounds[#xpSounds + 1] = { path = path, channel = ch }
        return true, 1
    end
    ns.Api.ProfileStore:Set("quest", "xpBuffExpiryAlert", true)
    ns.Api.ProfileStore:Set("ui", "alertSoundKey", "dingdong")
    qem.xpBuffPrimed = false
    qem.activeXpBuffs = nil
    qem.lastXpAlertAt = -999
    mockPlayerLevel = 24
    _G.__FS_MOCK.now = 6000
    _G.__FS_MOCK.auraList = {
        { spellId = 25694,  name = "포만감" },
        { spellId = 433106, name = "충분한 휴식" },
        { spellId = 1243,   name = "신의 권능: 인내" },
    }
    -- First scan primes baseline silently
    local n0 = qem:CheckXpBuffExpiry()
    assertEq(n0, 0, "Initial XP buff prime must not trigger alert")
    assertEq(#xpSounds, 0, "Initial prime plays 0 sounds")

    -- Ordinary buff disappearing triggers 0 XP alerts
    _G.__FS_MOCK.auraList = {
        { spellId = 25694,  name = "포만감" },
        { spellId = 433106, name = "충분한 휴식" },
    }
    local nOrd = qem:CheckXpBuffExpiry()
    assertEq(nOrd, 0, "Ordinary combat buff expiring must not trigger XP buff alert")

    -- Food buff "포만감" disappearing at Lv.24 triggers alert + dingdong chime!
    _G.__FS_MOCK.now = 6010
    _G.__FS_MOCK.auraList = {
        { spellId = 433106, name = "충분한 휴식" },
    }
    local nExp, expNames = qem:CheckXpBuffExpiry()
    assertEq(nExp, 1, "Expiring food buff '포만감' at Lv.24 must trigger XP expiry alert")
    assertEq(expNames[1], "포만감", "Expired buff name accurately reported")
    assertEq(#xpSounds, 1, "XP buff expiry plays dingdong notification sound")
    assert(string.find(xpSounds[1].path, "dingdong_75.ogg", 1, true) ~= nil, "XP expiry plays dingdong_75.ogg")

    -- Secret/unreadable aura scan preserves activeXpBuffs (0 false alarms!)
    _G.__FS_MOCK.auraList = { { spellId = FS_MakeSecret("s", "number"), name = "비밀" } }
    local nSec, rSec = qem:CheckXpBuffExpiry()
    assertEq(nSec, 0, "Secret aura scan must NOT trigger false expiry")
    assertEq(rSec, "UNREADABLE", "Secret scan returns UNREADABLE")
    assertEq(qem.activeXpBuffs["충분한 휴식"], true, "Secret scan preserves prior activeXpBuffs")

    -- At Lv.60, XP buff expiry alert is completely silent
    mockPlayerLevel = 60
    _G.__FS_MOCK.auraList = {}
    local n60, r60 = qem:CheckXpBuffExpiry()
    assertEq(n60, 0, "Lv.60 player must receive 0 XP buff expiry alerts")
    assertEq(r60, "MAX_LEVEL", "Lv.60 returns MAX_LEVEL")

    _G.PlaySoundFile = origPlaySoundFile
    _G.UnitLevel = origUnitLevel
    _G.__FS_MOCK.now = origNow
    _G.__FS_MOCK.inGroup = origInGroup
    _G.__FS_MOCK.inRaid = origInRaid
    _G.__FS_MOCK.unitNames = origUnitNames
    _G.__FS_MOCK.auraList = origAuraList
end

print("OK: 29_faction_quests_home_and_db_refresh")
