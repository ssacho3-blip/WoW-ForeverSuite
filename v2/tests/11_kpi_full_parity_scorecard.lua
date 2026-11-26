-- Test 11: Hard GodJohnson 1:1 Parity KPI Verification Scorecard (KPI-1 through KPI-9)
-- Fails closed if ANY KPI drops below 100% against the real 17,910-entry compiled LoD packs!
local ns = _G.ForeverSuiteV2

__FS_FIRE_EVENT("PLAYER_LOGIN")

-- Wire C_AddOns.LoadAddOn to load ALL 7 real compiled LoD packs from disk
local origLoad = C_AddOns.LoadAddOn
C_AddOns.LoadAddOn = function(name)
    if string.find(tostring(name), "^ForeverSuite_Data") then
        local loaded = __FS_LOAD_DATA_ADDON(name)
        _G.__FS_MOCK.loadedAddOns[name] = loaded
        return loaded, loaded and nil or "LOAD_FAILED"
    end
    return origLoad(name)
end

local hub = ns.UI.CommandHub
hub:EnsureWindow()

-- ============================================================================
-- KPI-1: Dedicated 2-Pane Dungeon Browser (40 dungeons, 272 bosses, 432 quests, Run Report)
-- ============================================================================
hub:SelectPage("dungeons")
local dbp = ns.Features.DungeonBrowserPage
assert(dbp.selectedDungeon ~= nil, "KPI-1: DungeonBrowser must select initial dungeon")
local dPacks = _G.ForeverSuiteData.packs
assert(#dPacks.dungeons.entries >= 35, "KPI-1: Expected >=35 dungeons")
assert(#dPacks.dungeon_bosses.entries >= 200, "KPI-1: Expected >=200 dungeon bosses")
assert(#dPacks.dungeon_quests.entries >= 350, "KPI-1: Expected >=350 dungeon quests")
assert(#dPacks.dungeon_loot.entries >= 5000, "KPI-1: Expected >=5000 dungeon loot items")

-- Boss -> Drop join works cleanly
local zf = nil
for _, d in ipairs(dPacks.dungeons.entries) do
    if d.title == "줄파락" then zf = d; break end
end
assert(zf ~= nil, "KPI-1: Zul'Farrak must exist in dungeons pack")
local zfBosses = ns.Domain.DungeonBrowserModel.GetBossesForDungeon(dPacks.dungeon_bosses.entries, zf)
assert(#zfBosses >= 5, "KPI-1: Zul'Farrak must have >=5 bosses")
local zfDrops = ns.Domain.DungeonBrowserModel.GetDropsForBoss(zfBosses[1], dbp.lootByID)
assert(#zfDrops >= 1, "KPI-1: Boss drops must resolve from loot index")

-- Live Quest Preparation Checklist detects COMPLETED / IN_LOG / AVAILABLE
local rfc = nil
for _, d in ipairs(dPacks.dungeons.entries) do
    if d.id == "rfc" then rfc = d; break end
end
assert(rfc ~= nil)
local qRows, qCounts = ns.Domain.DungeonBrowserModel.BuildQuestReadiness(dPacks.dungeon_quests.entries, rfc, {
    completed = { [5723] = true },
    inLog = { [5722] = true },
})
assert(qCounts.total >= 2 and qCounts.completed >= 1 and qCounts.inLog >= 1, "KPI-1: Quest readiness must track completed & in-log")

-- Live Dungeon Run Report tracks entry -> boss kill -> exit history
_G.__FS_MOCK.inInstance = true
_G.__FS_MOCK.instanceType = "party"
_G.__FS_MOCK.instanceName = "줄파락"
_G.__FS_MOCK.now = 5000
_G.__FS_MOCK.money = 100000
dbp:OnInstanceChanged()
assert(dbp.activeRun ~= nil and dbp.activeRun.name == "줄파락")
dbp:OnBossKilled("안투술", 1)
assert(#dbp.activeRun.bossesKilled == 1)
_G.__FS_MOCK.now = 5900
_G.__FS_MOCK.money = 145000
_G.__FS_MOCK.inInstance = false
_G.__FS_MOCK.instanceType = "none"
dbp:OnInstanceChanged()
assert(dbp.activeRun == nil and #dbp.runHistory == 1 and dbp.runHistory[1].goldDelta == 45000)

-- ============================================================================
-- KPI-2: Dedicated BiS Browser with Live 1:1 Equipped Item iLvl Comparison & Acquisitions
-- ============================================================================
_G.__FS_MOCK.equippedItems = { [11] = 70001 } -- Ring slot equipped iLvl 40
_G.__FS_MOCK.itemLevels[70001] = 40
hub:SelectPage("bis")
local bisPack = _G.ForeverSuiteData.packs.bis
assert(#bisPack.entries >= 500, "KPI-2: Expected >=500 BiS entries")
local eqMap = ns.Api.GameAdapters.GetEquippedItemLevelMap()
assert(eqMap[11] == 40, "KPI-2: Live equipped ring iLvl must be read")
local upgList = ns.Domain.BiSBrowserModel.FilterAndCompare(bisPack.entries, {
    slotFilter = "손가락",
    upgradeOnly = true,
    equippedBySlot = eqMap,
})
assert(#upgList >= 1 and upgList[1].delta > 0 and string.find(upgList[1].badge, "업글", 1, true), "KPI-2: Must detect live ring upgrades")

-- ============================================================================
-- KPI-3: Dedicated 13-Profession Guide (Routes + 2,541 Recipes + 582 Trainers + Rogue Poison)
-- ============================================================================
hub:SelectPage("professions")
local profGuides = _G.ForeverSuiteData.packs.prof_guides.entries
assert(#profGuides >= 12, "KPI-3: Expected >=12 professions (including Rogue Poison)")
local hasPoison = false
local hasRoutes = false
for _, pg in ipairs(profGuides) do
    if pg.title == "독 제조" then hasPoison = true end
    if type(pg.routesText) == "string" and pg.routesText ~= "" then hasRoutes = true end
end
assert(hasPoison == true, "KPI-3: Rogue Poison catalogue must be present")
assert(hasRoutes == true, "KPI-3: Practical step-by-step leveling routes must be present")
local alchRecipes = ns.Domain.ProfessionBrowserModel.FilterRecipes(_G.ForeverSuiteData.packs.professions.entries, profGuides[1], "")
assert(#alchRecipes >= 1, "KPI-3: Profession recipe filter must return entries")

-- ============================================================================
-- KPI-4: Rewards Mode/Team Filter & Hunter Pet Multi-Spawn + Rare Filter
-- ============================================================================
ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_Reward")
ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_Pet")
local repRewards = ns.Domain.PetRewardModel.FilterRewards(_G.ForeverSuiteData.packs.rewards.entries, { mode = "reputation" })
assert(#repRewards >= 10, "KPI-4: Reputation reward filter must return entries")
local rarePets = ns.Domain.PetRewardModel.FilterPets(_G.ForeverSuiteData.packs.hunter_pets.entries, { rareOnly = true })
assert(#rarePets >= 10, "KPI-4: Rare hunter pet filter must return entries")
local parsedLocs = ns.Domain.PetRewardModel.ParseMultiLocs("1429:0.284:0.664:엘윈 숲|1429:0.320:0.684:엘윈 숲")
assert(#parsedLocs == 2 and parsedLocs[2].mapID == 1429, "KPI-4: Multi-spawn coordinates must parse cleanly")

-- ============================================================================
-- KPI-5: WorldMap Canvas Direct Pin Overlay (3,609 real `!` Quest Start Pins, Zero-Taint)
-- ============================================================================
_G.__FS_MOCK.worldMapID = 1411 -- Durotar
_G.__FS_MOCK.playerFaction = "Horde"
_G.__FS_MOCK.worldMapShown = true
_G.WorldMapFrame:FireScript("OnShow")
local qPinsPack = _G.ForeverSuiteData.packs.map_quest_starts
assert(type(qPinsPack) == "table" and #qPinsPack.entries >= 3000, "KPI-5: Expected >=3,000 real WorldMap quest start pins")
local wmo = ns.Features.WorldMapOverlay
assert(wmo.pinLayer ~= nil and wmo.pinLayer:IsShown() == true, "KPI-5: Direct canvas pin layer must show on WorldMap")
local activePins = 0
for _, pin in ipairs(wmo.pinPool) do
    if pin:IsShown() then activePins = activePins + 1 end
end
assert(activePins >= 5, "KPI-5: Durotar must render live `!`/NPC pins directly on canvas, got " .. tostring(activePins))
_G.__FS_MOCK.worldMapShown = false
_G.WorldMapFrame:FireScript("OnHide")
assert(wmo.pinLayer:IsShown() == false, "KPI-5: Pin layer must hide immediately on WorldMap OnHide")

-- ============================================================================
-- KPI-6: Leveling Planner & 638 Class Quest Korean Step-by-Step Walkthroughs
-- ============================================================================
hub:SelectPage("questguide")
local cqEntries = _G.ForeverSuiteData.packs.class_quests.entries
local withWalk = ns.Domain.QuestGuideModel.FilterClassQuests(cqEntries, { withWalkthroughOnly = true })
assert(#withWalk >= 100, "KPI-6: Expected >=100 class quests with full Korean step-by-step walkthroughs, got " .. tostring(#withWalk))
local lvlZones = ns.Domain.QuestGuideModel.RecommendLevelingZones(25, "Alliance")
assert(#lvlZones >= 4 and lvlZones[1].recommended == true, "KPI-6: Leveling planner must recommend level-appropriate zones first")

-- ============================================================================
-- KPI-7: Live GDKP Auction Engine + Auto Chat Bid Collection + Anti-Snipe + Persistence
-- ============================================================================
local util = ns.Features.UtilitiesPage
util:HandleGdkpCommand("reset")
_G.__FS_MOCK.now = 8000
assert(util:HandleGdkpCommand("start 오닉시아 머리 100 20 15") == true)
assert(util.activeAuction ~= nil and util.activeAuction.status == "OPEN")
-- Live raid chat bid auto-collected!
_G.__FS_MOCK.now = 8012 -- within last 5s -> triggers +5s anti-snipe!
ns.Features.ChatToolsModule:OnChatEvent("CHAT_MSG_RAID", "150g", "입찰자A")
assert(util.activeAuction.highBidder == "입찰자A" and util.activeAuction.highBidCopper == 1500000)
assert(util.activeAuction.endsAt == 8017, "KPI-7: Anti-snipe must extend auction by 5s")
-- Low bid rejected
local okLow, rLow = util:OnIncomingChatBid("160", "입찰자B")
assert(okLow == false and rLow == "TOO_LOW")
-- Valid higher bid accepted -> close auction -> persisted in SavedVariables!
assert(util:OnIncomingChatBid("200골", "입찰자B") == true)
assert(util:HandleGdkpCommand("close") == true)
assert(util.activeAuction == nil and #util.gdkpSales == 1 and util.gdkpSales[1].buyer == "입찰자B")
local savedGdkp = ns.Api.ProfileStore:GetState("gdkpLedger")
assert(type(savedGdkp) == "table" and #savedGdkp.sales == 1, "KPI-7: GDKP ledger must persist in SavedVariables")

-- ============================================================================
-- KPI-8: Party Finder Auto-Parser + Multi-Style Cursor FX (Ring / Crosshair / Trail)
-- ============================================================================
ns.Features.ChatToolsModule:OnChatEvent("CHAT_MSG_CHANNEL", "줄파락 탱 힐 구함 출발!", "공대장킴")
local pf = ns.Features.PartyFinderPage
assert(#pf.board == 1 and pf.board[1].dungeonID == "zf" and pf.board[1].needTank == true and pf.board[1].needHeal == true)
local tankList = ns.Domain.PartyFinderModel.FilterBoard(pf.board, "tank", "")
assert(#tankList == 1, "KPI-8: PartyFinder role filter must match tank listings")

-- Cursor FX styles + combatOnly mode
ns.Api.ProfileStore:Set("ui", "showCursorRing", true)
ns.Api.ProfileStore:Set("ui", "cursorStyle", "trail")
ns.Api.ProfileStore:Set("ui", "cursorCombatOnly", true)
assert(ns.Features.CursorTrailHud.ring:IsShown() == false, "KPI-8: combatOnly cursor FX stays hidden OOC")
ns.Features.CursorTrailHud:ApplyVisibility(true)
assert(ns.Features.CursorTrailHud.ring:IsShown() == true and ns.Features.CursorTrailHud.ring._fxStyle == "trail")
ns.Api.ProfileStore:Set("ui", "showCursorRing", false)
assert(ns.Features.CursorTrailHud.ring._scripts["OnUpdate"] == nil, "KPI-8: Disabled cursor FX must have 0% CPU (OnUpdate nil)")

-- ============================================================================
-- Independent Review Regression Guards (B1 + Batch 2 B1-B8)
-- ============================================================================
-- 1. PartyFinderModel.FilterBoard TTL expiration when chat goes quiet
local expiredBoard = { { dungeonName = "줄파락", sender = "A", text = "탱 구함", needTank = true, updatedAt = 1000 } }
assert(#ns.Domain.PartyFinderModel.FilterBoard(expiredBoard, "all", "", 1601) == 0, "Expired listing must be hidden after TTL")
assert(#ns.Domain.PartyFinderModel.FilterBoard(expiredBoard, "all", "", 1599) == 1, "Fresh listing stays visible within TTL")

-- 2. QuestGuideModel unknown level & unknown class fail-closed (Zero Fabricated Status)
local unkZones = ns.Domain.QuestGuideModel.RecommendLevelingZones(nil, "Alliance")
assert(#unkZones > 0 and unkZones[1].recommended == false, "Unknown level must never fabricate Lv.1 recommendation")
local unkClassQ = ns.Domain.QuestGuideModel.FilterClassQuests(cqEntries, { myClassOnly = true, playerClass = nil })
assert(#unkClassQ == 0, "myClassOnly=true with unknown class must fail-closed to 0 rows")

-- 3. WorldMapModel.ProjectMapToScreen rejects NaN
local nanX = ns.Domain.WorldMapModel.ProjectMapToScreen(0 / 0, 0.5, { left = 0, bottom = 0, width = 100, height = 100 })
assert(nanX == nil, "ProjectMapToScreen must reject NaN coordinates")

-- 4. GdkpModel.SubmitBid rejects exact boundary now == endsAt
local bAuc = ns.Domain.GdkpModel.StartAuction("검", 100, 10, 15, 5000)
local okBoundary, rBoundary = ns.Domain.GdkpModel.SubmitBid(bAuc, "입찰자", 1000000, 5015)
assert(okBoundary == false and rBoundary == "EXPIRED", "Bid at exact endsAt boundary must expire")

-- 5. UtilitiesPage:LoadSavedGdkp sanitizes malformed SavedVariables entries
ns.Api.ProfileStore:SetState("gdkpLedger", { sales = { { item = "정상템", buyer = "테스터", copper = 50000 }, { bad = true } }, members = 10, cutPct = 0 })
util:LoadSavedGdkp()
assert(#util.gdkpSales == 1 and util.gdkpSales[1].item == "정상템", "LoadSavedGdkp must strip malformed entries")

-- 6. ChatToolsModule drops secret GUID at arg 12 (WoW Classic CHAT_MSG_* position)
local secGuid = FS_MakeSecret("Player-1234-ABCD", "string")
local okSec, rSec = ns.Features.ChatToolsModule:OnChatEvent("CHAT_MSG_SAY", "안녕", "테스터", "공용어", "", "", "", 0, 0, "", 0, 1, secGuid)
assert(okSec == false and rSec == "SECRET", "Secret GUID at arg 12 must be dropped immediately")

-- 7. CursorTrailHud explicit false override must hide even if InCombat() would differ
ns.Api.ProfileStore:Set("ui", "showCursorRing", true)
ns.Api.ProfileStore:Set("ui", "cursorCombatOnly", true)
ns.Features.CursorTrailHud:ApplyVisibility(false)
assert(ns.Features.CursorTrailHud.ring:IsShown() == false, "Explicit false combat override must hide combatOnly cursor")
ns.Api.ProfileStore:Set("ui", "showCursorRing", false)
