-- Test 09: M2 6-Pack Sharded LoD Data Compiler Output, Registration Guard, 5-State Loader & Multi-Tab Codex Browser
local ns = _G.ForeverSuiteV2

__FS_FIRE_EVENT("PLAYER_LOGIN")

-- 1. Zero LoD packs loaded at login (0MB RAM invariant I5)
assert(_G.ForeverSuiteData == nil, "No LoD data packs may be loaded at PLAYER_LOGIN")

-- 2. RegisterPack schema/shard validation rejects malformed packs, non-integers, and shard count mismatches (B4)
local okBad, errBad = _G.ForeverSuite_RegisterPack("bad", 99, {}, 1, 1, {})
assert(okBad == false and errBad == "INVALID_SCHEMA")
local okBadShard, errBadShard = _G.ForeverSuite_RegisterPack("bad", 2, {}, 5, 2, {})
assert(okBadShard == false and errBadShard == "INVALID_SHARD")
local okFrac, errFrac = _G.ForeverSuite_RegisterPack("bad", 2, {}, 1.5, 2, {})
assert(okFrac == false and errFrac == "INVALID_SHARD")
local okP1, stP1 = _G.ForeverSuite_RegisterPack("shard_test", 2, { title = "t" }, 1, 2, { { title = "a" } })
assert(okP1 == true and stP1 == "PARTIAL")
local okMismatch, errMismatch = _G.ForeverSuite_RegisterPack("shard_test", 2, { title = "t" }, 2, 3, { { title = "b" } })
assert(okMismatch == false and errMismatch == "SHARD_MISMATCH")
assert(_G.ForeverSuiteData.packs.shard_test._complete == false)
_G.ForeverSuiteData = nil

-- 3. 5-state LoadDataPack: IN_COMBAT and NOT_INSTALLED fail closed
_G.__FS_MOCK.inCombat = true
local okC, stC = ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_Dungeon")
assert(okC == false and stC == "IN_COMBAT")
_G.__FS_MOCK.inCombat = false

_G.__FS_MOCK.addonExists["ForeverSuite_Data_Missing"] = false
local okM, stM = ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_Missing")
assert(okM == false and stM == "NOT_INSTALLED")

-- 4. Wire C_AddOns.LoadAddOn to load real compiled LoD addons from disk into Lua 5.1 VM
local origLoad = C_AddOns.LoadAddOn
C_AddOns.LoadAddOn = function(name)
    if string.find(tostring(name), "^ForeverSuite_Data") then
        local loaded = __FS_LOAD_DATA_ADDON(name)
        _G.__FS_MOCK.loadedAddOns[name] = loaded
        return loaded, loaded and nil or "LOAD_FAILED"
    end
    return origLoad(name)
end

-- Load ALL 6 compiled real GodJohnson LoD packs and verify real encyclopedic entry counts!
local expectedPacks = {
    { addon = "ForeverSuite_Data_Dungeon", id = "dungeons", minCount = 10 },
    { addon = "ForeverSuite_Data_Dungeon", id = "dungeon_loot", minCount = 200 },
    { addon = "ForeverSuite_Data_BiS", id = "bis", minCount = 200 },
    { addon = "ForeverSuite_Data_Profession", id = "professions", minCount = 500 },
    { addon = "ForeverSuite_Data_Reward", id = "rewards", minCount = 100 },
    { addon = "ForeverSuite_Data_Pet", id = "hunter_pets", minCount = 100 },
    { addon = "ForeverSuite_Data_Atlas", id = "atlas_npcs", minCount = 100 },
    { addon = "ForeverSuite_Data_Atlas", id = "class_quests", minCount = 50 },
    { addon = "ForeverSuite_Data_Atlas", id = "training_spells", minCount = 100 },
}

for _, spec in ipairs(expectedPacks) do
    local ok, st = ns.Api.SafeAPI.LoadDataPack(spec.addon)
    assert(ok == true and st == "LOADED", "Failed to load LoD pack: " .. spec.addon)
    local p = _G.ForeverSuiteData and _G.ForeverSuiteData.packs and _G.ForeverSuiteData.packs[spec.id]
    assert(type(p) == "table" and p._complete == true, "Pack incomplete or missing: " .. spec.id)
    assert(#p.entries >= spec.minCount, "Expected >=" .. tostring(spec.minCount) .. " entries in " .. spec.id .. ", got " .. tostring(#p.entries))
end

-- 5. Multi-tab CodexPage browsing, search, pagination, quest completion badge & zero frame leak
local hub = ns.UI.CommandHub
hub:EnsureWindow()
hub:SelectPage("codex")

local codex = ns.Features.CodexPage
codex.activePack = "bis"
codex:EnsureDataLoaded("bis")
codex:RenderPack("")
assert(codex.visibleRows == 13 and codex.totalMatches >= 200)
local framesBeforePage = #_G.__FS_MOCK.frames
codex:StepPage(1)
assert(codex.pageIndex == 2)
codex:StepPage(-1)
assert(codex.pageIndex == 1)
assert(#_G.__FS_MOCK.frames == framesBeforePage, "Pagination must reuse pooled rows (zero frame leak)")

-- Quest completion badge in class_quests tab
local firstCQ = _G.ForeverSuiteData.packs.class_quests.entries[1]
_G.__FS_MOCK.questFlaggedCompleted[firstCQ.questID] = true
codex.activePack = "class_quests"
codex:RenderPack("")
assert(string.find(codex.rowPool[1]._left:GetText(), "[완료]", 1, true), "Completed class quest must show [완료] badge")
