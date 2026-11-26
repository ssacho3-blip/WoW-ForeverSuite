-- Test 12: KPI-10 (Combat HUD Pack), KPI-11 (Corpse Guide, Quest Announcer, Transport Docks, Special/Books),
--          and KPI-12 (Extended Stats, Trade History/Farm GPH, Favorite /way Bookmarks, Profile Export/Import)
--          end-to-end verification against real compiled ForeverSuite_Data_Atlas pack.

local ns = ForeverSuiteV2
assert(ns ~= nil, "ForeverSuiteV2 namespace missing")

-- Mock additional WoW Classic APIs for KPI-10/11/12 testing
local mockCombo = 0
local mockHasTarget = false
local mockDist = { [3] = false, [2] = false, [1] = true, [4] = true }
local mockCorpsePos = { x = 0.42, y = 0.61 }
local mockDead = false
local mockTradePartner = "거래상대"
local mockGiveCopper, mockRecvCopper = 50000, 120000

_G.UnitPower = function(_, powerType) return (powerType == 4) and mockCombo or 0 end
_G.UnitPowerMax = function(_, powerType) return (powerType == 4) and 5 or 100 end
_G.UnitExists = function(u)
    if u == "target" then return mockHasTarget end
    return true
end
_G.CheckInteractDistance = function(u, idx)
    if u == "target" then return mockDist[idx] end
    return false
end
_G.UnitIsDeadOrGhost = function() return mockDead end
_G.C_DeathInfo = {
    GetCorpseMapPosition = function(mid)
        if mid == 1453 then return mockCorpsePos end
        return nil
    end,
}
_G.UnitAttackPower = function() return 450, 50, 0 end
_G.GetCritChance = function() return 22.5 end
_G.GetSpellCritChance = function() return 14.2 end
_G.GetSpellBonusDamage = function() return 310 end
_G.UnitArmor = function() return 2400, 2850 end
_G.GetDodgeChance = function() return 8.4 end
_G.GetParryChance = function() return 5.0 end
_G.GetBlockChance = function() return 0 end
_G.GetUnitSpeed = function() return 0, 7.56 end -- standing still (0) with 108% run speed (7.56)
_G.GetGameTime = function() return 21, 35 end
_G.GetPlayerTradeMoney = function() return mockGiveCopper end
_G.GetTargetTradeMoney = function() return mockRecvCopper end
_G.GetTradePlayerItemInfo = function(i) if i == 1 then return "두꺼운 가죽", nil, 5 end return nil end
_G.GetTradeTargetItemInfo = function(i) if i == 1 then return "신비한 수정", nil, 2 end return nil end
_G.UnitName = function(u)
    if u == "npc" then return mockTradePartner end
    return "영웅"
end

-- Trigger Bootstrap:Init() and wire real disk LoD pack loader
__FS_FIRE_EVENT("PLAYER_LOGIN")
local origLoad = C_AddOns.LoadAddOn
C_AddOns.LoadAddOn = function(name)
    if string.find(tostring(name), "^ForeverSuite_Data") then
        local loaded = __FS_LOAD_DATA_ADDON(name)
        _G.__FS_MOCK.loadedAddOns[name] = loaded
        return loaded, loaded and nil or "LOAD_FAILED"
    end
    return origLoad(name)
end

-- ============================================================================
-- KPI-10: Combo Points HUD, Target Range Display, Short Buffs, Screen Clock
-- ============================================================================
local ch = ns.Features.CombatHudPack
assert(ch.comboFrame ~= nil and ch.rangeFrame ~= nil and ch.buffFrame ~= nil and ch.clockFrame ~= nil, "KPI-10 HUD frames must exist")

-- Combo Points: 0 -> hidden, 5 -> shown & full
mockCombo = 0
ch:RefreshCombo()
assert(ch.comboFrame:IsShown() == false, "Combo HUD must hide at 0 points")
mockCombo = 5
ch:RefreshCombo()
assert(ch.comboFrame:IsShown() == true, "Combo HUD must show at 5 points")
local cEval = ns.Domain.CombatHudModel.EvaluateComboPoints(5, 5)
assert(cEval.active == true and cEval.isFull == true)

-- Target Range: no target -> hidden & ticker nil (0% idle CPU); target at <=10m -> shown
mockHasTarget = false
ch:RefreshRange()
assert(ch.rangeFrame:IsShown() == false and ch.rangeTicker == nil, "Range HUD must stay idle when no target")
mockHasTarget = true
mockDist[3] = true
ch:RefreshRange()
assert(ch.rangeFrame:IsShown() == true and ch.rangeLabel._text == "근접 (≤10m)", "Range HUD must classify <=10m melee")
mockHasTarget = false
ch:RefreshRange()
assert(ch.rangeFrame:IsShown() == false and ch.rangeTicker == nil)

-- Short Buffs filter & sort
local shortList = ns.Domain.CombatHudModel.FilterShortBuffs({
    { name = "난도질", spellId = 5171, duration = 21, expirationTime = 1004.0 },
    { name = "전력 질주", spellId = 2983, duration = 15, expirationTime = 1012.0 },
    { name = "신비한 지능", spellId = 1459, duration = 1800, expirationTime = 2500.0 },
}, 1000.0, 30, 4)
assert(#shortList == 2, "Short buffs must exclude >30s long buffs")
assert(shortList[1].name == "난도질" and shortList[1].urgent == true, "Short buffs must sort soonest first & flag <=5s urgent")

-- Screen Clock: default OFF (0% CPU), ON shows local+server time
assert(ch.clockFrame:IsShown() == false and ch.clockTicker == nil, "Screen clock must be OFF by default")
ns.Api.ProfileStore:Set("ui", "showScreenClock", true)
assert(ch.clockFrame:IsShown() == true and ch.clockTicker ~= nil, "Screen clock must activate when enabled")
ns.Api.ProfileStore:Set("ui", "showScreenClock", false)
assert(ch.clockFrame:IsShown() == false and ch.clockTicker == nil, "Screen clock must cancel ticker when disabled")

-- ============================================================================
-- KPI-11: Corpse Guide, Quest Progress Announcer, Transport Docks, Special/Books
-- ============================================================================
-- Corpse Guide: PLAYER_DEAD sets /way to corpse; PLAYER_ALIVE clears it
_G.__FS_MOCK.playerPos = { mapID = 1453, x = 0.50, y = 0.50 }
mockDead = true
ns.Features.CorpseGuideModule:OnPlayerDead()
assert(ns.Features.CorpseGuideModule.active == true, "CorpseGuide must activate on PLAYER_DEAD")
assert(ns.Features.NavigationHud.target ~= nil and ns.Features.NavigationHud.target.label == "내 시체 위치", "CorpseGuide must set NavigationHud target to corpse")
mockDead = false
ns.Features.CorpseGuideModule:OnPlayerRevived()
assert(ns.Features.CorpseGuideModule.active == false and ns.Features.NavigationHud.target == nil, "CorpseGuide must clear on revive")

-- Quest Progress Party Announcer: pure diff emits 0 on prime, emits objective & completion on transition
local a0, st1 = ns.Domain.TravelQuestModel.DiffQuestProgress(nil, {
    { questID = 100, title = "코볼트 퇴치", isComplete = false, objectives = { { text = "코볼트 5/10", finished = false } } },
})
assert(#a0 == 0, "Initial prime must emit 0 announcements")
local a1, st2 = ns.Domain.TravelQuestModel.DiffQuestProgress(st1, {
    { questID = 100, title = "코볼트 퇴치", isComplete = false, objectives = { { text = "코볼트 10/10", finished = true } } },
})
assert(#a1 == 1 and string.find(a1[1], "완료", 1, true) ~= nil, "Objective completion must emit 1 announcement")
local a2, _ = ns.Domain.TravelQuestModel.DiffQuestProgress(st2, {
    { questID = 100, title = "코볼트 퇴치", isComplete = true, objectives = { { text = "코볼트 10/10", finished = true } } },
})
assert(#a2 == 1 and string.find(a2[1], "완료 보고", 1, true) ~= nil, "Quest completion must emit completion announcement")

-- Real compiled Atlas pack: Transport Docks (27) + Special/Library Books (44)
assert(ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_Atlas") == true)
local atlasNpcs = _G.ForeverSuiteData.packs.atlas_npcs.entries
local transports = ns.Domain.WorldMapModel.FilterPOIs(atlasNpcs, 1453, "transport", "", 10)
assert(#transports >= 2, "KPI-11: Stormwind must have compiled boat/tram transport docks")
local specPack = _G.ForeverSuiteData.packs.special_guides
assert(type(specPack) == "table" and #specPack.entries >= 40, "KPI-11: Expected >=40 compiled Forever library books & special quests")
local torchMatches = ns.Domain.TravelQuestModel.FilterSpecialGuides(specPack.entries, "special", "횃불")
assert(#torchMatches == 1 and torchMatches[1].mapID == 1431, "KPI-11: Night Watchman's Torch must be searchable with exact mapID")

-- ============================================================================
-- KPI-12: Extended Stats, Trade Log & Farm GPH, Favorite /way, Profile Export/Import
-- ============================================================================
-- Extended Stats (standing still must still report runSpeed 108%, not 0%)
local st = ns.Api.GameAdapters.GetExtendedCharacterStats()
assert(st.attackPower == 500 and st.spellPower == 310 and st.armor == 2850 and st.moveSpeedPct == 108)
local stLines = ns.Domain.PowerQoLModel.FormatExtendedStatsLines(st)
assert(#stLines == 4 and string.find(stLines[1].right, "AP 500", 1, true) ~= nil)
local nilStLines = ns.Domain.PowerQoLModel.FormatExtendedStatsLines({})
assert(string.find(nilStLines[4].right, "—%", 1, true) == nil, "Nil moveSpeedPct must never render '—%'")

-- B1/B2/B3 + PLAYER_ALIVE ghost retention regression guards
assert(ns.Domain.CombatHudModel.ClassifyTargetRange(true, false, nil, nil, nil) == nil, "B1: Never fabricate >28m when 28m checks are nil")
assert(ns.Domain.CombatHudModel.ClassifyTargetRange(true, false, false, false, false).label == "원거리 (>28m)", "B1: Valid >28m when 28m check is false")
_G.__FS_MOCK.inCombat = true
mockHasTarget = true
ch:RefreshRange()
assert(ch.rangeFrame:IsShown() == false and ch.rangeTicker == nil, "B2: Range HUD must pause in combat to avoid ADDON_ACTION_BLOCKED")
_G.__FS_MOCK.inCombat = false
mockHasTarget = false

-- B3 DDT: All 6 trade event-order, timestamp fail-closed, & two-trade attribution cases via real EventBus
local tl = ns.Features.TradeLogModule
-- Case 1: ERR_TRADE_COMPLETE -> TRADE_CLOSED (after accept)
_G.__FS_MOCK.now = 2000
tl.log = {}
__FS_FIRE_EVENT("TRADE_SHOW")
__FS_FIRE_EVENT("TRADE_ACCEPT_UPDATE", 1, 0)
__FS_FIRE_EVENT("UI_INFO_MESSAGE", 1, "거래가 완료되었습니다.")
__FS_FIRE_EVENT("TRADE_CLOSED")
assert(#tl.log == 1 and tl.log[1].partner == "거래상대" and tl.log[1].givenCopper == 50000 and tl.log[1].receivedCopper == 120000, "Case 1: Info -> Close must record once")

-- Case 2: TRADE_CLOSED (x2) -> ERR_TRADE_COMPLETE within 2.0s grace window
_G.__FS_MOCK.now = 2100
tl.log = {}
__FS_FIRE_EVENT("TRADE_SHOW")
__FS_FIRE_EVENT("TRADE_ACCEPT_UPDATE", 0, 1)
__FS_FIRE_EVENT("TRADE_CLOSED")
__FS_FIRE_EVENT("TRADE_CLOSED")
_G.__FS_MOCK.now = 2102.0 -- exact 2.0s boundary included
__FS_FIRE_EVENT("UI_INFO_MESSAGE", 1, "거래가 완료되었습니다.")
assert(#tl.log == 1, "Case 2: Close(x2) -> Info at exact 2.0s must record")
__FS_FIRE_EVENT("UI_INFO_MESSAGE", 1, "거래가 완료되었습니다.")
assert(#tl.log == 1, "Duplicate Info must not double-log")

-- Case 3: Expired ERR_TRADE_COMPLETE (>2s after TRADE_CLOSED) must be ignored
_G.__FS_MOCK.now = 2200
tl.log = {}
__FS_FIRE_EVENT("TRADE_SHOW")
__FS_FIRE_EVENT("TRADE_ACCEPT_UPDATE", 1, 0)
__FS_FIRE_EVENT("TRADE_CLOSED")
_G.__FS_MOCK.now = 2203.5
__FS_FIRE_EVENT("UI_INFO_MESSAGE", 1, "거래가 완료되었습니다.")
assert(#tl.log == 0, "Case 3: Stale Info (>2s) must be ignored")

-- Case 4: Both accepted then canceled/failed without ERR_TRADE_COMPLETE -> ZERO fabricated trade
_G.__FS_MOCK.now = 2300
tl.log = {}
__FS_FIRE_EVENT("TRADE_SHOW")
__FS_FIRE_EVENT("TRADE_ACCEPT_UPDATE", 1, 1)
__FS_FIRE_EVENT("TRADE_CLOSED")
assert(#tl.log == 0, "Case 4: Canceled trade without ERR_TRADE_COMPLETE must NEVER fabricate a trade entry")

-- Case 5: Two-trade race — Trade A closes, Trade B opens (unaccepted), delayed ERR_TRADE_COMPLETE arrives -> MUST NOT mis-attribute B!
_G.__FS_MOCK.now = 2400
tl.log = {}
mockTradePartner = "상대A"
__FS_FIRE_EVENT("TRADE_SHOW")
__FS_FIRE_EVENT("TRADE_ACCEPT_UPDATE", 1, 0)
__FS_FIRE_EVENT("TRADE_CLOSED")
mockTradePartner = "상대B"
__FS_FIRE_EVENT("TRADE_SHOW") -- opens unaccepted trade B, clears lastClosed
__FS_FIRE_EVENT("UI_INFO_MESSAGE", 1, "거래가 완료되었습니다.")
assert(#tl.log == 0, "Case 5: Delayed completion MUST NOT mis-attribute unaccepted Trade B")
mockTradePartner = "거래상대"

-- Case 6: Missing monotonic clock at close fails closed (never substitutes 0)
local savedGetTime = _G.GetTime
_G.GetTime = function() return nil end
tl.log = {}
__FS_FIRE_EVENT("TRADE_SHOW")
__FS_FIRE_EVENT("TRADE_ACCEPT_UPDATE", 1, 0)
__FS_FIRE_EVENT("TRADE_CLOSED")
_G.GetTime = function() return 1.0 end
__FS_FIRE_EVENT("UI_INFO_MESSAGE", 1, "거래가 완료되었습니다.")
_G.GetTime = savedGetTime
assert(#tl.log == 0, "Case 6: Missing close timestamp must invalidate grace snapshot fail-closed")

-- PLAYER_ALIVE while still ghost must keep corpse guide active; PLAYER_UNGHOST clears it
mockDead = true
ns.Features.CorpseGuideModule:OnPlayerDead()
__FS_FIRE_EVENT("PLAYER_ALIVE")
assert(ns.Features.CorpseGuideModule.active == true, "PLAYER_ALIVE as ghost must NOT clear CorpseGuide")
mockDead = false
__FS_FIRE_EVENT("PLAYER_UNGHOST")
assert(ns.Features.CorpseGuideModule.active == false, "PLAYER_UNGHOST must clear CorpseGuide")

assert(ns.Domain.PowerQoLModel.ComputeFarmGph(100000, 1800) == 200000, "10g in 30m must compute 20g/hr")
assert(ns.Domain.PowerQoLModel.ComputeFarmGph(100000, 0) == nil, "0 elapsed sec must fail-closed nil")

-- Favorite /way Bookmarks
local util = ns.Features.UtilitiesPage
util.bookmarks = {}
assert(util:HandleFavCommand("add 스톰 은행 앞") == true)
assert(#util.bookmarks == 1 and util.bookmarks[1].label == "스톰 은행 앞" and util.bookmarks[1].mapID == 1453)
assert(util:HandleFavCommand("del 1") == true and #util.bookmarks == 0)

-- Profile Export / Import roundtrip & fail-closed malformed rejection
ns.Api.ProfileStore:Set("ui", "showScreenClock", false)
local exported = util:HandleProfileCommand("export")
assert(type(exported) == "string" and string.sub(exported, 1, 4) == "FS2:", "Export must start with FS2:")
local badOk, badErr = util:HandleProfileCommand("import BAD_HEADER")
assert(badOk == false and badErr == "INVALID_HEADER", "Malformed profile string must fail-closed")
local impOk, impCnt = util:HandleProfileCommand("import " .. exported)
assert(impOk == true and impCnt >= 10, "Valid exported profile string must import cleanly")
