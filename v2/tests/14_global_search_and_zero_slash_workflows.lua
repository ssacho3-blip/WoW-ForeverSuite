-- Test 14: ForeverSuite v3.0 Phase 2 — Global Search Palette (synonym jump + inline toggle + 0MB LoD safe),
--          Zero-Slash Utilities (GDKP GUI, Bookmarks GUI, Chat Keywords/URL Modal, >12-row ScrollBar),
--          and Safe PartyFinder (2-step Whisper Draft + Hover Freeze).
local ns = _G.ForeverSuiteV2

_G.__FS_MOCK.playerPos = { mapID = 1453, x = 0.55, y = 0.42 }
_G.__FS_MOCK.zoneText = "스톰윈드"
_G.__FS_MOCK.level = 60
_G.__FS_MOCK.playerClass = "WARRIOR"
_G.__FS_MOCK.now = 5000

__FS_FIRE_EVENT("PLAYER_LOGIN")

local hub = ns.UI.CommandHub
hub:Toggle()

-- 1. Global Search Palette: synonym search "골드팟" jumps straight to Utilities GDKP tab (0MB LoD untouched!)
hub.searchBox:SetText("골드팟")
hub.searchBox:FireScript("OnTextChanged")
assert(hub.searchPalette ~= nil and hub.searchPalette:IsShown() == true, "Global search palette must open on input")
assert(#hub.paletteItems >= 1 and hub.paletteItems[1].pageId == "utilities" and hub.paletteItems[1].subTab == "gdkp", "Synonym '골드팟' must resolve to utilities/gdkp")
assert(_G.ForeverSuiteData == nil, "Global search MUST NEVER force-load LoD packs")

hub.paletteRows[1]:FireScript("OnClick", "LeftButton")
assert(hub.activePageId == "utilities" and ns.Features.UtilitiesPage.activeSub == "gdkp", "Clicking palette feature must jump to utilities/gdkp")
assert(hub.searchPalette:IsShown() == false, "Palette must close after jump")

-- 2. Global Search Palette: inline setting toggle ("시계" -> ui.showScreenClock)
assert(ns.Api.ProfileStore:Get("ui", "showScreenClock") == false)
hub.searchBox:SetText("시계")
hub.searchBox:FireScript("OnTextChanged")
local toggledIdx = nil
for i, it in ipairs(hub.paletteItems) do
    if it.kind == "setting" and it.key == "showScreenClock" then
        toggledIdx = i
        break
    end
end
assert(toggledIdx ~= nil, "Global search must find showScreenClock setting")
hub.paletteRows[toggledIdx]:FireScript("OnClick", "LeftButton")
assert(ns.Api.ProfileStore:Get("ui", "showScreenClock") == true, "Clicking boolean setting in palette must toggle live")
hub.searchBox:SetText("")
hub.searchBox:FireScript("OnTextChanged")
assert(hub.searchPalette:IsShown() == false, "Clearing search box must close palette")
ns.Api.ProfileStore:Set("ui", "showScreenClock", false)

-- 3. Zero-Slash Utilities: GDKP ActionInputBar starts live auction & closes it via GUI, >12 items scroll cleanly
local util = ns.Features.UtilitiesPage
util.gdkpSales = {}
for i = 1, 16 do
    ns.Domain.GdkpModel.AddSale(util.gdkpSales, "레이드 템 #" .. tostring(i), "유저" .. tostring(i), i * 100000)
end
util.scrollOffset = 0
util:Render("")
assert(util.scrollBar:IsShown() == true, "GDKP >10 sales must display ScrollBar (no 12-row truncation)")
local topBefore = util.rowPool[1]._left:GetText()
util.scrollBar:Step(4)
assert(util.rowPool[1]._left:GetText() ~= topBefore, "GDKP ScrollBar step must scroll sales list")

-- Start auction via ActionInputBar
util.gdkpInputBar:SetValue("item", "용암 망토")
util.gdkpInputBar:SetValue("gold", "200")
util.gdkpInputBar._submitBtn:FireScript("OnClick", "LeftButton")
assert(util.activeAuction ~= nil and util.activeAuction.item == "용암 망토", "GDKP ActionInputBar must start live auction without slash")
assert(util.gdkpMeta.banner:IsShown() == true, "Active auction banner must appear when OPEN")
-- Starting a second auction while OPEN must fail-closed without overwriting active auction
local dupOk, dupErr = util:StartGdkpAuctionDirect("두번째 템", 500)
assert(dupOk == false and dupErr == "AUCTION_OPEN" and util.activeAuction.item == "용암 망토", "Second GDKP auction while OPEN must fail-closed")
util:HandleGdkpCommand("cancel")
assert(util.activeAuction == nil and util.gdkpMeta.banner:IsShown() == false)

-- 4. Zero-Slash Bookmarks GUI
util:SelectSubTab("bookmarks")
util.bookmarks = {}
util.bookmarkInputBar:SetValue("label", "경매장 입구")
util.bookmarkInputBar._submitBtn:FireScript("OnClick", "LeftButton")
assert(#util.bookmarks == 1 and util.bookmarks[1].label == "경매장 입구", "Bookmark GUI must save current coords without /fs fav")

-- 5. Zero-Slash Chat URL opens CopyPasteModal
util:SelectSubTab("chat")
ns.Features.ChatToolsModule.history = {
    { channel = "SAY", sender = "안내원", text = "공략 https://example.com/guide 확인", urls = { "https://example.com/guide" } },
}
util:Render("")
util.rowPool[1]:FireScript("OnClick", "LeftButton")
local modal = ns.UI.Widgets.CopyPasteModal()
assert(modal:IsShown() == true and modal._box:GetText() == "https://example.com/guide", "Clicking URL row must open CopyPasteModal")
modal:Hide()

-- 6. Safe PartyFinder: 2-step whisper (row click NEVER auto-sends; draft button opens chat box) + Hover Freeze
hub:SelectPage("partyfinder")
local pf = ns.Features.PartyFinderPage
pf.board = {}
_G.__FS_MOCK.sentChats = {}
_G.__FS_MOCK.openedChats = {}
pf:IngestChatMessage("화심 공대 탱커 구함 귓주세요", "공대장A", "CHANNEL")
assert(#pf.board == 1)

-- Row click selects listing without auto-sending whisper!
pf.rows[1]:FireScript("OnClick", "LeftButton")
assert(#_G.__FS_MOCK.sentChats == 0, "Row click in PartyFinder MUST NOT auto-send whisper!")
assert(pf.selectedListing ~= nil and pf.selectedListing.sender == "공대장A")
assert(pf.draftBtn:IsShown() == true)

-- Draft button opens safe `/w` chat input
pf.draftBtn:FireScript("OnClick", "LeftButton")
assert(#_G.__FS_MOCK.openedChats == 1 and string.find(_G.__FS_MOCK.openedChats[1], "/w 공대장A ", 1, true) ~= nil, "Draft button must open safe whisper draft")
assert(#_G.__FS_MOCK.sentChats == 0, "Draft button must NOT auto-send whisper")

-- Hover Freeze: row1->row2 transition & row click MUST stay frozen without shifting rows; expiry blocks whisper!
pf.rows[1]:FireScript("OnEnter")
assert(pf.hoverFrozen == true)
pf:IngestChatMessage("오닉시아 힐러 구함", "공대장B", "CHANNEL")
assert(pf.pendingUpdates == 1 and pf.freezeLbl:IsShown() == true, "Hover Freeze must hold new listings and show badge")
-- Row click while frozen must NOT pull in 공대장B
pf.rows[1]:FireScript("OnClick", "LeftButton")
assert(pf.rows[2]:IsShown() == false, "Row click during hover freeze must keep frozen snapshot")
-- Pointer moving row1 -> row2 must NOT flush before row2 enter cancels the leave timer
pf.rows[1]:FireScript("OnLeave")
pf.rows[2]:FireScript("OnEnter")
__FS_FLUSH_AFTER_TIMERS()
assert(pf.hoverFrozen == true and pf.pendingUpdates == 1, "Pointer moving between rows must stay frozen")
-- Pointer actually leaving list flushes pending listings
pf.rows[2]:FireScript("OnLeave")
__FS_FLUSH_AFTER_TIMERS()
assert(pf.hoverFrozen == false and pf.pendingUpdates == 0, "Mouse leave must unfreeze and flush pending listings")

-- Expired selection MUST be rejected before whisper!
pf:SelectListing(pf.board[1])
_G.__FS_MOCK.now = 5000 + 700 -- >10 min expiry
_G.__FS_MOCK.openedChats = {}
pf.draftBtn:FireScript("OnClick", "LeftButton")
assert(#_G.__FS_MOCK.openedChats == 0 and pf.selectedListing == nil, "Expired party listing must fail-closed on whisper draft")

-- CopyPasteModal Enter key submits import cleanly without non-existent WoW FireScript method
local impModal = ns.UI.Widgets.CopyPasteModal()
local gotText = nil
impModal:OpenImport("테스트", "안내", function(t) gotText = t; return true, "OK" end, "FS2:ABC")
impModal._box:FireScript("OnEnterPressed")
assert(gotText == "FS2:ABC", "CopyPasteModal Enter key must invoke import callback cleanly")
impModal:Hide()

-- Secret numeric IDs MUST NOT throw Lua errors in GetItemIconSafe / GetSpellIconSafe / GetItemLinkSafe / OpenWhisperDraftSafe
assert(ns.Api.GameAdapters.GetItemIconSafe(FS_MakeSecret("item", "number")) == nil, "Secret itemID must fail-closed nil")
assert(ns.Api.GameAdapters.GetSpellIconSafe(FS_MakeSecret("spell", "number")) == nil, "Secret spellID must fail-closed nil")
assert(ns.Api.GameAdapters.GetItemLinkSafe(FS_MakeSecret("item", "number"), "test") == nil, "Secret itemID link must fail-closed nil")
local wOk, wErr = ns.Api.GameAdapters.OpenWhisperDraftSafe("공대장A", FS_MakeSecret("txt", "string"))
assert(wOk == false and wErr == "SECRET_TEXT", "Secret prefillText must fail-closed")

-- GDKP GUI buyer field with spaces MUST be rejected cleanly instead of silently mangling item name
local utilOk, utilErr = util:AddGdkpSaleDirect("용암 망토", "Alice Bob", 500)
assert(utilOk == false and utilErr == "INVALID_BUYER", "Buyer containing whitespace must be rejected cleanly")

-- CommandHub searchBox live-filters active PartyFinderPage alongside Global Search Palette
_G.__FS_MOCK.now = 6000
pf.board = {}
pf:IngestChatMessage("화심 공대 탱커 구함", "공대장X", "CHANNEL")
pf:IngestChatMessage("오닉시아 힐러 구함", "공대장Y", "CHANNEL")
hub:SelectPage("partyfinder")
hub.searchBox:SetText("오닉시아")
hub.searchBox:FireScript("OnTextChanged")
assert(pf.rows[1]:IsShown() == true and pf.rows[2]:IsShown() == false, "Hub search must live-filter active PartyFinderPage")
hub.searchBox:SetText("")
hub.searchBox:FireScript("OnTextChanged")
