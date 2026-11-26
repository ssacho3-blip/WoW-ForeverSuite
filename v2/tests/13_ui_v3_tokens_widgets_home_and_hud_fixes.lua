-- Test 13: ForeverSuite v3.0 Phase 1 — Tokens v3, CompositeWidgets, 5 HUD Bug Fixes, Floating Edit Bar,
--          Home Dashboard (0MB LoD login invariant), 960x640 4-Group CommandHub & Position Persistence.
local ns = _G.ForeverSuiteV2

_G.__FS_MOCK.playerName = "아르타스"
_G.__FS_MOCK.playerClass = "PALADIN"
_G.__FS_MOCK.level = 54
_G.__FS_MOCK.zoneText = "서부 역병지대"
_G.__FS_MOCK.bagFreeSlots = 8
_G.__FS_MOCK.money = 1254320
_G.__FS_MOCK.durability = { [1] = { 80, 100 }, [5] = { 90, 100 } }

__FS_FIRE_EVENT("PLAYER_LOGIN")

-- 1. 0-MB LoD login invariant MUST remain unbroken with Home Dashboard!
assert(_G.ForeverSuiteData == nil, "HomePage & v3.0 boot MUST NOT force-load ForeverSuite_Data at login")

-- 2. Tokens v3 SSOT checks
local T = ns.UI.Tokens
assert(T.ELEVATION.L1_PANEL == "MEDIUM" and T.ELEVATION.L3_OVERLAY == "FULLSCREEN_DIALOG", "L1_PANEL and L3_OVERLAY tokens must exist")
assert(T.QUALITY[4] ~= nil and T.CLASS_COLORS.PALADIN ~= nil and T.ICON.CLASS_TEX.PALADIN ~= nil, "Quality/Class/Icon tokens must exist")

-- 3. Fix #1 & #2: CombatHudPack must register valid table anchors & non-nil L1_CARD strata
local reg = ns.UI.HudLayout.registry
for _, id in ipairs({ "comboHud", "rangeHud", "shortBuffHud", "clockHud" }) do
    local rec = reg[id]
    assert(rec ~= nil, "Missing HudLayout registration for " .. id)
    assert(type(rec.defaultAnchor) == "table" and type(rec.defaultAnchor.point) == "string", id .. " defaultAnchor must be table")
    assert(type(rec.label) == "string" and not string.find(rec.label, "CENTER", 1, true), id .. " label must be human-readable Korean")
    assert(rec.frame._strata ~= nil, id .. " frame must have valid strata")
end
assert(reg.comboHud.defaultAnchor.y == -116 and reg.rangeHud.defaultAnchor.y == -148, "Combo and Range HUDs must not stack at (0,0)")
assert(reg.clockHud.defaultAnchor.point == "TOPRIGHT" and reg.clockHud.defaultAnchor.y == -148, "Clock HUD must anchor cleanly above StatusPill")

-- 4. Fix #3: ThreatMeterHud vs FishingCardHud must NOT overlap at BOTTOMRIGHT (-24, 180)
assert(reg.threatMeter.defaultAnchor.y == 180, "ThreatMeter default y=180")
assert(reg.fishingCard.defaultAnchor.y == 344, "FishingCard must move to y=344 to avoid colliding with ThreatMeter")

-- 5. Floating HUD Edit Control Bar & Preview-Show of hidden HUDs during unlock
local ch = ns.Features.CombatHudPack
assert(ch.comboFrame:IsShown() == false, "Combo HUD starts hidden when 0 combo points")
ns.UI.HudLayout:SetUnlocked(true)
assert(ns.UI.HudLayout.controlBar ~= nil and ns.UI.HudLayout.controlBar:IsShown() == true, "Floating edit bar must appear when unlocked")
assert(ch.comboFrame:IsShown() == true, "Hidden HUDs must preview-show during unlock mode for dragging")
ns.UI.HudLayout:SetUnlocked(false)
assert(ns.UI.HudLayout.controlBar:IsShown() == false, "Floating edit bar must hide when locked")
assert(ch.comboFrame:IsShown() == false, "Previously hidden HUDs must restore hidden state on lock")

-- 6. CommandHub 960x640, 4-Group Rail, Home default landing, Drag Position Persistence
local hub = ns.UI.CommandHub
hub:Toggle()
assert(hub.window:GetWidth() == 960 and hub.window:GetHeight() == 640, "CommandHub must be 960x640")
assert(hub.activePageId == "home", "CommandHub must land on Home Dashboard by default")
assert(_G.ForeverSuiteData == nil, "Opening CommandHub Home MUST still keep LoD packs unloaded (0MB)")
assert(string.find(ns.Features.HomePage.heroTitle:GetText(), "아르타스", 1, true) ~= nil, "Home hero must show player name")
assert(string.find(ns.Features.HomePage.briefDungeonLbl:GetText(), "검은바위 나락", 1, true) ~= nil, "Lv.54 recommendation must suggest BRD/Strat/Scholo")
assert(ns.Features.HomePage.statCards.durability._value:GetText() == "85%", "Home durability StatCard must show honest 85%")

-- Hub drag stop persists position in ProfileStore
hub.window:ClearAllPoints()
hub.window:SetPoint("TOPLEFT", _G.UIParent, "TOPLEFT", 120, -80)
hub.window:FireScript("OnDragStop")
local savedHub = ns.Api.ProfileStore:GetLayout("commandHub")
assert(savedHub ~= nil and savedHub.x == 120 and savedHub.y == -80, "CommandHub drag position must persist")

-- 7. CompositeWidgets unit verification: IconFrame, FlowPillGroup, ScrollText, CopyPasteModal
local W = ns.UI.Widgets
local flow = W.FlowPillGroup(hub.contentHost, {
    { value = "all", label = "전체", width = 60 },
    { value = "head", label = "머리", width = 60 },
    { value = "chest", label = "가슴", width = 60 },
    { value = "hands", label = "손", width = 60 },
}, "all", 140, nil)
assert(flow:GetValue() == "all" and flow._totalHeight > 22, "FlowPillGroup must wrap to multiple rows")
flow:SetValue("hands", true)
assert(flow:GetValue() == "hands", "FlowPillGroup must maintain single unified selection state")

local st = W.ScrollText(hub.contentHost, 320, 90, { lineHeight = 16 })
st:SetText("1줄\n2줄\n3줄\n4줄\n5줄\n6줄\n7줄\n8줄\n9줄\n10줄")
assert(#st._lines == 10 and st._scrollBar:IsShown() == true, "ScrollText must show scrollbar when lines exceed viewport")
st:ScrollBy(3)
assert(st._offset == 3 and st._rows[1]:GetText() == "4줄", "ScrollText scroll must advance visible lines")

local modal = W.CopyPasteModal()
modal:OpenExport("테스트 내보내기", "안내", "FS2:TEST_PAYLOAD")
assert(modal:IsShown() == true and modal._box:GetText() == "FS2:TEST_PAYLOAD" and modal._box._highlighted == true)
modal:Hide()
