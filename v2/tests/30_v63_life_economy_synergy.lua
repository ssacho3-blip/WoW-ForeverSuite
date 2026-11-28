-- Test 30: v6.3.0 Life / Economy / Gathering Synergy Suite
-- Covers: Auctionator & Syndicator UI wiring (Profession ShoppingList, Fishing AH prices, Combined Farm GPH,
--         CharacterDock account gold), AltCooldown auto-recorder & HomePage CountReady, and TrackingSwitcher alerts/auto-cycle.
local ns = _G.ForeverSuite
__FS_FIRE_EVENT("PLAYER_LOGIN")

local function assertEq(actual, expected, msg)
    assert(actual == expected, (msg or "assertEq failed") .. " (got=" .. tostring(actual) .. ", expected=" .. tostring(expected) .. ")")
end

local savedAuctionator = _G.Auctionator
local savedSyndicator = _G.Syndicator
local savedCItem = _G.C_Item
local savedCMinimap = _G.C_Minimap
local savedCSpell = _G.C_Spell
local savedGetServerTime = _G.GetServerTime
local savedInCombat = _G.InCombatLockdown

local createdLists = {}
local mockPrices = {
    [765] = 1500,    -- 은엽초 15s
    [2447] = 2500,   -- 평온초 25s
    [6522] = 12000,  -- 돌연변이 물고기 1g 20s
    [13422] = 35000, -- 돌비늘 뱀장어 3g 50s
}
local mockNames = {
    [765] = "은엽초",
    [2447] = "평온초",
    [2770] = "구리 광석",
    [6522] = "돌연변이 물고기",
}

_G.Auctionator = {
    API = {
        v1 = {
            RegisterForDBUpdate = function() end,
            GetAuctionPriceByItemID = function(_, itemID)
                return mockPrices[itemID]
            end,
            CreateShoppingList = function(_, listName, terms)
                createdLists[#createdLists + 1] = { name = listName, terms = terms }
            end,
        },
    },
}

local synReady = true
local synInventory = {
    [765] = {
        characters = {
            { character = "본캐", bags = 4, bank = 6, mail = 0, equipped = 0 },
            { character = "부캐", bags = 0, bank = 5, mail = 0, equipped = 0 },
        },
        warband = 0,
    },
    [2447] = {
        characters = {},
        warband = 0,
    },
}
_G.Syndicator = {
    API = {
        IsReady = function() return synReady end,
        GetInventoryInfoByItemID = function(itemID)
            return synInventory[itemID] or { characters = {}, warband = 0 }
        end,
        GetAllCharacters = function()
            return { "본캐-ForeverKR", "부캐-ForeverKR" }
        end,
        GetCharacter = function(key)
            if key == "본캐-ForeverKR" then return { details = { money = 100000 } } end
            if key == "부캐-ForeverKR" then return { details = { money = 250000 } } end
            return nil
        end,
    },
}

_G.C_Item = _G.C_Item or {}
local origGetItemInfo = _G.C_Item.GetItemInfo
local origGetItemCount = _G.C_Item.GetItemCount
local origGetItemCooldown = _G.GetItemCooldown
_G.C_Item.GetItemInfo = function(id) return mockNames[id] end
_G.C_Item.GetItemCount = function(id) return (id == 15846) and 1 or 0 end
_G.GetItemCooldown = function(id)
    if id == 15846 then return 1000, 7200, 1 end
    return 0, 0, 1
end

ns.Bridges.Auctionator:InvalidateCache()

------------------------------------------------------------------------
-- 1. SyndicatorBridge:GetTotalAccountMoney & Fail-Closed WARMING
------------------------------------------------------------------------
local totalMoney, charCnt, mStatus = ns.Bridges.Syndicator:GetTotalAccountMoney()
assertEq(mStatus, "OK", "Syndicator account money OK when ready")
assertEq(totalMoney, 350000, "Syndicator sums money across characters")
assertEq(charCnt, 2, "Syndicator counted 2 characters")

synReady = false
local warmMoney, _, warmStatus = ns.Bridges.Syndicator:GetTotalAccountMoney()
assertEq(warmMoney, nil, "Syndicator returns nil when warming (never fabricated 0c)")
assertEq(warmStatus, "WARMING", "Syndicator reports WARMING status")
synReady = true

------------------------------------------------------------------------
-- 2. ProfessionPage: Syndicator cross-alt counts + Auctionator ShoppingList
------------------------------------------------------------------------
local owned765, who765, src765 = ns.Features.ProfessionPage:GetOwnedCountSummary(765)
assertEq(owned765, 15, "Syndicator sums 본캐(10) + 부캐(5) = 15")
assertEq(src765, "SYNDICATOR", "ProfessionPage prefers Syndicator when ready")
assert(string.find(who765, "본캐:10", 1, true) and string.find(who765, "부캐:5", 1, true), "Summary names characters")

-- Fallback to local ledger when Syndicator is warming
synReady = false
ns.Api.ProfileStore:SetState("altMaterials", { ["로컬캐"] = { [765] = 7 } })
local fbOwned, _, fbSrc = ns.Features.ProfessionPage:GetOwnedCountSummary(765)
assertEq(fbOwned, 7, "Falls back to local altMaterials when Syndicator warming")
assertEq(fbSrc, "LOCAL", "Source tag reports LOCAL fallback")
synReady = true

-- BuildShoppingEntries & CreateMissingShoppingList
local sampleMats = {
    { itemID = 765, kind = "herb" },  -- owned 15 -> NOT missing
    { itemID = 2447, kind = "herb" }, -- owned 0 -> missing, AH 2500c
    { itemID = 2770, kind = "ore" },  -- owned 0 -> missing, AH nil (unpriced, never 0c)
}
ns.Features.ProfessionPage.selectedProf = { title = "연금술" }
ns.Features.ProfessionPage.lastFilteredMaterials = sampleMats
local okShop, builtShop = ns.Features.ProfessionPage:CreateMissingShoppingList()
assertEq(okShop, true, "CreateMissingShoppingList succeeds OOC")
assertEq(#createdLists, 1, "Auctionator CreateShoppingList invoked once")
assertEq(createdLists[1].name, "ForeverSuite: 연금술", "Shopping list name includes profession")
assertEq(#createdLists[1].terms, 2, "Only the 2 missing materials included (owned item 765 excluded)")
assertEq(createdLists[1].terms[1], '"평온초"', "Exact-match quoted term 1")
assertEq(createdLists[1].terms[2], '"구리 광석"', "Exact-match quoted term 2")
assertEq(builtShop.pricedCount, 1, "Only 1 missing item has real AH price")
assertEq(builtShop.estimatedCopper, 2500, "Estimated AH cost sums only priced items")

-- Combat guard on shopping list
_G.InCombatLockdown = function() return true end
local okShopCombat, combatReason = ns.Features.ProfessionPage:CreateMissingShoppingList()
assertEq(okShopCombat, false, "Shopping list blocked in combat")
assertEq(combatReason, "IN_COMBAT", "Combat block reason")
_G.InCombatLockdown = savedInCombat

------------------------------------------------------------------------
-- 3. PowerQoLModel & TradeLogModule: Self-Loot Parser + AH-Valued Farm GPH
------------------------------------------------------------------------
local pid1, pcnt1 = ns.Domain.PowerQoLModel.ParseSelfLootItem("아이템을 획득했습니다: |cffffffff|Hitem:2447::::::::60:::::::|h[평온초]|h|rx3.")
assertEq(pid1, 2447, "Parses koKR self-loot itemID")
assertEq(pcnt1, 3, "Parses koKR stack count x3")

local pidParty = ns.Domain.PowerQoLModel.ParseSelfLootItem("파티원님이 아이템을 획득했습니다: |cffffffff|Hitem:2447::::::::60:::::::|h[평온초]|h|r.")
assertEq(pidParty, nil, "Strictly rejects other players' loot")

local pidEn, pcntEn = ns.Domain.PowerQoLModel.ParseSelfLootItem("You receive loot: |cffffffff|Hitem:6522::::::::60:::::::|h[Deviate Fish]|h|rx2.")
assertEq(pidEn, 6522, "Parses enUS self-loot itemID")
assertEq(pcntEn, 2, "Parses enUS stack count x2")

local pidSpaced, pcntSpaced = ns.Domain.PowerQoLModel.ParseSelfLootItem("아이템을 획득했습니다: |cffffffff|Hitem:2447::::::::60:::::::|h[평온초]|h|r x5.")
assertEq(pidSpaced, 2447, "Parses spaced stack loot itemID")
assertEq(pcntSpaced, 5, "Parses spaced stack count '|h|r x5'")

ns.Features.TradeLogModule:ResetFarm()
ns.Features.TradeLogModule.farmStartTime = (ns.Api.GameAdapters.GetMonotonicTime() or 100) - 3600
local lootOk, lootVal = ns.Features.TradeLogModule:OnLootMessage("아이템을 획득했습니다: |cffffffff|Hitem:6522::::::::60:::::::|h[돌연변이 물고기]|h|rx2.")
assertEq(lootOk, true, "TradeLogModule records self-loot")
assertEq(lootVal, 24000, "2x Deviate Fish valued at 24000c via Auctionator")
local farmSum = ns.Features.TradeLogModule:GetFarmSummary()
assert(farmSum and farmSum.lootCount == 2, "Farm summary tracks loot count")
assertEq(farmSum.lootValueCopper, 24000, "Farm summary tracks AH loot value")
assert(farmSum.totalGph >= 24000, "Combined GPH includes AH loot value")

------------------------------------------------------------------------
-- 4. FishingCardHud: AH Unit Price on Fish Rows + Catch Value
------------------------------------------------------------------------
__FS_LOAD_DATA_ADDON("ForeverSuite_Data")
local origZoneText = ns.Api.GameAdapters.GetPlayerZoneText
ns.Api.GameAdapters.GetPlayerZoneText = function() return "불모의 땅" end
ns.Features.FishingCardHud.sessionCatches = 0
ns.Features.FishingCardHud.sessionLootValueCopper = 0
ns.Features.FishingCardHud:Open()
local foundAhFish = false
for i = 1, 3 do
    local row = ns.Features.FishingCardHud.fishRows[i]
    if row and row._right and type(row._right.GetText) == "function" then
        local rt = row._right:GetText() or ""
        if string.find(rt, "1g", 1, true) then
            foundAhFish = true
        end
    end
end
assert(foundAhFish, "FishingCardHud displays Auctionator unit price on Deviate Fish row in Barrens")
ns.Features.FishingCardHud:OnLootMessage("아이템을 획득했습니다: |cffffffff|Hitem:6522::::::::60:::::::|h[돌연변이 물고기]|h|r.")
assertEq(ns.Features.FishingCardHud.sessionCatches, 1, "FishingCardHud increments catch count")
assertEq(ns.Features.FishingCardHud.sessionLootValueCopper, 12000, "FishingCardHud adds Auctionator price to session value")
ns.Features.FishingCardHud:Close()
ns.Api.GameAdapters.GetPlayerZoneText = origZoneText

------------------------------------------------------------------------
-- 5. CharacterDockPanel: Skills Tab Displays Syndicator Account Gold
------------------------------------------------------------------------
__FS_LOAD_DATA_ADDON("ForeverSuite_Data_Atlas")
local skillsSummary = ns.Features.CharacterDockPanel:Render("skills")
assert(string.find(skillsSummary, "계정 35g", 1, true), "CharacterDock skills deficit includes Syndicator total account gold (got=" .. tostring(skillsSummary) .. ")")

------------------------------------------------------------------------
-- 6. AltCooldownModel & ProfessionPage:SyncAltCooldowns + HomePage CountReady
------------------------------------------------------------------------
local ACM = ns.Domain.AltCooldownModel
local testStore = {}
local rOk = ACM.RecordRemaining(testStore, "부캐-ForeverKR", "mooncloth", 0, 1700000000)
assertEq(rOk, true, "RecordRemaining accepts 0 remaining (ready)")
local nanOk, nanErr = ACM.RecordRemaining(testStore, "부캐-ForeverKR", "mooncloth", 0/0, 1700000000)
assertEq(nanOk, false, "RecordRemaining rejects NaN remaining")
assertEq(nanErr, "INVALID_REMAINING", "NaN error code")
local readyCnt, totalCnt = ACM.CountReady(testStore, 1700000100)
assertEq(readyCnt, 1, "CountReady reports 1 ready")
assertEq(totalCnt, 1, "CountReady reports 1 total")
local nilR, nilT = ACM.CountReady(testStore, nil)
assertEq(nilR, 0, "CountReady(store, nil) fails closed to 0")
assertEq(nilT, 0, "CountReady(store, nil) total 0")
local nilSR, nilST = ACM.CountReady(nil, 1700000100)
assertEq(nilSR, 0, "CountReady(nil, now) fails closed to 0")
assertEq(nilST, 0, "CountReady(nil, now) total 0")

-- H2: GetPlayerCharKeySafe returns nil when realm is UNAVAILABLE or empty (zero fabricated key)
local origCanonRealm = ns.Api.SafeAPI.GetCanonicalRealm
ns.Api.SafeAPI.GetCanonicalRealm = function() return ns.Api.SafeAPI.UNAVAILABLE end
assertEq(ns.Api.GameAdapters.GetPlayerCharKeySafe(), nil, "GetPlayerCharKeySafe rejects UNAVAILABLE sentinel")
ns.Api.SafeAPI.GetCanonicalRealm = function() return "" end
assertEq(ns.Api.GameAdapters.GetPlayerCharKeySafe(), nil, "GetPlayerCharKeySafe rejects empty realm")
ns.Api.SafeAPI.GetCanonicalRealm = origCanonRealm

-- M1: GetItemCooldownSafe preserves enabled=0 as false (not tautological true)
local savedItemCdFn = _G.GetItemCooldown
_G.GetItemCooldown = function() return 100, 300, 0 end
local _, _, cdEnabled0 = ns.Api.GameAdapters.GetItemCooldownSafe(15846)
assertEq(cdEnabled0, false, "GetItemCooldownSafe returns false when enabled=0")
_G.GetItemCooldown = savedItemCdFn

-- H1: Test auto-recorder via ProfessionPage:SyncAltCooldowns including NEGATIVE startTime (pre-login multi-day CD)
_G.GetServerTime = function() return 1700000100 end
local origGetKnown = ns.Api.GameAdapters.GetKnownSpellSet
local origGetMono = ns.Api.GameAdapters.GetMonotonicTime
local origSpellCd = ns.Api.GameAdapters.GetSpellCooldownSafe
ns.Api.GameAdapters.GetKnownSpellSet = function() return { [17187] = true } end -- Arcanite Transmute
ns.Api.GameAdapters.GetMonotonicTime = function() return 1000 end
ns.Api.GameAdapters.GetSpellCooldownSafe = function(sid)
    -- Negative startTime (-79170) + dur (86400) - mono (1000) = 6230s remaining!
    if sid == 17187 then return -79170, 86400, true end
    return 0, 0, true
end
ns.Api.ProfileStore:SetState("altCooldowns", { ["부캐-ForeverKR"] = { mooncloth = 1700000000 } })
ns.Features.ProfessionPage.lastCooldownSyncAt = 0
ns.Features.ProfessionPage.announcedReadyAlts = false
local synced, syncedStore = ns.Features.ProfessionPage:SyncAltCooldowns(true)
assertEq(synced, true, "SyncAltCooldowns records known spell + Salt Shaker cooldowns")
local pKey = ns.Api.GameAdapters.GetPlayerCharKeySafe()
assert(type(syncedStore[pKey]) == "table" and syncedStore[pKey].transmute == 1700006330,
    "Negative pre-login startTime (-79170, dur 86400, mono 1000 => rem 6230s) recorded accurately")
assert(syncedStore[pKey].salt_shaker == 1700007300, "Salt Shaker remaining 7200s recorded accurately")
assertEq(ns.Features.ProfessionPage.announcedReadyAlts, true, "Announces ready alt cooldown once per session")

-- C1-a: Unavailable/nil spell cooldown read MUST NOT clobber existing future readyAt with fabricated 0
ns.Api.GameAdapters.GetSpellCooldownSafe = function() return nil end
local origItemCdFn2 = _G.GetItemCooldown
-- C1-c: Negative pre-login startTime on Salt Shaker item path (-79170 + 86400 - 1000 = 6230s => 1700006330)
_G.GetItemCooldown = function(id)
    if id == 15846 then return -79170, 86400, 1 end
    return 0, 0, 1
end
local syncedC1, storeC1 = ns.Features.ProfessionPage:SyncAltCooldowns(false, true)
assertEq(syncedC1, true, "Salt Shaker negative-startTime sync succeeds while spell read is nil")
assertEq(storeC1[pKey].transmute, 1700006330, "C1-a: Nil spell cooldown read preserves existing future transmute readyAt unclobbered")
assertEq(storeC1[pKey].salt_shaker, 1700006330, "C1-c: Negative pre-login startTime on Salt Shaker recorded accurately")
_G.GetItemCooldown = origItemCdFn2

-- C1-b: Nil monotonic time fails closed with UNAVAILABLE and zero store writes
ns.Api.GameAdapters.GetMonotonicTime = function() return nil end
local syncedMonoNil, monoNilErr = ns.Features.ProfessionPage:SyncAltCooldowns(false, true)
assertEq(syncedMonoNil, false, "C1-b: Nil monotonic time fails closed")
assertEq(monoNilErr, "UNAVAILABLE", "C1-b: Error reason is UNAVAILABLE")
local afterMonoNil = ns.Api.ProfileStore:GetState("altCooldowns")
assertEq(afterMonoNil[pKey].transmute, 1700006330, "C1-b: Store untouched when monotonic time unavailable")
ns.Api.GameAdapters.GetMonotonicTime = function() return 1000 end

-- HomePage now renders real CountReady output (1 ready / 3 total)
ns.UI.CommandHub:Toggle()
ns.UI.CommandHub:SelectPage("home")
ns.Features.HomePage:OnShow()
local bridgeTxt = ns.Features.HomePage.bridgeStatusLbl and ns.Features.HomePage.bridgeStatusLbl:GetText() or ""
assert(string.find(bridgeTxt, "완료 1/3건", 1, true), "HomePage shows live AltCooldown CountReady summary (got=" .. tostring(bridgeTxt) .. ")")

ns.Api.GameAdapters.GetKnownSpellSet = origGetKnown
ns.Api.GameAdapters.GetMonotonicTime = origGetMono
ns.Api.GameAdapters.GetSpellCooldownSafe = origSpellCd

------------------------------------------------------------------------
-- 7. TrackingSwitcher: Missing Tracker Alert + OOC Auto-Cycle Ticker
------------------------------------------------------------------------
local mockTrackers = {
    { index = 1, name = "약초 찾기", active = false, type = "spell" },
    { index = 2, name = "광물 찾기", active = false, type = "spell" },
}
_G.C_Minimap = {
    GetNumTrackingTypes = function() return #mockTrackers end,
    GetTrackingInfo = function(i) return mockTrackers[i] end,
    SetTracking = function(idx, val)
        for i = 1, #mockTrackers do
            mockTrackers[i].active = (i == idx) and (val == true) or false
        end
        return true
    end,
}
ns.Features.TrackingSwitcher.lastAlertAt = 0
local alerted, aReason = ns.Features.TrackingSwitcher:CheckMissingTrackingAlert(false)
assertEq(alerted, true, "Alerts when player has gathering trackers but none active")
assertEq(aReason, "ALERTED", "Alert reason is ALERTED")

-- Throttled on immediate re-check
local alerted2, aReason2 = ns.Features.TrackingSwitcher:CheckMissingTrackingAlert(false)
assertEq(alerted2, false, "Throttles repeated alert within 300s")
assertEq(aReason2, "THROTTLED", "Throttle reason")

-- Enable auto-cycle -> ticker starts OOC with >=2 trackers
ns.Api.ProfileStore:Set("profession", "autoCycleTracking", true)
local running, runReason = ns.Features.TrackingSwitcher:SyncAutoCycle()
assertEq(running, true, "Auto-cycle starts when enabled with >=2 trackers OOC")
assertEq(runReason, "RUNNING", "Auto-cycle status RUNNING")
assert(ns.Features.TrackingSwitcher.autoTicker ~= nil, "Ticker created")

-- Combat immediately stops auto-cycle
_G.InCombatLockdown = function() return true end
local runCombat, combatSt = ns.Features.TrackingSwitcher:SyncAutoCycle()
assertEq(runCombat, false, "Auto-cycle stops immediately in combat")
assertEq(combatSt, "IN_COMBAT", "Combat reason")
assertEq(ns.Features.TrackingSwitcher.autoTicker, nil, "Ticker cancelled in combat")
_G.InCombatLockdown = savedInCombat

-- Disable auto-cycle via /fs track auto
ns.Features.TrackingSwitcher:HandleCommand("auto")
assertEq(ns.Api.ProfileStore:Get("profession", "autoCycleTracking"), false, "/fs track auto toggles setting OFF")
assertEq(ns.Features.TrackingSwitcher.autoTicker, nil, "Ticker stays nil when disabled")

-- Restore globals cleanly
_G.Auctionator = savedAuctionator
_G.Syndicator = savedSyndicator
_G.C_Item.GetItemInfo = origGetItemInfo
_G.C_Item.GetItemCount = origGetItemCount
_G.GetItemCooldown = origGetItemCooldown
if savedCItem == nil then _G.C_Item = nil end
_G.C_Minimap = savedCMinimap
_G.C_Spell = savedCSpell
_G.GetServerTime = savedGetServerTime
_G.InCombatLockdown = savedInCombat

print("OK: 30_v63_life_economy_synergy")
