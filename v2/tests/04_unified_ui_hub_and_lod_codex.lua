-- Test 04: Unified Obsidian-Gold UI, 9-Anchor Clamped Dock, Live StatusPill/QuestLog, Read-Only Rollback & LoD Codex
local ns = _G.ForeverSuiteV2

_G.__FS_MOCK.questEntries = {
    { isHeader = true, title = "서부 몰락지대" },
    { isHeader = false, questID = 101, title = "밴클리프 처치", level = 22 },
}
_G.__FS_MOCK.questComplete = { [101] = true }
_G.__FS_MOCK.questSpecialItems = { [2] = { "|Hitem:5501|h[데피아즈 신호탄]|h", 133710 } }
_G.__FS_MOCK.bagFreeSlots = 12
_G.__FS_MOCK.money = 50000

__FS_FIRE_EVENT("PLAYER_LOGIN")

-- 1. Media typography objects created and bound
assert(_G.FS_Font_Title ~= nil and _G.FS_Font_Body ~= nil and _G.FS_Font_Mono ~= nil)
assert(ns.UI.Tokens.GetFont("title") == "FS_Font_Title")

-- 2. Live QuestLog -> RefreshLive -> QuestItemDock slot 1 + C_QuestLog.IsComplete + EventBus error forwarding
assert(ns.Features.QuestTrackerView.lastSnapshot.questCount == 1)
assert(ns.Features.QuestTrackerView.lastSnapshot.rows[2].isComplete == true, "must use C_QuestLog.IsComplete")
assert(_G.ForeverSuiteV2QuestItemSlot1:GetAttribute("item") == "|Hitem:5501|h[데피아즈 신호탄]|h", "live quest special item must bind to QuestItemDock slot 1")
assert(string.find(ns.Features.StatusPillHud.label:GetText(), "가방 60칸", 1, true)) -- 5 bags * 12

-- EventBus forwards handler errors to geterrorhandler()
ns.Api.EventBus:Subscribe("test:err", function() error("deliberate_err") end)
ns.Api.EventBus:Publish("test:err")
assert(#_G.__FS_MOCK.errorsForwarded == 1 and string.find(_G.__FS_MOCK.errorsForwarded[1], "deliberate_err", 1, true))
_G.__FS_MOCK.money = 65000
__FS_FIRE_EVENT("PLAYER_MONEY")
assert(string.find(ns.Features.StatusPillHud.label:GetText(), "1g 50s 00c", 1, true))
ns.Features.StatusPillHud:Refresh(nil, nil)
assert(string.find(ns.Features.StatusPillHud.label:GetText(), "가방 집계 없음", 1, true))
assert(string.find(ns.Features.StatusPillHud.label:GetText(), "골드 집계 없음", 1, true))

-- 3. Parametrized 9-anchor test: QuestItemDock NEVER goes off-screen for any of the 9 WoW anchor points!
local all9 = {
    { point = "TOPLEFT", x = 20, y = -20 },
    { point = "TOP", x = 0, y = -20 },
    { point = "TOPRIGHT", x = -20, y = -20 },
    { point = "LEFT", x = 20, y = 0 },
    { point = "CENTER", x = 0, y = 0 },
    { point = "RIGHT", x = -20, y = 0 },
    { point = "BOTTOMLEFT", x = 20, y = 20 },
    { point = "BOTTOM", x = 0, y = 20 },
    { point = "BOTTOMRIGHT", x = -20, y = 20 },
}
for _, a in ipairs(all9) do
    ns.Features.QuestTrackerView:SyncDockAnchor(a)
    local da = ns.Secure.QuestItemDock.anchor
    assert(da.relPoint == "BOTTOMLEFT", "Dock must use canonical BOTTOMLEFT")
    assert(da.x >= 40 and da.x <= 1880, "Dock x out of bounds for " .. a.point .. ": " .. tostring(da.x))
    assert(da.y >= 238 and da.y <= 1064, "Dock y out of bounds for " .. a.point .. ": " .. tostring(da.y))
end

-- 4. HudLayout drag overlay saves snapped coordinates
ns.UI.HudLayout:SetUnlocked(true)
local rec = ns.UI.HudLayout.registry["questTracker"]
rec.frame:ClearAllPoints()
rec.frame:SetPoint("TOPRIGHT", _G.UIParent, "TOPRIGHT", -51, -101)
rec.overlay:FireScript("OnDragStop")
local saved = ns.Api.ProfileStore:GetLayout("questTracker")
assert(saved.x == -52 and saved.y == -100)
ns.UI.HudLayout:ResetAll()

-- 5. /fs2 Command Hub, live showStatusPill setting, Read-Only toggle rollback, and honest status bar
assert(_G.ForeverSuiteData == nil, "ForeverSuite_Data must NOT be loaded at login")
local origLoad = C_AddOns.LoadAddOn
C_AddOns.LoadAddOn = function(name)
    if name == "ForeverSuite_Data" then
        local loaded = __FS_LOAD_DATA_ADDON()
        _G.__FS_MOCK.loadedAddOns[name] = loaded
        return loaded, nil
    end
    return origLoad(name)
end

_G.SlashCmdList["FOREVERSUITEV2"]("")
local hub = ns.UI.CommandHub
assert(hub.window ~= nil and hub.window:IsShown() == true)
hub.searchBox._focused = true
hub.searchBox:FireScript("OnEscapePressed")
assert(hub.searchBox._focused == false)

-- Live consumer for ui.showStatusPill
ns.Api.ProfileStore:Set("ui", "showStatusPill", false)
assert(ns.Features.StatusPillHud.card:IsShown() == false)
ns.Api.ProfileStore:Set("ui", "showStatusPill", true)
assert(ns.Features.StatusPillHud.card:IsShown() == true)

-- Pooled SettingsPage + read-only rollback on Toggle
hub:SelectPage("settings")
local framesBeforeSearch = #_G.__FS_MOCK.frames
hub.pages["settings"]:OnSearch("추적기")
hub.pages["settings"]:OnSearch("")
assert(#_G.__FS_MOCK.frames == framesBeforeSearch)

-- Read-only mode rolls back Toggle click and renders honest status bar
ns.Api.ProfileStore.readOnly = true
local pillToggle = ns.Features.SettingsPage.builtItems[2].main
assert(pillToggle._checked == true)
pillToggle:FireScript("OnClick")
assert(pillToggle._checked == true, "Toggle must roll back when ProfileStore:Set fails in read-only")
hub:RefreshStatusBar()
assert(string.find(hub.statusLabel:GetText(), "집계 없음", 1, true))
ns.Api.ProfileStore.readOnly = false

-- 6. Pooled CodexPage lazy-loads ForeverSuite_Data and reports honest missing-pack state
hub:SelectPage("codex")
assert(type(_G.ForeverSuiteData) == "table" and ns.Features.CodexPage.visibleRows >= 1)
local framesAfterCodex = #_G.__FS_MOCK.frames
hub.pages["codex"]:OnSearch("뱀장어")
hub.pages["codex"]:OnSearch("")
assert(#_G.__FS_MOCK.frames == framesAfterCodex)
ns.Features.CodexPage.activePack = "unbuilt_pack"
ns.Features.CodexPage:RenderPack("")
assert(ns.Features.CodexPage.visibleRows == 0)

-- 7. Taint canary records BOTH BLOCKED and FORBIDDEN safely with Secret payloads
__FS_FIRE_EVENT("ADDON_ACTION_BLOCKED", FS_MakeSecret("a", "string"), "ProtectedFn")
__FS_FIRE_EVENT("ADDON_ACTION_FORBIDDEN", "GodJohnsonGoldBorder", "Show")
assert(ns.Api.ProfileStore.db.v2.diagnostics.taintTotal == 2)
