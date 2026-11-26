-- Test 01: Domain pure models & v1 -> v2 SavedVariables migration + rollback (real Lua 5.1 VM)
local ns = _G.ForeverSuiteV2
assert(type(ns) == "table", "ForeverSuiteV2 namespace missing")

local snap = ns.Domain.QuestTrackerModel.BuildSnapshot({
    {
        questID = 101,
        title = "에드윈 밴클리프 처치",
        zone = "서부 몰락지대",
        level = 22,
        itemLink = "|Hitem:5501|h[신호탄]|h",
        itemIcon = 133710,
        objectives = { { text = "밴클리프: 0/1", finished = false } },
    },
    {
        questID = 90001,
        title = "포에버 차원의 틈",
        zone = "오그리마",
        level = 60,
        isForever = true,
        isComplete = true,
    },
}, { superTrackedQuestID = 90001 })

assert(snap.questCount == 2)
assert(#snap.dockSlots == 1 and snap.dockSlots[1].questID == 101)
assert(snap.rows[2].questID == 90001)
assert(string.find(snap.rows[2].title, "[∞ 포에버]", 1, true))
assert(string.find(snap.rows[4].title, "[1]", 1, true))

assert(ns.Domain.LedgerModel.FormatCopper(123456) == "12g 34s 56c")
assert(ns.Domain.LedgerModel.FormatCopper(-502) == "-5s 02c")
local sum = ns.Domain.LedgerModel.Summarize({ { delta = 50000 }, { delta = -12000 } })
assert(sum.net == 38000)

-- Non-destructive legacy import preserves protectedItems & _diagnostics, keeping defaultTrackerMode safely at "coexist"
local legacyV1 = {
    schemaVersion = 2,
    account = {
        utility = { protectedItems = { [6948] = true } },
        quest = { hideDefaultTracker = true },
    },
    _diagnostics = { taintCounts = { ["ForeverSuite:Test"] = 3 } },
}
local migrated, ro, status = ns.Domain.ProfileMigrationModel.Migrate({}, {
    quest = { defaultTrackerMode = "hide" },
}, legacyV1)
assert(status == "OK" and ro == false and migrated.schemaVersion == 5)
assert(migrated.v2.protectedItems[6948] == true)
assert(migrated.v2.settings.quest.defaultTrackerMode == "hide")
assert(migrated.v2.diagnostics.importedV1TaintCounts["ForeverSuite:Test"] == 3)

-- Schema 3/4 -> 5 upgrade switches preview-era "coexist" to "hide" to eliminate duplicate quest trackers
local prevV3 = { schemaVersion = 3, v2 = { settings = { quest = { defaultTrackerMode = "coexist" } } } }
local upgradedV5 = ns.Domain.ProfileMigrationModel.Migrate(prevV3, { quest = { defaultTrackerMode = "hide" } })
assert(upgradedV5.schemaVersion == 5 and upgradedV5.v2.settings.quest.defaultTrackerMode == "hide")

-- Shape repair on corrupted schema-5 DB + backup/restore
local broken = { schemaVersion = 5, v2 = "corrupted" }
local repaired, rro = ns.Domain.ProfileMigrationModel.Migrate(broken, { quest = { defaultTrackerMode = "hide" } })
assert(rro == false and type(repaired.v2.diagnostics) == "table" and repaired.v2.settings.quest.defaultTrackerMode == "hide")

local withPrev = { oldField = 42 }
local upg = ns.Domain.ProfileMigrationModel.Migrate(withPrev, {})
local restored, okRestore = ns.Domain.ProfileMigrationModel.RestoreBackup(upg)
assert(okRestore == true and restored.oldField == 42)

-- Future schema stays Fail-Closed read-only
local future, fro, fstatus = ns.Domain.ProfileMigrationModel.Migrate({ schemaVersion = 99 }, {})
assert(fro == true and fstatus == "FUTURE_SCHEMA_READONLY")
