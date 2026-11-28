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

print("OK: 29_faction_quests_home_and_db_refresh")
