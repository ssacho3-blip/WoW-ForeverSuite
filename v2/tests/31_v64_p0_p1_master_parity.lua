-- Test 31: ForeverSuite v6.4.0 P0 + P1 Master Parity Suite
-- Covers: C_DurationUtil HUD wiring (ProcCooldownHud & CombatHudPack), Tooltip Syndicator/Auctionator yield,
--         Spoken fishing audio ducking, CharacterDock [상급자 화살표], Fishing <60s lure pulse & quest ★,
--         Independent CommandPalette (/fs k), Strangler Fig Boot/Schemas split, SoundKitID 0KB catalog,
--         MailboxModel & MailboxModule (COD safety + Postal yield), and SetupWizard C_EncodingUtil export.
local ns = _G.ForeverSuite
__FS_FIRE_EVENT("PLAYER_LOGIN")

local function assertEq(actual, expected, msg)
    assert(actual == expected, (msg or "assertEq failed") .. " (got=" .. tostring(actual) .. ", expected=" .. tostring(expected) .. ")")
end

------------------------------------------------------------------------
-- 1. Strangler Fig Boot/Schemas extraction
------------------------------------------------------------------------
assert(type(ns.Features.Boot) == "table" and type(ns.Features.Boot.DEFAULT_SCHEMAS) == "table" and #ns.Features.Boot.DEFAULT_SCHEMAS >= 50,
    "Features/Boot/Schemas.lua must export all declarative setting schemas")
assertEq(ns.Api.ProfileStore:Get("qol", "mailboxSafeOpen"), true, "mailboxSafeOpen schema defaults to true")

------------------------------------------------------------------------
-- 2. P0 #1: C_DurationUtil native C++ binding wired into ProcCooldownHud & CombatHudPack
------------------------------------------------------------------------
local savedDurUtil = _G.C_DurationUtil
local savedCSpell = _G.C_Spell
local savedCUnitAuras = _G.C_UnitAuras
local durBindCalls = {}
_G.C_DurationUtil = {
    CreateDurationTextBinding = function(durObj, fs)
        durBindCalls[#durBindCalls + 1] = { durObj = durObj, fs = fs }
        if type(fs.SetText) == "function" then
            fs:SetText("C++BOUND")
        end
        return { bound = true }
    end,
}
_G.C_Spell = _G.C_Spell or {}
local origSpellCdDur = _G.C_Spell.GetSpellCooldownDuration
_G.C_Spell.GetSpellCooldownDuration = function(sid) return { kind = "spell", id = sid } end

local origGetCls = ns.Api.GameAdapters.GetPlayerClass
local origGetCd = ns.Api.GameAdapters.GetSpellCooldownSafe
local origMono = ns.Api.GameAdapters.GetMonotonicTime
ns.Api.GameAdapters.GetPlayerClass = function() return "MAGE" end
ns.Api.GameAdapters.GetMonotonicTime = function() return 1000 end
ns.Api.GameAdapters.GetSpellCooldownSafe = function(sid)
    if sid == 12042 then return 990, 30, true end
    return 0, 0, true
end
local shownCd = ns.Features.ProcCooldownHud:RefreshCooldowns()
assertEq(shownCd, 1, "ProcCooldownHud shows active Mage cooldown")
assertEq(#durBindCalls, 1, "ProcCooldownHud invokes C_DurationUtil.CreateDurationTextBinding")
assertEq(durBindCalls[1].durObj.id, 12042, "Bound spellID 12042 via C_DurationUtil")
assertEq(ns.Features.ProcCooldownHud.cdTimeRows[1]:GetText(), "C++BOUND", "Time label bound natively by C_DurationUtil")
ns.Features.ProcCooldownHud:StopCdTicker()

_G.C_UnitAuras = _G.C_UnitAuras or {}
local origGetAuraDur = _G.C_UnitAuras.GetAuraDuration
_G.C_UnitAuras.GetAuraDuration = function(u, instId) return { kind = "aura", unit = u, inst = instId } end
local origHelpful = ns.Api.GameAdapters.GetPlayerHelpfulAuras
ns.Api.GameAdapters.GetPlayerHelpfulAuras = function()
    return {
        { name = "신비의 마법 강화", spellId = 12042, auraInstanceID = 777, duration = 15, expirationTime = 1012 },
    }
end
ns.Features.CombatHudPack:RefreshShortBuffs()
assertEq(#durBindCalls, 2, "CombatHudPack invokes C_DurationUtil.CreateDurationTextBinding for short buff")
assertEq(durBindCalls[2].durObj.inst, 777, "Bound auraInstanceID 777 via C_DurationUtil")
assertEq(ns.Features.CombatHudPack.buffTimeLabels[1]:GetText(), "C++BOUND", "Short buff time label bound natively")
ns.Features.CombatHudPack:StopBuffTicker()

-- Restore duration mocks
ns.Api.GameAdapters.GetPlayerClass = origGetCls
ns.Api.GameAdapters.GetSpellCooldownSafe = origGetCd
ns.Api.GameAdapters.GetMonotonicTime = origMono
ns.Api.GameAdapters.GetPlayerHelpfulAuras = origHelpful
_G.C_DurationUtil = savedDurUtil
_G.C_Spell.GetSpellCooldownDuration = origSpellCdDur
if savedCSpell == nil then _G.C_Spell = nil end
_G.C_UnitAuras.GetAuraDuration = origGetAuraDur
if savedCUnitAuras == nil then _G.C_UnitAuras = nil end

------------------------------------------------------------------------
-- 3. P0 #2: TooltipModel & TooltipEnhanceModule (Syndicator alt-owned + Auctionator yield)
------------------------------------------------------------------------
local tLines = ns.Domain.TooltipModel.BuildItemLines(2447, 500, 1, {}, {
    showVendorPrice = false,
    altOwnedText = "총 15개",
})
local hasAltLine, hasVendorPrice = false, false
for _, ln in ipairs(tLines) do
    if ln.left == "부캐 보유 (Syndicator)" and ln.right == "총 15개" then hasAltLine = true end
    if ln.right and string.find(ln.right, "5s", 1, true) then hasVendorPrice = true end
end
assert(hasAltLine, "TooltipModel emits Syndicator alt-owned line")
assert(not hasVendorPrice, "TooltipModel omits vendor price when yielded to Auctionator")

local savedSyn = _G.Syndicator
_G.Syndicator = {
    API = {
        IsReady = function() return true end,
        GetInventoryInfoByItemID = function(id)
            if id == 2447 then return { characters = { { bags = 8, bank = 7, mail = 0, equipped = 0 } }, warband = 0 } end
            return { characters = {}, warband = 0 }
        end,
    },
}
local addedLines = {}
local mockTT = {
    AddDoubleLine = function(_, l, r) addedLines[#addedLines + 1] = { l = l, r = r } end,
    AddLine = function(_, l) addedLines[#addedLines + 1] = { l = l, r = "" } end,
}
ns.Features.TooltipEnhanceModule:OnItemTooltip(mockTT, 2447)
local foundAltInTT = false
for _, ln in ipairs(addedLines) do
    if ln.l == "부캐 보유 (Syndicator)" and ln.r == "총 15개" then foundAltInTT = true end
end
assert(foundAltInTT, "TooltipEnhanceModule wires live Syndicator alt inventory count into item tooltip")
_G.Syndicator = savedSyn

------------------------------------------------------------------------
-- 4. P0 #3: Spoken audio ducking pauses & resumes Fishing sound boost
------------------------------------------------------------------------
local boostCalls = {}
local origSetBoost = ns.Api.GameAdapters.SetFishingSoundBoostSafe
ns.Api.GameAdapters.SetFishingSoundBoostSafe = function(enable)
    boostCalls[#boostCalls + 1] = enable
    return true, enable and "BOOST_ON" or "BOOST_OFF"
end
ns.Features.FishingCardHud.soundBoost = true
ns.Features.FishingCardHud.soundBoostPausedBySpoken = false
local okP, stP = ns.Features.FishingCardHud:OnSpokenPlaybackChanged(true)
assertEq(okP, true, "Fishing sound boost pauses when Spoken starts")
assertEq(stP, "PAUSED", "Spoken duck state PAUSED")
assertEq(boostCalls[#boostCalls], false, "Fishing CVar boost turned off during Spoken playback")
local okR, stR = ns.Features.FishingCardHud:OnSpokenPlaybackChanged(false)
assertEq(okR, true, "Fishing sound boost resumes when Spoken stops")
assertEq(stR, "RESUMED", "Spoken duck state RESUMED")
assertEq(boostCalls[#boostCalls], true, "Fishing CVar boost restored after Spoken finishes")
-- Post-combat reconciliation when Spoken stopped during combat
ns.Features.FishingCardHud.soundBoost = true
ns.Features.FishingCardHud.soundBoostPausedBySpoken = true
ns.Bridges.Spoken.playingFlag = false
local okRec, stRec = ns.Features.FishingCardHud:ReconcileSpokenAudio()
assertEq(okRec, true, "ReconcileSpokenAudio resumes deferred fishing boost after combat")
assertEq(stRec, "RESUMED", "Post-combat Spoken reconciliation returns RESUMED")
ns.Features.FishingCardHud.soundBoost = false
ns.Api.GameAdapters.SetFishingSoundBoostSafe = origSetBoost

------------------------------------------------------------------------
-- 5. P0 #4: CharacterDockPanel [상급자 화살표] navigates to nearest class trainer
------------------------------------------------------------------------
__FS_LOAD_DATA_ADDON("ForeverSuite_Data_Atlas")
ns.Features.CharacterDockPanel:Render("skills")
assert(ns.Features.CharacterDockPanel.trainerArrowBtn ~= nil, "CharacterDockPanel creates [상급자 화살표] button")
local origSetTarget = ns.Features.NavigationHud.SetTarget
local navTargets = {}
ns.Features.NavigationHud.SetTarget = function(_, mapID, x, y, title)
    navTargets[#navTargets + 1] = { mapID = mapID, x = x, y = y, title = title }
end
local okTr, trRec = ns.Features.CharacterDockPanel:NavigateToNearestClassTrainer()
assertEq(okTr, true, "NavigateToNearestClassTrainer finds class trainer from ForeverSuite_Data_Atlas")
assert(type(trRec) == "table" and #navTargets == 1, "NavigationHud target set to trainer coordinates")
ns.Features.NavigationHud.SetTarget = origSetTarget

------------------------------------------------------------------------
-- 6. P0 #5: FishingCardHud <60s lure pulse & active quest fish ★ highlight
------------------------------------------------------------------------
__FS_LOAD_DATA_ADDON("ForeverSuite_Data")
local origZone = ns.Api.GameAdapters.GetPlayerZoneText
local origFishStat = ns.Api.GameAdapters.GetFishingStatusSafe
local origCollectQ = ns.Api.SafeAPI.CollectQuestLog
ns.Api.GameAdapters.GetPlayerZoneText = function() return "불모의 땅" end
ns.Api.GameAdapters.GetFishingStatusSafe = function() return { hasLure = true, lureSec = 42, skill = 120, maxSkill = 150 } end
ns.Api.SafeAPI.CollectQuestLog = function()
    return {
        { questID = 9001, title = "오아시스의 돌연변이 물고기", isComplete = false, objectives = { { text = "돌연변이 물고기 3/5", finished = false } } },
    }
end
ns.Features.FishingCardHud:Open()
local metaTxt = ns.Features.FishingCardHud.metaLbl:GetText() or ""
assert(string.find(metaTxt, "[!] 미끼 00:42", 1, true), "Lure <60s displays urgent warning pulse text (got=" .. tostring(metaTxt) .. ")")
local foundQuestStar = false
for i = 1, 3 do
    local row = ns.Features.FishingCardHud.fishRows[i]
    if row and row._left and string.find(row._left:GetText() or "", "★ [퀘]", 1, true) then
        foundQuestStar = true
    end
end
assert(foundQuestStar, "FishingCardHud highlights active quest fish with ★ [퀘]")
ns.Features.FishingCardHud:Close()
ns.Api.GameAdapters.GetPlayerZoneText = origZone
ns.Api.GameAdapters.GetFishingStatusSafe = origFishStat
ns.Api.SafeAPI.CollectQuestLog = origCollectQ

------------------------------------------------------------------------
-- 7. P0 #6: Independent CommandPalette (/fs k)
------------------------------------------------------------------------
ns.Features.CommandPalette:Open("")
assertEq(ns.Features.CommandPalette.visible, true, "CommandPalette opens independently without CommandHub")
assert(#ns.Features.CommandPalette.results >= 5, "Empty query shows default Quick Actions")
local cntSearch = ns.Features.CommandPalette:RenderResults("쇼핑리스트")
assert(cntSearch >= 1, "CommandPalette matches shopping list quick action")
assertEq(ns.Features.CommandPalette.results[1].kind, "action", "Top result is quick action")
ns.Features.CommandPalette:Hide()
assertEq(ns.Features.CommandPalette.visible, false, "CommandPalette closes cleanly")

------------------------------------------------------------------------
-- 8. P1 #9: 0KB SoundKitID Catalog in GameAdapters
------------------------------------------------------------------------
local playedIds = {}
local savedPlaySound = _G.PlaySound
_G.PlaySound = function(id, ch)
    playedIds[#playedIds + 1] = { id = id, ch = ch }
    return true
end
assertEq(ns.Api.GameAdapters.PlayNotificationSound("level_up", 75, "SFX", true), true, "SoundKitID 'level_up' plays via _G.PlaySound")
assertEq(playedIds[#playedIds].id, 888, "SoundKitID 'level_up' resolves to 888")
assertEq(ns.Api.GameAdapters.PlayNotificationSound("coin", 75, "SFX", true), true, "SoundKitID 'coin' plays via _G.PlaySound")
assertEq(playedIds[#playedIds].id, 120, "SoundKitID 'coin' resolves to 120")
_G.PlaySound = savedPlaySound

------------------------------------------------------------------------
-- 9. P1 #10: MailboxModel & MailboxModule (COD safety & batch collect)
------------------------------------------------------------------------
local mailSum = ns.Domain.MailboxModel.SummarizeInbox({
    { index = 1, money = 50000, cod = 0, hasItem = 1 },
    { index = 2, money = 0, cod = 999999, hasItem = 1 }, -- COD MUST BE SKIPPED!
    { index = 3, money = 12000, cod = 0, hasItem = 0 },
    { index = 4, money = 5000, cod = nil, codUnknown = true, hasItem = 1 }, -- Fail-closed unknown COD!
    { index = 1.9, money = 5000, cod = 0, hasItem = 1 }, -- Fractional index rejected!
})
assertEq(mailSum.total, 5, "MailboxModel counts 5 total mails")
assertEq(mailSum.codCount, 2, "MailboxModel counts both explicit COD and fail-closed unknown COD")
assertEq(mailSum.lootableCount, 2, "MailboxModel strictly excludes COD, unknown COD, and fractional indices")
assertEq(mailSum.totalCopper, 62000, "MailboxModel sums safe copper")

local savedGetInboxNum = _G.GetInboxNumItems
local savedGetInboxHdr = _G.GetInboxHeaderInfo
local savedTakeMoney = _G.TakeInboxMoney
local savedAutoLoot = _G.AutoLootMailItem
local takenM, takenI = {}, {}
_G.GetInboxNumItems = function() return 3 end
_G.GetInboxHeaderInfo = function(i)
    if i == 1 then return nil, nil, "부캐", "골드", 30000, 0, 30, 1 end
    if i == 2 then return nil, nil, "상인", "COD청구", 0, 500000, 3, 1 end
    if i == 3 then return nil, nil, "불명", "COD미상", 1000, nil, 3, 1 end -- nil COD fails closed!
end
_G.TakeInboxMoney = function(i) takenM[#takenM + 1] = i end
_G.AutoLootMailItem = function(i) takenI[#takenI + 1] = i end

ns.Features.MailboxModule:OnMailShow()
-- Postal yield check
local origIsLoaded = ns.Api.AddonProbe.IsLoaded
ns.Api.AddonProbe.IsLoaded = function(name) return name == "Postal" end
local okPostal, reasonPostal = ns.Features.MailboxModule:CollectAllSafe()
assertEq(okPostal, false, "MailboxModule yields CollectAllSafe when Postal is loaded")
assertEq(reasonPostal, "YIELDED_POSTAL", "Postal yield returns YIELDED_POSTAL")
ns.Api.AddonProbe.IsLoaded = origIsLoaded

local okMail, mailRes = ns.Features.MailboxModule:CollectAllSafe()
assertEq(okMail, true, "MailboxModule CollectAllSafe succeeds OOC")
assertEq(mailRes.takenMails, 1, "Only 1 safe mail collected")
assertEq(mailRes.skippedCod, 2, "Explicit COD and nil-COD mails both safely skipped (fail-closed)")
assertEq(takenM[1], 1, "TakeInboxMoney called ONLY on index 1 (never COD index 2 or nil-COD index 3)")
assertEq(takenI[1], 1, "AutoLootMailItem called ONLY on index 1")
ns.Features.MailboxModule:OnMailClosed()

_G.GetInboxNumItems = savedGetInboxNum
_G.GetInboxHeaderInfo = savedGetInboxHdr
_G.TakeInboxMoney = savedTakeMoney
_G.AutoLootMailItem = savedAutoLoot

------------------------------------------------------------------------
-- 10. P1 #11: SetupWizard Portable 3-Device Profile Export
------------------------------------------------------------------------
local expStr, expMode = ns.Features.SetupWizard:ExportPortableProfile()
assertEq(expMode, "PORTABLE_FS6", "SetupWizard exports portable FS6 profile string")
assert(type(expStr) == "string" and string.sub(expStr, 1, 8) == "FS6|FS2:",
    "Exported portable profile uses clean FS6|FS2: format without device key (got=" .. tostring(expStr) .. ")")

print("OK: 31_v64_p0_p1_master_parity")
