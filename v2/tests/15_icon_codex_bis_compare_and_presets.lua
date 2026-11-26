-- Test 15: ForeverSuite v3.0 Phase 3A & 3B — Built-in Icons (IconRow), BiS FlowPillGroup & 2-Pane Comparison,
--          Dungeon/Profession/QuestGuide ScrollText & ScrollBar, Settings 3-Preset Strip + 43 desc Cards + [비전투] Badge,
--          and L0/L1 HUD Cohesion (NavigationHud [x], ThreatMeter gauge, StatusPill low-durability danger, WorldMap collapse).
local ns = _G.ForeverSuiteV2

_G.__FS_MOCK.playerClass = "WARRIOR"
_G.__FS_MOCK.level = 60
_G.__FS_MOCK.playerPos = { mapID = 1453, x = 0.50, y = 0.50 }
_G.__FS_MOCK.equippedItems = { [1] = 12640 } -- Lionheart Helm slot 1
_G.__FS_MOCK.itemLevels = { [12640] = 61 }
_G.__FS_MOCK.itemIcons = { [12640] = 133130 }

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

local hub = ns.UI.CommandHub
hub:Toggle()

-- 1. BiSBrowserPage: Bug #4 Fix (single FlowPillGroup) + 2-Pane Equipped vs BiS Comparison + Real Icon
hub:SelectPage("bis")
local bis = ns.Features.BiSBrowserPage
assert(bis.slotPillGroup ~= nil and bis.slotPillGroup:GetValue() == "all")
bis.slotPillGroup:SetValue("머리")
assert(bis.slotPillGroup:GetValue() == "머리" and bis.slotFilter == "머리", "Unified FlowPillGroup must switch cleanly without dual active gold pills")
assert(bis.selectedRec ~= nil and bis.detailPanel ~= nil, "BiS 2-Pane detail panel must auto-select first candidate")
assert(bis.rows[1]._icon._iconPath ~= nil, "BiS IconRow must display built-in item icon texture")
assert(string.find(bis.equippedNameLbl:GetText(), "12640", 1, true) ~= nil or string.find(bis.equippedSubLbl:GetText(), "61", 1, true) ~= nil, "BiS 2-Pane must compare live equipped Head iLvl 61")

-- 2. DungeonBrowserPage: ScrollText overview + Bosses IconRow drops + ScrollBar on both panes
hub:SelectPage("dungeons")
local dun = ns.Features.DungeonBrowserPage
assert(dun.leftScrollBar ~= nil and dun.rightScrollBar ~= nil, "DungeonBrowser must have ScrollBars on both panes")
assert(type(dun.overviewBody.ScrollBy) == "function", "Dungeon overview must use W.ScrollText")
dun.activeTab = "bosses"
dun:RenderRight()
assert(dun.rightRows[1]:IsShown() == true, "Dungeon bosses/drops tab must render IconRows")

-- 3. ProfessionPage: 13 built-in profession icons + ScrollText guide
hub:SelectPage("professions")
local prof = ns.Features.ProfessionPage
assert(prof.leftRows[1]._icon._iconPath ~= nil and string.find(tostring(prof.leftRows[1]._icon._iconPath), "Interface\\Icons\\", 1, true) ~= nil, "Profession rows must display built-in WoW profession icons")
assert(type(prof.guideBody.ScrollBy) == "function", "Profession leveling guide must use W.ScrollText")

-- 4. QuestGuidePage: DetailPanel + ScrollText walkthrough
hub:SelectPage("questguide")
local qg = ns.Features.QuestGuidePage
assert(qg.detailPanel ~= nil and type(qg.detailPanel._body.ScrollBy) == "function", "QuestGuide walkthrough must use DetailPanel + ScrollText")

-- 5. SettingsPage: Bug #5 Fix (all 43 schema.desc rendered + [비전투] badge) + 3-Preset Strip
hub:SelectPage("settings")
local sp = ns.Features.SettingsPage
local descCount = 0
local nonCombatBadgeCount = 0
for _, entry in ipairs(sp.builtItems) do
    if entry.descLbl ~= nil then descCount = descCount + 1 end
    if entry.combatTag ~= nil then nonCombatBadgeCount = nonCombatBadgeCount + 1 end
end
assert(descCount >= 40, "Bug #5 Fix: SettingsPage must render schema.desc for all declared settings")
assert(nonCombatBadgeCount >= 4, "SettingsPage must render [비전투 전용] badges for combatSafe==false settings")

-- Apply Minimal preset -> turns off status pill & threat meter; then restore Standard preset!
local okMin, cntMin = sp:ApplyPreset("minimal")
assert(okMin == true and cntMin >= 10)
assert(ns.Api.ProfileStore:Get("ui", "showStatusPill") == false and ns.Api.ProfileStore:Get("combat", "showThreatMeter") == false)
local okStd, cntStd = sp:ApplyPreset("standard")
assert(okStd == true and cntStd >= 15)
assert(ns.Api.ProfileStore:Get("ui", "showStatusPill") == true and ns.Api.ProfileStore:Get("combat", "showThreatMeter") == true)

-- Read-only ProfileStore MUST cause ApplyPreset to fail-closed (never fabricate success!)
ns.Api.ProfileStore.readOnly = true
local okRo, cntRo = sp:ApplyPreset("minimal")
assert(okRo == false and cntRo == 0, "Read-only ProfileStore must fail-closed on ApplyPreset")
ns.Api.ProfileStore.readOnly = false

-- BiS pack-load failure MUST clear stale detail panel & hide linkBtn
local savedBisPack = _G.ForeverSuiteData.packs.bis
_G.ForeverSuiteData.packs.bis = nil
bis:Render("")
assert(bis.selectedRec == nil and bis.linkBtn:IsShown() == false, "BiS load failure must clear stale selection and hide chat-link CTA")
_G.ForeverSuiteData.packs.bis = savedBisPack

-- 6. L0/L1 HUD Cohesion: NavigationHud [x] button, StatusPill low-durability DANGER, WorldMapOverlay collapse, ThreatMeter gauge
local nav = ns.Features.NavigationHud
nav:SetTarget(1453, 0.70, 0.70, "테스트 목적지")
assert(nav.card:IsShown() == true and nav.closeBtn ~= nil)
nav.closeBtn:FireScript("OnClick", "LeftButton")
assert(nav.target == nil and nav.card:IsShown() == false, "NavigationHud [x] button must clear waypoint")

local pill = ns.Features.StatusPillHud
pill:Refresh(10, 0, 22)
assert(string.find(pill.label:GetText(), "|cfff87171내구 22%|r", 1, true) ~= nil, "Durability <30% must highlight durability segment DANGER red")
assert(pill.label._textColor[1] == ns.UI.Tokens.TEXT.PRIMARY[1], "Other StatusPill segments must stay crisp PRIMARY white")
pill:Refresh(10, 0, 95)
assert(string.find(pill.label:GetText(), "|cfff87171", 1, true) == nil, "Healthy durability must clear inline red highlight")
assert(pill.label._textColor[1] == ns.UI.Tokens.TEXT.PRIMARY[1], "Healthy durability must keep PRIMARY color")

local wmo = ns.Features.WorldMapOverlay
wmo:EnsureCard()
wmo:SetCollapsed(true)
assert(wmo.card:GetHeight() == 50, "WorldMapOverlay collapse must shrink to 1-line 50px coord strip")
wmo:SetCollapsed(false)
assert(wmo.card:GetHeight() == 240, "WorldMapOverlay expand must restore 240px full panel")

-- ThreatMeter gauge bar test
_G.__FS_MOCK.inCombat = true
_G.__FS_MOCK.threatData = { player = { true, 3, 100, 100, 5000 } }
ns.Features.ThreatMeterHud:Refresh()
assert(ns.Features.ThreatMeterHud.rows[1]._gauge:IsShown() == true, "ThreatMeterHud must display proportional gauge bar")
_G.__FS_MOCK.inCombat = false
ns.Features.ThreatMeterHud:OnCombatEnd()
