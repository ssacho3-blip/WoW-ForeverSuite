-- Test 28: Convenience Restoration & HUD UX Verification
-- Verifies:
--   1. 1-Click Fishing Helper Window (FishingCardHud + Secure/FishingCastButton visible OOC dock,
--      combat deferral, pole<->weapon swap, lure auto-detect, crash-safe sound boost CVar journal,
--      session catch counter, /fs fish command, and Director pinned visibility).
--   2. Minimap Overlap Protection & Direct HUD Dragging (StatusPillHud Shift+Drag without /fs move,
--      SetUnlocked(false) preserving directDrag movability, BlizzMinimap overlap detection & auto-separate).
--   3. Compact Collapsible Quick Tool Dock (7 1-click actions, collapse/expand persistence, /fs dock).
--   4. Zero-Taint Merchant Quick Strip (UIParent-owned, show/hide on MERCHANT_SHOW/CLOSED, manual sell/repair).
local ns = _G.ForeverSuite
__FS_FIRE_EVENT("PLAYER_LOGIN")

local function assertEq(actual, expected, msg)
    assert(actual == expected, (msg or "assertEq failed") .. " (got=" .. tostring(actual) .. ", expected=" .. tostring(expected) .. ")")
end

------------------------------------------------------------------------
-- 1. 1-Click Fishing Helper Window & Secure OOC Dock
------------------------------------------------------------------------
local FH = ns.Features.FishingCardHud
local SCB = ns.Secure.FishingCastButton

-- Mock bag containing Aquadynamic Fish Attractor (6533, +100), Bright Baubles (6532, +75), and a Fishing Pole (6256)
local origGetSlots = _G.C_Container and _G.C_Container.GetContainerNumSlots
local origGetItemInfoC = _G.C_Container and _G.C_Container.GetContainerItemInfo
local origGetItemInfo = _G.C_Item and _G.C_Item.GetItemInfo
local origGetInvID = _G.GetInventoryItemID
local origEquip = _G.EquipItemByName
local origInCombat = _G.InCombatLockdown

local equippedMH = 19019 -- Thunderfury (normal combat weapon)
local equippedOH = 18805
local equippedLog = {}

_G.C_Container = _G.C_Container or {}
_G.C_Container.GetContainerNumSlots = function(bag) return bag == 0 and 3 or 0 end
_G.C_Container.GetContainerItemInfo = function(bag, slot)
    if bag ~= 0 then return nil end
    if slot == 1 then return { itemID = 6532, quality = 1, stackCount = 2, isLocked = false, itemName = "빛나는 미끼" } end
    if slot == 2 then return { itemID = 6533, quality = 1, stackCount = 3, isLocked = false, itemName = "아쿠아다이내믹 물고기 유인기" } end
    if slot == 3 then return { itemID = 6256, quality = 1, stackCount = 1, isLocked = false, itemName = "낚싯대" } end
    return nil
end
_G.C_Item = _G.C_Item or {}
_G.C_Item.GetItemInfo = function(id)
    if id == 6256 then return "낚싯대", nil, 1, 1, 1, "무기", "낚싯대", 1, "", 0, 100, 2, 20 end
    if id == 6533 then return "아쿠아다이내믹 물고기 유인기", nil, 1, 1, 1, "소비용품", "", 5, "", 0, 250, 0, 0 end
    if id == 6532 then return "빛나는 미끼", nil, 1, 1, 1, "소비용품", "", 5, "", 0, 100, 0, 0 end
    return "전투 무기", nil, 4, 80, 60, "무기", "도검", 1, "", 0, 10000, 2, 7
end
_G.GetInventoryItemID = function(_, slot)
    if slot == 16 then return equippedMH end
    if slot == 17 then return equippedOH end
    return nil
end
_G.EquipItemByName = function(itemID)
    equippedLog[#equippedLog + 1] = itemID
    if itemID == 6256 then
        equippedMH = 6256
        equippedOH = nil
    elseif itemID == 19019 then
        equippedMH = 19019
    elseif itemID == 18805 then
        equippedOH = 18805
    end
end

-- Best lure auto-detection picks +100 (6533) over +75 (6532)
local bestLure = ns.Api.GameAdapters.FindBestFishingLureInBags()
assert(bestLure and bestLure.itemID == 6533 and bestLure.bonus == 100 and bestLure.count == 3,
    "FindBestFishingLureInBags must select highest bonus lure (6533, +100)")

-- Open via /fs fish -> visible even without pole equipped, and Director keeps fishingCard alpha = 1.0!
_G.SlashCmdList["FOREVERSUITE"]("fish on")
assertEq(FH.visible, true, "/fs fish on must show FishingCardHud")
assertEq(FH.pinned, true, "/fs fish on must pin FishingCardHud")
assert(SCB.dockCastBtn and SCB.dockCastBtn:IsShown(), "1-click secure Cast button must be shown OOC")
assert(SCB.dockLureBtn and SCB.dockLureBtn:IsShown(), "1-click secure Lure button must be shown OOC")
assertEq(SCB.dockCastBtn:GetParent(), _G.UIParent, "Secure Cast button parent MUST be _G.UIParent (Zero-Taint)")
assertEq(SCB.dockLureBtn:GetParent(), _G.UIParent, "Secure Lure button parent MUST be _G.UIParent (Zero-Taint)")
assertEq(SCB.dockLureBtn._attrs.type, "macro", "Secure Lure button must use macro type")
assertEq(SCB.dockLureBtn._attrs.macrotext, "/use item:6533\n/use 16", "Secure Lure macro must target best lure onto slot 16")
assertEq(ns.UI.Director.state, "FISHING", "Pinned fishing card must keep Director in FISHING state OOC")

-- 1-click Pole <-> Combat Weapon swap round-trip
local okSwap1, rSwap1 = FH:SwapFishingPole()
assert(okSwap1 and rSwap1 == "EQUIPPED_POLE", "SwapFishingPole must equip fishing pole from bags")
assertEq(equippedMH, 6256, "Mainhand must now be fishing pole")
local okSwap2, rSwap2 = FH:SwapFishingPole()
assert(okSwap2 and rSwap2 == "RESTORED_WEAPONS", "Second SwapFishingPole must restore saved combat weapons")
assertEq(equippedMH, 19019, "Mainhand combat weapon restored")
assertEq(equippedOH, 18805, "Offhand combat weapon restored")

-- Session fish catch counter via CHAT_MSG_LOOT (self-loot only; ignores party loot!)
local beforeCatches = FH.sessionCatches or 0
__FS_FIRE_EVENT("CHAT_MSG_LOOT", "파티원님이 아이템을 획득했습니다: |cffffffff|Hitem:6308::::::::60:::::::|h[생 붉은퉁돔]|h|r")
-- Wait: koKR party loot says "파티원님이 ... 획득했습니다" vs self "아이템을 획득했습니다" — let's test English party loot too
__FS_FIRE_EVENT("CHAT_MSG_LOOT", "Thrall receives loot: |cffffffff|Hitem:6308::::::::60:::::::|h[Raw Redgill]|h|r")
assertEq(FH.sessionCatches, beforeCatches, "Party loot must NOT inflate self fishing catch counter")
__FS_FIRE_EVENT("CHAT_MSG_LOOT", "아이템을 획득했습니다: |cffffffff|Hitem:6308::::::::60:::::::|h[생 붉은퉁돔]|h|r")
assertEq(FH.sessionCatches, beforeCatches + 1, "Self CHAT_MSG_LOOT while fishing window open must increment session catch count")

-- Crash-safe Fishing Sound Boost CVar journal round-trip
local okSnd1, rSnd1 = FH:ToggleSoundBoost(true)
assert(okSnd1 and rSnd1 == "BOOST_ON" and FH.soundBoost == true, "Fishing sound boost ON must succeed OOC")
local okSnd2, rSnd2 = FH:ToggleSoundBoost(false)
assert(okSnd2 and rSnd2 == "BOOST_OFF" and FH.soundBoost == false, "Fishing sound boost OFF must restore CVars cleanly")

-- Combat lockdown deferral + zero invisible click-catcher + combat->peace auto-restore!
assertEq(SCB.dockCastBtn._attrs.fsVisible, true, "Secure Cast button must store fsVisible=true intent OOC")
_G.InCombatLockdown = function() return true end
__FS_FIRE_EVENT("PLAYER_REGEN_DISABLED")
assertEq(FH.card:IsShown(), false, "FishingCardHud card must Hide during combat (no invisible alpha-0 click-catcher)")
local okCmb, rCmb = SCB:SyncDock(FH.card, true, bestLure)
assertEq(okCmb, false, "SyncDock must defer during combat lockdown")
assertEq(rCmb, "DEFERRED_COMBAT", "SyncDock must return DEFERRED_COMBAT")
local okSwapCmb, rSwapCmb = FH:SwapFishingPole()
assert(okSwapCmb == false and rSwapCmb == "IN_COMBAT", "SwapFishingPole must refuse in combat")
_G.InCombatLockdown = origInCombat
__FS_FIRE_EVENT("PLAYER_REGEN_ENABLED")
assertEq(FH.card:IsShown(), true, "Combat exit must automatically restore FishingCardHud card")
assertEq(SCB.dockCastBtn:IsShown(), true, "Combat exit must automatically restore 1-click secure Cast button")
assertEq(SCB.dockLureBtn:IsShown(), true, "Combat exit must automatically restore 1-click secure Lure button")

-- Close fishing card cleanly
FH:Close()
assertEq(FH.visible, false, "FishingCardHud:Close must hide card")
assertEq(SCB.dockCastBtn:IsShown(), false, "Closing fishing card must hide secure Cast button")
assertEq(SCB.dockLureBtn:IsShown(), false, "Closing fishing card must hide secure Lure button")

-- Restore bag/item mocks
if origGetSlots then _G.C_Container.GetContainerNumSlots = origGetSlots end
if origGetItemInfoC then _G.C_Container.GetContainerItemInfo = origGetItemInfoC end
if origGetItemInfo then _G.C_Item.GetItemInfo = origGetItemInfo end
if origGetInvID then _G.GetInventoryItemID = origGetInvID end
if origEquip then _G.EquipItemByName = origEquip else _G.EquipItemByName = nil end

------------------------------------------------------------------------
-- 2. Minimap Overlap Protection & Direct HUD Dragging
------------------------------------------------------------------------
local HL = ns.UI.HudLayout
local SP = ns.Features.StatusPillHud

-- StatusPillHud must stay movable even when HudLayout is locked (direct Shift+Drag!)
HL:SetUnlocked(true)
HL:SetUnlocked(false)
assertEq(SP.card._movable, true, "SetUnlocked(false) must preserve SetMovable(true) on directDrag StatusPillHud")
assertEq(ns.Features.QuestTrackerView.container._movable, true, "SetUnlocked(false) must preserve movability on QuestTrackerView")
assertEq(ns.Features.QuickDockHud.bar._movable, true, "SetUnlocked(false) must preserve movability on QuickDockHud")

-- Shifting clockHud up into Blizzard Minimap must be detected & auto-separated by HudLayout!
HL:Nudge("clockHud", 0, 120) -- y=-216 -> y=-96 (deep inside BlizzMinimap!)
local mmOverlaps = HL:FindOverlaps()
local sawMinimap = false
for _, p in ipairs(mmOverlaps) do
    if p.a == "clockHud" and p.b == "BlizzMinimap" then
        sawMinimap = true
        break
    end
end
assert(sawMinimap, "HudLayout:FindOverlaps must detect HUD overlap against BlizzMinimap")
local movedMm, remMm = HL:ResolveOverlaps()
assert(movedMm >= 1 and remMm == 0, "HudLayout:ResolveOverlaps must separate HUD out of BlizzMinimap (rem=" .. tostring(remMm) .. ")")
HL:ResetOne("clockHud")

------------------------------------------------------------------------
-- 3. Compact Collapsible Quick Tool Dock
------------------------------------------------------------------------
local QD = ns.Features.QuickDockHud
assert(QD.bar and QD.bar:IsShown(), "QuickDockHud must be visible by default")
assertEq(#QD.buttons, 7, "QuickDockHud must expose 7 quick-access buttons")
assertEq(QD.bar:GetWidth(), 314, "Expanded QuickDockHud width must be 314")

-- Collapse / expand toggle + ProfileStore persistence
QD:SetCollapsed(true)
assertEq(QD.collapsed, true, "QuickDockHud must collapse")
assertEq(QD.bar:GetWidth(), 30, "Collapsed QuickDockHud width must shrink to 30")
assertEq(ns.Api.ProfileStore:GetState("quickDockCollapsed"), true, "Collapsed state must persist")
QD:SetCollapsed(false)
assertEq(QD.bar:GetWidth(), 314, "Expanded QuickDockHud width must restore to 314")

-- /fs dock toggle
_G.SlashCmdList["FOREVERSUITE"]("dock")
assertEq(QD.bar:IsShown(), false, "/fs dock must hide QuickDockHud")
_G.SlashCmdList["FOREVERSUITE"]("dock")
assertEq(QD.bar:IsShown(), true, "Second /fs dock must show QuickDockHud")

------------------------------------------------------------------------
-- 4. Zero-Taint Merchant Quick Strip
------------------------------------------------------------------------
local MM = ns.Features.MerchantModule
__FS_FIRE_EVENT("MERCHANT_SHOW")
assert(MM.quickStrip and MM.quickStrip:IsShown(), "MERCHANT_SHOW must display Zero-Taint Merchant Quick Strip")
assertEq(MM.quickStrip:GetParent(), _G.UIParent, "Merchant Quick Strip parent MUST be _G.UIParent (Zero-Taint)")
__FS_FIRE_EVENT("MERCHANT_CLOSED")
assertEq(MM.quickStrip:IsShown(), false, "MERCHANT_CLOSED must hide Merchant Quick Strip")

print("OK: 28_convenience_restoration_and_hud_ux")
