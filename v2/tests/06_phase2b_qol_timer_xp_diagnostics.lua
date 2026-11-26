-- Test 06: Phase 2B QoL Automation, Session XP/h Tracker, Encounter/Dungeon/Pull Timer HUD, DiagnosticsPage, Strata & All Adversarial Regression Guards (B1..B4, N1..N7)
local ns = _G.ForeverSuiteV2

_G.__FS_MOCK.now = 1000
_G.__FS_MOCK.xp = 1000
_G.__FS_MOCK.xpMax = 10000
_G.__FS_MOCK.level = 20
_G.__FS_MOCK.maxLevel = 60
_G.__FS_MOCK.restedXP = 800
_G.__FS_MOCK.cvars = { autoLootDefault = "1", cameraDistanceMaxZoomFactor = "1.9" }
_G.__FS_MOCK.friends = { "길드친구-ForeverKR", "타서버친구-RealmA" }
_G.__FS_MOCK.guildMembers = { "전우-ForeverKR" }

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

-- 1. Explicit L0/L1 elevation strata on all HUD cards
assert(ns.Features.StatusPillHud.card._strata == ns.UI.Tokens.ELEVATION.L0_HUD)
assert(ns.Features.NavigationHud.card._strata == ns.UI.Tokens.ELEVATION.L0_HUD)
assert(ns.Features.CombatAssistHud.strip._strata == ns.UI.Tokens.ELEVATION.L0_HUD)
assert(ns.Features.EncounterTimerHud.card._strata == ns.UI.Tokens.ELEVATION.L0_HUD)
assert(ns.Features.FishingCardHud.card._strata == ns.UI.Tokens.ELEVATION.L1_CARD)

-- 2. QoL Fast Loot + N6 (IsModifiedClick("AUTOLOOTTOGGLE") + fail-closed modifier/CVar + v1 yield)
_G.__FS_MOCK.lootCount = 3
_G.__FS_MOCK.lootedSlots = {}
_G.__FS_MOCK.shiftDown = false
_G.__FS_MOCK.modifiedClicks = {}
__FS_FIRE_EVENT("LOOT_READY")
assert(#_G.__FS_MOCK.lootedSlots == 3 and _G.__FS_MOCK.lootedSlots[1] == 3 and _G.__FS_MOCK.lootedSlots[3] == 1, "fast loot must loot in reverse order (3,2,1)")

-- Custom AUTOLOOTTOGGLE keybind active even while Shift is NOT pressed -> MUST skip!
_G.__FS_MOCK.lootedSlots = {}
_G.__FS_MOCK.modifiedClicks["AUTOLOOTTOGGLE"] = true
__FS_FIRE_EVENT("LOOT_READY")
assert(#_G.__FS_MOCK.lootedSlots == 0, "AUTOLOOTTOGGLE modified click must suppress fast loot when autoLootDefault=1")

-- Secret/unreadable modifier -> fail-closed (must NOT loot!)
_G.__FS_MOCK.modifiedClicks["AUTOLOOTTOGGLE"] = FS_MakeSecret("mod", "boolean")
__FS_FIRE_EVENT("LOOT_READY")
assert(#_G.__FS_MOCK.lootedSlots == 0, "unreadable modifier must fail closed")
_G.__FS_MOCK.modifiedClicks = {}

-- Unreadable CVar -> fail-closed
_G.__FS_MOCK.cvars.autoLootDefault = nil
__FS_FIRE_EVENT("LOOT_READY")
assert(#_G.__FS_MOCK.lootedSlots == 0, "unreadable autoLootDefault CVar must fail closed")
_G.__FS_MOCK.cvars.autoLootDefault = "1"

-- ForeverSuite 2.0.0 itself being loaded must NEVER yield to itself; only legacy ForeverSuite_GJBridge yields!
_G.__FS_MOCK.loadedAddOns["ForeverSuite"] = true
__FS_FIRE_EVENT("LOOT_READY")
assert(#_G.__FS_MOCK.lootedSlots == 3, "ForeverSuite 2.0.0 must NEVER self-yield when loaded as ForeverSuite")
_G.__FS_MOCK.lootedSlots = {}
_G.__FS_MOCK.loadedAddOns["ForeverSuite_GJBridge"] = true
__FS_FIRE_EVENT("LOOT_READY")
assert(#_G.__FS_MOCK.lootedSlots == 0, "FastLoot must yield if legacy ForeverSuite_GJBridge is somehow loaded")
_G.__FS_MOCK.loadedAddOns["ForeverSuite_GJBridge"] = false

-- 3. QoL BG-only Auto-Release Spirit (NEVER in dungeon, NEVER with Soulstone, NEVER on secret HasSoulstone)
_G.__FS_MOCK.releasedSpirit = 0
_G.__FS_MOCK.inInstance = true
_G.__FS_MOCK.instanceType = "party"
_G.__FS_MOCK.hasSoulstone = false
__FS_FIRE_EVENT("PLAYER_DEAD")
assert(_G.__FS_MOCK.releasedSpirit == 0, "must NEVER auto-release in 5-man dungeon")

_G.__FS_MOCK.instanceType = "pvp"
_G.__FS_MOCK.hasSoulstone = "영혼석"
__FS_FIRE_EVENT("PLAYER_DEAD")
assert(_G.__FS_MOCK.releasedSpirit == 0, "must NEVER auto-release when Soulstone available")

_G.__FS_MOCK.hasSoulstone = "윤회" -- Shaman Reincarnation is also reported by WoW HasSoulstone()
__FS_FIRE_EVENT("PLAYER_DEAD")
assert(_G.__FS_MOCK.releasedSpirit == 0, "must NEVER auto-release when Shaman Reincarnation available")

_G.__FS_MOCK.hasSoulstone = FS_MakeSecret("ss", "string")
__FS_FIRE_EVENT("PLAYER_DEAD")
assert(_G.__FS_MOCK.releasedSpirit == 0, "secret HasSoulstone must fail closed")

_G.__FS_MOCK.hasSoulstone = false
__FS_FIRE_EVENT("PLAYER_DEAD")
assert(_G.__FS_MOCK.releasedSpirit == 1, "BG without self-res must auto-release")

-- 4. B1 Regression: Out-of-Combat Auto-Accept Res (NEVER during boss encounter, NEVER when caster is in combat, NEVER when UnitAffectingCombat missing or casterName missing/secret!)
_G.__FS_MOCK.acceptedRes = 0
_G.__FS_MOCK.inCombat = false
_G.__FS_MOCK.affectingCombat = false -- dead player is out of combat!

-- Case 4A: Caster is in combat (classic raid battle-res!) -> MUST BLOCK
_G.__FS_MOCK.unitCombat = { ["드루이드힐러"] = true }
__FS_FIRE_EVENT("RESURRECT_REQUEST", "드루이드힐러")
assert(_G.__FS_MOCK.acceptedRes == 0, "B1: combat-res from in-combat caster must NOT auto-accept")
_G.__FS_MOCK.unitCombat = {}

-- Case 4B: Active boss encounter even if caster combat flag is false -> MUST BLOCK
__FS_FIRE_EVENT("ENCOUNTER_START", 200, "라그나로스")
__FS_FIRE_EVENT("RESURRECT_REQUEST", "드루이드힐러")
assert(_G.__FS_MOCK.acceptedRes == 0, "B1: res during active boss encounter must NOT auto-accept")
__FS_FIRE_EVENT("ENCOUNTER_END", 200, "라그나로스", 1, 40, 0)

-- Case 4C: UnitAffectingCombat missing -> fail-closed MUST BLOCK
local savedCombatFn = _G.UnitAffectingCombat
_G.UnitAffectingCombat = nil
__FS_FIRE_EVENT("RESURRECT_REQUEST", "드루이드힐러")
assert(_G.__FS_MOCK.acceptedRes == 0, "B1: missing UnitAffectingCombat must fail closed")
_G.UnitAffectingCombat = savedCombatFn

-- Case 4D: Missing/secret casterName -> fail-closed MUST BLOCK
__FS_FIRE_EVENT("RESURRECT_REQUEST", nil)
__FS_FIRE_EVENT("RESURRECT_REQUEST", FS_MakeSecret("caster", "string"))
assert(_G.__FS_MOCK.acceptedRes == 0, "B1: nil/secret casterName must fail closed")

-- Case 4E: Verified out-of-combat player + out-of-combat caster + no encounter -> ACCEPTS
__FS_FIRE_EVENT("RESURRECT_REQUEST", "드루이드힐러")
assert(_G.__FS_MOCK.acceptedRes == 1, "verified out-of-combat res must auto-accept")

-- 5. B2 Regression: Cross-realm impersonation blocked!
_G.__FS_MOCK.acceptedGroup = 0
__FS_FIRE_EVENT("PARTY_INVITE_REQUEST", "모르는유저-ForeverKR")
assert(_G.__FS_MOCK.acceptedGroup == 0, "stranger invite must NOT auto-accept")
__FS_FIRE_EVENT("PARTY_INVITE_REQUEST", "타서버친구-RealmB")
assert(_G.__FS_MOCK.acceptedGroup == 0, "B2: same name on DIFFERENT realm (RealmB vs RealmA) must NOT auto-accept")
__FS_FIRE_EVENT("PARTY_INVITE_REQUEST", "타서버친구") -- no realm suffix -> ForeverKR != RealmA
assert(_G.__FS_MOCK.acceptedGroup == 0, "B2: bare name (ForeverKR) must NOT match RealmA friend")
__FS_FIRE_EVENT("PARTY_INVITE_REQUEST", FS_MakeSecret("inv", "string"))
assert(_G.__FS_MOCK.acceptedGroup == 0, "secret inviter name must fail closed")
__FS_FIRE_EVENT("PARTY_INVITE_REQUEST", "길드친구") -- bare name attaches ForeverKR == ForeverKR
assert(_G.__FS_MOCK.acceptedGroup == 1, "same-realm friend must auto-accept")
__FS_FIRE_EVENT("PARTY_INVITE_REQUEST", "타서버친구-RealmA") -- exact realm match
assert(_G.__FS_MOCK.acceptedGroup == 2, "exact cross-realm friend match must auto-accept")
__FS_FIRE_EVENT("PARTY_INVITE_REQUEST", "전우-ForeverKR")
assert(_G.__FS_MOCK.acceptedGroup == 3, "guild member must auto-accept")

-- 6. N7 + P0-3 Regression: combatSafe=false rejected in combat; deferred CVar applies OOC and RESTORES when toggled OFF!
_G.__FS_MOCK.inCombat = true
local okZoomCombat, reasonZoomCombat = ns.Api.ProfileStore:Set("qol", "maxCameraZoom", true)
assert(okZoomCombat == false and reasonZoomCombat == "IN_COMBAT", "P0-3: combatSafe=false setting must fail-closed in combat")
assert(_G.__FS_MOCK.cvars.cameraDistanceMaxZoomFactor == "1.9", "must NOT touch camera CVar during combat")
-- Also verify QoLModule itself defers CVar mutation if already enabled before combat
ns.Api.ProfileStore.db.v2.settings.qol.maxCameraZoom = true
ns.Features.QoLModule:ApplyCameraZoomIfEnabled()
assert(_G.__FS_MOCK.cvars.cameraDistanceMaxZoomFactor == "1.9", "QoLModule must NOT mutate camera CVar during combat")
_G.__FS_MOCK.inCombat = false
__FS_FIRE_EVENT("PLAYER_REGEN_ENABLED")
assert(_G.__FS_MOCK.cvars.cameraDistanceMaxZoomFactor == "2.6", "must apply camera CVar safely out of combat")
ns.Api.ProfileStore:Set("qol", "maxCameraZoom", false)
assert(_G.__FS_MOCK.cvars.cameraDistanceMaxZoomFactor == "1.9", "N7: disabling maxCameraZoom must restore previous CVar")

-- 7. Session XP/h Tracker: normal gain, Classic wrap before level-up, Secret gap honesty, /fs2 xp & /fs2 xp reset
_G.__FS_MOCK.now = 1600
_G.__FS_MOCK.xp = 4000
__FS_FIRE_EVENT("PLAYER_XP_UPDATE")
local st1 = ns.Features.QoLModule:GetSessionXPStats()
assert(st1.sessionGained == 3000 and st1.xpPerHour == 18000, "3000 XP in 600s = 18000 XP/h")

_G.__FS_MOCK.xp = 500
__FS_FIRE_EVENT("PLAYER_XP_UPDATE")
_G.__FS_MOCK.level = 21
_G.__FS_MOCK.xpMax = 12000
__FS_FIRE_EVENT("PLAYER_LEVEL_UP")
local st2 = ns.Features.QoLModule:GetSessionXPStats()
assert(st2.sessionGained == 9500, "wrap + subsequent level-up must NOT double-count")

_G.__FS_MOCK.xp = FS_MakeSecret("xp", "number")
__FS_FIRE_EVENT("PLAYER_XP_UPDATE")
assert(ns.Features.QoLModule.xpState.secretGap == true)
_G.__FS_MOCK.xp = 500
_G.SlashCmdList["FOREVERSUITEV2"]("xp")
assert(string.find(_G.__FS_MOCK.printed[#_G.__FS_MOCK.printed], "Secret 미집계", 1, true))
_G.SlashCmdList["FOREVERSUITEV2"]("xp reset")
assert(ns.Features.QoLModule.xpState.sessionGained == 0 and ns.Features.QoLModule.xpState.secretGap == false)

-- 8. B3, B4, N1, N2, N5 Regressions for EncounterTimerHud
-- 8A. B4 + N5: Outside instance/combat, /fs2 pull nan & -5 rejected; /fs2 pull 5 shows PULL_GO for 2s then auto-hides & stops ticker!
_G.__FS_MOCK.inInstance = false
_G.__FS_MOCK.instanceType = "none"
_G.__FS_MOCK.instanceName = ""
_G.__FS_MOCK.now = 1900
__FS_FIRE_EVENT("ZONE_CHANGED_NEW_AREA")

local okNan = ns.Features.EncounterTimerHud:HandlePullCommand("nan")
local okNeg = ns.Features.EncounterTimerHud:HandlePullCommand("-5")
assert(okNan == false and okNeg == false, "N5: nan and negative pull durations must be rejected")

ns.Api.ProfileStore:Set("combat", "showEncounterTimer", false)
local okDis, reasonDis = ns.Features.EncounterTimerHud:HandlePullCommand("10")
assert(okDis == false and reasonDis == "HUD_DISABLED", "N5: pull must report HUD_DISABLED when timer HUD is off")
ns.Api.ProfileStore:Set("combat", "showEncounterTimer", true)

_G.SlashCmdList["FOREVERSUITEV2"]("pull 5")
assert(ns.Features.EncounterTimerHud.card:IsShown() == true and ns.Features.EncounterTimerHud.ticker ~= nil)
_G.__FS_MOCK.now = 1905
ns.Features.EncounterTimerHud.ticker:Tick()
assert(ns.Features.EncounterTimerHud.lastView.mode == "PULL_GO" and ns.Features.EncounterTimerHud.ticker ~= nil, "B4: PULL_GO must keep ticker alive for 2s dwell")
_G.__FS_MOCK.now = 1907.1
ns.Features.EncounterTimerHud.ticker:Tick()
assert(ns.Features.EncounterTimerHud.card:IsShown() == false and ns.Features.EncounterTimerHud.ticker == nil, "B4: PULL_GO must auto-hide and cancel ticker after 2s dwell")

-- 8B. B3 + N1 + N2: Instance run preserves state on Secret IsInInstance, empty name, and ghost run-back; clears stale bossStart on real exit
_G.__FS_MOCK.now = 2000
_G.__FS_MOCK.inInstance = true
_G.__FS_MOCK.instanceType = "party"
_G.__FS_MOCK.instanceName = "죽음의 폐광"
__FS_FIRE_EVENT("ZONE_CHANGED_NEW_AREA")
assert(ns.Features.EncounterTimerHud.state.instance.name == "죽음의 폐광")

-- B3: Secret IsInInstance must NOT falsely end the dungeon run!
_G.__FS_MOCK.inInstance = FS_MakeSecret("inst", "boolean")
__FS_FIRE_EVENT("ZONE_CHANGED_NEW_AREA")
assert(ns.Features.EncounterTimerHud.state.instance ~= nil and ns.Features.EncounterTimerHud.state.instance.name == "죽음의 폐광", "B3: secret IsInInstance must NOT end run")

-- B3: Empty instanceName inside same dungeon must NOT split run!
_G.__FS_MOCK.inInstance = true
_G.__FS_MOCK.instanceName = ""
__FS_FIRE_EVENT("ZONE_CHANGED_NEW_AREA")
assert(ns.Features.EncounterTimerHud.state.instance.name == "죽음의 폐광", "B3: empty instanceName must keep existing run")
_G.__FS_MOCK.instanceName = "죽음의 폐광"

-- N1: Ghost run-back outside dungeon must HOLD run state!
__FS_FIRE_EVENT("PLAYER_DEAD")
assert(ns.Features.EncounterTimerHud.state.instance.deaths == 1)
_G.__FS_MOCK.deadOrGhost = true
_G.__FS_MOCK.inInstance = false
_G.__FS_MOCK.instanceType = "none"
__FS_FIRE_EVENT("ZONE_CHANGED_NEW_AREA")
assert(ns.Features.EncounterTimerHud.state.instance ~= nil and ns.Features.EncounterTimerHud.state.instance.deaths == 1, "N1: ghost run-back must hold dungeon run")
_G.__FS_MOCK.deadOrGhost = false
_G.__FS_MOCK.inInstance = true
_G.__FS_MOCK.instanceType = "party"
__FS_FIRE_EVENT("ZONE_CHANGED_NEW_AREA")
assert(ns.Features.EncounterTimerHud.state.instance.deaths == 1, "N1: re-entering dungeon keeps death count")

-- N2: Active boss encounter without ENCOUNTER_END is cleared when truly exiting dungeon alive!
__FS_FIRE_EVENT("ENCOUNTER_START", 101, "에드윈 밴클리프")
assert(ns.Features.EncounterTimerHud:IsBossActive() == true)
_G.__FS_MOCK.now = 2300
_G.__FS_MOCK.inInstance = false
_G.__FS_MOCK.instanceType = "none"
_G.__FS_MOCK.instanceName = ""
__FS_FIRE_EVENT("ZONE_CHANGED_NEW_AREA")
assert(ns.Features.EncounterTimerHud:IsBossActive() == false, "N2: leaving instance must clear stale bossStart")
assert(ns.Features.EncounterTimerHud.card:IsShown() == false and ns.Features.EncounterTimerHud.ticker == nil, "idle EncounterTimerHud must cancel ticker (0 CPU)")
assert(string.find(_G.__FS_MOCK.printed[#_G.__FS_MOCK.printed], "인스턴스 기록 [죽음의 폐광]", 1, true))

-- 9. Phase 2A Nit Closures (NavPort UNVERIFIABLE + Merchant unreadable money)
_G.__FS_MOCK.playerPos = { mapID = 1411, x = 0.50, y = 0.50, facing = 0 }
ns.Api.NavPort.SetWaypoint(1411, 0.40, 0.40)
local origGetWp = C_Map.GetUserWaypoint
C_Map.GetUserWaypoint = function() return FS_MakeSecret("wp", "table") end
local okClr, reasonClr = ns.Api.NavPort.ClearWaypoint()
assert(okClr == false and reasonClr == "UNVERIFIABLE" and ns.Api.NavPort.ownedWaypoint ~= nil)
C_Map.GetUserWaypoint = origGetWp
local okClr2, reasonClr2 = ns.Api.NavPort.ClearWaypoint()
assert(okClr2 == true and reasonClr2 == "CLEARED" and ns.Api.NavPort.ownedWaypoint == nil)

_G.__FS_MOCK.canRepair = true
_G.__FS_MOCK.repairCost = 2000
_G.__FS_MOCK.canGuildRepair = true
_G.__FS_MOCK.asyncGuildRepair = true
_G.__FS_MOCK.guildRepairShouldFail = true
_G.__FS_MOCK.bagItems = {}
__FS_FIRE_EVENT("MERCHANT_SHOW")
local savedMoney = _G.__FS_MOCK.money
_G.__FS_MOCK.money = FS_MakeSecret("gold", "number")
__FS_FLUSH_AFTER_TIMERS()
assert(string.find(_G.__FS_MOCK.printed[#_G.__FS_MOCK.printed], "개인 골드 조회 불가", 1, true))
_G.__FS_MOCK.money = savedMoney
__FS_FIRE_EVENT("MERCHANT_CLOSED")
_G.__FS_MOCK.asyncGuildRepair = false

-- 10. Standalone DiagnosticsPage (zero GodJohnson text, honest disabled status) + 46 LoD entries + SettingsPage tabs
_G.SlashCmdList["FOREVERSUITE"]("")
ns.UI.CommandHub:SelectPage("diagnostics")
assert(string.find(ns.Features.DiagnosticsPage.readinessLabel:GetText(), "독립 실행: Zero-Taint", 1, true))
assert(not string.find(ns.Features.DiagnosticsPage.readinessLabel:GetText(), "GodJohnson", 1, true), "Phase 3 standalone UI must NOT mention GodJohnson")

-- Turning off all QoL toggles must show "비활성(설정 꺼짐)"!
for _, k in ipairs({ "fastLoot", "autoReleaseBG", "autoAcceptRes", "autoAcceptFriends", "maxCameraZoom" }) do
    ns.Api.ProfileStore:Set("qol", k, false)
end
ns.Features.DiagnosticsPage:OnShow()
assert(ns.Features.DiagnosticsPage.moduleRows[3].row._right:GetText() == "비활성(설정 꺼짐)", "N3: disabled QoL must NOT show 활성")

ns.Api.SafeAPI.LoadDataPack()
local totalEntries = 0
for _, pack in pairs(_G.ForeverSuiteData.packs) do
    totalEntries = totalEntries + #pack.entries
end
assert(totalEntries == 46, "expected exact 46 enriched LoD Codex entries across 5 packs, got " .. tostring(totalEntries))

ns.UI.CommandHub:SelectPage("settings")
ns.Features.SettingsPage.activeSection = "qol"
ns.Features.SettingsPage:RenderList("")
assert(ns.Features.SettingsPage.visibleCount >= 5, "QoL settings tab must show at least 5 QoL toggles")
