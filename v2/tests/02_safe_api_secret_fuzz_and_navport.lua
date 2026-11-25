-- Test 02: SafeAPI C_Secrets Proxy Fuzzing (type-preserving), Fail-Closed InCombat, and NavPort WorldMap OnHide Flush
local ns = _G.ForeverSuiteV2
local SafeAPI = ns.Api.SafeAPI
local NavPort = ns.Api.NavPort

__FS_FIRE_EVENT("PLAYER_LOGIN")

-- 1. Type-preserving SecretProxy fuzzing: type(s) == "number", SafeRead intercepts before any op
local sNum = FS_MakeSecret("combat_hp", "number")
assert(type(sNum) == "number", "SecretProxy must preserve underlying Lua type")
assert(SafeAPI.IsSecret(sNum) == true)
local secretVal = SafeAPI.SafeRead(function() return sNum end)
assert(secretVal == SafeAPI.UNAVAILABLE)

-- Fail-closed InCombat(): secret or throwing InCombatLockdown returns true!
local origCombat = InCombatLockdown
InCombatLockdown = function() return FS_MakeSecret("inCombat", "boolean") end
assert(SafeAPI.InCombat() == true, "InCombat must fail-closed to true on Secret value")
InCombatLockdown = function() error("boom") end
assert(SafeAPI.InCombat() == true, "InCombat must fail-closed to true on error")
InCombatLockdown = origCombat

-- 2. KR empty realm normalization
_G.__FS_MOCK.realm = ""
_G.__FS_MOCK.realmFallback = ""
assert(SafeAPI.GetCanonicalRealm() == "ForeverKR")

-- 3. NavPort defers BOTH SuperTrack & Waypoint while WorldMapFrame is shown, and flushes immediately on WorldMap OnHide!
_G.__FS_MOCK.questLogSet = { [101] = 1, [202] = 2 }
_G.__FS_MOCK.superTrackedQuestID = 0
_G.__FS_MOCK.userWaypoint = nil
_G.__FS_MOCK.worldMapShown = true

local okQ, stQ = NavPort.RequestSuperTrack(101)
local okW, stW = NavPort.SetWaypoint(1411, 0.55, 0.42)
assert(okQ == false and stQ == "DEFERRED")
assert(okW == false and stW == "DEFERRED")
assert(_G.__FS_MOCK.superTrackedQuestID == 0 and _G.__FS_MOCK.userWaypoint == nil)

-- WorldMapFrame closes -> Blizzard/WorldMapAdapter OnHide flushes BOTH automatically without needing combat!
_G.__FS_MOCK.worldMapShown = false
_G.WorldMapFrame:FireScript("OnHide")
assert(_G.__FS_MOCK.superTrackedQuestID == 101, "SuperTrack must flush on WorldMap OnHide")
assert(_G.__FS_MOCK.userWaypoint ~= nil and _G.__FS_MOCK.userWaypoint.uiMapID == 1411, "Waypoint must flush on WorldMap OnHide")

-- Abandoned quest mid-combat is skipped cleanly at drain
_G.__FS_MOCK.inCombat = true
NavPort.RequestSuperTrack(202)
_G.__FS_MOCK.questLogSet[202] = nil
_G.__FS_MOCK.inCombat = false
__FS_FIRE_EVENT("PLAYER_REGEN_ENABLED")
assert(_G.__FS_MOCK.superTrackedQuestID == 101)
