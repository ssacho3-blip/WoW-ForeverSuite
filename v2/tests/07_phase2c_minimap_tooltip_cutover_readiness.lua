-- Test 07: Phase 2C Minimap Medallion, Zero-Taint Tooltip Enhancer, Persistent Camera CVar, Uninstalled AddOn Presence & All Phase 2B Nit Closures
local ns = _G.ForeverSuiteV2

_G.__FS_MOCK.now = 3000
_G.__FS_MOCK.cvars = { autoLootDefault = "1", cameraDistanceMaxZoomFactor = "1.7" }
_G.__FS_MOCK.bagItems = {
    { bag = 0, slot = 1, itemID = 4242, quality = 2, stackCount = 1, unitPrice = 12500, name = "황금 단검", isLocked = false },
}

__FS_FIRE_EVENT("PLAYER_LOGIN")

-- 1. MinimapButton: polar math, drag angle persistence, clicks (Left -> Hub, Right -> Move, Shift+Right -> Ledger), hide/show toggle, tooltip
local mb = ns.Features.MinimapButton.button
assert(mb ~= nil and mb:IsShown() == true)
assert(mb._angle == 220)

-- Simulate circular drag around Minimap center (1820, 980) -> cursor directly East (1900, 980) = 0 deg
_G.__FS_MOCK.cursorX = 1900
_G.__FS_MOCK.cursorY = 980
mb:FireScript("OnDragStart")
mb:FireScript("OnUpdate")
mb:FireScript("OnDragStop")
assert(mb._angle == 0 and mb._scripts["OnUpdate"] == nil, "drag must snap angle to 0 deg and clear OnUpdate (0 CPU)")
assert(ns.Api.ProfileStore:GetState("minimapAngle") == 0, "dragged minimap angle must persist in ProfileStore state")

-- Left click toggles CommandHub
mb:FireScript("OnClick", "LeftButton")
assert(ns.UI.CommandHub.window:IsShown() == true)
mb:FireScript("OnClick", "LeftButton")
assert(ns.UI.CommandHub.window:IsShown() == false)

-- Shift + Right click opens Ledger directly
_G.__FS_MOCK.shiftDown = true
mb:FireScript("OnClick", "RightButton")
assert(ns.UI.CommandHub.window:IsShown() == true and ns.UI.CommandHub.activePageId == "ledger")
_G.__FS_MOCK.shiftDown = false

-- Tooltip on hover
mb:FireScript("OnEnter")
assert(#_G.GameTooltip._lines >= 4 and string.find(_G.GameTooltip._lines[1].left, "ForeverSuite", 1, true))

-- Toggle ui.showMinimapButton hides & shows
ns.Api.ProfileStore:Set("ui", "showMinimapButton", false)
assert(mb:IsShown() == false)
ns.Api.ProfileStore:Set("ui", "showMinimapButton", true)
assert(mb:IsShown() == true)

-- 2. TooltipEnhanceModule: Item ID + vendor price + protected badge + Spell ID + Forbidden/Secret fail-closed + setting toggle
ns.Features.MerchantModule:ToggleProtectItem("4242")
_G.GameTooltip._lines = {}
__FS_FIRE_TOOLTIP(0, _G.GameTooltip, { id = 4242 })
assert(#_G.GameTooltip._lines == 2, "protected item with sell price must append ID/price + protected badge")
assert(string.find(_G.GameTooltip._lines[1].left, "#4242", 1, true) and string.find(_G.GameTooltip._lines[1].right, "1g 25s 00c", 1, true))
assert(string.find(_G.GameTooltip._lines[2].left, "판매 보호", 1, true))

-- Spell tooltip
_G.GameTooltip._lines = {}
__FS_FIRE_TOOLTIP(1, _G.GameTooltip, { id = 324 })
assert(#_G.GameTooltip._lines == 1 and _G.GameTooltip._lines[1].right == "#324")

-- Forbidden tooltip & Secret ID MUST be ignored cleanly (Zero-Taint!)
_G.GameTooltip._lines = {}
_G.GameTooltip._forbidden = true
__FS_FIRE_TOOLTIP(0, _G.GameTooltip, { id = 4242 })
assert(#_G.GameTooltip._lines == 0, "forbidden tooltip must NEVER be touched")
_G.GameTooltip._forbidden = false
__FS_FIRE_TOOLTIP(0, _G.GameTooltip, { id = FS_MakeSecret("item", "number") })
assert(#_G.GameTooltip._lines == 0, "secret item ID must NOT append lines")

-- Disabling ui.enhanceTooltips suppresses tooltip lines
ns.Api.ProfileStore:Set("ui", "enhanceTooltips", false)
__FS_FIRE_TOOLTIP(0, _G.GameTooltip, { id = 4242 })
assert(#_G.GameTooltip._lines == 0)
ns.Api.ProfileStore:Set("ui", "enhanceTooltips", true)

-- 3. Phase 2B Nit #1 + GLM Note #5: Persistent cameraZoomPrev survives simulated /reload AND restores even if v1 loads!
ns.Api.ProfileStore:Set("qol", "maxCameraZoom", true)
assert(_G.__FS_MOCK.cvars.cameraDistanceMaxZoomFactor == "2.6")
assert(ns.Api.ProfileStore:GetState("cameraZoomPrev") == "1.7", "pre-v2 camera CVar must persist in SavedVariables state")
-- Simulate /reload wiping in-memory field while v1 also loads
ns.Features.QoLModule.savedCameraZoom = nil
_G.__FS_MOCK.loadedAddOns["ForeverSuite"] = true
ns.Api.ProfileStore:Set("qol", "maxCameraZoom", false)
assert(_G.__FS_MOCK.cvars.cameraDistanceMaxZoomFactor == "1.7", "disabling maxCameraZoom must restore persisted 1.7 even after reload & v1 load")
assert(ns.Api.ProfileStore:GetState("cameraZoomPrev") == nil)
_G.__FS_MOCK.loadedAddOns["ForeverSuite"] = false

-- 4. Phase 2B Nit #2 & #3: Tri-state unreadable dead/ghost holds dungeon run; PLAYER_UNGHOST outside finalizes run!
_G.__FS_MOCK.inInstance = true
_G.__FS_MOCK.instanceType = "party"
_G.__FS_MOCK.instanceName = "통곡의 동굴"
__FS_FIRE_EVENT("ZONE_CHANGED_NEW_AREA")
assert(ns.Features.EncounterTimerHud.state.instance.name == "통곡의 동굴")

-- Unreadable (secret) UnitIsDeadOrGhost while outside -> MUST hold run!
_G.__FS_MOCK.inInstance = false
_G.__FS_MOCK.instanceType = "none"
_G.__FS_MOCK.deadOrGhost = FS_MakeSecret("dead", "boolean")
__FS_FIRE_EVENT("ZONE_CHANGED_NEW_AREA")
assert(ns.Features.EncounterTimerHud.state.instance ~= nil, "unreadable dead/ghost state must HOLD dungeon run")

-- Player revives outside (PLAYER_UNGHOST) -> cleanly finalizes held run!
_G.__FS_MOCK.deadOrGhost = false
__FS_FIRE_EVENT("PLAYER_UNGHOST")
assert(ns.Features.EncounterTimerHud.state.instance == nil, "PLAYER_UNGHOST outside dungeon must finalize held run")

-- 5. Phase 2B Nit #4: UnitExists(casterName) == false blocks auto-res fail-closed!
_G.__FS_MOCK.acceptedRes = 0
_G.__FS_MOCK.inCombat = false
_G.__FS_MOCK.affectingCombat = false
_G.__FS_MOCK.unitExists = { ["외부시전자"] = false }
__FS_FIRE_EVENT("RESURRECT_REQUEST", "외부시전자")
assert(_G.__FS_MOCK.acceptedRes == 0, "unresolvable caster (UnitExists == false) must fail closed")
_G.__FS_MOCK.unitExists = {}

-- 6. Standalone DiagnosticsPage: missing taintTotal shows "집계 없음", DoesAddOnExist == false returns NOT_INSTALLED cleanly
local origIsLoaded = C_AddOns.IsAddOnLoaded
C_AddOns.IsAddOnLoaded = function(name)
    if name == "ForeverSuite_GJBridge" then
        error("uninstalled_addon_error")
    end
    return origIsLoaded(name)
end
_G.__FS_MOCK.addonExists = { ForeverSuite_GJBridge = false }
assert(ns.Api.SafeAPI.GetAddOnPresenceState("ForeverSuite_GJBridge") == "NOT_INSTALLED")
assert(ns.Api.SafeAPI.IsV1Loaded() == false)
ns.UI.CommandHub:SelectPage("diagnostics")
assert(string.find(ns.Features.DiagnosticsPage.summaryLabel:GetText(), "버전: 3.0.1", 1, true))

-- Missing taintTotal displays "집계 없음" instead of fabricated "0건"
ns.Api.ProfileStore.db.v2.diagnostics.taintTotal = nil
ns.Features.DiagnosticsPage:OnShow()
assert(string.find(ns.Features.DiagnosticsPage.summaryLabel:GetText(), "Taint: 집계 없음", 1, true))
C_AddOns.IsAddOnLoaded = origIsLoaded
_G.__FS_MOCK.addonExists = {}

-- 7. /fs help and /fs clearway primary slash commands (plus /way)
_G.SlashCmdList["FOREVERSUITE"]("help")
assert(string.find(_G.__FS_MOCK.printed[#_G.__FS_MOCK.printed], "/way", 1, true))
_G.SlashCmdList["FOREVERSUITE"]("clearway")
assert(string.find(_G.__FS_MOCK.printed[#_G.__FS_MOCK.printed], "웨이포인트를 해제", 1, true))
