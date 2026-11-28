-- Test 24: ForeverSuite v6.0 Phase 2 — v5->v6 3-Tier SV Migration & /fsdb restore v5 (AC-8),
--          Data/manifest.lua 3-Tier Fallback & FS.Data.epoch, RegisterPack(2|6) Atomic Shards, and 0-Pack Survival.
local ns = _G.ForeverSuite
__FS_FIRE_EVENT("PLAYER_LOGIN")

local function assertEq(actual, expected, msg)
    assert(actual == expected, (msg or "assertEq failed") .. " (got=" .. tostring(actual) .. ", expected=" .. tostring(expected) .. ")")
end

------------------------------------------------------------------------
-- 1. AC-8: v5 -> v6 lossless idempotent 3-tier migration + _backup_v5 + v7 fail-closed
------------------------------------------------------------------------
local Mig = ns.Domain.ProfileMigrationModel
assertEq(Mig.TARGET_SCHEMA, 6, "TARGET_SCHEMA must be 6")

-- T1: Realistic v5 fixture with protectedItems, ledger, HUD layout, and legacy _v1_backup
local v5Fixture = {
    schemaVersion = 5,
    _v1_backup = { hugeLegacy = true },
    v2 = {
        settings = { quest = { defaultTrackerMode = "hide" }, combat = { lowHealthAlert = true } },
        layout = { questTracker = { point = "TOPRIGHT", x = -24, y = -120 } },
        ledger = { { delta = 50000, reason = "보스 드랍" } },
        protectedItems = { [19019] = true },
        state = { userExplicitTrackerMode = true },
        diagnostics = { taintTotal = 0, taintCounts = {} },
    },
}

local v6, ro, st = Mig.Migrate(v5Fixture, { quest = { defaultTrackerMode = "hide" } })
assertEq(st, "OK", "v5->v6 status OK")
assertEq(ro, false, "v5->v6 writable")
assertEq(v6.schemaVersion, 6, "upgraded to schemaVersion 6")
assertEq(v6.v2.protectedItems[19019], true, "protectedItems preserved")
assertEq(v6.v2.ledger[1].delta, 50000, "ledger preserved")
assert(type(v6._backup_v5) == "table", "_backup_v5 snapshot created")
assertEq(v6._backup_v5._v1_backup, nil, "_backup_v5 excludes nested _v1_backup (no bloat)")
assertEq(v6.v2.profiles.devices.legacy.questTracker.x, -24, "v5 layout seeded into devices.legacy")

-- T2: Idempotent second run preserves _backup_v5 and existing data
local v6Again, ro2, st2 = Mig.Migrate(v6, {})
assertEq(st2, "OK", "idempotent re-migration OK")
assertEq(ro2, false, "still writable")
assertEq(v6Again.schemaVersion, 6, "stays v6")
assertEq(v6Again.v2.protectedItems[19019], true, "protectedItems intact after 2nd run")

-- T3: Multi-device copy-on-first-sight layout & 3-tier setting priority (char > device > account > default)
local dev4k = Mig.MakeDeviceKey(3840, 2160, 0.65, true)
local devFhd = Mig.MakeDeviceKey(1920, 1080, 1.0, false)
assertEq(dev4k, "3840x2160@0.65:MAC", "4K Mac device key format")
assertEq(devFhd, "1920x1080@1.00:WIN", "FHD Win device key format")

local lay4k = Mig.ResolveDeviceLayout(v6, "questTracker", dev4k)
assertEq(lay4k.x, -24, "copy-on-first-sight from devices.legacy")
lay4k.x = -80
local layFhd = Mig.ResolveDeviceLayout(v6, "questTracker", devFhd)
assertEq(layFhd.x, -24, "FHD device gets independent copy from legacy, untouched by 4K edit")

v6.v2.profiles.account.ui = { fontScale = 1.0 }
v6.v2.profiles.devices[dev4k].settings = { ui = { fontScale = 1.25 } }
v6.v2.profiles.chars["Thrall-ForeverKR"] = { ui = { fontScale = 1.40 } }
assertEq(Mig.ResolveSetting(v6, "ui", "fontScale", "Thrall-ForeverKR", dev4k, 0.9), 1.40, "char overrides device & account")
assertEq(Mig.ResolveSetting(v6, "ui", "fontScale", "Jaina-ForeverKR", dev4k, 0.9), 1.25, "device overrides account")
assertEq(Mig.ResolveSetting(v6, "ui", "fontScale", "Jaina-ForeverKR", devFhd, 0.9), 1.0, "account overrides default")
assertEq(Mig.ResolveSetting(v6, "ui", "missingKey", "Jaina-ForeverKR", devFhd, 0.9), 0.9, "fallback to default")

-- T4: RestoreV5Backup restores schemaVersion=5, preserves top-level _v1_backup, and fails safely when absent
assert(v6.v2.profiles.account ~= v6.v2.settings, "B1: profiles.account must be an independent DeepCopy (no SV alias)")
v6.v2.protectedItems[19019] = nil
local restoredV5, okRest = Mig.RestoreV5Backup(v6)
assertEq(okRest, true, "RestoreV5Backup succeeds")
assertEq(restoredV5.schemaVersion, 5, "restored schemaVersion=5")
assertEq(restoredV5.v2.protectedItems[19019], true, "v5 protectedItems restored cleanly")
assert(type(restoredV5._v1_backup) == "table" and restoredV5._v1_backup.hugeLegacy == true, "B3: _v1_backup preserved on v5 restore")
local noBak, okNoBak = Mig.RestoreV5Backup({ schemaVersion = 6, v2 = { protectedItems = { [1] = true } } })
assertEq(okNoBak, false, "B2: RestoreV5Backup returns false when _backup_v5 absent (zero data loss)")
assertEq(noBak, nil, "B2: RestoreV5Backup returns nil when _backup_v5 absent")
-- B4: non-numeric schemaVersion does not crash
local badVerDb, badVerRo, badVerSt = Mig.Migrate({ schemaVersion = "corrupted" }, { quest = { defaultTrackerMode = "hide" } })
assertEq(badVerRo, false, "non-numeric schemaVersion handled cleanly")
assertEq(badVerSt, "OK", "repairs cleanly")
assertEq(badVerDb.schemaVersion, 6, "repaired to schema 6")

-- T5: Future schema (v7) stays strictly Fail-Closed ReadOnly (0 writes)
local v7 = { schemaVersion = 7, v2 = { protectedItems = { [999] = true } } }
local fDb, fRo, fSt = Mig.Migrate(v7, { quest = { defaultTrackerMode = "hide" } })
assertEq(fRo, true, "v7 must be ReadOnly")
assertEq(fSt, "FUTURE_SCHEMA_READONLY", "v7 fail-closed reason")
assertEq(fDb.schemaVersion, 7, "v7 untouched")
assertEq(fDb.v2.settings, nil, "0 writes performed on v7")

-- T6: PresetManager syncedSharedSettings absorbed once into chars[charKey] (D2)
_G.ForeverSuiteV2DB = { schemaVersion = 5, v2 = { settings = {} } }
_G.ForeverSuiteV2CharDB = {
    realm = "ForeverKR",
    applySyncedOnNextLogin = true,
    syncedSharedSettings = { ui = { uiTheme = "dark" } },
}
ns.Api.ProfileStore:Init()
assertEq(_G.ForeverSuiteV2CharDB.applySyncedOnNextLogin, false, "applySyncedOnNextLogin cleared after one-time absorb")
assertEq(ns.Api.ProfileStore:Get("ui", "uiTheme"), "dark", "synced setting hydrated")
local ck = ns.Api.ProfileStore:GetCharKey()
assertEq(ns.Api.ProfileStore.db.v2.profiles.chars[ck].ui.uiTheme, "dark", "absorbed into v6 chars[charKey]")

------------------------------------------------------------------------
-- 2. D5: RegisterPack(2|6) normalization + atomic shard ACTIVE + FS.Data.epoch
------------------------------------------------------------------------
local Hub = ns.Api.DataHub
assert(ns.Data == Hub, "ns.Data alias points to Api.DataHub")

local origData = _G.ForeverSuiteData
_G.ForeverSuiteData = { version = "6.0.0", epoch = 0, packs = {} }
local ep0 = Hub:GetEpoch()

-- Reject invalid schema (e.g. 99), accept schema 6
local badOk, badErr = _G.ForeverSuite_RegisterPack("v6_test", 99, {}, 1, 1, {})
assertEq(badOk, false, "schemaVer 99 rejected")
assertEq(badErr, "INVALID_SCHEMA", "INVALID_SCHEMA reason")

-- 2-shard atomic activation: shard 1/2 stays PENDING, shard 2/2 promotes ACTIVE & bumps epoch!
local ok1, st1 = _G.ForeverSuite_RegisterPack("v6_fish", 6, { title = "Fishing v6" }, 1, 2, { { zone = "엘윈 숲", title = "정적 연어" } })
assertEq(ok1, true, "shard 1/2 accepted")
assertEq(st1, "PARTIAL", "shard 1/2 is PARTIAL")
assertEq(_G.ForeverSuiteData.packs.v6_fish._status, "PENDING", "incomplete pack stays PENDING")
assertEq(Hub:GetEpoch(), ep0, "incomplete shard does not bump epoch")

-- Duplicate shard 1/2 is strictly idempotent
_G.ForeverSuite_RegisterPack("v6_fish", 6, { title = "Fishing v6" }, 1, 2, { { zone = "엘윈 숲", title = "중복" } })
assertEq(#_G.ForeverSuiteData.packs.v6_fish.entries, 1, "duplicate shard ignored idempotently")

-- Shard 2/2 completes pack -> ACTIVE + epoch bump
local ok2, st2 = _G.ForeverSuite_RegisterPack("v6_fish", 6, { title = "Fishing v6" }, 2, 2, { { zone = "타나리스", title = "정적 통돔" } })
assertEq(ok2, true, "shard 2/2 accepted")
assertEq(st2, "COMPLETE", "shard 2/2 completes pack")
assertEq(_G.ForeverSuiteData.packs.v6_fish._status, "ACTIVE", "completed pack is ACTIVE")
assert(Hub:GetEpoch() > ep0, "completing pack bumps DataHub epoch")

------------------------------------------------------------------------
-- 3. D-3: 3-Tier DataResolver (STATIC -> LIVE -> EMBEDDED) + [STALE_PACK] + 0-Pack Survival!
------------------------------------------------------------------------
-- Valid manifest (16001) -> STATIC tier wins
_G.ForeverSuiteData.manifest = { schema = 6, builtForInterface = 16001, generatedEpoch = 1795796800, ttlDays = 365 }
local valS, tierS = Hub:Get("v6_fish", "엘윈 숲")
assert(type(valS) == "table" and valS.title == "정적 연어", "STATIC entry resolved")
assertEq(tierS, "STATIC", "Tier 1 STATIC selected")
assertEq(Hub:IsStalePack(), false, "16001 manifest is fresh")

-- Stale manifest (15999) -> immediately bypasses static pack to LIVE or EMBEDDED + flags [STALE_PACK]!
_G.ForeverSuiteData.manifest.builtForInterface = 15999
assertEq(Hub:IsStalePack(), true, "15999 manifest detected as stale")
local diag = Hub:GetDiagnostics()
assert(string.find(diag.manifestStatus, "STALE_PACK", 1, true) ~= nil, "Diagnostics flags [STALE_PACK]")

local valL, tierL = Hub:Get("fishing", "엘윈 숲", function() return { title = "라이브 API 물고기" } end)
assertEq(valL.title, "라이브 API 물고기", "Stale pack bypassed to LIVE getter")
assertEq(tierL, "LIVE_STALE_BYPASS", "LIVE_STALE_BYPASS tier tag")

local valE, tierE = Hub:Get("fishing", "엘윈 숲")
assert(type(valE) == "table" and string.find(valE.title, "연어", 1, true), "Stale pack bypassed to EMBEDDED when no live getter")
assertEq(tierE, "EMBEDDED_STALE_BYPASS", "EMBEDDED_STALE_BYPASS tier tag")

-- 0-PACK SURVIVAL: completely wipe _G.ForeverSuiteData -> Core still runs with 0 Lua errors!
_G.ForeverSuiteData = nil
local zeroDiag = Hub:GetDiagnostics()
assertEq(zeroDiag.zeroPackMode, true, "0-pack mode detected cleanly")
local zFish, zTier = Hub:Get("fishing", "불모의 땅")
assert(type(zFish) == "table" and zFish.minSkill == 75, "0-pack survival resolves embedded fishing table")
assertEq(zTier, "EMBEDDED", "Tier 3 EMBEDDED selected in 0-pack mode")
local zCd = Hub:Get("craft_cooldowns", "mooncloth")
assert(type(zCd) == "table" and zCd.hours == 96, "0-pack survival resolves embedded craft cooldowns")
local zMiss, zMissTier = Hub:Get("fishing", "존재하지않는지역")
assertEq(zMiss, nil, "missing key returns nil (Zero Fabricated Status, never fake 0)")
assertEq(zMissTier, "MISSING", "MISSING tier tag")

-- Restore original data table
_G.ForeverSuiteData = origData

------------------------------------------------------------------------
-- 7. Track L Unanchored Release Audit Regressions (P1-1, P1-2, P1-3)
------------------------------------------------------------------------
-- P1-1a: Non-table ForeverSuiteV2DB MUST NOT be clobbered with nil
local savedV2Global = _G.ForeverSuiteV2DB
_G.ForeverSuiteV2DB = "CORRUPT_STRING_PAYLOAD"
ns.Api.ProfileStore:Init()
assertEq(_G.ForeverSuiteV2DB, "CORRUPT_STRING_PAYLOAD", "invalid non-table ForeverSuiteV2DB preserved untouched")
assertEq(ns.Api.ProfileStore.readOnly, true, "invalid DB enters readOnly mode")

-- P1-1b: Future-schema (v7) GetLayout MUST NOT mutate devices table
local v7db = {
    schemaVersion = 7,
    v2 = {
        settings = {},
        layout = {},
        profiles = { devices = { legacy = { tracker = { x = 10, y = 20 } } } },
    },
}
_G.ForeverSuiteV2DB = v7db
ns.Api.ProfileStore:Init()
assertEq(ns.Api.ProfileStore.readOnly, true, "v7 DB is readOnly")
local v7Layout = ns.Api.ProfileStore:GetLayout("tracker")
assert(type(v7Layout) == "table" and v7Layout.x == 10, "v7 GetLayout still resolves legacy fallback")
local devKeyNow = ns.Api.ProfileStore:GetDeviceKey()
assertEq(v7db.v2.profiles.devices[devKeyNow], nil, "v7 readOnly GetLayout must NOT seed devices[devKey]")

-- P1-2a: RestoreV5 blocked when readOnly (v7)
local okV7Res, stV7Res = ns.Api.ProfileStore:RestoreV5()
assertEq(okV7Res, false, "RestoreV5 blocked on readOnly future schema")
assertEq(stV7Res, "READ_ONLY", "RestoreV5 returns READ_ONLY")

-- P1-2b: RestoreV5 preserves live v6 in _pre_restore_v6 and restores exact source schema (e.g. v4 -> 4)
local v4db = { schemaVersion = 4, v2 = { settings = { ui = { uiTheme = "dark" } }, layout = {}, state = {}, ledger = { { delta = 100 } } } }
_G.ForeverSuiteV2DB = v4db
ns.Api.ProfileStore:Init()
assertEq(_G.ForeverSuiteV2DB.schemaVersion, 6, "v4 migrated to v6")
assertEq(_G.ForeverSuiteV2DB._backup_v5_schema, 4, "source schema 4 recorded alongside _backup_v5")
_G.ForeverSuiteV2DB.v2.ledger = { { delta = 100 }, { delta = 9999 } }
local okV4Res = ns.Api.ProfileStore:RestoreV5()
assertEq(okV4Res, true, "RestoreV5 succeeds on writable v6")
assertEq(_G.ForeverSuiteV2DB.schemaVersion, 4, "restored DB preserves true source schema 4 (not falsely stamped 5)")
assert(type(_G.ForeverSuiteV2DB._pre_restore_v6) == "table" and #_G.ForeverSuiteV2DB._pre_restore_v6.ledger == 2, "live v6 ledger preserved in _pre_restore_v6")
-- Repeated RestoreV5 MUST NOT erase _pre_restore_v6 with legacy payload
local okV4Res2 = ns.Api.ProfileStore:RestoreV5()
assertEq(okV4Res2, true, "repeated RestoreV5 succeeds cleanly")
assert(type(_G.ForeverSuiteV2DB._pre_restore_v6) == "table" and #_G.ForeverSuiteV2DB._pre_restore_v6.ledger == 2, "repeated RestoreV5 preserves original _pre_restore_v6 snapshot")

-- P1-3b: Read-only future-schema (v7) journal MUST NOT mutate client CVars
local v7CvarHit = false
local origSetCVarV7 = _G.C_CVar and _G.C_CVar.SetCVar
_G.C_CVar = _G.C_CVar or {}
_G.C_CVar.SetCVar = function() v7CvarHit = true; return true end
_G.ForeverSuiteV2DB = {
    schemaVersion = 7,
    v2 = { settings = {}, layout = {}, state = { cvarRestoreJournal = { cameraDistanceMaxZoomFactor = "1.9" } } },
}
ns.Api.ProfileStore:Init()
local v7App, v7Def = ns.Api.ProfileStore:RestoreCvarJournal(nil)
assertEq(v7App, 0, "v7 readOnly DB applies 0 CVars")
assertEq(v7Def, 0, "v7 readOnly DB defers 0 CVars")
assertEq(v7CvarHit, false, "v7 readOnly DB never invokes SetCVar")
_G.C_CVar.SetCVar = origSetCVarV7

-- P1-3: Failed CVar restore via CombatQueue MUST NOT count as executed, and direct restore blocks in combat
_G.ForeverSuiteV2DB = savedV2Global
ns.Api.ProfileStore:Init()
ns.Api.ProfileStore:RecordCvarJournal("cameraDistanceMaxZoomFactor", "1.9")
local origCombatFlag = _G.__FS_MOCK.inCombat
local origSetCVarP1 = _G.C_CVar and _G.C_CVar.SetCVar
_G.C_CVar = _G.C_CVar or {}
local directSetCalled = false
_G.C_CVar.SetCVar = function() directSetCalled = true; return true end
_G.__FS_MOCK.inCombat = true
local appDirect = ns.Api.ProfileStore:RestoreCvarJournal(nil)
assertEq(appDirect, 0, "direct RestoreCvarJournal refuses to run in combat")
assertEq(directSetCalled, false, "direct SetCVar not called in combat")

_G.__FS_MOCK.inCombat = false
_G.C_CVar.SetCVar = function() return false end
local execBefore = ns.Secure.CombatQueue.stats.executed
local reqBefore = ns.Secure.CombatQueue.stats.requeued
ns.Api.ProfileStore:RestoreCvarJournal(function(k, fn) return ns.Secure.CombatQueue:RunOrDefer(k, fn) end)
assertEq(ns.Secure.CombatQueue.stats.executed, execBefore, "failed CVar restore must NOT increment CombatQueue stats.executed")
assert(ns.Secure.CombatQueue.stats.requeued > reqBefore, "failed CVar restore requeued for retry")
ns.Secure.CombatQueue.pending = {}
ns.Secure.CombatQueue.order = {}
ns.Secure.CombatQueue.inOrder = {}
ns.Secure.CombatQueue.attempts = {}
ns.Api.ProfileStore:ClearCvarJournal("cameraDistanceMaxZoomFactor")

-- P1-3c: Deferred CVar restore queued during combat MUST NO-OP if active DB switches before Flush()
ns.Api.ProfileStore:RecordCvarJournal("cameraDistanceMaxZoomFactor", "1.9")
_G.__FS_MOCK.inCombat = true
local _, defCount = ns.Api.ProfileStore:RestoreCvarJournal(function(k, fn) return ns.Secure.CombatQueue:RunOrDefer(k, fn) end)
assertEq(defCount, 1, "CVar restore deferred during combat")
-- Switch active DB to a replacement profile with its own journal entry before combat ends
local replacementDb = {
    schemaVersion = 6,
    v2 = { settings = {}, layout = {}, state = { cvarRestoreJournal = { cameraDistanceMaxZoomFactor = "2.6" } } },
}
_G.ForeverSuiteV2DB = replacementDb
ns.Api.ProfileStore:Init()
local staleHit = false
_G.C_CVar.SetCVar = function() staleHit = true; return true end
_G.__FS_MOCK.inCombat = false
ns.Secure.CombatQueue:Flush()
assertEq(staleHit, false, "stale deferred CVar callback must NOT write after profile switch")
assertEq(ns.Api.ProfileStore:GetState("cvarRestoreJournal").cameraDistanceMaxZoomFactor, "2.6", "replacement profile journal stays intact")
_G.ForeverSuiteV2DB = savedV2Global
ns.Api.ProfileStore:Init()
ns.Api.ProfileStore:ClearCvarJournal()

-- P1-3d: Same-journal SAME-VALUE ABA test (proves generation guard independently of value inequality)
ns.Api.ProfileStore:RecordCvarJournal("otherCvar", "1")
ns.Api.ProfileStore:RecordCvarJournal("cameraDistanceMaxZoomFactor", "1.9")
_G.__FS_MOCK.inCombat = true
ns.Api.ProfileStore:RestoreCvarJournal(function(k, fn) return ns.Secure.CombatQueue:RunOrDefer(k, fn) end)
ns.Api.ProfileStore:ClearCvarJournal("cameraDistanceMaxZoomFactor")
ns.Api.ProfileStore:RecordCvarJournal("cameraDistanceMaxZoomFactor", "1.9")
local abaApplied = {}
_G.C_CVar.SetCVar = function(name, val) abaApplied[name] = val; return true end
_G.__FS_MOCK.inCombat = false
ns.Secure.CombatQueue:Flush()
assertEq(abaApplied["cameraDistanceMaxZoomFactor"], nil, "stale same-value ABA callback blocked by generation guard")
assertEq(ns.Api.ProfileStore:GetState("cvarRestoreJournal").cameraDistanceMaxZoomFactor, "1.9", "re-recorded same-value key stays intact in journal")
ns.Api.ProfileStore:ClearCvarJournal()
_G.C_CVar.SetCVar = origSetCVarP1
_G.__FS_MOCK.inCombat = origCombatFlag

print("Test 24 PASS: v5->v6 3-tier SV migration, /fsdb restore v5, RegisterPack(2|6), 3-tier DataHub & [STALE_PACK], and 0-pack survival verified!")
