-- Test 16: ForeverSuite v3.0.1 Carbon × Fable Audit Regression Suite
-- Verifies ALL P0/P1 remediations against REAL compiled LoD data packs and live widgets.
local ns = _G.ForeverSuiteV2

__FS_FIRE_EVENT("PLAYER_LOGIN")

local origLoad = C_AddOns.LoadAddOn
C_AddOns.LoadAddOn = function(name)
    if string.find(tostring(name), "^ForeverSuite_Data") then
        local loaded = __FS_LOAD_DATA_ADDON(name)
        _G.__FS_MOCK.loadedAddOns[name] = loaded
        return loaded, loaded and nil or "LOAD_FAILED"
    end
    return origLoad(name)
end

-- ============================================================================
-- 1. P0-4: ZERO "table: 0x" memory address leaks in REAL ForeverSuite_Data_BiS
-- ============================================================================
local okBis = ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_BiS")
assert(okBis == true, "P0-4: ForeverSuite_Data_BiS must load cleanly")
local bisEntries = _G.ForeverSuiteData.packs.bis.entries
assert(#bisEntries >= 500, "P0-4: Expected >=500 BiS entries")
local leakCount = 0
for _, it in ipairs(bisEntries) do
    local s = tostring(it.acq or "") .. " " .. tostring(it.note or "") .. " " .. tostring(it.title or "")
    if string.find(s, "table: 0x", 1, true) or string.find(s, "function: 0x", 1, true) then
        leakCount = leakCount + 1
    end
end
assert(leakCount == 0, "P0-4: ZERO 'table: 0x' leaks allowed in BiS data pack (found " .. tostring(leakCount) .. ")")

-- ============================================================================
-- 2. P0-5 & P0-6: Deduplicated dungeons (0 dupes, aq20/zg=20, brs=10) + real dungeon_loot equipSlot
-- ============================================================================
local okDung = ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_Dungeon")
assert(okDung == true, "P0-5: ForeverSuite_Data_Dungeon must load cleanly")
local dEntries = _G.ForeverSuiteData.packs.dungeons.entries
local seenTitles = {}
local dupes = 0
local aq20Size, zgSize, brsSize = nil, nil, nil
for _, d in ipairs(dEntries) do
    if seenTitles[d.title] then
        dupes = dupes + 1
    end
    seenTitles[d.title] = true
    if d.id == "aq20" then aq20Size = d.partySize end
    if d.id == "zg" then zgSize = d.partySize end
    if d.id == "brs" then brsSize = d.partySize end
end
assert(dupes == 0, "P0-5: ZERO duplicate dungeon titles allowed (found " .. tostring(dupes) .. ")")
assert(#dEntries == 25, "P0-5: Expected exact 25 deduplicated dungeons (got " .. tostring(#dEntries) .. ")")
assert(aq20Size == 20 and zgSize == 20, "P0-5: AQ20 and ZG must have partySize == 20")
assert(brsSize == 10, "P0-5: BRS must have partySize == 10")

local lootEntries = _G.ForeverSuiteData.packs.dungeon_loot.entries
local withEquipSlot = 0
local checkedHead, checkedChest = false, false
for _, it in ipairs(lootEntries) do
    if it.slot == "머리" then assert(it.equipSlot == 1, "머리 must map to slot 1"); checkedHead = true end
    if it.slot == "가슴" then assert(it.equipSlot == 5, "가슴 must map to slot 5"); checkedChest = true end
    if type(it.equipSlot) == "number" and it.equipSlot > 0 then
        withEquipSlot = withEquipSlot + 1
    end
end
assert(withEquipSlot >= 3000 and checkedHead and checkedChest, "P0-6: >=3000 real dungeon_loot items must carry accurate numeric equipSlot (got " .. tostring(withEquipSlot) .. ")")
assert(ns.Domain.BiSBrowserModel.ResolveEquipSlot({ slot = "한손 장비" }) == 16, "P0-6: ResolveEquipSlot must map Korean slot strings")
assert(ns.Domain.BiSBrowserModel.ResolveEquipSlot({ equipSlot = 12 }) == 11, "P0-6: ResolveEquipSlot must normalize ring 12->11")
assert(ns.Domain.BiSBrowserModel.CanClassUseItem("MAGE", "판금") == false, "P1-4: Mage cannot wear plate")
assert(ns.Domain.BiSBrowserModel.CanClassUseItem("MAGE", "천") == true, "P1-4: Mage can wear cloth")

-- ============================================================================
-- 3. P0-1: C_Secrets event guards (direct + event dispatch, independent secrets + valid success)
-- ============================================================================
ns.Features.DungeonBrowserPage.activeRun = { name = "테스트 던전", bossesKilled = {} }
ns.Features.TradeLogModule.hadAccept = false
ns.Features.DungeonBrowserPage:OnBossKilled(FS_MakeSecret("boss", "string"), 1)
ns.Features.DungeonBrowserPage:OnBossKilled("라그나로스", FS_MakeSecret(1, "number"))
__FS_FIRE_EVENT("ENCOUNTER_END", 100, FS_MakeSecret("boss", "string"), 1, 5, FS_MakeSecret(1, "number"))
assert(#ns.Features.DungeonBrowserPage.activeRun.bossesKilled == 0, "P0-1: secret ENCOUNTER_END must NOT record boss kill")
ns.Features.DungeonBrowserPage:OnBossKilled("라그나로스", 1)
assert(#ns.Features.DungeonBrowserPage.activeRun.bossesKilled == 1 and ns.Features.DungeonBrowserPage.activeRun.bossesKilled[1] == "라그나로스", "P0-1: valid non-secret boss kill must record")
ns.Features.TradeLogModule:OnTradeAcceptUpdate(FS_MakeSecret(1, "number"), 0)
ns.Features.TradeLogModule:OnTradeAcceptUpdate(0, FS_MakeSecret(1, "number"))
__FS_FIRE_EVENT("TRADE_ACCEPT_UPDATE", FS_MakeSecret(1, "number"), FS_MakeSecret(1, "number"))
assert(ns.Features.TradeLogModule.hadAccept == false, "P0-1: secret TRADE_ACCEPT_UPDATE must NOT set hadAccept")
ns.Features.DungeonBrowserPage.activeRun = nil
__FS_FIRE_EVENT("QUEST_ACCEPTED", FS_MakeSecret(1, "number"), FS_MakeSecret(42, "number"))
__FS_FIRE_EVENT("UNIT_AURA", FS_MakeSecret("player", "string"))
__FS_FIRE_EVENT("UNIT_POWER_UPDATE", FS_MakeSecret("player", "string"))
__FS_FIRE_EVENT("UNIT_HEALTH", FS_MakeSecret("player", "string"))
__FS_FIRE_EVENT("UNIT_INVENTORY_CHANGED", FS_MakeSecret("player", "string"))

-- ============================================================================
-- 4. P0-2: QuestItemDock safe fallback when OptionalDeps ForeverSuite_Media is absent
-- ============================================================================
local savedSmallFont = _G.FS_Font_Small
_G.FS_Font_Small = nil
ns.Secure.QuestItemDock.buttons = {}
local dockBtns = ns.Secure.QuestItemDock:EnsureButtons()
assert(#dockBtns == 6 and dockBtns[1]._badge ~= nil, "P0-2: QuestItemDock must initialize cleanly without FS_Font_Small")
_G.FS_Font_Small = savedSmallFont

-- ============================================================================
-- 5. P0-3: ProfileStore:Set enforces combatSafe == false in combat
-- ============================================================================
_G.__FS_MOCK.inCombat = true
local okT, rT = ns.Api.ProfileStore:Set("quest", "defaultTrackerMode", "coexist")
assert(okT == false and rT == "IN_COMBAT", "P0-3: defaultTrackerMode must reject in combat")
local okF, rF = ns.Api.ProfileStore:Set("ui", "fontPreset", "bold_kr")
assert(okF == false and rF == "IN_COMBAT", "P0-3: fontPreset must reject in combat")
local okU, rU = ns.UI.HudLayout:SetUnlocked(true)
assert(okU == false and rU == "IN_COMBAT", "P1-3: HudLayout:SetUnlocked(true) must reject in combat")
_G.__FS_MOCK.inCombat = false

-- ============================================================================
-- 6. P0-7: W.PillBar OnLeave preserves active gold background + W.ScrollBar real drag
-- ============================================================================
local W = ns.UI.Widgets
local T = ns.UI.Tokens
local dummyParent = CreateFrame("Frame", nil, _G.UIParent)
local pb = W.PillBar(dummyParent, {
    { value = "a", label = "A", width = 60 },
    { value = "b", label = "B", width = 60 },
}, "a", function() end)
pb._pills[1].btn:FireScript("OnEnter")
pb._pills[1].btn:FireScript("OnLeave")
assert(pb._pills[1].btn._fsBg._color[1] == T.SURFACE.GOLD_TINT[1], "P0-7: PillBar active pill MUST stay GOLD_TINT after OnLeave")

local draggedTo = nil
local sb = W.ScrollBar(dummyParent, 200, function(off) draggedTo = off end)
sb:SetMetrics(0, 10, 50)
_G.__FS_MOCK.cursorX = 100
_G.__FS_MOCK.cursorY = 300
sb._thumb:FireScript("OnDragStart")
assert(sb._dragging == true and sb._thumb._scripts.OnUpdate ~= nil, "P0-7: ScrollBar drag must attach OnUpdate")
_G.__FS_MOCK.cursorY = 220
sb._thumb:FireScript("OnUpdate", 0.016)
assert(type(draggedTo) == "number" and draggedTo > 0, "P0-7: ScrollBar cursor-Y drag must advance scroll offset")
sb._thumb:FireScript("OnDragStop")
assert(sb._dragging == false and sb._thumb._scripts.OnUpdate == nil, "P0-7: ScrollBar OnDragStop must clear OnUpdate (0% idle CPU)")

-- ============================================================================
-- 7. P0-8: W.ScrollText Korean visual-width wrapping & color code safety
-- ============================================================================
local st = W.ScrollText(dummyParent, 500, 160)
st:SetText("|cfff3d25e가나다라마바사아자차카타파하|r 가나다라마바사아자차카타파하 가나다라마바사아자차카타파하")
assert(#st._lines <= 2, "P0-8: 500px ScrollText must fit ~40 Korean chars per line (got " .. tostring(#st._lines) .. " lines)")
assert(string.find(st._lines[1], "|cfff3d25e", 1, true) ~= nil, "P0-8: ScrollText must never split WoW color escape codes")
local stWrap = W.ScrollText(dummyParent, 240, 120)
stWrap:SetText("|cfff3d25e가나다라마바사 아자차카타파하 가나다라마바사 아자차카타파하|r 끝")
assert(#stWrap._lines >= 2, "P0-8: narrow ScrollText must wrap long colored text")
assert(string.sub(stWrap._lines[1], -2) == "|r" and string.sub(stWrap._lines[2], 1, 10) == "|cfff3d25e", "P0-8: ScrollText word wrap must carry active color across line break")

-- ============================================================================
-- 8. P1-3: QuestTrackerView real trackerLocked drag + DetailCard ESC registration
-- ============================================================================
local qtv = ns.Features.QuestTrackerView
qtv:Init()
ns.Api.ProfileStore:Set("quest", "trackerLocked", true)
qtv:SyncToolbarLabels()
assert(qtv.container._movable == false, "P1-3: trackerLocked=true must disable movable")
ns.Api.ProfileStore:Set("quest", "trackerLocked", false)
qtv:SyncToolbarLabels()
assert(qtv.container._movable == true, "P1-3: trackerLocked=false must enable header drag")
qtv:ShowDetailCard({ questID = 777, title = "테스트 퀘스트", zone = "엘윈 숲", level = 10, objectives = {} })
local inSpecial = false
for _, name in ipairs(_G.UISpecialFrames or {}) do
    if name == "ForeverSuiteQuestDetailCard" then inSpecial = true; break end
end
assert(inSpecial == true, "P2-5: QuestTrackerView detail card must be registered in UISpecialFrames")

-- ============================================================================
-- 9. P1-5 / P1-8 / P2-1: UtilitiesPage 보호목록 GUI, FontsPage 5 presets, LedgerPage ScrollBar+OnSearch, CodexPage ScrollBar
-- ============================================================================
local hub = ns.UI.CommandHub
hub:EnsureWindow()
hub:JumpTo("utilities", { subTab = "protect" })
local up = ns.Features.UtilitiesPage
assert(up.activeSub == "protect" and up.protectInputBar ~= nil, "P1-5: UtilitiesPage must expose 보호목록 GUI sub-tab")
up.protectInputBar:SetValue("item", "6948")
up.protectInputBar._submitBtn:FireScript("OnClick", "LeftButton")
assert(ns.Api.ProfileStore.db.v2.protectedItems[6948] == true, "P1-5: 보호목록 GUI must add itemID 6948")

hub:SelectPage("fonts")
local fp = ns.Features.FontsPage
assert(fp.presetBar ~= nil and #fp.presetBar._pills == 5, "P1-8: FontsPage FlowPillGroup must expose all 5 presets")
local fontSchema = ns.Api.ProfileStore.schemaByKey["ui.fontPreset"]
assert(fontSchema ~= nil and #fontSchema.options == 5, "P1-8: ui.fontPreset schema must register all 5 presets")

hub:SelectPage("ledger")
local lp = ns.Features.LedgerPage
lp:RecordEntry("repair", -5000, "특별수리테스트")
lp:RecordEntry("other", 2000, "일반드랍")
assert(lp.scrollBar ~= nil, "P2-1: LedgerPage must have W.ScrollBar")
lp:OnSearch("특별수리")
assert(lp.visibleRows == 1, "P2-1: LedgerPage:OnSearch must filter matching rows")

hub:SelectPage("codex")
assert(ns.Features.CodexPage.scrollBar ~= nil, "P2-1: CodexPage must have W.ScrollBar")
