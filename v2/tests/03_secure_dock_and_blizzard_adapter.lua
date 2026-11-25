-- Test 03: Secure QuestItemDock, CombatQueue dedup, and ObjectiveTrackerAdapter true no-op coexist + hide->dim restore
local ns = _G.ForeverSuiteV2

__FS_FIRE_EVENT("PLAYER_LOGIN")

-- 1. ObjectiveTrackerAdapter default "coexist" is a TRUE NO-OP (zero Show/SetAlpha/HookScript calls!)
local adapter = ns.Blizzard.ObjectiveTrackerAdapter
assert(adapter.mode == "coexist")
assert(adapter.touched == false and adapter.hooked == false)
assert(_G.__FS_MOCK.objTrackerTouches == 0, "coexist default must NEVER touch ObjectiveTrackerFrame")

-- Transition to hide -> dim restores Show() and Alpha=0.15!
adapter:ApplyMode("hide")
assert(_G.ObjectiveTrackerFrame:IsShown() == false and _G.ObjectiveTrackerFrame:GetAlpha() == 0)
adapter:ApplyMode("dim")
assert(_G.ObjectiveTrackerFrame:IsShown() == true and _G.ObjectiveTrackerFrame:GetAlpha() == 0.15)

-- 2. QuestItemDock UIParent-direct SecureActionButton + combat badge freeze alignment
local dock = ns.Secure.QuestItemDock
dock:ApplySlots({
    { slot = 1, questID = 101, itemLink = "|Hitem:5501|h[신호탄]|h", itemIcon = 133710 },
})
local btn1 = _G.ForeverSuiteV2QuestItemSlot1
assert(btn1:GetParent() == _G.UIParent)
assert(btn1._clicks[1] == "LeftButtonUp" and #btn1._clicks == 1)
assert(btn1:GetAttribute("useOnKeyDown") == false)
assert(dock:GetActiveSlotForQuest(101) == 1)

-- Mid-combat update defers dock mutation AND keeps activeSlotByQuest synced with live secure button
_G.__FS_MOCK.inCombat = true
local ranNow = dock:ApplySlots({
    { slot = 1, questID = 202, itemLink = "|Hitem:9999|h[폭탄]|h", itemIcon = nil },
})
assert(ranNow == false and dock:GetActiveSlotForQuest(101) == 1)

_G.__FS_MOCK.inCombat = false
__FS_FIRE_EVENT("PLAYER_REGEN_ENABLED")
assert(btn1:GetAttribute("item") == "|Hitem:9999|h[폭탄]|h")
assert(btn1._icon._texture == nil, "nil itemIcon must clear previous texture")
assert(dock:GetActiveSlotForQuest(202) == 1)

-- 3. CombatQueue deduplicates immediate + deferred keys (never executes twice)
local calls = 0
_G.__FS_MOCK.inCombat = true
ns.Secure.CombatQueue:RunOrDefer("k1", function() calls = calls + 1 end)
_G.__FS_MOCK.inCombat = false
ns.Secure.CombatQueue:RunOrDefer("k1", function() calls = calls + 10 end)
ns.Secure.CombatQueue:Flush()
assert(calls == 10, "immediate run must discard earlier deferred closure")
