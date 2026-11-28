-- Test 05: Phase 2A Integrated Modules (all Round 1 + Round 2 invariants verified in real Lua 5.1 VM)
local ns = _G.ForeverSuiteV2

_G.__FS_MOCK.durability = { [1] = { 80, 100 }, [5] = { 90, 100 } }
_G.__FS_MOCK.playerPos = { mapID = 1411, x = 0.50, y = 0.50, facing = 0 }
_G.__FS_MOCK.playerClass = "SHAMAN"
_G.__FS_MOCK.knownSpells = { [324] = true, [8017] = true } -- Lightning Shield + Rockbiter Weapon
_G.__FS_MOCK.activeAuras = {}
_G.__FS_MOCK.mainHandEnchant = false
_G.__FS_MOCK.hp = 1000
_G.__FS_MOCK.hpMax = 1000
_G.__FS_MOCK.zoneText = "타나리스"

local origLoad = C_AddOns.LoadAddOn
C_AddOns.LoadAddOn = function(name)
    if name == "ForeverSuite_Data" then
        local loaded = __FS_LOAD_DATA_ADDON()
        _G.__FS_MOCK.loadedAddOns[name] = loaded
        return loaded, nil
    end
    return origLoad(name)
end

__FS_FIRE_EVENT("PLAYER_LOGIN")

-- 1. StatusPill shows live durability % (85%)
assert(string.find(ns.Features.StatusPillHud.label:GetText(), "내구 85%", 1, true))

-- 2. B7: /fs2 protect parses item links (|cff9d9d9d|Hitem:1014:...|h) correctly (NOT color code 9!)
_G.SlashCmdList["FOREVERSUITEV2"]("protect |cff9d9d9d|Hitem:1014:0:0:0|h[잡템14]|h|r")
assert(ns.Api.ProfileStore.db.v2.protectedItems[1014] == true)
assert(ns.Api.ProfileStore.db.v2.protectedItems[9] == nil, "must NEVER parse color code digits")

-- 3A. R2-B2 (async AWAIT_GUILD -> timer fallback) + R2-B1 (sign-matched FIFO ledger attribution) + M3 (buyback budget = 12 - 2 = 10)
_G.__FS_MOCK.canRepair = true
_G.__FS_MOCK.repairCost = 4200
_G.__FS_MOCK.canGuildRepair = true
_G.__FS_MOCK.asyncGuildRepair = true
_G.__FS_MOCK.guildRepairShouldFail = true -- server does NOT clear repairCost before 0.6s timer
_G.__FS_MOCK.buybackCount = 2 -- leaves 10 buyback slots available
_G.__FS_MOCK.bagItems = {}
for i = 1, 14 do
    _G.__FS_MOCK.bagItems[i] = { bag = 0, slot = i, itemID = 1000 + i, quality = 0, stackCount = 1, unitPrice = 100 * i, name = "잡템" .. i, isLocked = false }
end
-- Slot 13 has secret isLocked -> fail-closed (must NOT sell!)
_G.__FS_MOCK.bagItems[13].isLocked = FS_MakeSecret("locked", "boolean")

__FS_FIRE_EVENT("MERCHANT_SHOW")
assert(_G.__FS_MOCK.repairedGuild == true and _G.__FS_MOCK.repairedPersonal == false, "must NOT double-repair synchronously before async guild verification")
assert(ns.Features.MerchantModule.awaitingGuildRepair ~= nil, "must be in AWAIT_GUILD state")
assert(#_G.__FS_MOCK.soldItems == 10, "buyback budget 12 - 2 existing = max 10 items sold")
for _, s in ipairs(_G.__FS_MOCK.soldItems) do
    assert(s.slot ~= 14 and s.slot ~= 13, "protected #1014 and secret-locked #1013 must NOT be sold")
end

-- Flush 0.6s timer -> guild repair still unpaid -> falls back cleanly to personal repair
__FS_FLUSH_AFTER_TIMERS()
assert(_G.__FS_MOCK.repairedPersonal == true, "async guild timeout must fall back to personal repair")
assert(ns.Features.MerchantModule.awaitingGuildRepair == nil)

-- Verify PLAYER_MONEY single writer & exact sign-matched categories (10 vendorSell + 1 repair = 11)
local ledgerEntries = ns.Api.ProfileStore.db.v2.ledger
assert(#ledgerEntries == 11, "expected exactly 11 single-written ledger entries, got " .. tostring(#ledgerEntries))
for i = 1, 10 do
    assert(ledgerEntries[i].category == "vendorSell" and ledgerEntries[i].delta > 0, "junk sales must record vendorSell (+)")
end
assert(ledgerEntries[11].category == "repair" and ledgerEntries[11].delta == -4200, "fallback personal repair must record repair (-4200)")
assert(ns.Features.LedgerPage.sessionExpense == 4200, "expense must NOT be double-counted")
assert(ledgerEntries[1].ts == 1000, "ledger must store wall-clock epoch timestamp")

-- 3B. R2-B1 + M-1 exact-amount attribution & MERCHANT_CLOSED expiry (coalescing + vendor purchase never mislabeled!)
_G.__FS_MOCK.deferMoneyEvents = true
_G.__FS_MOCK.canRepair = true
_G.__FS_MOCK.repairCost = 500
_G.__FS_MOCK.canGuildRepair = false
_G.__FS_MOCK.bagItems = {
    { bag = 0, slot = 1, itemID = 2001, quality = 0, stackCount = 1, unitPrice = 900, name = "잡템A", isLocked = false },
}
_G.__FS_MOCK.soldItems = {}
_G.__FS_MOCK.buybackCount = 0
local framesAfterFirstToast = #_G.__FS_MOCK.frames
__FS_FIRE_EVENT("MERCHANT_SHOW")
-- M7: Toast is pooled (zero new frames!)
assert(#_G.__FS_MOCK.frames == framesAfterFirstToast, "Toast must be pooled (zero frame leak)")
-- Simulate coalesced positive net (+900 - 500 = +400) arriving asynchronously on PLAYER_MONEY
__FS_FIRE_EVENT("PLAYER_MONEY")
local lastE = ledgerEntries[#ledgerEntries]
assert(lastE.category == "merchant" and lastE.delta == 400, "coalesced +400 must classify honestly as merchant, not mislabel single vendorSell")
-- Simulate player buying a 150c item while merchant is still open: must NOT inherit queued -500 repair attribution!
_G.__FS_MOCK.money = _G.__FS_MOCK.money - 150
__FS_FIRE_EVENT("PLAYER_MONEY")
assert(ledgerEntries[#ledgerEntries].category == "merchant" and ledgerEntries[#ledgerEntries].delta == -150, "unrelated -150 vendor purchase must NOT inherit queued -500 repair attribution")
-- Remaining unconsumed attributions MUST be cleared on MERCHANT_CLOSED
assert(#ns.Features.LedgerPage.pendingQueue == 2)
__FS_FIRE_EVENT("MERCHANT_CLOSED")
assert(#ns.Features.LedgerPage.pendingQueue == 0, "MERCHANT_CLOSED must expire unconsumed attributions")
-- Outside merchant, random expense records "other" (never stale "repair")
_G.__FS_MOCK.money = _G.__FS_MOCK.money - 150
__FS_FIRE_EVENT("PLAYER_MONEY")
assert(ledgerEntries[#ledgerEntries].category == "other", "post-merchant delta must NOT inherit stale repair attribution")
_G.__FS_MOCK.deferMoneyEvents = false

-- 3C. R2-B2 + B-1 + M-3 AWAIT_GUILD cases:
-- Case 1 (B-1 red test): Durability event fires while repairCost is STILL 3000 -> MUST keep waiting (no premature personal repair!),
-- then cost becomes 0 before timer -> timer resolves GUILD_OK with zero personal repair!
_G.__FS_MOCK.repairedGuild = false
_G.__FS_MOCK.repairedPersonal = false
_G.__FS_MOCK.canRepair = true
_G.__FS_MOCK.repairCost = 3000
_G.__FS_MOCK.canGuildRepair = true
_G.__FS_MOCK.asyncGuildRepair = true
_G.__FS_MOCK.guildRepairShouldFail = false
_G.__FS_MOCK.bagItems = {}
__FS_FIRE_EVENT("MERCHANT_SHOW")
assert(ns.Features.MerchantModule.awaitingGuildRepair ~= nil)
-- Partial/unrelated durability event while cost is still 3000!
__FS_FIRE_EVENT("UPDATE_INVENTORY_DURABILITY")
assert(_G.__FS_MOCK.repairedPersonal == false and ns.Features.MerchantModule.awaitingGuildRepair ~= nil, "event with remaining cost must NOT fall back early")
-- Now guild repair completes before timer fires EVEN IF client's 2nd return stays true (capability flag)!
_G.__FS_MOCK.repairCost = 0
_G.__FS_MOCK.repairAllCanFlag = true
__FS_FLUSH_AFTER_TIMERS()
assert(ns.Features.MerchantModule.awaitingGuildRepair == nil and _G.__FS_MOCK.repairedPersonal == false, "guild success with remainingCost==0 & canRepair==true must resolve GUILD_OK without personal repair")
_G.__FS_MOCK.repairAllCanFlag = nil
__FS_FIRE_EVENT("MERCHANT_CLOSED")

-- Case 2 (M-3): CanMerchantRepair() == false during resolution -> UNREADABLE (never false GUILD_OK!)
_G.__FS_MOCK.repairedPersonal = false
_G.__FS_MOCK.canRepair = true
_G.__FS_MOCK.repairCost = 2000
__FS_FIRE_EVENT("MERCHANT_SHOW")
_G.__FS_MOCK.canRepair = false
local resNoRepair = ns.Features.MerchantModule:ResolvePendingGuildRepair("timer")
assert(resNoRepair == "UNREADABLE" and _G.__FS_MOCK.repairedPersonal == false, "CanMerchantRepair()==false must resolve UNREADABLE, never GUILD_OK")
_G.__FS_MOCK.canRepair = true
_G.__FS_MOCK.repairCost = 0
__FS_FIRE_EVENT("MERCHANT_CLOSED")

-- Case 3: Secret GetRepairAllCost during resolution -> UNREADABLE (no double repair!)
_G.__FS_MOCK.repairedPersonal = false
_G.__FS_MOCK.repairCost = 2000
__FS_FIRE_EVENT("MERCHANT_SHOW")
_G.__FS_MOCK.repairCost = FS_MakeSecret("repairCost", "number")
local resUnreadable = ns.Features.MerchantModule:ResolvePendingGuildRepair("timer")
assert(resUnreadable == "UNREADABLE" and _G.__FS_MOCK.repairedPersonal == false, "unreadable repairCost must abort fallback (fail-closed)")
_G.__FS_MOCK.repairCost = 0
__FS_FIRE_EVENT("MERCHANT_CLOSED")

-- Case 4: MERCHANT_CLOSED while awaiting guild repair -> cancels pending cleanly
_G.__FS_MOCK.repairedPersonal = false
_G.__FS_MOCK.repairCost = 2500
__FS_FIRE_EVENT("MERCHANT_SHOW")
assert(ns.Features.MerchantModule.awaitingGuildRepair ~= nil)
__FS_FIRE_EVENT("MERCHANT_CLOSED")
assert(ns.Features.MerchantModule.awaitingGuildRepair == nil)
__FS_FLUSH_AFTER_TIMERS()
assert(_G.__FS_MOCK.repairedPersonal == false, "timer firing after MERCHANT_CLOSED must NOT repair")
_G.__FS_MOCK.asyncGuildRepair = false

-- 3D. R2-M1: buyback unreadable (nil) -> fail-closed (0 sold); buyback full (12) -> 0 sold + residual notice
_G.__FS_MOCK.canRepair = false
_G.__FS_MOCK.repairCost = 0
_G.__FS_MOCK.bagItems = {
    { bag = 0, slot = 1, itemID = 3001, quality = 0, stackCount = 1, unitPrice = 500, name = "회색템", isLocked = false },
}
_G.__FS_MOCK.soldItems = {}
_G.__FS_MOCK.buybackCount = nil
__FS_FIRE_EVENT("MERCHANT_SHOW")
assert(#_G.__FS_MOCK.soldItems == 0, "unreadable nil GetNumBuybackItems must fail closed")
__FS_FIRE_EVENT("MERCHANT_CLOSED")

_G.__FS_MOCK.buybackCount = 12
local printsBeforeFull = #_G.__FS_MOCK.printed
__FS_FIRE_EVENT("MERCHANT_SHOW")
assert(#_G.__FS_MOCK.soldItems == 0, "full 12-slot buyback must sell 0 items")
assert(#_G.__FS_MOCK.printed > printsBeforeFull and string.find(_G.__FS_MOCK.printed[#_G.__FS_MOCK.printed], "재구매 창(12칸)", 1, true), "full buyback must notify user")
__FS_FIRE_EVENT("MERCHANT_CLOSED")
_G.__FS_MOCK.buybackCount = 0

-- 4. LedgerPage renders session + recent inside /fs2 CommandHub
_G.SlashCmdList["FOREVERSUITEV2"]("ledger")
assert(ns.UI.CommandHub.activePageId == "ledger" and ns.Features.LedgerPage.visibleRows >= 1)
assert(string.find(ns.Features.LedgerPage.summaryLbl:GetText(), "세션 ", 1, true))

-- 5. B8 + F2: QuestAutomation respects PvP flag (boolean true, classic numeric 1, AND missing QuestFlagsPVP fail-closed), gold cost, multi-choice, nil choices, Shift bypass, and QUEST_ACCEPTED NavPort
_G.__FS_MOCK.acceptedQuests = 0
_G.__FS_MOCK.turnedInQuests = 0
_G.__FS_MOCK.questPvp = true
__FS_FIRE_EVENT("QUEST_DETAIL")
assert(_G.__FS_MOCK.acceptedQuests == 0, "PvP-flagging quest (true) must NOT auto-accept")
_G.__FS_MOCK.questPvp = 1
__FS_FIRE_EVENT("QUEST_DETAIL")
assert(_G.__FS_MOCK.acceptedQuests == 0, "PvP-flagging quest (classic truthy 1) must NOT auto-accept")
local savedPvpFn = _G.QuestFlagsPVP
_G.QuestFlagsPVP = nil
__FS_FIRE_EVENT("QUEST_DETAIL")
assert(_G.__FS_MOCK.acceptedQuests == 0, "missing QuestFlagsPVP must fail closed and block auto-accept")
_G.QuestFlagsPVP = savedPvpFn
_G.__FS_MOCK.questPvp = false
__FS_FIRE_EVENT("QUEST_DETAIL")
assert(_G.__FS_MOCK.acceptedQuests == 1)

_G.__FS_MOCK.questReqMoney = 10000
__FS_FIRE_EVENT("QUEST_COMPLETE")
assert(_G.__FS_MOCK.turnedInQuests == 0, "gold-cost quest must NOT auto turn-in")
_G.__FS_MOCK.questReqMoney = 0
_G.__FS_MOCK.questChoices = nil -- fail-closed on nil choices!
__FS_FIRE_EVENT("QUEST_COMPLETE")
assert(_G.__FS_MOCK.turnedInQuests == 0, "nil GetNumQuestChoices must fail closed")
_G.__FS_MOCK.questChoices = 1
__FS_FIRE_EVENT("QUEST_COMPLETE")
assert(_G.__FS_MOCK.turnedInQuests == 1)

_G.__FS_MOCK.questLogSet = { [777] = 1 }
__FS_FIRE_EVENT("QUEST_ACCEPTED", 1, 777)
assert(_G.__FS_MOCK.superTrackedQuestID == 777, "QUEST_ACCEPTED must route autoSuperTrack via NavPort")

-- 6. B2/B3/B4/B5 + R2-M2: NavigationHud live ticker, honest map-units, nil facing -> "•", /way2 refuses without pos,
--    ClearWaypoint preserves unowned manual pin & defers when WorldMapFrame is shown!
local savedPos = _G.__FS_MOCK.playerPos
_G.__FS_MOCK.playerPos = nil
assert(ns.Features.NavigationHud:HandleWaySlash("50.0 40.0 금지") == false, "/way2 must refuse when position unavailable")
_G.__FS_MOCK.playerPos = savedPos

-- Unowned manual user waypoint must NOT be cleared by NavPort.ClearWaypoint()
_G.__FS_MOCK.userWaypoint = { uiMapID = 1411, position = { x = 0.2, y = 0.2 } }
local clearCallsBefore = _G.__FS_MOCK.clearWaypointCalls
local okUnowned, reasonUnowned = ns.Api.NavPort.ClearWaypoint()
assert(okUnowned == true and reasonUnowned == "NOT_OWNED", "must not clear unowned manual waypoint")
assert(_G.__FS_MOCK.clearWaypointCalls == clearCallsBefore and _G.__FS_MOCK.userWaypoint ~= nil)

_G.SlashCmdList["FOREVERSUITEWAYV2"]("50.0 40.0 테스트 목적지")
assert(ns.Features.NavigationHud.card:IsShown() == true)
assert(ns.Features.NavigationHud.ticker ~= nil and ns.Features.NavigationHud.ticker._cancelled == false)
assert(ns.Features.NavigationHud.arrowLbl:GetText() == "↑")
assert(string.find(ns.Features.NavigationHud.distLbl:GetText(), "10.0좌표", 1, true))

-- R2-M2 + N-4: Clearing while WorldMapFrame is shown defers ClearUserWaypoint until WorldMapFrame:Hide() (real OnHide hook!)
_G.__FS_MOCK.worldMapShown = true
local clearCallsMap = _G.__FS_MOCK.clearWaypointCalls
ns.Features.NavigationHud:Clear()
assert(ns.Api.NavPort.pendingClearWaypoint == true and _G.__FS_MOCK.clearWaypointCalls == clearCallsMap, "ClearWaypoint must defer while WorldMapFrame is shown")
_G.__FS_MOCK.worldMapShown = false
WorldMapFrame:Hide() -- exercises real WorldMapAdapter OnHide hook -> NavPort.FlushIfSafe()
assert(ns.Api.NavPort.pendingClearWaypoint == false and _G.__FS_MOCK.userWaypoint == nil, "WorldMapFrame:Hide() hook must execute deferred ClearUserWaypoint")

-- M-2: If user replaces addon's pin with their own manual pin while map is open, deferred Clear MUST preserve the user's pin!
_G.SlashCmdList["FOREVERSUITEWAYV2"]("50.0 40.0 교체전")
_G.__FS_MOCK.worldMapShown = true
ns.Features.NavigationHud:Clear()
assert(ns.Api.NavPort.pendingClearWaypoint == true)
-- User places their own manual pin at (0.80, 0.80) before closing the map
_G.__FS_MOCK.userWaypoint = { uiMapID = 1411, position = { x = 0.80, y = 0.80 } }
local clearCallsManual = _G.__FS_MOCK.clearWaypointCalls
_G.__FS_MOCK.worldMapShown = false
WorldMapFrame:Hide()
assert(_G.__FS_MOCK.clearWaypointCalls == clearCallsManual and _G.__FS_MOCK.userWaypoint ~= nil, "deferred Clear must NOT delete user's replacement manual pin")
_G.__FS_MOCK.userWaypoint = nil

-- Live ticker drives update & arrival automatically when player moves
_G.SlashCmdList["FOREVERSUITEWAYV2"]("50.0 40.0 테스트 목적지2")
_G.__FS_MOCK.playerPos.facing = nil
ns.Features.NavigationHud.ticker:Tick()
assert(ns.Features.NavigationHud.arrowLbl:GetText() == "·", "nil facing must show · instead of fake North")
_G.__FS_MOCK.playerPos.y = 0.402
ns.Features.NavigationHud.ticker:Tick()
assert(ns.Features.NavigationHud.card:IsShown() == false and ns.Features.NavigationHud.ticker == nil)
assert(_G.__FS_MOCK.userWaypoint == nil, "Clear on arrival must clear owned native waypoint")

-- Clear in combat cancels pending deferred waypoint
_G.__FS_MOCK.playerPos.y = 0.50
_G.__FS_MOCK.inCombat = true
ns.Features.NavigationHud:SetTarget(1411, 0.50, 0.30, "전투중")
assert(ns.Api.NavPort.pendingWaypoint ~= nil)
ns.Features.NavigationHud:Clear()
assert(ns.Api.NavPort.pendingWaypoint == nil, "Clear must cancel pending deferred waypoint")
_G.__FS_MOCK.inCombat = false
__FS_FIRE_EVENT("PLAYER_REGEN_ENABLED")
assert(_G.__FS_MOCK.userWaypoint == nil)

-- 7. B9/M4/M5 + R2-M3: CombatAssistHud explicit PLAYER_REGEN_DISABLED hide, ghost suppression,
--    low-level Rogue no false warn, and tri-state unreadable C_UnitAuras -> AURA_UNAVAILABLE (no false warn!)
assert(ns.Features.CombatAssistHud.strip:IsShown() == true)
__FS_FIRE_EVENT("PLAYER_REGEN_DISABLED") -- even while InCombatLockdown() is still false!
assert(ns.Features.CombatAssistHud.strip:IsShown() == false, "PLAYER_REGEN_DISABLED must hide buff strip immediately")
_G.__FS_MOCK.deadOrGhost = true
_G.__FS_MOCK.hp = 1
__FS_FIRE_EVENT("UNIT_HEALTH", "player")
assert(ns.Features.CombatAssistHud.strip:IsShown() == false, "ghost (1 HP) must NOT trigger low-HP warning")
_G.__FS_MOCK.deadOrGhost = false
_G.__FS_MOCK.hp = 1000
_G.__FS_MOCK.playerClass = "ROGUE"
_G.__FS_MOCK.knownSpells = {} -- low-level rogue without Poisons (2842)
ns.Features.CombatAssistHud:Refresh(false)
assert(ns.Features.CombatAssistHud.strip:IsShown() == false, "low-level Rogue without Poisons spell must NOT be warned")

-- R2-M3: Secret/unreadable C_UnitAuras must suppress buff alert cleanly
_G.__FS_MOCK.playerClass = "SHAMAN"
_G.__FS_MOCK.knownSpells = { [324] = true }
_G.__FS_MOCK.auraSecret = true
local auraRes = ns.Features.CombatAssistHud:Refresh(false)
assert(auraRes == "AURA_UNAVAILABLE" and ns.Features.CombatAssistHud.strip:IsShown() == false, "unreadable C_UnitAuras must NOT trigger false buff warning")
_G.__FS_MOCK.auraSecret = false

-- 8. B10: FishingCardHud shows "현재 지역 집계 없음" when zone == "" (never unrelated fish!)
_G.__FS_MOCK.mainHandItemID = 6256
_G.__FS_MOCK.zoneText = ""
__FS_FIRE_EVENT("UNIT_INVENTORY_CHANGED", "player")
assert(string.find(ns.Features.FishingCardHud.bodyLbl:GetText(), "현재 지역 집계 없음", 1, true))
_G.__FS_MOCK.zoneText = "타나리스"
__FS_FIRE_EVENT("ZONE_CHANGED_NEW_AREA")
assert(string.find(ns.Features.FishingCardHud.bodyLbl:GetText(), "돌비늘 뱀장어", 1, true))

-- 9. All 5 LoD Codex packs + /fs2 layer
assert(type(_G.ForeverSuiteData.packs.bis) == "table" and type(_G.ForeverSuiteData.packs.rewards) == "table" and type(_G.ForeverSuiteData.packs.professions) == "table")
_G.__FS_MOCK.targetGUID = "Creature-0-4210-0-7781-1234-00001"
_G.SlashCmdList["FOREVERSUITEV2"]("layer")
assert(string.find(_G.__FS_MOCK.printed[#_G.__FS_MOCK.printed], "#7781", 1, true))
