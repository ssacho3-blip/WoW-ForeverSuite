-- Module: Features/QuestTrackerView.lua
-- Responsibility: Full Obsidian & Burnished Gold Quest Tracker Card (zone/level grouping, filters, collapse,
--                 18-row mouse-wheel viewport, 6-state accent bars, hover tooltips, Ctrl own detail card,
--                 combat alpha fade, QuestItemDock 1..6 sibling sync, and NavPort).
-- Layer: Features (uses UI/Widgets only; zero raw CreateFrame; zero SetSelectedQuest; zero Dock mutation in combat).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local type = type
local math_max = math.max

local TRACKER_WIDTH = 340
local HEADER_HEIGHT = 30
local BODY_TOP_PAD = 4
local ROW_HEIGHT = 22
local FOOTER_HEIGHT = 18
local PADDING_X = 6
local PADDING_BOTTOM = 6
local MAX_VISIBLE_ROWS = 18

-- Airy GodJohnson / Kaliel's Tracker aesthetic:
-- Left-to-right gradient fade-out zone banners + transparent floating quest & objective rows (zero opaque spreadsheet feel!)
local ROW_THEMES = {
    group_current  = { bg = { 1.00, 0.90, 0.62, 0.92 }, accent = { 0.96, 0.80, 0.30, 1.00 }, ax = 0, aw = 3, sep = { 0.72, 0.56, 0.20, 0.42 }, pad = 10, tc = T.TEXT.GOLD, rc = T.TEXT.GOLD, fadeRight = true, useZoneRibbon = true },
    group_other    = { bg = { 0.78, 0.76, 0.82, 0.74 }, accent = { 0.55, 0.66, 0.84, 0.82 }, ax = 0, aw = 2, sep = { 0.32, 0.28, 0.20, 0.32 }, pad = 10, tc = T.TEXT.PRIMARY, rc = T.TEXT.SECONDARY, fadeRight = true, useZoneRibbon = true },
    quest_super    = { bg = { 0.28, 0.21, 0.05, 0.42 }, accent = { 0.98, 0.83, 0.28, 1.00 }, ax = 0, aw = 3, sep = nil, pad = 10, tc = T.TEXT.GOLD, rc = T.TEXT.GOLD, fadeRight = true },
    quest_complete = { bg = { 0.05, 0.20, 0.10, 0.30 }, accent = { 0.29, 0.87, 0.50, 0.92 }, ax = 0, aw = 2, sep = nil, pad = 10, tc = T.SEMANTIC.SUCCESS, rc = T.SEMANTIC.SUCCESS, fadeRight = true },
    quest_failed   = { bg = { 0.26, 0.06, 0.07, 0.34 }, accent = { 0.97, 0.44, 0.44, 0.95 }, ax = 0, aw = 2, sep = nil, pad = 10, tc = T.SEMANTIC.DANGER, rc = T.SEMANTIC.DANGER, fadeRight = true },
    quest_active   = { bg = { 0.04, 0.04, 0.05, 0.14 }, accent = { 0.55, 0.66, 0.84, 0.72 }, ax = 0, aw = 2, sep = nil, pad = 10, tc = T.TEXT.PRIMARY, rc = T.TEXT.SECONDARY, fadeRight = true },
    obj_done       = { bg = { 0.00, 0.00, 0.00, 0.00 }, accent = { 0.24, 0.66, 0.40, 0.55 }, ax = 8, aw = 2, sep = nil, pad = 16, tc = T.SEMANTIC.SUCCESS, rc = T.TEXT.MUTED },
    obj_progress   = { bg = { 0.00, 0.00, 0.00, 0.00 }, accent = { 0.96, 0.76, 0.24, 0.72 }, ax = 8, aw = 2, sep = nil, pad = 16, tc = T.SEMANTIC.WARN, rc = T.TEXT.MUTED },
    obj_pending    = { bg = { 0.00, 0.00, 0.00, 0.00 }, accent = { 0.34, 0.32, 0.28, 0.42 }, ax = 8, aw = 2, sep = nil, pad = 16, tc = T.TEXT.PRIMARY, rc = T.TEXT.MUTED },
    empty          = { bg = { 0.00, 0.00, 0.00, 0.00 }, accent = nil, ax = 0, aw = 0, sep = nil, pad = 10, tc = T.TEXT.MUTED, rc = T.TEXT.MUTED },
}

local QuestTrackerView = {
    container = nil,
    headerBar = nil,
    titleLbl = nil,
    btnGroupMode = nil,
    btnZoneFilter = nil,
    btnLock = nil,
    btnMinimize = nil,
    scrollHint = nil,
    scrollBar = nil,
    detailCard = nil,
    rowPool = {},
    scrollOffset = 0,
    lastSnapshot = nil,
    lastQuests = nil,
    lastOpts = nil,
    currentHeight = HEADER_HEIGHT + 40,
    _needsPostCombatReRender = false,
    _pendingDockAnchor = nil,
}
ns.Features.QuestTrackerView = QuestTrackerView

local function GetSetting(key, fallback)
    local v = ns.Api.ProfileStore and ns.Api.ProfileStore:Get("quest", key)
    if v == nil then return fallback end
    return v
end

local function SetSetting(key, val)
    if ns.Api.ProfileStore then
        return ns.Api.ProfileStore:Set("quest", key, val)
    end
    return false
end

local function CopyMap(src)
    local dst = {}
    if type(src) == "table" then
        for k, v in pairs(src) do dst[k] = v end
    end
    return dst
end

local function GetStateMap(stateKey)
    local raw = ns.Api.ProfileStore and ns.Api.ProfileStore:GetState(stateKey)
    return CopyMap(raw)
end

local function SaveStateMap(stateKey, tbl)
    if ns.Api.ProfileStore then
        return ns.Api.ProfileStore:SetState(stateKey, tbl)
    end
    return false
end

local function ComputeRectFromAnchor(anchor, screenW, screenH, height)
    local h = height or 360
    local pt = (anchor and anchor.point) or "TOPRIGHT"
    local x = (anchor and anchor.x) or 0
    local y = (anchor and anchor.y) or 0
    local left, top
    if pt == "TOPLEFT" then
        left, top = x, screenH + y
    elseif pt == "TOP" then
        left, top = (screenW - TRACKER_WIDTH) * 0.5 + x, screenH + y
    elseif pt == "TOPRIGHT" then
        left, top = screenW + x - TRACKER_WIDTH, screenH + y
    elseif pt == "LEFT" then
        left, top = x, (screenH + h) * 0.5 + y
    elseif pt == "CENTER" then
        left, top = (screenW - TRACKER_WIDTH) * 0.5 + x, (screenH + h) * 0.5 + y
    elseif pt == "RIGHT" then
        left, top = screenW + x - TRACKER_WIDTH, (screenH + h) * 0.5 + y
    elseif pt == "BOTTOMLEFT" then
        left, top = x, y + h
    elseif pt == "BOTTOM" then
        left, top = (screenW - TRACKER_WIDTH) * 0.5 + x, y + h
    else
        left, top = screenW + x - TRACKER_WIDTH, y + h
    end
    return left, left + TRACKER_WIDTH, top
end

function QuestTrackerView:SyncDockAnchor(anchor)
    -- Invariant I2: NEVER mutate QuestItemDock anchor while in combat; queue exact anchor for OOC flush
    if ns.Api.SafeAPI.InCombat() then
        self._pendingDockAnchor = anchor or true
        self._needsPostCombatReRender = true
        return
    end
    self._pendingDockAnchor = nil
    local screenW = (_G.UIParent and _G.UIParent.GetWidth and _G.UIParent:GetWidth()) or 1920
    local screenH = (_G.UIParent and _G.UIParent.GetHeight and _G.UIParent:GetHeight()) or 1080
    local scaleRatio = 1.0
    if self.container then
        local uiScale = (_G.UIParent and type(_G.UIParent.GetEffectiveScale) == "function") and _G.UIParent:GetEffectiveScale() or 1.0
        local cScale = (type(self.container.GetEffectiveScale) == "function") and self.container:GetEffectiveScale() or 1.0
        if type(uiScale) == "number" and uiScale > 0 and type(cScale) == "number" and cScale > 0 then
            scaleRatio = cScale / uiScale
        end
        if scaleRatio == 1.0 and type(self.container._fsHudScale) == "number" and self.container._fsHudScale > 0 then
            scaleRatio = self.container._fsHudScale
        end
    end
    local left, right, top
    if self.container and type(self.container.GetLeft) == "function" then
        local l = self.container:GetLeft()
        local r = self.container:GetRight()
        local t = self.container:GetTop()
        if type(l) == "number" and type(r) == "number" and type(t) == "number" then
            left, right, top = l * scaleRatio, r * scaleRatio, t * scaleRatio
        end
    end
    if not left then
        local a = type(anchor) == "table" and anchor or nil
        local s = (a and tonumber(a.scale)) or scaleRatio or 1.0
        local scaledAnchor = a and { point = a.point, relPoint = a.relPoint, x = (a.x or 0) * s, y = (a.y or 0) * s } or nil
        left, right, top = ComputeRectFromAnchor(scaledAnchor, screenW, screenH, (self.currentHeight or 100) * s)
        if s ~= 1.0 then
            local wScaled = TRACKER_WIDTH * s
            if a and (a.point == "TOPRIGHT" or a.point == "RIGHT" or a.point == "BOTTOMRIGHT") then
                left = right - wScaled
            else
                right = left + wScaled
            end
        end
    end
    ns.Secure.QuestItemDock:SetAnchorFromRect(left, right, top, screenW, screenH)
end

-- Own Zero-Taint Quest Detail Card (Contract C2: NEVER calls QuestMapFrame_OpenToQuestDetails or SetSelectedQuest)
function QuestTrackerView:ShowDetailCard(item)
    if type(item) ~= "table" or type(item.questID) ~= "number" then
        return false
    end
    if not self.detailCard then
        local card = W.PopupCard(_G.UIParent, 340, 220, "ForeverSuiteQuestDetailCard", T.ELEVATION.L2_HUB)
        W.MakeDraggable(card, "questDetailCard", { point = "CENTER", relPoint = "CENTER", x = 0, y = 40 })
        local title = W.Label(card, "", "heading", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
        title:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -10)
        title:SetPoint("TOPRIGHT", card, "TOPRIGHT", -36, -10)
        local closeBtn = W.MiniButton(card, "×", 22, 20, function() card:Hide() end, "닫기")
        closeBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", -8, -8)
        local meta = W.Label(card, "", "small", T.TEXT.SECONDARY, { justifyH = "LEFT", wordWrap = false })
        meta:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -32)
        meta:SetPoint("TOPRIGHT", card, "TOPRIGHT", -12, -32)
        local body = W.Label(card, "", "body", T.TEXT.PRIMARY, { justifyH = "LEFT", wordWrap = true })
        if type(body.SetJustifyV) == "function" then body:SetJustifyV("TOP") end
        body:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -54)
        body:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -12, 38)
        local trackBtn = W.Button(card, "★ 길안내·포커스", 132, 24, function()
            local qid = card._questID
            if type(qid) == "number" and qid > 0 then
                local cur = ns.Api.SafeAPI.GetSuperTrackedQuestID()
                local nextQID = (cur == qid) and 0 or qid
                ns.Api.NavPort.RequestSuperTrack(nextQID)
                if ns.Features.NavigationHud and type(ns.Features.NavigationHud.TrackQuest) == "function" then
                    ns.Features.NavigationHud:TrackQuest(nextQID, card._title and card._title:GetText() or nil, { allowLoadPacks = true, explicit = true })
                end
            end
        end, true)
        trackBtn:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 12, 8)
        local linkBtn = W.Button(card, "채팅 링크", 84, 24, function()
            if type(card._questID) == "number" then
                ns.Api.GameAdapters.InsertQuestChatLink(card._questID)
            end
        end)
        linkBtn:SetPoint("LEFT", trackBtn, "RIGHT", 8, 0)
        card._title = title
        card._meta = meta
        card._body = body
        if type(_G.UISpecialFrames) == "table" then
            local found = false
            for i = 1, #_G.UISpecialFrames do
                if _G.UISpecialFrames[i] == "ForeverSuiteQuestDetailCard" then
                    found = true
                    break
                end
            end
            if not found then
                _G.UISpecialFrames[#_G.UISpecialFrames + 1] = "ForeverSuiteQuestDetailCard"
            end
        end
        self.detailCard = card
    end

    local card = self.detailCard
    card._questID = item.questID
    card._title:SetText(tostring(item.rawTitle or item.title or ("퀘스트 #" .. tostring(item.questID))))
    if type(item.difficultyColor) == "table" then
        card._title:SetTextColor(item.difficultyColor[1], item.difficultyColor[2], item.difficultyColor[3], 1)
    else
        card._title:SetTextColor(T.TEXT.GOLD[1], T.TEXT.GOLD[2], T.TEXT.GOLD[3], 1)
    end
    local statusTxt = item.isComplete and "완료 가능" or (item.isFailed and "실패" or "진행 중")
    card._meta:SetText(
        "ID #" .. tostring(item.questID) .. " · " .. tostring(item.zone or "기타")
        .. (item.level and item.level > 0 and (" · Lv." .. tostring(item.level)) or "")
        .. " · " .. statusTxt
    )
    local lines = {}
    for _, obj in ipairs(item.objectives or {}) do
        local mark = obj.finished and "[V] " or "[ ] "
        lines[#lines + 1] = mark .. tostring(obj.text or "")
    end
    if #lines == 0 then
        lines[1] = "세부 목표가 없거나 NPC에게 바로 보고할 수 있습니다."
    end
    if ns.Features.QuestExtraModule then
        local partyTxt = ns.Features.QuestExtraModule:GetPartySummaryForQuest(item.questID)
        if type(partyTxt) == "string" and partyTxt ~= "" then
            lines[#lines + 1] = "\n[파티원 진행] " .. partyTxt
        end
        local routeRec = ns.Features.QuestExtraModule:GetDialogueRouteForQuest(item.questID)
        if type(routeRec) == "table" and type(routeRec.title) == "string" and routeRec.title ~= "" then
            lines[#lines + 1] = "[보고/대화 루트] " .. routeRec.title
        end
    end
    card._body:SetText(table.concat(lines, "\n"))
    card:Show()
    return true
end

function QuestTrackerView:UpdateCombatVisuals(inCombatOverride)
    if not self.container then
        return
    end
    local inCombat
    if inCombatOverride ~= nil then
        inCombat = (inCombatOverride == true)
    else
        inCombat = ns.Api.SafeAPI.InCombat()
    end
    local fadeEnabled = GetSetting("combatFade", true) ~= false
    -- Invariant I2: Combat fade mutates ONLY the card's SetAlpha (never touches QuestItemDock)
    self.container:SetAlpha((inCombat and fadeEnabled) and 0.35 or 1.0)
end

function QuestTrackerView:SyncToolbarLabels()
    if not self.btnGroupMode then return end
    local gm = ns.Domain.QuestTrackerModel.NormalizeGroupMode(GetSetting("groupMode", "zone"))
    local cz = GetSetting("currentZoneOnly", false) == true
    local lk = GetSetting("trackerLocked", false) == true
    local mn = GetSetting("trackerMinimized", false) == true
    self.btnGroupMode:SetLabel(gm == "level" and "레벨" or "지역")
    self.btnGroupMode:SetActive(gm == "level")
    self.btnZoneFilter:SetActive(cz)
    self.btnLock:SetLabel(lk and "잠김" or "이동")
    self.btnLock:SetActive(lk)
    if self.container and type(self.container.SetMovable) == "function" then
        local hudEdit = ns.UI.HudLayout and ns.UI.HudLayout:IsUnlocked()
        self.container:SetMovable(hudEdit or (not lk))
    end
    self.btnMinimize:SetLabel(mn and "+" or "-")
    self.btnMinimize:SetActive(mn)
    if self.btnMinimize._atlasTex then
        local atlas = mn and "ui-questtrackerbutton-expand-all" or "ui-questtrackerbutton-collapse-all"
        if T.TrySetAtlas and T.TrySetAtlas(self.btnMinimize._atlasTex, atlas, false) then
            self.btnMinimize._atlasTex:Show()
            self.btnMinimize._label:Hide()
        else
            self.btnMinimize._atlasTex:Hide()
            self.btnMinimize._label:Show()
        end
    end
end

function QuestTrackerView:ToggleGroupMode()
    local cur = ns.Domain.QuestTrackerModel.NormalizeGroupMode(GetSetting("groupMode", "zone"))
    local nextMode = (cur == "level") and "zone" or "level"
    if SetSetting("groupMode", nextMode) then
        self.scrollOffset = 0
        self:RefreshLive()
    end
end

function QuestTrackerView:ToggleCurrentZoneFilter()
    local cur = GetSetting("currentZoneOnly", false) == true
    if SetSetting("currentZoneOnly", not cur) then
        self.scrollOffset = 0
        self:RefreshLive()
    end
end

function QuestTrackerView:ToggleLocked()
    local cur = GetSetting("trackerLocked", false) == true
    if SetSetting("trackerLocked", not cur) then
        self:SyncToolbarLabels()
    end
end

function QuestTrackerView:ToggleMinimized()
    local cur = GetSetting("trackerMinimized", false) == true
    if SetSetting("trackerMinimized", not cur) then
        self:RefreshLive()
    end
end

function QuestTrackerView:ScrollBy(delta)
    if not self.lastSnapshot then
        return
    end
    local step = (delta and delta > 0) and -2 or 2
    local nextOff = ns.Domain.QuestTrackerModel.ClampScrollOffset(
        self.scrollOffset + step,
        self.lastSnapshot.totalRows,
        MAX_VISIBLE_ROWS
    )
    if nextOff ~= self.scrollOffset then
        self.scrollOffset = nextOff
        if self.lastQuests then
            self:Render(self.lastQuests, nil)
        else
            self:RefreshLive()
        end
    end
end

function QuestTrackerView:Init()
    if self.container then
        return self.container
    end
    -- v5.0 Airy Borderless Quest Tracker (GodJohnson / Kaliel's aesthetic: zero outer boxy frame!)
    local box = W.HudFloating(_G.UIParent, TRACKER_WIDTH, HEADER_HEIGHT + 44, "ForeverSuiteV2QuestTracker", T.ELEVATION.L1_CARD)
    local scrim = box:CreateTexture(nil, "BACKGROUND", nil, -5)
    scrim:SetAllPoints(box)
    scrim:SetColorTexture(T.SURFACE.HUD_SCRIM[1], T.SURFACE.HUD_SCRIM[2], T.SURFACE.HUD_SCRIM[3], T.SURFACE.HUD_SCRIM[4])
    box._fsBg = scrim
    box:SetClampedToScreen(true)
    if type(box.EnableMouseWheel) == "function" then
        box:EnableMouseWheel(true)
    end
    box:SetScript("OnMouseWheel", function(_, delta)
        QuestTrackerView:ScrollBy(delta)
    end)

    -- Sculpted zone-ribbon header bar (direct drag when unlocked)
    local hdr = W.HudGlass(box, TRACKER_WIDTH - 2, HEADER_HEIGHT, nil, nil, {
        bg = { 0.085, 0.072, 0.055, 0.78 },
        border = { 0.65, 0.50, 0.20, 0.45 },
    })
    hdr:SetPoint("TOPLEFT", box, "TOPLEFT", 1, -1)
    hdr:SetPoint("TOPRIGHT", box, "TOPRIGHT", -1, -1)
    if type(hdr.EnableMouse) == "function" then hdr:EnableMouse(true) end
    if type(hdr.RegisterForDrag) == "function" then hdr:RegisterForDrag("LeftButton") end
    hdr:SetScript("OnDragStart", function()
        if GetSetting("trackerLocked", false) == true then return end
        if ns.Api.SafeAPI.InCombat() then return end
        if type(box.SetMovable) == "function" then box:SetMovable(true) end
        if type(box.StartMoving) == "function" then box:StartMoving() end
    end)
    hdr:SetScript("OnDragStop", function()
        if type(box.StopMovingOrSizing) == "function" then box:StopMovingOrSizing() end
        if GetSetting("trackerLocked", false) ~= true and ns.UI.HudLayout then
            ns.UI.HudLayout:SaveCurrentPosition("questTracker")
        end
    end)

    local title = W.Label(hdr, "★ 퀘스트 (0)", "heading", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false, outline = "OUTLINE" })
    title:SetPoint("LEFT", hdr, "LEFT", 8, 0)

    local btnMin = W.MiniButton(hdr, "-", 22, 20, function()
        QuestTrackerView:ToggleMinimized()
    end, "퀘스트 추적기 접기 / 펼치기", { ghost = true })
    btnMin:SetPoint("RIGHT", hdr, "RIGHT", -6, 0)
    local minAtlas = btnMin:CreateTexture(nil, "ARTWORK")
    minAtlas:SetSize(14, 14)
    minAtlas:SetPoint("CENTER", btnMin, "CENTER", 0, 0)
    minAtlas:Hide()
    btnMin._atlasTex = minAtlas

    local btnLock = W.MiniButton(hdr, "이동", 36, 20, function()
        QuestTrackerView:ToggleLocked()
    end, "추적기 위치 잠금 / 해제", { ghost = true })
    btnLock:SetPoint("RIGHT", btnMin, "LEFT", -4, 0)

    local btnZone = W.MiniButton(hdr, "현지역", 46, 20, function()
        QuestTrackerView:ToggleCurrentZoneFilter()
    end, "현재 지역 퀘스트만 표시", { ghost = true })
    btnZone:SetPoint("RIGHT", btnLock, "LEFT", -4, 0)

    local btnMode = W.MiniButton(hdr, "지역", 36, 20, function()
        QuestTrackerView:ToggleGroupMode()
    end, "정렬 기준 전환 (지역별 / 레벨별)", { ghost = true })
    btnMode:SetPoint("RIGHT", btnZone, "LEFT", -4, 0)

    title:SetPoint("RIGHT", btnMode, "LEFT", -6, 0)

    local hint = W.Label(box, "", "small", T.TEXT.MUTED, { justifyH = "CENTER", wordWrap = false })
    hint:SetPoint("BOTTOMLEFT", box, "BOTTOMLEFT", 6, 4)
    hint:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -6, 4)
    hint:Hide()

    local sb = W.ScrollBar(box, 120, function(newOff)
        QuestTrackerView.scrollOffset = newOff
        if QuestTrackerView.lastQuests then
            QuestTrackerView:Render(QuestTrackerView.lastQuests, nil)
        else
            QuestTrackerView:RefreshLive()
        end
    end)
    sb:SetPoint("TOPRIGHT", box, "TOPRIGHT", -2, -(HEADER_HEIGHT + BODY_TOP_PAD))
    sb:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -2, FOOTER_HEIGHT + PADDING_BOTTOM)

    self.container = box
    self.headerBar = hdr
    self.titleLbl = title
    self.btnGroupMode = btnMode
    self.btnZoneFilter = btnZone
    self.btnLock = btnLock
    self.btnMinimize = btnMin
    self.scrollHint = hint
    self.scrollBar = sb

    ns.UI.HudLayout:Register("questTracker", box, {
        point = "TOPRIGHT",
        relPoint = "TOPRIGHT",
        x = -24,
        y = -272,
    }, "퀘스트 추적기", function(anchor)
        QuestTrackerView:SyncDockAnchor(anchor)
    end)

    self:SyncToolbarLabels()
    self:UpdateCombatVisuals()
    return box
end

function QuestTrackerView:OnRowClick(rowBtn, mouseBtn)
    local item = rowBtn and rowBtn._rowData
    if type(item) ~= "table" then
        return
    end

    if item.kind == "overflow" then
        SetSetting("compactMode", false)
        self:RefreshLive()
        return
    end

    if item.kind == "header" and item.groupKey then
        local map = GetStateMap("collapsedGroups")
        if mouseBtn == "RightButton" then
            local anyExpanded = false
            for _, g in ipairs((self.lastSnapshot and self.lastSnapshot.groups) or {}) do
                if not g.isCollapsed then
                    anyExpanded = true
                    break
                end
            end
            for _, g in ipairs((self.lastSnapshot and self.lastSnapshot.groups) or {}) do
                map[g.key] = anyExpanded and true or nil
            end
            SaveStateMap("collapsedGroups", map)
        else
            map[item.groupKey] = (not map[item.groupKey]) and true or nil
            SaveStateMap("collapsedGroups", map)
        end
        self:RefreshLive()
        return
    end

    local qid = item.questID
    if type(qid) ~= "number" or qid <= 0 then
        return
    end

    if mouseBtn == "RightButton" then
        local qMap = GetStateMap("collapsedQuests")
        qMap[qid] = (not qMap[qid]) and true or nil
        SaveStateMap("collapsedQuests", qMap)
        self:RefreshLive()
        return
    end

    -- Modifier priority: Ctrl(own zero-taint detail card) > Alt(chat link) > Shift(chat link or watch) > Left(SuperTrack)
    if ns.Api.GameAdapters.IsControlDown() then
        self:ShowDetailCard(item)
        return
    end
    if ns.Api.GameAdapters.IsAltDown() then
        ns.Api.GameAdapters.InsertQuestChatLink(qid)
        return
    end
    if ns.Api.GameAdapters.IsShiftDown() then
        if ns.Api.GameAdapters.HasActiveChatEditBox() then
            ns.Api.GameAdapters.InsertQuestChatLink(qid)
        else
            ns.Api.GameAdapters.ToggleQuestWatchSafe(qid, item.isWatched == true)
            self:RefreshLive()
        end
        return
    end

    local cur = ns.Api.SafeAPI.GetSuperTrackedQuestID()
    local nextQID = (cur == qid) and 0 or qid
    local ok, status = ns.Api.NavPort.RequestSuperTrack(nextQID)
    if not ok and status == "DEFERRED" then
        ns.Api.SafeAPI.Print("전투 또는 지도 종료 후 퀘스트 포커스를 전환합니다.")
    end
    if ns.Features.NavigationHud and type(ns.Features.NavigationHud.TrackQuest) == "function" then
        local navOk, navStatus = ns.Features.NavigationHud:TrackQuest(nextQID, item.rawTitle or item.title, { allowLoadPacks = true, explicit = true })
        if nextQID > 0 and (not navOk) and navStatus == "NO_COORDS" then
            ns.Api.SafeAPI.Print("퀘스트 포커스 설정됨 (좌표 미등록 - 월드맵에서 Alt+좌클릭으로 /way 직접 지정 가능)")
        end
    end
end

local function ShowRowTooltip(rowBtn)
    local item = rowBtn and rowBtn._rowData
    if type(item) ~= "table" or (item.kind ~= "quest" and item.kind ~= "objective") then
        return
    end
    if not (_G.GameTooltip and type(_G.GameTooltip.SetOwner) == "function") then
        return
    end
    pcall(function()
        _G.GameTooltip:SetOwner(rowBtn, "ANCHOR_LEFT")
        _G.GameTooltip:ClearLines()
        local titleCol = (type(item.difficultyColor) == "table") and item.difficultyColor or T.TEXT.GOLD
        _G.GameTooltip:AddLine(tostring(item.rawTitle or item.title or "퀘스트"), titleCol[1], titleCol[2], titleCol[3])
        local sub = tostring(item.zone or "기타")
        if type(item.level) == "number" and item.level > 0 then
            sub = sub .. " · Lv." .. tostring(item.level)
        end
        _G.GameTooltip:AddLine(sub, T.TEXT.SECONDARY[1], T.TEXT.SECONDARY[2], T.TEXT.SECONDARY[3])
        for _, obj in ipairs(item.objectives or {}) do
            local c = obj.finished and T.SEMANTIC.SUCCESS or T.TEXT.PRIMARY
            _G.GameTooltip:AddLine((obj.finished and "V " or "· ") .. tostring(obj.text or ""), c[1], c[2], c[3])
        end
        if ns.Features.QuestExtraModule and type(item.questID) == "number" then
            local partyTxt = ns.Features.QuestExtraModule:GetPartySummaryForQuest(item.questID)
            if type(partyTxt) == "string" and partyTxt ~= "" then
                _G.GameTooltip:AddLine("파티 동기화: " .. partyTxt, T.TEXT.GOLD[1], T.TEXT.GOLD[2], T.TEXT.GOLD[3], true)
            end
            local routeRec = ns.Features.QuestExtraModule:GetDialogueRouteForQuest(item.questID)
            if type(routeRec) == "table" and type(routeRec.title) == "string" and routeRec.title ~= "" then
                _G.GameTooltip:AddLine("보고 루트: " .. routeRec.title, T.SEMANTIC.INFO[1], T.SEMANTIC.INFO[2], T.SEMANTIC.INFO[3], true)
            end
        end
        _G.GameTooltip:AddLine("좌클릭: 포커스+화살표 길안내 · 우클릭: 접기 · Ctrl: 상세 · Shift: 링크/주시", T.TEXT.MUTED[1], T.TEXT.MUTED[2], T.TEXT.MUTED[3])
        _G.GameTooltip:Show()
    end)
end

local function HideRowTooltip()
    if _G.GameTooltip and type(_G.GameTooltip.Hide) == "function" then
        pcall(_G.GameTooltip.Hide, _G.GameTooltip)
    end
end

function QuestTrackerView:EnsureRow(idx)
    if self.rowPool[idx] then
        return self.rowPool[idx]
    end
    local row = W.ListRow(self.container, ROW_HEIGHT, function(btn, mouseBtn)
        QuestTrackerView:OnRowClick(btn, mouseBtn)
    end)
    row:SetTooltipHandler(ShowRowTooltip, HideRowTooltip)
    self.rowPool[idx] = row
    return row
end

function QuestTrackerView:BuildLiveOpts(extra)
    local opts = {}
    if type(extra) == "table" then
        for k, v in pairs(extra) do opts[k] = v end
    end
    if opts.superTrackedQuestID == nil then
        opts.superTrackedQuestID = ns.Api.SafeAPI.GetSuperTrackedQuestID()
    end
    if opts.currentZone == nil then
        opts.currentZone = ns.Api.GameAdapters.GetPlayerZoneText()
    end
    if opts.playerLevel == nil then
        opts.playerLevel = ns.Api.GameAdapters.GetPlayerLevel()
    end
    if opts.groupMode == nil then
        opts.groupMode = ns.Domain.QuestTrackerModel.NormalizeGroupMode(GetSetting("groupMode", "zone"))
    end
    if opts.currentZoneOnly == nil then
        opts.currentZoneOnly = GetSetting("currentZoneOnly", false) == true
    end
    if opts.minimized == nil then
        opts.minimized = GetSetting("trackerMinimized", false) == true
    end
    if opts.compactMode == nil then
        opts.compactMode = GetSetting("compactMode", false) == true
    end
    if opts.collapsedGroups == nil then
        opts.collapsedGroups = GetStateMap("collapsedGroups")
    end
    if opts.collapsedQuests == nil then
        opts.collapsedQuests = GetStateMap("collapsedQuests")
    end
    if opts.scrollOffset == nil then
        opts.scrollOffset = self.scrollOffset
    end
    if opts.maxVisibleRows == nil then
        local uiH = (_G.UIParent and type(_G.UIParent.GetHeight) == "function") and _G.UIParent:GetHeight() or 1080
        if type(uiH) == "number" and uiH > 0 then
            -- Continuous viewport budget: tracker top (uiH - 270) down to ThreatMeter top (232) + 12px gap
            local chrome = HEADER_HEIGHT + BODY_TOP_PAD + FOOTER_HEIGHT + PADDING_BOTTOM
            local fitRows = math.floor((uiH - 514 - chrome) / ROW_HEIGHT)
            if fitRows < 5 then fitRows = 5 end
            if fitRows > MAX_VISIBLE_ROWS then fitRows = MAX_VISIBLE_ROWS end
            opts.maxVisibleRows = fitRows
        else
            opts.maxVisibleRows = MAX_VISIBLE_ROWS
        end
    end
    return opts
end

function QuestTrackerView:RefreshLive()
    local quests = ns.Api.SafeAPI.CollectQuestLog()
    return self:Render(quests, nil)
end

function QuestTrackerView:ReRenderLast()
    if self._pendingDockAnchor and not ns.Api.SafeAPI.InCombat() then
        local pending = self._pendingDockAnchor
        self._pendingDockAnchor = nil
        self:SyncDockAnchor(type(pending) == "table" and pending or nil)
    end
    if not self._needsPostCombatReRender then
        return nil
    end
    self._needsPostCombatReRender = false
    if self.lastQuests then
        return self:Render(self.lastQuests, self.lastOpts)
    end
    return self:RefreshLive()
end

function QuestTrackerView:Render(quests, opts)
    self:Init()
    self.lastQuests = quests
    self.lastOpts = opts

    local mergedOpts = self:BuildLiveOpts(opts)
    local snap = ns.Domain.QuestTrackerModel.BuildSnapshot(quests, mergedOpts)
    self.lastSnapshot = snap
    if not snap.minimized then
        self.scrollOffset = snap.scrollOffset
    end

    -- Invariant I2: Apply QuestItemDock & pending Dock anchor ONLY when OOC (defer flag if in combat)
    local dockApplied = false
    if not ns.Api.SafeAPI.InCombat() then
        if self._pendingDockAnchor then
            local pending = self._pendingDockAnchor
            self._pendingDockAnchor = nil
            self:SyncDockAnchor(type(pending) == "table" and pending or nil)
        end
        dockApplied = ns.Secure.QuestItemDock:ApplySlots(snap.dockSlots)
    end
    self._needsPostCombatReRender = (not dockApplied) or (self._pendingDockAnchor ~= nil)

    self:SyncToolbarLabels()
    if self.titleLbl then
        local countTxt = tostring(snap.questCount)
        if snap.hiddenCount > 0 then
            countTxt = countTxt .. "/" .. tostring(snap.totalQuestCount)
        end
        self.titleLbl:SetText("★ 퀘스트 (" .. countTxt .. ")")
    end

    -- Fixed B6: Compute scrollbar visibility BEFORE anchoring rows so right inset clears the 10px scrollbar!
    local showFooter = (not snap.minimized) and (snap.maxScroll > 0)
    local rowRightInset = showFooter and 16 or PADDING_X

    local y = HEADER_HEIGHT + BODY_TOP_PAD
    local shown = 0
    for i, item in ipairs(snap.visibleRows) do
        shown = i
        local row = self:EnsureRow(i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", self.container, "TOPLEFT", PADDING_X, -y)
        row:SetPoint("TOPRIGHT", self.container, "TOPRIGHT", -rowRightInset, -y)
        row._questID = item.questID
        row._rowData = item

        local theme = ROW_THEMES[item.visualState] or ROW_THEMES.empty
        local ribbonTex = (theme.useZoneRibbon and T.UI_ART and T.UI_ART.zoneRibbon) or nil
        row:SetRowStyle(theme.bg, theme.accent, theme.ax, theme.aw, theme.sep, theme.pad, theme.fadeRight, ribbonTex)

        if item.kind == "header" then
            row._left:SetText(item.text)
            row._left:SetTextColor(theme.tc[1], theme.tc[2], theme.tc[3], 1)
            row._right:SetText(item.rightText or "")
            row._right:SetTextColor(theme.rc[1], theme.rc[2], theme.rc[3], 1)
        elseif item.kind == "quest" then
            local title = item.title
            if not dockApplied then
                local liveSlot = ns.Secure.QuestItemDock:GetActiveSlotForQuest(item.questID)
                title = (liveSlot and ("[" .. tostring(liveSlot) .. "] ") or "") ..
                    tostring(item.title):gsub("^%[%d+%] ", "")
            end
            local marker = item.isSuperTracked and "★ " or (item.isComplete and "V " or "")
            local diffCol = (type(item.difficultyColor) == "table") and item.difficultyColor or nil
            -- Classic Original Quest Difficulty Colors for title & level badge; preserve accent/badge cues for super/complete/failed
            local titleCol = item.isFailed and T.SEMANTIC.DANGER or (diffCol or theme.tc)
            local rightCol = item.isComplete and T.SEMANTIC.SUCCESS
                or (item.isFailed and T.SEMANTIC.DANGER or (diffCol or theme.rc))
            if item.visualState == "quest_active" and diffCol then
                row:SetRowStyle(theme.bg, diffCol, theme.ax, theme.aw, theme.sep, theme.pad, theme.fadeRight)
            end
            row._left:SetText(marker .. title)
            row._left:SetTextColor(titleCol[1], titleCol[2], titleCol[3], 1)
            row._right:SetText(item.rightText or "")
            row._right:SetTextColor(rightCol[1], rightCol[2], rightCol[3], 1)
        elseif item.kind == "objective" then
            local prefix = item.finished and "V " or "· "
            row._left:SetText(prefix .. item.text)
            row._left:SetTextColor(theme.tc[1], theme.tc[2], theme.tc[3], 1)
            row._right:SetText("")
        else
            row._left:SetText(item.text or "")
            row._left:SetTextColor(theme.tc[1], theme.tc[2], theme.tc[3], 1)
            row._right:SetText("")
        end
        row:Show()
        y = y + ROW_HEIGHT
    end

    for i = shown + 1, #self.rowPool do
        self.rowPool[i]:Hide()
    end

    if self.scrollBar then
        if showFooter then
            self.scrollBar:SetMetrics(snap.scrollOffset, (shown > 0 and shown or 1), snap.totalRows)
        else
            self.scrollBar:SetMetrics(0, 1, 0)
        end
    end
    if self.scrollHint then
        if showFooter then
            local fromN = snap.scrollOffset + 1
            local toN = snap.scrollOffset + shown
            self.scrollHint:SetText("휠 스크롤 " .. tostring(fromN) .. "-" .. tostring(toN) .. " / " .. tostring(snap.totalRows) .. "행")
            self.scrollHint:Show()
        else
            self.scrollHint:Hide()
        end
    end

    local totalHeight
    if snap.minimized then
        totalHeight = HEADER_HEIGHT + 2
    else
        totalHeight = math_max(HEADER_HEIGHT + 30, y + (showFooter and FOOTER_HEIGHT or 0) + PADDING_BOTTOM)
    end
    self.currentHeight = totalHeight
    self.container:SetHeight(totalHeight)
    self:UpdateCombatVisuals()

    return snap
end
