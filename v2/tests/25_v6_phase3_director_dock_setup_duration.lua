-- Test 25: ForeverSuite v6.0 Phase 3 — PixelUtil 1px HiDPI, Director 5-State (+EDIT_OVERRIDE, 1.2s post-combat hold,
--          Feign Death exclusion, single 60Hz tween), CorpseGuide /way restore, TrackingSwitcher, CharacterDock 3-tab
--          (extended stats, Top-3 upgrades, upcoming 5-level spells), SetupWizard + undo, C_DurationUtil, and AltCooldowns.
local ns = _G.ForeverSuite
__FS_FIRE_EVENT("PLAYER_LOGIN")

local function assertEq(actual, expected, msg)
    assert(actual == expected, (msg or "assertEq failed") .. " (got=" .. tostring(actual) .. ", expected=" .. tostring(expected) .. ")")
end

------------------------------------------------------------------------
-- 1. PixelUtil 1px HiDPI formula & 3-device display tiers
------------------------------------------------------------------------
local PU = ns.UI.PixelUtil
local origPhys = _G.GetPhysicalScreenSize
_G.GetPhysicalScreenSize = function() return 3840, 2160 end
local mockFrame = { GetEffectiveScale = function() return 0.65 end }
local px4k = PU.OnePixel(mockFrame)
assert(math.abs(px4k - ((768.0 / 2160) / 0.65)) < 0.0001, "exact 768/physH/effectiveScale 1px math")
local tier4k, typo4k = PU.GetDisplayTier(2160)
assertEq(tier4k, "UHD_4K", "2160p -> UHD_4K")
assertEq(typo4k.outline, "OUTLINE", "4K enables L0 OUTLINE")
assertEq(PU.GetDisplayTier(1440), "RETINA", "1440p -> RETINA")
assertEq(PU.GetDisplayTier(1080), "FHD", "1080p -> FHD")
_G.GetPhysicalScreenSize = origPhys

------------------------------------------------------------------------
-- 2. DirectorModel & UI/Director 5-State Morphing + 1.2s hold + Feign Death guard + 0ms idle convergence
------------------------------------------------------------------------
local DM = ns.Domain.DirectorModel
assertEq(DM.ResolveState({ isEditOverride = true, inCombat = true }), "EDIT_OVERRIDE", "EDIT_OVERRIDE > COMBAT")
assertEq(DM.ResolveState({ inCombat = true, isDialogueShown = true }), "COMBAT", "COMBAT > DIALOGUE")
assertEq(DM.ResolveState({ isDeadOrGhost = true, isFeignDeath = true }), "EXPLORATION", "Feign Death NEVER enters DEAD")
assertEq(DM.ResolveState({ isDeadOrGhost = true, isFeignDeath = false }), "DEAD", "real death enters DEAD")
assertEq(DM.ResolveState({ hasFishingPole = true, isMounted = true }), "EXPLORATION", "mounted ignores fishing pole")
assertEq(DM.ResolveState({ hasFishingPole = true, isMounted = false }), "FISHING", "unmounted fishing pole enters FISHING")
assertEq(DM.ResolveState({ isDialogueShown = true }), "DIALOGUE", "dialogue state")

local Dir = ns.UI.Director
local dirTimers = {}
Dir:SetScheduler(function(delay, fn)
    dirTimers[#dirTimers + 1] = { delay = delay, fn = fn }
    return true
end)

local chAlphas = { questTracker = 1.0, fishingCard = 0.0 }
Dir:RegisterChannel("questTracker", {
    GetAlpha = function() return chAlphas.questTracker end,
    SetAlpha = function(_, a) chAlphas.questTracker = a end,
})
Dir:RegisterChannel("fishingCard", {
    GetAlpha = function() return chAlphas.fishingCard end,
    SetAlpha = function(_, a) chAlphas.fishingCard = a end,
})

-- Enter COMBAT immediately (0ms), fishingCard -> 0.0, questTracker -> 0.35
local stC, modeC = Dir:ApplySignals({ inCombat = true, hasFishingPole = true })
assertEq(stC, "COMBAT", "enters COMBAT")
assertEq(modeC, "IMMEDIATE", "COMBAT is immediate")
assertEq(chAlphas.fishingCard, 0.0, "fishingCard instant 0 alpha in combat")
assertEq(chAlphas.questTracker, 0.35, "questTracker dimmed to 0.35 in combat")

-- Exit COMBAT -> 1.2s hold! Re-entering combat cancels the hold (zero strobing on Feign Death!)
local stHold, modeHold = Dir:ApplySignals({ inCombat = false, hasFishingPole = true })
assertEq(stHold, "COMBAT", "holds COMBAT visuals for 1.2s")
assertEq(modeHold, "HELD", "HELD mode")
assertEq(dirTimers[#dirTimers].delay, 1.2, "1.2s post-combat hold timer")
local staleHoldFn = dirTimers[#dirTimers].fn
Dir:ApplySignals({ inCombat = true, hasFishingPole = true }) -- combat resumes!
staleHoldFn() -- old timer fires -> MUST be cancelled by token!
assertEq(Dir.state, "COMBAT", "re-entering combat cancelled stale 1.2s exit hold")

-- Clean exit after 1.2s hold -> transitions to FISHING and converges via single tweenFrame
Dir:ApplySignals({ inCombat = false, hasFishingPole = true })
dirTimers[#dirTimers].fn()
assertEq(Dir.state, "FISHING", "transitioned to FISHING after clean 1.2s hold")
for _ = 1, 20 do Dir:StepTween(0.05) end
assertEq(Dir:StepTween(0.05), false, "tween converges and detaches OnUpdate (0.00ms idle)")
assertEq(chAlphas.fishingCard, 1.0, "fishingCard converged to 1.0")

-- 4.5s SetupWizard live preview
local previewDone = false
Dir:RunSetupPreview(function() previewDone = true end)
assertEq(Dir.previewActive, true, "preview active")
for i = #dirTimers - 2, #dirTimers do dirTimers[i].fn() end
assertEq(previewDone, true, "4.5s preview completed and restored state")
Dir:SetScheduler(ns.Api.GameAdapters.RunAfter)

------------------------------------------------------------------------
-- 3. CorpseGuide Feign Death exclusion & manual /way restoration
------------------------------------------------------------------------
local CG = ns.Features.CorpseGuideModule
local origFeign = _G.UnitIsFeignDeath
local origDead = _G.UnitIsDeadOrGhost
_G.UnitIsFeignDeath = function() return true end
_G.UnitIsDeadOrGhost = function() return true end
local cgOk, cgReason = CG:OnPlayerDead()
assertEq(cgOk, false, "CorpseGuide ignores Feign Death")
assertEq(cgReason, "FEIGN_DEATH", "FEIGN_DEATH reason")
_G.UnitIsFeignDeath = origFeign
_G.UnitIsDeadOrGhost = origDead

------------------------------------------------------------------------
-- 4. CharacterGuideModel Top-3 upgrades & upcoming 5-level spells + CharacterDockPanel 3 tabs
------------------------------------------------------------------------
local CGM = ns.Domain.CharacterGuideModel
local top3 = CGM.RankTopUpgrades({
    { itemID = 1, title = "도끼", itemLevel = 65, reqLevel = 60, equipSlot = 16, isTwoHand = true },
    { itemID = 2, title = "고유 반지", itemLevel = 60, reqLevel = 58, equipSlot = 11, uniqueEquipped = true },
    { itemID = 2, title = "고유 반지", itemLevel = 60, reqLevel = 58, equipSlot = 12, uniqueEquipped = true },
    { itemID = 3, title = "미래 레이드", itemLevel = 90, reqLevel = 65, equipSlot = 5 },
    { itemID = 4, title = "화산 망토", itemLevel = 62, reqLevel = 58, equipSlot = 15 },
}, 58, { [16] = 50, [17] = 50, [11] = 45, [15] = 40 }, 3)
assertEq(#top3, 3, "filters reqLevel<=61, deduplicates uniqueEquipped, ranks Top 3")
assertEq(top3[1].itemID, 4, "largest delta (+22) ranked #1")
assertEq(top3[2].itemID, 1, "2H compares average(16,17)=50 -> +15 (higher iLvl 65 tiebreaker)")
assertEq(top3[3].itemID, 2, "uniqueEquipped kept once (+15, iLvl 60)")

local sp = CGM.SplitUpcomingSpells({
    { class = "SHAMAN", spellID = 101, level = 20, cost = 5000 },
    { class = "SHAMAN", spellID = 102, level = 24, cost = 12000 },
    { class = "SHAMAN", spellID = 103, level = 30, cost = 50000 },
}, "SHAMAN", 20, {}, 10000)
assertEq(#sp.learnableNow, 1, "1 spell learnable now at Lv20")
assertEq(#sp.upcoming5, 1, "1 spell upcoming in Lv21..25 (Lv30 excluded)")
assertEq(sp.totalCost, 17000, "total cost 1g 70s")
assertEq(sp.deficit, 7000, "deficit 70s with 1g on hand")

ns.Features.CharacterDockPanel:Init()
local statsTxt = ns.Features.CharacterDockPanel:Render("stats")
assert(string.find(statsTxt, "주문력:", 1, true) and string.find(statsTxt, "MP5", 1, true), "CharacterDock stats tab rendered")

------------------------------------------------------------------------
-- 5. SetupWizard 3 steps + default-OFF external ImportString + /fs setup undo
------------------------------------------------------------------------
ns.Api.ProfileStore:Set("ui", "uiTheme", "gold")
local sw = ns.Features.SetupWizard
assertEq(sw.optImportExternal, false, "external ImportString defaults OFF")
local step1Txt = sw:Open(1)
assert(string.find(step1Txt, "Step 1/3", 1, true) ~= nil, "Step 1 renders device & coexistence scan")
local ok2 = sw:ApplyStep2({ uiTheme = "dark" })
assertEq(ok2, true, "Step 2 applied")
assertEq(ns.Api.ProfileStore:Get("ui", "uiTheme"), "dark", "theme changed to dark")
local okUndo, stUndo = sw:HandleCommand("undo")
assertEq(okUndo, true, "/fs setup undo succeeds")
assertEq(stUndo, "UNDONE", "UNDONE status")
assertEq(ns.Api.ProfileStore:Get("ui", "uiTheme"), "gold", "1-click undo restored original gold theme")

------------------------------------------------------------------------
-- 6. C_DurationUtil adapter (I1/I2) + TrackingSwitcher + AltCooldownModel (48h/72h/96h)
------------------------------------------------------------------------
local boundObj = nil
local origDurUtil = _G.C_DurationUtil
local origUnitAuras = _G.C_UnitAuras
_G.C_UnitAuras = _G.C_UnitAuras or {}
_G.C_UnitAuras.GetAuraDuration = function() return { _opaque = true } end
_G.C_DurationUtil = {
    CreateDurationTextBinding = function(durObj, fs) boundObj = { dur = durObj, fs = fs }; return true end,
}
local okBind = ns.Api.Adapters.Duration.BindAuraDuration("player", 42, { SetText = function() end })
assertEq(okBind, true, "C_DurationUtil opaque binding works with zero secret arithmetic")
assert(boundObj ~= nil, "binding forwarded to CreateDurationTextBinding")
_G.C_DurationUtil = origDurUtil
_G.C_UnitAuras = origUnitAuras

local cdStore = {}
local ACM = ns.Domain.AltCooldownModel
ACM.RecordUse(cdStore, "Thrall-ForeverKR", "transmute", 1000000)
ACM.RecordUse(cdStore, "Jaina-ForeverKR", "mooncloth", 1000000)
local r1, c1 = ACM.EvaluateAll(cdStore, 1000000 + 50 * 3600)
assertEq(#r1, 1, "48h transmute ready at +50h")
assertEq(r1[1].recipeId, "transmute", "transmute ready")
assertEq(#c1, 1, "96h mooncloth still cooling at +50h")
assertEq(ACM.FormatRemaining(3660), "1시간 01분", "remaining formatter")

-- 9. Phase 3 Adversarial Review Regressions (B1-B9)
-- B4: Real COMBAT preempts RunSetupPreview and cancels pending preview timers
local previewTimers = {}
Dir:SetScheduler(function(delay, fn)
    previewTimers[#previewTimers + 1] = { delay = delay, fn = fn }
    return true
end)
Dir:ApplySignals({ inCombat = false }, true)
assertEq(Dir:RunSetupPreview(), true, "setup preview starts OOC")
assertEq(Dir.previewActive, true, "preview active")
Dir:ApplySignals({ inCombat = true }, false)
assertEq(Dir.state, "COMBAT", "real COMBAT preempts setup preview")
assertEq(Dir.previewActive, false, "setup preview cancelled on real COMBAT")
for _, t in ipairs(previewTimers) do t.fn() end
assertEq(Dir.state, "COMBAT", "stale preview timers must NOT clobber real COMBAT state")

-- B5 & B6: Corpse arrival (NavigationHud.target == nil) still restores preDeathTarget with quest metadata
ns.Features.NavigationHud.target = { mapID = 1411, x = 0.50, y = 0.50, label = "[퀘스트] 테스트", source = "quest", questID = 777, isComplete = true }
local restoredTarget = nil
local origSetTarget = ns.Features.NavigationHud.SetTarget
local origTrackQuest = ns.Features.NavigationHud.TrackQuest
ns.Features.NavigationHud.SetTarget = function(self, mapID, x, y, label, opts)
    self.target = { mapID = mapID, x = x, y = y, label = label, source = opts and opts.source, questID = opts and opts.questID }
    restoredTarget = self.target
    return true
end
ns.Features.NavigationHud.TrackQuest = function() return false end
_G.UnitIsDeadOrGhost = function() return true end
_G.UnitIsFeignDeath = function() return false end
ns.Api.GameAdapters.GetCorpsePosition = function() return { mapID = 1411, x = 0.40, y = 0.40 } end
CG:OnPlayerDead()
-- Simulate arriving at corpse so NavigationHud auto-cleared target to nil before revive
ns.Features.NavigationHud.target = nil
_G.UnitIsDeadOrGhost = function() return false end
CG:OnPlayerRevived()
assert(restoredTarget ~= nil and restoredTarget.source == "quest" and restoredTarget.questID == 777, "corpse arrival + revive restores quest target metadata")
ns.Features.NavigationHud.SetTarget = origSetTarget
ns.Features.NavigationHud.TrackQuest = origTrackQuest

-- B1/B2/B3: Bootstrap wires all 5 real HUD channels and responds to live signal provider (FISHING)
assert(ns.Features.QuestTrackerView.container ~= nil, "QuestTrackerView.container exists")
assert(Dir.channels.navArrow == ns.Features.NavigationHud.card, "navArrow channel wired to .card")
assert(Dir.channels.statusPill == ns.Features.StatusPillHud.card, "statusPill channel wired to .card")
assert(Dir.channels.combatAssist == ns.Features.CombatAssistHud.strip, "combatAssist channel wired to .strip")
Dir:RegisterChannel("fishingCard", ns.Features.FishingCardHud.card)
ns.Api.GameAdapters.IsFishingPoleEquipped = function() return true end
ns.Api.GameAdapters.IsPlayerMounted = function() return false end
ns.Api.SafeAPI.InCombat = function() return false end
ns.Api.GameAdapters.IsPlayerDeadOrGhost = function() return false end
Dir:SyncFromProvider(true)
assertEq(Dir.state, "FISHING", "live signal provider resolves FISHING with matching keys")
assertEq(ns.Features.FishingCardHud.card:GetAlpha(), 1.00, "fishingCard alpha becomes 1.00 in FISHING")

-- PixelUtil negative snap sign preservation
assert(PU.Snap(mockFrame, -1) < 0, "negative snap preserves negative sign")

-- B8: Equipped 2H weapon (slot 16=60, slot 17=nil) MUST NOT halve baseline to 30 and recommend iLvl 50 2H
local twoHandCheck = CGM.RankTopUpgrades({
    { itemID = 901, title = "하위 양손무기", itemLevel = 50, reqLevel = 55, equipSlot = 16, slot = "양손" },
    { itemID = 902, title = "상위 양손무기", itemLevel = 68, reqLevel = 60, equipSlot = 16, slot = "양손" },
}, 60, { [16] = 60 }, 3)
assertEq(#twoHandCheck, 1, "iLvl 50 2H rejected against equipped iLvl 60 2H")
assertEq(twoHandCheck[1].itemID, 902, "only iLvl 68 2H recommended")
assertEq(twoHandCheck[1].delta, 8, "delta is 68 - 60 = +8 (not halved)")

-- B9: AddonProbe.Exists + SetupWizard LSM Korean font registration with real ForeverSuite_Media_Assets paths
local origDoesExist = _G.C_AddOns and _G.C_AddOns.DoesAddOnExist
local origLibStub = _G.LibStub
_G.C_AddOns = _G.C_AddOns or {}
_G.C_AddOns.DoesAddOnExist = function(name) return name == "ForeverSuite_Media_Assets" end
local lsmRegistered = {}
_G.LibStub = function(libName)
    if libName == "LibSharedMedia-3.0" then
        return { Register = function(_, mediaType, name, path) lsmRegistered[name] = { t = mediaType, p = path } end }
    end
end
assertEq(ns.Api.AddonProbe.Exists("ForeverSuite_Media_Assets"), true, "AddonProbe.Exists detects ForeverSuite_Media_Assets")
assertEq(ns.Api.AddonProbe.Exists("NoSuchAddon_XYZ"), false, "AddonProbe.Exists returns false for missing addon")
sw:ApplyStep2({})
assertEq(sw.lastStep2Result.lsmCount, 2, "SetupWizard registers 2 Korean fonts into LSM when assets exist")
assert(lsmRegistered["ForeverSuite Gmarket Bold"] and string.find(lsmRegistered["ForeverSuite Gmarket Bold"].p, "ForeverSuite_Media_Assets\\Fonts\\", 1, true), "real ForeverSuite_Media_Assets font path registered")
_G.C_AddOns.DoesAddOnExist = origDoesExist
_G.LibStub = origLibStub

print("Test 25 PASS: PixelUtil, Director 5-State + 1.2s hold, CorpseGuide, CharacterDock 3-tab, SetupWizard + undo, C_DurationUtil, and AltCooldowns verified!")
