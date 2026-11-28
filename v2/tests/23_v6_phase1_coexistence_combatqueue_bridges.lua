-- Test 23: ForeverSuite v6.0 Phase 1 — CoexistenceRegistry (40 cells), CombatQueue v6 (mid-flush combat re-entry),
--          C7 cvarRestoreJournal, and Official 6-Bridge + ForeverTotems/RareScanner Coexistence Suite.
local ns = _G.ForeverSuite
__FS_FIRE_EVENT("PLAYER_LOGIN")

local function assertEq(actual, expected, msg)
    assert(actual == expected, (msg or "assertEq failed") .. " (got=" .. tostring(actual) .. ", expected=" .. tostring(expected) .. ")")
end

------------------------------------------------------------------------
-- 1. AC-4: CoexistenceRegistry 5-state x 8-event = 40-cell exhaustive DDT
------------------------------------------------------------------------
local Coex = ns.Domain.Coexistence
assert(type(Coex) == "table", "Domain/Coexistence must load")

local bridgePolicy = { id = "baganator", target = "Baganator", mode = "bridge" }
local yieldPolicy = { id = "rare_scanner", target = "RareScanner", mode = "yield" }

local EXPECTED_BRIDGE_40 = {
    SELF = {
        ABSENT = "SELF",
        PRESENT = "BRIDGE_WARMING",
        BRIDGE_WAIT = "BRIDGE_WARMING",
        BRIDGE_OK = "BRIDGE_ONLY",
        BRIDGE_FAIL = "FAULTED",
        CONFLICT = "FAULTED",
        OVERRIDE_SELF = "SELF",
        RESET = "SELF",
    },
    YIELDED = {
        ABSENT = "SELF",
        PRESENT = "YIELDED",
        BRIDGE_WAIT = "FAULTED",
        BRIDGE_OK = "FAULTED",
        BRIDGE_FAIL = "FAULTED",
        CONFLICT = "FAULTED",
        OVERRIDE_SELF = "SELF",
        RESET = "SELF",
    },
    BRIDGE_WARMING = {
        ABSENT = "SELF",
        PRESENT = "BRIDGE_WARMING",
        BRIDGE_WAIT = "BRIDGE_WARMING",
        BRIDGE_OK = "BRIDGE_ONLY",
        BRIDGE_FAIL = "FAULTED",
        CONFLICT = "FAULTED",
        OVERRIDE_SELF = "SELF",
        RESET = "SELF",
    },
    BRIDGE_ONLY = {
        ABSENT = "SELF",
        PRESENT = "BRIDGE_ONLY",
        BRIDGE_WAIT = "BRIDGE_WARMING",
        BRIDGE_OK = "BRIDGE_ONLY",
        BRIDGE_FAIL = "FAULTED",
        CONFLICT = "FAULTED",
        OVERRIDE_SELF = "SELF",
        RESET = "SELF",
    },
    FAULTED = {
        ABSENT = "FAULTED",
        PRESENT = "FAULTED",
        BRIDGE_WAIT = "FAULTED",
        BRIDGE_OK = "FAULTED",
        BRIDGE_FAIL = "FAULTED",
        CONFLICT = "FAULTED",
        OVERRIDE_SELF = "FAULTED",
        RESET = "SELF",
    },
}

local cellCount = 0
for st, evMap in pairs(EXPECTED_BRIDGE_40) do
    for ev, expectedNext in pairs(evMap) do
        local got = Coex.Transition(st, ev, bridgePolicy)
        assertEq(got, expectedNext, "40-cell mismatch at " .. st .. " + " .. ev)
        cellCount = cellCount + 1
    end
end
assertEq(cellCount, 40, "must verify all 40 state-event cells")

-- Verify yield mode transitions SELF + PRESENT -> YIELDED
assertEq(Coex.Transition("SELF", "PRESENT", yieldPolicy), "YIELDED", "yield mode SELF+PRESENT")

-- Fail-closed invalid inputs
local badRes, badReason = Coex.ResolveAll("not-a-table")
assertEq(badRes, nil, "ResolveAll must fail closed on non-table probes")
assertEq(badReason, "INVALID_PROBES", "ResolveAll reason")

------------------------------------------------------------------------
-- 2. AC-7: CombatQueue v6 — Lockdown deferral, mid-flush combat re-entry,
--          tail ordering ahead of new deferrals, retry cap, and CQ.Run alias
------------------------------------------------------------------------
local CQ = ns.Secure.CombatQueue
assert(CQ.Run == CQ.RunOrDefer, "CombatQueue.Run compatibility alias must exist")

-- Reset clean state for test
CQ.pending, CQ.order, CQ.inOrder, CQ.attempts, CQ.flushing = {}, {}, {}, {}, false

_G.__FS_MOCK.inCombat = true
local executed = {}
for i = 1, 50 do
    local ok, reason = CQ:Run("k" .. tostring(i), function()
        executed[#executed + 1] = i
    end)
    assertEq(ok, false, "combat call must defer")
    assertEq(reason, "DEFERRED", "combat deferral reason")
end
assertEq(#executed, 0, "0 protected calls may run during combat lockdown")
assertEq(CQ:PendingCount(), 50, "all 50 keys queued")

-- Deduplicate same key (last-writer-wins)
CQ:RunOrDefer("k1", function() executed[#executed + 1] = 999 end)
assertEq(CQ:PendingCount(), 50, "last-writer-wins keeps 50 unique keys")

-- Clear and test mid-flush combat re-entry + tail preservation!
CQ.pending, CQ.order, CQ.inOrder, CQ.attempts = {}, {}, {}, {}
local seq = {}
_G.__FS_MOCK.inCombat = true
CQ:RunOrDefer("A", function()
    seq[#seq + 1] = "A"
    -- Re-enter combat mid-flush AND enqueue new item D!
    _G.__FS_MOCK.inCombat = true
    CQ:RunOrDefer("D", function() seq[#seq + 1] = "D" end)
end)
CQ:RunOrDefer("B", function() seq[#seq + 1] = "B" end)
CQ:RunOrDefer("C", function() seq[#seq + 1] = "C" end)

_G.__FS_MOCK.inCombat = false
local ran1 = CQ:Flush()
assertEq(ran1, 1, "must stop immediately when combat re-enters mid-flush")
assertEq(#seq, 1, "only A ran before mid-flush combat re-entry")
assertEq(CQ:PendingCount(), 3, "B, C, D must all be preserved")

-- Exit combat again: remaining tail (B, C) MUST execute BEFORE newly queued D!
_G.__FS_MOCK.inCombat = false
local ran2 = CQ:Flush()
assertEq(ran2, 3, "remaining tail + new item flush cleanly")
assertEq(table.concat(seq, ","), "A,B,C,D", "tail B,C must stay ahead of newly deferred D")
assertEq(CQ:PendingCount(), 0, "queue empty after second flush")

-- Retry cap (maxRetry = 2 -> total 3 attempts then dropped into failed stat)
local failRuns = 0
_G.__FS_MOCK.inCombat = true
CQ:RunOrDefer("flaky", function()
    failRuns = failRuns + 1
    error("boom")
end)
_G.__FS_MOCK.inCombat = false
CQ:Flush()
assertEq(failRuns, 3, "xpcall retries up to maxRetry=2 (1 initial + 2 retries = 3)")
assertEq(CQ:PendingCount(), 0, "exhausted key dropped cleanly")

-- Codex D3 regression: failing callback that enqueues a NEW replacement for same key must NOT be overwritten by retry!
local replacementRan = 0
_G.__FS_MOCK.inCombat = true
CQ:RunOrDefer("replaceMe", function()
    CQ:RunOrDefer("replaceMe", function()
        replacementRan = replacementRan + 1
    end)
    error("old callback crashed after scheduling replacement")
end)
_G.__FS_MOCK.inCombat = false
CQ:Flush()
assertEq(replacementRan, 1, "newer replacement callback survived old callback crash without being overwritten")

------------------------------------------------------------------------
-- 3. C7: Crash-safe cvarRestoreJournal inside active ForeverSuiteV2DB
------------------------------------------------------------------------
local cvarLog = {}
local origSetCVar = _G.C_CVar and _G.C_CVar.SetCVar
_G.C_CVar = _G.C_CVar or {}
_G.C_CVar.SetCVar = function(name, val)
    cvarLog[name] = val
    return true
end

ns.Api.ProfileStore:Init()
assert(ns.Api.ProfileStore:RecordCvarJournal("Sound_SFXVolume", "0.35"), "record cvar journal")
-- Idempotent second record must NOT overwrite original 0.35!
ns.Api.ProfileStore:RecordCvarJournal("Sound_SFXVolume", "0.90")
assertEq(ns.Api.ProfileStore.db.v2.state.cvarRestoreJournal["Sound_SFXVolume"], "0.35", "original value preserved")
assert(_G.ForeverSuiteDB == nil or _G.ForeverSuiteDB.cvarRestoreJournal == nil, "D1: never write to legacy ForeverSuiteDB")

local restoredCount = ns.Api.ProfileStore:RestoreCvarJournal(function(k, fn)
    CQ:RunOrDefer(k, fn)
end)
assertEq(restoredCount, 1, "1 CVar restored from journal")
assertEq(cvarLog["Sound_SFXVolume"], "0.35", "Sound_SFXVolume restored to 0.35")
assertEq(ns.Api.ProfileStore.db.v2.state.cvarRestoreJournal, nil, "journal cleared after restore")

-- B1 regression: in-combat RestoreCvarJournal defers (returns applied=0, deferred=1), then Flush() clears journal!
cvarLog["Sound_SFXVolume"] = "0.95"
ns.Api.ProfileStore:RecordCvarJournal("Sound_SFXVolume", "0.40")
_G.__FS_MOCK.inCombat = true
local appInCombat, defInCombat = ns.Api.ProfileStore:RestoreCvarJournal(function(k, fn)
    return CQ:RunOrDefer(k, fn)
end)
assertEq(appInCombat, 0, "0 applied during combat")
assertEq(defInCombat, 1, "1 deferred during combat")
assertEq(cvarLog["Sound_SFXVolume"], "0.95", "CVar must NOT mutate during combat lockdown")
assertEq(ns.Api.ProfileStore.db.v2.state.cvarRestoreJournal["Sound_SFXVolume"], "0.40", "journal persists while deferred in combat")
_G.__FS_MOCK.inCombat = false
CQ:Flush()
assertEq(cvarLog["Sound_SFXVolume"], "0.40", "CVar restored on Flush after combat")
assertEq(ns.Api.ProfileStore.db.v2.state.cvarRestoreJournal, nil, "journal cleared inside deferred closure after Flush")

-- C7 regression: when SetCVar returns false, journal entry MUST stay persisted (never lost!)
_G.C_CVar.SetCVar = function() return false end
ns.Api.ProfileStore:RecordCvarJournal("Sound_SFXVolume", "0.25")
local appFail = ns.Api.ProfileStore:RestoreCvarJournal()
assertEq(appFail, 0, "failed SetCVar reports 0 applied")
assertEq(ns.Api.ProfileStore.db.v2.state.cvarRestoreJournal["Sound_SFXVolume"], "0.25", "failed restore preserves journal entry")
ns.Api.ProfileStore:ClearCvarJournal("Sound_SFXVolume")
_G.C_CVar.SetCVar = function(name, val) cvarLog[name] = val; return true end

-- EventBus regression: mid-dispatch same-key replacement must NOT fire the new handler in current dispatch
local replacedNewRan = 0
ns.Api.EventBus:OnEvent("test:replTarget", "CUSTOM_REPL_EV", function() end)
ns.Api.EventBus:OnEvent("test:replTrigger", "CUSTOM_REPL_EV", function()
    ns.Api.EventBus:OnEvent("test:replTarget", "CUSTOM_REPL_EV", function()
        replacedNewRan = replacedNewRan + 1
    end)
end)
__FS_FIRE_EVENT("CUSTOM_REPL_EV")
assertEq(replacedNewRan, 0, "new handler replacing same ownerKey mid-dispatch must NOT fire on current event")
ns.Api.EventBus:OffEvent("test:replTarget", "CUSTOM_REPL_EV")
ns.Api.EventBus:OffEvent("test:replTrigger", "CUSTOM_REPL_EV")

-- B4 regression: EventBus preserves >6 arguments (e.g. 9-arg CHAT_MSG_*) including nil holes
local gotArgs = {}
ns.Api.EventBus:OnEvent("test:nineArgs", "CHAT_MSG_SAY", function(ev, a1, a2, a3, a4, a5, a6, a7, a8, a9)
    gotArgs = { ev = ev, a1 = a1, a5 = a5, a8 = a8, a9 = a9 }
end)
__FS_FIRE_EVENT("CHAT_MSG_SAY", "msg", "player", "lang", nil, "target", "flag", 7, 8, "arg9")
assertEq(gotArgs.a1, "msg", "arg1 preserved")
assertEq(gotArgs.a5, "target", "arg5 after nil hole preserved")
assertEq(gotArgs.a8, 8, "arg8 preserved")
assertEq(gotArgs.a9, "arg9", "arg9 preserved (no 6-arg truncation)")
ns.Api.EventBus:OffEvent("test:nineArgs", "CHAT_MSG_SAY")
if origSetCVar then _G.C_CVar.SetCVar = origSetCVar end

------------------------------------------------------------------------
-- 4. AC-5: External 9-addon coexistence & 6 official API bridges
------------------------------------------------------------------------
local Host = ns.Bridges.BridgeHost
local loadedAddons = {
    Baganator = true,
    Syndicator = true,
    Auctionator = true,
    DialogueUI = true,
    Spoken = true,
    Platynator = true,
    ForeverTotems = true,
    RareScanner = true,
    WhatTheWhisper = true,
}

local origCAddOns = _G.C_AddOns
_G.C_AddOns = _G.C_AddOns or {}
local origIsLoaded = _G.C_AddOns.IsAddOnLoaded
local origExists = _G.C_AddOns.DoesAddOnExist
_G.C_AddOns.IsAddOnLoaded = function(name) return loadedAddons[name] == true end
_G.C_AddOns.DoesAddOnExist = function(name) return loadedAddons[name] == true end

-- Mock external APIs matching REAL installed 1.60.1 addon signatures!
local bagCalls = { corner = 0, junk = 0, upgrade = 0, region = 0, imported = nil, regionW = 0 }
_G.Baganator = {
    API = {
        RegisterCornerWidget = function() bagCalls.corner = bagCalls.corner + 1 end,
        RegisterJunkPlugin = function() bagCalls.junk = bagCalls.junk + 1 end,
        RegisterUpgradePlugin = function() bagCalls.upgrade = bagCalls.upgrade + 1 end,
        RegisterRegion = function(label, id, viewType, position, frame)
            assert(type(label) == "string" and type(id) == "string" and viewType == "backpack" and position == "bottom_left", "exact 5-arg Baganator.API.RegisterRegion signature")
            assert(type(frame) == "table" and type(frame.SetParent) == "function" and type(frame.GetWidth) == "function", "RegisterRegion requires real frame")
            bagCalls.region = bagCalls.region + 1
            bagCalls.regionW = frame:GetWidth()
        end,
        ImportString = function(s) bagCalls.imported = s end,
    },
}

local synReady = false
_G.Syndicator = {
    API = {
        IsReady = function() return synReady end,
        GetInventoryInfoByItemID = function(id)
            -- Include numeric warband slot matching real Syndicator 1.60.1 output
            return { characters = { { bags = 4, bank = 6, mail = 2, equipped = 0 } }, warband = { 3 } }
        end,
        GetAllCharacters = function() return { "Thrall-ForeverKR" } end,
        GetCurrencyInfo = function() return { characters = {} } end,
    },
}

local ahPrice = 12500
local ahUpdateCb = nil
local ahShoppingCreated = nil
_G.Auctionator = {
    API = {
        v1 = {
            RegisterForDBUpdate = function(_, cb) ahUpdateCb = cb end,
            GetAuctionPriceByItemID = function(_, id) return id == 6358 and ahPrice or nil end,
            GetDisenchantPriceByItemID = function(_, id) return id == 6358 and 4000 or nil end,
            GetVendorPriceByItemID = function(_, id) return id == 6358 and 250 or nil end,
            CreateShoppingList = function(_, name, list) ahShoppingCreated = { name = name, count = #list } end,
        },
    },
}

local duiEvalCount = 0
local duiTranslatorSpec = nil
local duiShown = false
_G.DialogueUIAPI = {
    AddItemEvaluator = function() duiEvalCount = duiEvalCount + 1 end,
    GetActiveTranslator = function() return nil end,
    SetTranslator = function(spec) duiTranslatorSpec = spec end,
    IsAnyDUIWindowShown = function() return duiShown end,
}

local spokenPlaying = false
local spokenGateFn = nil
_G.Spoken = {
    IsPlaying = function() return spokenPlaying end,
    RegisterCallback = function() end,
    AddGate = function(_, fn)
        assert(type(fn) == "function", "real Spoken:AddGate takes a single function(clip)")
        spokenGateFn = fn
    end,
}

local platImported = nil
_G.Platynator = {
    API = {
        ImportString = function(s) platImported = s end,
    },
}

-- Resolve all as SHAMAN
Host:Reset()
Host:ResolveAll({}, { playerClass = "SHAMAN" })

assertEq(Host:GetState("baganator"), "BRIDGE_ONLY", "Baganator bridge active")
assertEq(bagCalls.corner, 1, "Baganator corner widget registered")
assertEq(bagCalls.junk, 1, "Baganator junk plugin registered")
assertEq(bagCalls.upgrade, 1, "Baganator upgrade plugin registered")
assertEq(bagCalls.region, 1, "Baganator bottom_left region registered")
assert(bagCalls.regionW <= 52 and bagCalls.regionW > 0, "bottom_left pill width <= 52px")

-- Protected item SKY badge & junk exclusion
ns.Api.ProfileStore.db.v2.protectedItems[19019] = true
local pBadge = ns.Bridges.Baganator:EvaluateCornerBadge({ itemID = 19019 })
assert(pBadge and pBadge.text == "보호", "protected item gets 보호 badge")
assertEq(ns.Bridges.Baganator:EvaluateJunk(0, 1, 19019), false, "protected item is never junk")

-- Syndicator cold-boot: BRIDGE_WARMING (NOT FAULTED!), returns nil ("—"), then promotes on IsReady()==true
assertEq(Host:GetState("syndicator"), "BRIDGE_WARMING", "Syndicator cold-boot must be BRIDGE_WARMING, never FAULTED")
local warmCnt, warmSt = ns.Bridges.Syndicator:GetTotalItemCount(6358)
assertEq(warmCnt, nil, "warming Syndicator must not fabricate 0")
assertEq(warmSt, "WARMING", "warming status returned")
synReady = true
assertEq(Host:RecheckWarming(), 1, "RecheckWarming promotes Syndicator")
assertEq(Host:GetState("syndicator"), "BRIDGE_ONLY", "Syndicator promoted to BRIDGE_ONLY")
local readyCnt, readySt = ns.Bridges.Syndicator:GetTotalItemCount(6358)
assertEq(readyCnt, 15, "Syndicator aggregates bags+bank+mail+numeric warband (12+3=15)")
assertEq(readySt, "OK", "Syndicator OK")

-- Auctionator cache + DBUpdate invalidation + nil on miss + OOC-only CreateShoppingList + vendor yield
assertEq(Host:GetState("auctionator"), "BRIDGE_ONLY", "Auctionator active")
assertEq(ns.Bridges.Auctionator:GetAuctionPrice(6358), 12500, "AH price fetched")
assertEq(ns.Bridges.Auctionator:GetAuctionPrice(999999), nil, "unknown item returns nil, never 0c")
ahPrice = 15000
assertEq(ns.Bridges.Auctionator:GetAuctionPrice(6358), 12500, "cached before DBUpdate")
ahUpdateCb()
assertEq(ns.Bridges.Auctionator:GetAuctionPrice(6358), 15000, "cache invalidated on RegisterForDBUpdate")
assertEq(Host:IsFeatureYielded("tooltip_vendor_price"), true, "Auctionator yields duplicate tooltip vendor price")
_G.__FS_MOCK.inCombat = true
local shOk, shErr = ns.Bridges.Auctionator:CreateShoppingList("Mat", { "Herb" })
assertEq(shOk, false, "CreateShoppingList blocked in combat")
assertEq(shErr, "IN_COMBAT", "IN_COMBAT reason")
_G.__FS_MOCK.inCombat = false
assertEq(ns.Bridges.Auctionator:CreateShoppingList("Mat", { "Herb" }), true, "CreateShoppingList works OOC")
assertEq(ahShoppingCreated.name, "Mat", "shopping list forwarded")

-- DialogueUI: real Translator.lua calls questDataGetter(questID) with 1 arg -> fetches live title to preserve Korean!
assertEq(Host:GetState("dialogue_ui"), "BRIDGE_ONLY", "DialogueUI active")
assertEq(duiEvalCount, 1, "DialogueUI evaluator registered")
assert(type(duiTranslatorSpec) == "table", "DialogueUI translator registered when none active")
ns.Bridges.DialogueUI:SetProviders({
    translator = function(qid) return { title = "번역된 퀘스트 #" .. tostring(qid) } end,
})
local origGetTitleForQ = _G.C_QuestLog and _G.C_QuestLog.GetTitleForQuestID
_G.C_QuestLog = _G.C_QuestLog or {}
_G.C_QuestLog.GetTitleForQuestID = function(qid)
    if qid == 101 then return "이미 한글로 번역된 퀘스트 제목" end
    if qid == 102 then return "Kobold Camp Cleanup" end
    return nil
end
assertEq(duiTranslatorSpec.questDataGetter(101), nil, "1-arg DialogueUI call preserves native Korean quest untouched")
local enTr = duiTranslatorSpec.questDataGetter(102)
assert(type(enTr) == "table" and enTr.title == "번역된 퀘스트 #102", "1-arg DialogueUI call translates English-only quest")
if origGetTitleForQ then _G.C_QuestLog.GetTitleForQuestID = origGetTitleForQ end
assertEq(Host:IsFeatureYielded("quest_automation"), true, "DialogueUI/Spoken yield QuestAutomation")

-- Spoken: ducks non-survival SFX while playing (including live GameAdapters.PlayNotificationSound), lets survival alerts pierce
assertEq(Host:GetState("spoken"), "BRIDGE_ONLY", "Spoken active")
local soundPlayed = 0
local origPlaySound = _G.PlaySound
_G.PlaySound = function() soundPlayed = soundPlayed + 1; return true end
spokenPlaying = true
assertEq(ns.Bridges.Spoken:ShouldDuckAudio(false), true, "non-survival SFX ducked while Spoken plays")
assertEq(ns.Api.GameAdapters.PlayNotificationSound("quest_complete", 75, "SFX", false), false, "live PlayNotificationSound ducked by Spoken")
assertEq(soundPlayed, 0, "0 non-survival sounds played while Spoken speaks")
assertEq(ns.Bridges.Spoken:ShouldDuckAudio(true), false, "survival alert bypasses Spoken ducking")
assertEq(ns.Api.GameAdapters.PlayNotificationSound("raid_warning", 75, "SFX", true), true, "survival PlayNotificationSound pierces Spoken")
assertEq(soundPlayed, 1, "survival sound played")
spokenPlaying = false
assertEq(ns.Bridges.Spoken:ShouldDuckAudio(false), false, "no ducking when Spoken silent")
_G.PlaySound = origPlaySound

-- Platynator + ForeverTotems (SHAMAN) + RareScanner
assertEq(Host:GetState("platynator"), "BRIDGE_ONLY", "Platynator active")
assertEq(ns.Bridges.Platynator:ImportPreset("obsidian-gold-v6"), true, "Platynator OOC import")
assertEq(platImported, "obsidian-gold-v6", "preset string passed")
assertEq(Host:GetState("forever_totems"), "YIELDED", "ForeverTotems yields for SHAMAN")
assertEq(Host:IsFeatureYielded("shaman_assist"), true, "shaman_assist yielded to ForeverTotems")
assert(ns.Bridges.Platynator:GetTotemSafeZone() ~= nil, "totem safe zone active for SHAMAN")
assertEq(Host:GetState("rare_scanner"), "YIELDED", "RareScanner yields rare_alerts")
assertEq(Host:IsFeatureYielded("rare_alerts"), true, "rare_alerts yielded")
ns.Features.QuestExtraModule:SyncProximityTicker(false)
assertEq(ns.Features.QuestExtraModule.proximityTicker, nil, "2s proximity ticker stopped when RareScanner yields rare_alerts")
assertEq(Host:GetState("what_the_whisper"), "YIELDED", "9th external addon WhatTheWhisper yields whisper_tabs")
assertEq(Host:IsFeatureYielded("whisper_tabs"), true, "whisper_tabs yielded")

-- Fault quarantine + O(1) EventBus unsubscription + /fs reset recovery
Host:Register({
    id = "faulty_test",
    target = "FaultyAddon",
    mode = "bridge",
    init = function() error("simulated bridge crash") end,
})
loadedAddons["FaultyAddon"] = true
Host:OnAddonLoaded("FaultyAddon")
assertEq(Host:GetState("faulty_test"), "FAULTED", "runtime error quarantines bridge to FAULTED")
assert(Host.faults["faulty_test"] ~= nil, "fault stack captured")
-- Absorbing: another OnAddonLoaded does NOT exit FAULTED
Host:OnAddonLoaded("FaultyAddon")
assertEq(Host:GetState("faulty_test"), "FAULTED", "FAULTED stays absorbing until Reset")
loadedAddons["FaultyAddon"] = false
Host:Reset("faulty_test")
assertEq(Host:GetState("faulty_test"), "SELF", "Reset exits FAULTED cleanly")

-- B5 regression: BRIDGE_WARMING auto-scheduled bounded recheck chain times out & reclaims yielded features
local scheduledCbs = {}
Host:SetScheduler(function(delay, cb)
    assertEq(delay, 2.0, "warming recheck uses 2.0s bounded delay")
    scheduledCbs[#scheduledCbs + 1] = cb
    return true
end)
Host:Register({
    id = "stuck_warm",
    target = "StuckWarmAddon",
    mode = "bridge",
    yields = { "stuck_feature" },
    init = function() return "WARMING" end,
    onWarmCheck = function() return "WARMING" end,
})
loadedAddons["StuckWarmAddon"] = true
Host:OnAddonLoaded("StuckWarmAddon")
assertEq(Host:GetState("stuck_warm"), "BRIDGE_WARMING", "enters BRIDGE_WARMING")
assertEq(Host:IsFeatureYielded("stuck_feature"), true, "yields while warming")
assertEq(#scheduledCbs, 1, "OnAddonLoaded auto-scheduled warming recheck")
for tick = 1, 5 do
    local cb = table.remove(scheduledCbs, 1)
    assert(type(cb) == "function", "scheduled recheck #" .. tostring(tick) .. " exists")
    cb()
end
assertEq(#scheduledCbs, 0, "recheck chain stops immediately once timed out (0 polling)")
assertEq(Host:GetState("stuck_warm"), "FAULTED", "attempt 5 hits WARM_TIMEOUT -> FAULTED")
assertEq(Host.faults["stuck_warm"], "WARM_TIMEOUT", "fault reason recorded")
assertEq(Host:IsFeatureYielded("stuck_feature"), false, "FAULTED reclaims feature back to SELF")
loadedAddons["StuckWarmAddon"] = false
Host:Reset("stuck_warm")
Host:SetScheduler(ns.Api.GameAdapters.RunAfter)

-- B3 regression: 3 subscribers on same event; #2 faults & triggers UnsubscribeAll mid-dispatch without crashing #3
local subFired = { s1 = 0, s3 = 0 }
Host:Register({
    id = "mid_fault_b",
    target = "MidFaultAddon",
    mode = "bridge",
    init = function() return "OK" end,
})
loadedAddons["MidFaultAddon"] = true
Host:OnAddonLoaded("MidFaultAddon")
ns.Api.EventBus:OnEvent("test:sib1", "CUSTOM_MID_EV", function() subFired.s1 = subFired.s1 + 1 end)
Host:Subscribe("mid_fault_b", "CUSTOM_MID_EV", function() error("mid-dispatch crash") end)
ns.Api.EventBus:OnEvent("test:sib3", "CUSTOM_MID_EV", function() subFired.s3 = subFired.s3 + 1 end)
__FS_FIRE_EVENT("CUSTOM_MID_EV")
assertEq(subFired.s1, 1, "sibling #1 ran")
assertEq(subFired.s3, 1, "sibling #3 survived #2 mid-dispatch fault & UnsubscribeAll")
assertEq(Host:GetState("mid_fault_b"), "FAULTED", "crashing bridge quarantined")
assertEq(Host.subscriptions["mid_fault_b"], nil, "crashing bridge unsubscribed in O(1)")
ns.Api.EventBus:OffEvent("test:sib1", "CUSTOM_MID_EV")
ns.Api.EventBus:OffEvent("test:sib3", "CUSTOM_MID_EV")
loadedAddons["MidFaultAddon"] = false
Host:Reset("mid_fault_b")

-- Restore mock C_AddOns
_G.C_AddOns.IsAddOnLoaded = origIsLoaded
_G.C_AddOns.DoesAddOnExist = origExists
if not origCAddOns then _G.C_AddOns = nil end

print("Test 23 PASS: Coexistence 40-cell DDT, CombatQueue v6 tail preservation, C7 CVar journal, and 6 official bridges verified!")
