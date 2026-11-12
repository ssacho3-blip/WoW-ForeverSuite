-- Module: UI/QuestTracker.lua
-- Responsibility: Regional/Level on-screen QuestTracker HUD View, modifier clicks, objective tooltips, lock state, and quest item buttons.
-- Dependencies: Core/Init.lua, Core/ProfileManager.lua, UI/Framework.lua, UI/QuestTrackerModel.lua, UI/QuestLogCollector.lua, UI/DefaultTrackerSync.lua.
-- Public API: ns.QuestTracker (Enable, Disable, Refresh, SetGroupMode, ToggleGroupMode, ToggleCurrentZoneFilter, ToggleMinimized, ToggleLocked, ResetLayout).
-- Combat/Secret Safety: Secure item buttons are pooled on UIParent (never parented/anchored to tracker) and mutated exclusively via CombatQueue:RunOrDefer.
local _, ns = ...

local type, ipairs, pairs = type, ipairs, pairs
local tostring, tonumber, pcall = tostring, tonumber, pcall
local math_max, math_min, math_floor = math.max, math.min, math.floor
local string_find, string_format = string.find, string.format

local TRACKER_WIDTH, HEADER_HEIGHT, ROW_HEIGHT = 308, 30, 19
local MAX_VISIBLE_ROWS, MAX_ITEM_BUTTONS = 18, 6
local PADDING_X, PADDING_BOTTOM = 10, 8
local READONLY_MSG = "읽기 전용 프로필(미래 스키마)에서는 설정을 저장할 수 없습니다."

local RESET_DEFAULTS = {
    { "trackerEnabled", true }, { "groupMode", "zone" }, { "currentZoneOnly", false },
    { "watchedOnly", true }, { "trackerMinimized", false }, { "trackerLocked", false },
    { "trackerPoint", "TOPRIGHT" }, { "trackerRelPoint", "TOPRIGHT" },
    { "trackerX", -22 }, { "trackerY", -215 },
}

local QuestTracker = ns.QuestTracker or {}
ns.QuestTracker = QuestTracker
for k, v in pairs({
    rowWidgets = {}, itemButtons = {}, collapsedQuests = {},
    scrollOffset = 0, lastFrameHeight = HEADER_HEIGHT, active = false, _suppressAutoRefresh = false,
}) do
    if QuestTracker[k] == nil then QuestTracker[k] = v end
end

function QuestTracker:ApplySavedAnchor(frame)
    frame = frame or self.frame
    if not (frame and frame.SetPoint) then return end
    local point = ns.ProfileManager:Get("quest", "trackerPoint") or "TOPRIGHT"
    local relPoint = ns.ProfileManager:Get("quest", "trackerRelPoint") or "TOPRIGHT"
    local x = tonumber(ns.ProfileManager:Get("quest", "trackerX")) or -22
    local y = tonumber(ns.ProfileManager:Get("quest", "trackerY")) or -215
    if frame.ClearAllPoints then frame:ClearAllPoints() end
    frame:SetPoint(point, _G.UIParent, relPoint, x, y)
end

local function SetQuestSettingSilent(tracker, key, value)
    if not ns.ProfileManager:CanWrite() then
        ns.Warn(READONLY_MSG)
        return false
    end
    tracker._suppressAutoRefresh = true
    local ok = ns.ProfileManager:Set("quest", key, value, "account")
    tracker._suppressAutoRefresh = false
    if not ok then ns.Warn(READONLY_MSG); return false end
    return true
end

local function ToggleQuestBoolean(tracker, key, resetScroll)
    local cur = ns.ProfileManager:Get("quest", key) and true or false
    local nxt = not cur
    if not SetQuestSettingSilent(tracker, key, nxt) then return false, cur end
    if resetScroll then tracker.scrollOffset = 0 end
    tracker:Refresh()
    return true, nxt
end

function QuestTracker:SetGroupMode(mode)
    local normalized = (not ns.IsSecret(mode) and mode == "level") and "level" or "zone"
    if not SetQuestSettingSilent(self, "groupMode", normalized) then
        return false, ns.ProfileManager:Get("quest", "groupMode") or "zone"
    end
    self.scrollOffset = 0
    self:Refresh()
    return true, normalized
end

function QuestTracker:ToggleGroupMode()
    return self:SetGroupMode((ns.ProfileManager:Get("quest", "groupMode") == "level") and "zone" or "level")
end

function QuestTracker:ToggleCurrentZoneFilter() return ToggleQuestBoolean(self, "currentZoneOnly", true) end
function QuestTracker:ToggleMinimized() return ToggleQuestBoolean(self, "trackerMinimized", false) end
function QuestTracker:ToggleLocked() return ToggleQuestBoolean(self, "trackerLocked", false) end

function QuestTracker:ResetLayout()
    if not ns.ProfileManager:CanWrite() then
        ns.Warn("읽기 전용 프로필(미래 스키마)에서는 설정을 초기화할 수 없습니다.")
        return false
    end
    self._suppressAutoRefresh = true
    for _, kv in ipairs(RESET_DEFAULTS) do
        ns.ProfileManager:Set("quest", kv[1], kv[2], "account")
    end
    ns.ProfileManager:ClearCollapsedQuestGroups()
    self._suppressAutoRefresh = false
    ns.WipeTable(self.collapsedQuests)
    self.scrollOffset = 0
    self:ApplySavedAnchor()
    self:Refresh()
    return true
end

function QuestTracker:OpenQuestDetails(questID)
    if ns.InCombat() then
        ns.Warn("전투 중에는 퀘스트 상세 창을 열 수 없습니다.")
        return false
    end
    if C_QuestLog and C_QuestLog.SetSelectedQuest then pcall(C_QuestLog.SetSelectedQuest, questID) end
    for _, fnName in ipairs({ "QuestMapFrame_OpenToQuestDetails", "QuestMapFrame_ShowQuestDetails" }) do
        if type(_G[fnName]) == "function" and pcall(_G[fnName], questID) then return true end
    end
    if type(_G.ToggleQuestLog) == "function" and pcall(_G.ToggleQuestLog) then return true end
    ns.Print("현재 환경에서 퀘스트 상세 창 열기 UI를 사용할 수 없습니다 (ID: " .. tostring(questID) .. ").")
    return false
end

function QuestTracker:InsertQuestChatLink(questID, activeEdit)
    if type(_G.GetQuestLink) ~= "function" then return false end
    local okLink, link = pcall(_G.GetQuestLink, questID)
    if not okLink or ns.IsSecret(link) or type(link) ~= "string" or link == "" then return false end
    if type(_G.ChatEdit_InsertLink) == "function" then
        local okIns, inserted = pcall(_G.ChatEdit_InsertLink, link)
        if okIns and inserted ~= false then return true end
    end
    local editBox = activeEdit or (_G.ChatEdit_GetActiveWindow and _G.ChatEdit_GetActiveWindow()) or nil
    if editBox and type(editBox.Insert) == "function" then
        return pcall(editBox.Insert, editBox, link) and true or false
    end
    return false
end

local function ToggleGroupHeaderCollapse(tracker, data, mouseBtn)
    if not ns.ProfileManager:CanWrite() then ns.Warn(READONLY_MSG); return end
    tracker._suppressAutoRefresh = true
    if mouseBtn == "RightButton" then
        local snap = tracker.lastSnapshot
        if snap and type(snap.groups) == "table" then
            local anyExpanded = false
            for i = 1, #snap.groups do
                if not snap.groups[i].isCollapsed then anyExpanded = true; break end
            end
            if anyExpanded then
                for i = 1, #snap.groups do ns.ProfileManager:SetQuestGroupCollapsed(snap.groups[i].key, true) end
            else
                ns.ProfileManager:ClearCollapsedQuestGroups()
            end
        end
    else
        ns.ProfileManager:SetQuestGroupCollapsed(data.groupKey, not ns.ProfileManager:IsQuestGroupCollapsed(data.groupKey))
    end
    tracker._suppressAutoRefresh = false
    tracker:Refresh()
end

function QuestTracker:OnRowClicked(rowWidget, mouseBtn)
    local data = rowWidget and rowWidget._rowData
    if type(data) ~= "table" then return end
    if data.kind == "group" and data.groupKey then
        ToggleGroupHeaderCollapse(self, data, mouseBtn)
        return
    end
    if (data.kind ~= "quest" and data.kind ~= "objective") or not data.questID then return end

    local qid = data.questID
    if mouseBtn == "RightButton" then
        self.collapsedQuests[qid] = (not self.collapsedQuests[qid]) and true or nil
        self:Refresh()
        return
    end

    -- Modifier priority: Ctrl > Alt > Shift(chat active) > Shift(watch toggle) > LeftClick(SuperTrack)
    if _G.IsControlKeyDown and _G.IsControlKeyDown() then self:OpenQuestDetails(qid); return end
    local activeEdit = (_G.ChatEdit_GetActiveWindow and _G.ChatEdit_GetActiveWindow()) or nil
    if _G.IsAltKeyDown and _G.IsAltKeyDown() then self:InsertQuestChatLink(qid, activeEdit); return end
    if _G.IsShiftKeyDown and _G.IsShiftKeyDown() then
        if activeEdit ~= nil then self:InsertQuestChatLink(qid, activeEdit); return end
        if C_QuestLog then
            if data.isWatched and C_QuestLog.RemoveQuestWatch then
                pcall(C_QuestLog.RemoveQuestWatch, qid)
            elseif (not data.isWatched) and C_QuestLog.AddQuestWatch then
                pcall(C_QuestLog.AddQuestWatch, qid)
            end
            self:Refresh()
        end
        return
    end

    if C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID then
        local currentSuper = self:QuerySuperTrackedQuestID()
        pcall(C_SuperTrack.SetSuperTrackedQuestID, (currentSuper == qid) and 0 or qid)
        if C_QuestLog and C_QuestLog.SetSelectedQuest then pcall(C_QuestLog.SetSelectedQuest, qid) end
        self:Refresh()
    end
end

local function ApplyRowRestingBg(bgTex, d)
    if not (bgTex and bgTex.SetColorTexture) then return end
    if d and d.kind == "group" then
        if d.isCurrentZone then bgTex:SetColorTexture(0.24, 0.20, 0.08, 0.72) else bgTex:SetColorTexture(0.14, 0.17, 0.22, 0.72) end
    elseif d and d.kind == "quest" and d.isSuperTracked then
        bgTex:SetColorTexture(0.26, 0.22, 0.09, 0.45)
    else
        bgTex:SetColorTexture(0, 0, 0, 0)
    end
end

local function RenderRowTooltip(owner, d)
    if not (d and _G.GameTooltip and _G.GameTooltip.SetOwner) then return end
    _G.GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    if d.kind == "group" then
        _G.GameTooltip:AddLine("그룹 접기 / 펼치기", 1.0, 0.85, 0.35)
        _G.GameTooltip:AddLine("좌클릭: 현재 그룹 토글  |  우클릭: 전체 그룹 일괄 접기/펼치기", 0.80, 0.84, 0.90)
    elseif d.kind == "quest" then
        _G.GameTooltip:AddLine(d.questTitle or "퀘스트 포커스 및 제어", 1.0, 0.85, 0.35)
        _G.GameTooltip:AddLine("좌클릭: 화살표(SuperTrack)  |  Ctrl+좌클릭: 퀘스트 상세 열기", 0.85, 0.90, 0.95)
        _G.GameTooltip:AddLine("Alt+좌클릭: 채팅 링크  |  Shift+좌클릭: 추적 토글  |  우클릭: 접기", 0.72, 0.78, 0.86)
    elseif d.kind == "objective" then
        _G.GameTooltip:AddLine(d.questTitle or "퀘스트 목표", 1.0, 0.85, 0.35)
        _G.GameTooltip:AddLine(d.fullObjectiveText or d.text or "", 0.93, 0.95, 0.98, true)
        _G.GameTooltip:AddLine("좌클릭: 화살표  |  Ctrl+좌클릭: 상세  |  Alt+좌클릭: 링크", 0.65, 0.72, 0.82)
    else
        return
    end
    _G.GameTooltip:Show()
end

local function CreateRowWidget(parent, rowIndex)
    local row = _G.CreateFrame("Button", nil, parent)
    row:SetSize(TRACKER_WIDTH - (PADDING_X * 2), ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", PADDING_X, -(HEADER_HEIGHT + 4 + (rowIndex - 1) * ROW_HEIGHT))
    if row.RegisterForClicks then row:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
    if row.CreateTexture then
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(row)
        bg:SetColorTexture(0, 0, 0, 0)
        row._bg = bg
    end

    local leftText = ns.UI.CreateLabel(row, "", "GameFontHighlightSmall", ns.UI.COLORS.TEXT)
    if leftText then
        leftText:SetPoint("LEFT", row, "LEFT", 4, 0)
        if leftText.SetJustifyH then leftText:SetJustifyH("LEFT") end
        if leftText.SetWordWrap then leftText:SetWordWrap(false) end
        if leftText.SetWidth then leftText:SetWidth(TRACKER_WIDTH - (PADDING_X * 2) - 42) end
        row._leftText = leftText
    end

    local rightText = ns.UI.CreateLabel(row, "", "GameFontHighlightSmall", ns.UI.COLORS.MUTED)
    if rightText then
        rightText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        if rightText.SetJustifyH then rightText:SetJustifyH("RIGHT") end
        row._rightText = rightText
    end

    row:SetScript("OnEnter", function(self)
        local d = self._rowData
        if self._bg and self._bg.SetColorTexture and d and d.kind ~= "empty" then
            self._bg:SetColorTexture(0.22, 0.26, 0.34, 0.55)
        end
        RenderRowTooltip(self, d)
    end)
    row:SetScript("OnLeave", function(self)
        ApplyRowRestingBg(self._bg, self._rowData)
        if _G.GameTooltip and _G.GameTooltip.Hide then _G.GameTooltip:Hide() end
    end)
    row:SetScript("OnClick", function(self, mouseBtn) QuestTracker:OnRowClicked(self, mouseBtn) end)
    return row
end

function QuestTracker:EnsureItemButtonPool()
    if not _G.CreateFrame then return end
    ns.CombatQueue:RunOrDefer("quest:initItemBtnPool", function()
        for idx = 1, MAX_ITEM_BUTTONS do
            if not QuestTracker.itemButtons[idx] then
                local btnName = "ForeverSuiteQuestItemBtn" .. tostring(idx)
                local btn = _G[btnName]
                if type(btn) ~= "table" then
                    -- Strictly parented to UIParent (NEVER ForeverSuiteQuestTracker) to prevent implicit protection!
                    btn = _G.CreateFrame("Button", btnName, _G.UIParent, "SecureActionButtonTemplate")
                end
                if btn then
                    btn:SetSize(20, 20)
                    if btn.RegisterForClicks then btn:RegisterForClicks("AnyUp", "AnyDown") end
                    if btn.CreateTexture and not btn._fsIcon then
                        local icon = btn:CreateTexture(nil, "ARTWORK")
                        icon:SetAllPoints(btn)
                        btn._fsIcon = icon
                    end
                    btn:SetScript("OnEnter", function(selfBtn)
                        if _G.GameTooltip and _G.GameTooltip.SetOwner and selfBtn._fsItemLink then
                            _G.GameTooltip:SetOwner(selfBtn, "ANCHOR_LEFT")
                            _G.GameTooltip:AddLine(selfBtn._fsQuestTitle or "퀘스트 특수 아이템", 1.0, 0.85, 0.35)
                            _G.GameTooltip:AddLine(tostring(selfBtn._fsItemLink), 0.90, 0.94, 0.98)
                            _G.GameTooltip:Show()
                        end
                    end)
                    btn:SetScript("OnLeave", function()
                        if _G.GameTooltip and _G.GameTooltip.Hide then _G.GameTooltip:Hide() end
                    end)
                    if btn.Hide then btn:Hide() end
                    QuestTracker.itemButtons[idx] = btn
                end
            end
        end
    end)
end

local function ComputeItemButtonAnchor(point, baseX, baseY, frameHeight, rowIdx)
    local placeLeft = string_find(point, "RIGHT", 1, true) ~= nil
    local xOffset = placeLeft and (baseX - TRACKER_WIDTH - 6) or (baseX + TRACKER_WIDTH + 6)
    local topY = baseY
    if string_find(point, "BOTTOM", 1, true) then
        topY = baseY + frameHeight
    elseif not string_find(point, "TOP", 1, true) then
        topY = baseY + math_floor(frameHeight / 2)
    end
    return placeLeft and "TOPRIGHT" or "TOPLEFT", xOffset, topY - (HEADER_HEIGHT + 4 + (rowIdx - 1) * ROW_HEIGHT)
end

function QuestTracker:SyncQuestItemButtons()
    ns.CombatQueue:RunOrDefer("quest:syncItemBtns", function()
        local trackerEnabled = ns.ProfileManager:Get("quest", "trackerEnabled") and true or false
        local minimized = ns.ProfileManager:Get("quest", "trackerMinimized") and true or false
        if (not QuestTracker.active) or (not trackerEnabled) or minimized or (not QuestTracker.frame) or (not QuestTracker.lastSnapshot) then
            for i = 1, #QuestTracker.itemButtons do
                if QuestTracker.itemButtons[i] and QuestTracker.itemButtons[i].Hide then QuestTracker.itemButtons[i]:Hide() end
            end
            return
        end

        local point = ns.ProfileManager:Get("quest", "trackerPoint") or "TOPRIGHT"
        local relPoint = ns.ProfileManager:Get("quest", "trackerRelPoint") or "TOPRIGHT"
        local baseX = tonumber(ns.ProfileManager:Get("quest", "trackerX")) or -22
        local baseY = tonumber(ns.ProfileManager:Get("quest", "trackerY")) or -215
        local frameHeight = tonumber(QuestTracker.lastFrameHeight) or HEADER_HEIGHT

        local used = 0
        for rowIdx = 1, MAX_VISIBLE_ROWS do
            local widget = QuestTracker.rowWidgets[rowIdx]
            local d = widget and widget._rowData
            if widget and widget.IsShown and widget:IsShown() and d and d.kind == "quest" and d.questID then
                local liveLink, liveIcon = QuestTracker:ResolveLiveSpecialItem(d.questID)
                local itemLink = liveLink or d.specialItemLink
                local itemIcon = liveIcon or d.specialItemIcon
                if itemLink and used < MAX_ITEM_BUTTONS then
                    used = used + 1
                    local btn = QuestTracker.itemButtons[used]
                    if btn then
                        btn._fsQuestID, btn._fsQuestTitle, btn._fsItemLink = d.questID, d.questTitle, itemLink
                        if btn.SetAttribute then
                            btn:SetAttribute("type", "item")
                            btn:SetAttribute("item", itemLink)
                        end
                        if btn._fsIcon and btn._fsIcon.SetTexture and itemIcon then
                            pcall(btn._fsIcon.SetTexture, btn._fsIcon, itemIcon)
                        end
                        if btn.ClearAllPoints then btn:ClearAllPoints() end
                        local btnPoint, xOff, yOff = ComputeItemButtonAnchor(point, baseX, baseY, frameHeight, rowIdx)
                        btn:SetPoint(btnPoint, _G.UIParent, relPoint, xOff, yOff)
                        if btn.Show then btn:Show() end
                    end
                end
            end
        end

        for i = used + 1, #QuestTracker.itemButtons do
            local btn = QuestTracker.itemButtons[i]
            if btn then
                btn._fsQuestID, btn._fsItemLink = nil, nil
                if btn.Hide then btn:Hide() end
            end
        end
    end)
end

local function CreateTrackerChrome(f)
    if not f.CreateTexture then return end
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetColorTexture(0.06, 0.07, 0.09, 0.86)
    local headerBg = f:CreateTexture(nil, "BORDER")
    headerBg:SetHeight(HEADER_HEIGHT)
    headerBg:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    headerBg:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    headerBg:SetColorTexture(0.10, 0.12, 0.16, 0.96)
    for _, bar in ipairs({ { 0, 0.83, 0.69, 0.22, 0.85 }, { -HEADER_HEIGHT, 0.28, 0.32, 0.38, 0.80 } }) do
        local line = f:CreateTexture(nil, "OVERLAY")
        line:SetHeight(1)
        line:SetPoint("TOPLEFT", f, "TOPLEFT", 0, bar[1])
        line:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, bar[1])
        line:SetColorTexture(bar[2], bar[3], bar[4], bar[5])
    end
end

function QuestTracker:EnsureFrame(ctx)
    if self.frame then return self.frame end
    local f = ctx:CreateFrame("Frame", "ForeverSuiteQuestTracker", _G.UIParent)
    if not f then return nil end

    if not f._fsTrackerInitialized then
        f._fsTrackerInitialized = true
        f:SetSize(TRACKER_WIDTH, HEADER_HEIGHT + 36)
        if f.SetClampedToScreen then f:SetClampedToScreen(true) end
        if f.SetMovable then
            f:SetMovable(true)
            f:EnableMouse(true)
            f:RegisterForDrag("LeftButton")
            f:SetScript("OnDragStart", function(sf)
                if not ns.ProfileManager:Get("quest", "trackerLocked") and not ns.InCombat() and sf.StartMoving then
                    sf._fsDragging = true
                    sf:StartMoving()
                end
            end)
            f:SetScript("OnDragStop", function(sf)
                local wasDragging = sf._fsDragging
                sf._fsDragging = false
                if sf.StopMovingOrSizing then sf:StopMovingOrSizing() end
                if ns.ProfileManager:Get("quest", "trackerLocked") and not wasDragging then return end
                if sf.GetPoint and ns.ProfileManager:CanWrite() then
                    local pt, _, relPt, xOfs, yOfs = sf:GetPoint(1)
                    if type(pt) == "string" and type(relPt) == "string" and type(xOfs) == "number" and type(yOfs) == "number" then
                        ns.ProfileManager:Set("quest", "trackerPoint", pt, "account")
                        ns.ProfileManager:Set("quest", "trackerRelPoint", relPt, "account")
                        ns.ProfileManager:Set("quest", "trackerX", math_floor(xOfs + 0.5), "account")
                        ns.ProfileManager:Set("quest", "trackerY", math_floor(yOfs + 0.5), "account")
                        QuestTracker:SyncQuestItemButtons()
                    end
                end
            end)
        end
        if f.EnableMouseWheel then
            f:EnableMouseWheel(true)
            f:SetScript("OnMouseWheel", function(_, delta)
                local snap = QuestTracker.lastSnapshot
                if not snap or #snap.rows <= MAX_VISIBLE_ROWS then return end
                local maxOffset = math_max(0, #snap.rows - MAX_VISIBLE_ROWS)
                local step = (type(delta) == "number" and delta > 0) and -2 or 2
                local nextOffset = math_max(0, math_min(maxOffset, QuestTracker.scrollOffset + step))
                if nextOffset ~= QuestTracker.scrollOffset then
                    QuestTracker.scrollOffset = nextOffset
                    QuestTracker:RenderSnapshot(snap)
                end
            end)
        end

        CreateTrackerChrome(f)
        local title = ns.UI.CreateLabel(f, "퀘스트", "GameFontNormalSmall", ns.UI.COLORS.ACCENT)
        if title then title:SetPoint("LEFT", f, "TOPLEFT", PADDING_X, -(HEADER_HEIGHT / 2)); f._fsHeaderTitle = title end

        local prevPill = nil
        for _, ps in ipairs({
            { field = "_fsMinBtn", text = "–", w = 20, tip = "퀘스트 추적창 접기/펼치기", sub = "클릭하면 본문 목록을 최소화하거나 펼칩니다.", fn = function() QuestTracker:ToggleMinimized() end },
            { field = "_fsHereBtn", text = "현지역", w = 42, tip = "현재 지역 퀘스트만 보기", sub = "켜면 현재 지역 퀘스트와 완료 퀘스트만 표시합니다.", fn = function() QuestTracker:ToggleCurrentZoneFilter() end },
            { field = "_fsLevelBtn", text = "레벨별", w = 42, tip = "레벨별 분류 보기 (/fs quest level)", sub = "난이도 구간(수월·적정·도전) 및 레벨 순으로 나눕니다.", fn = function() QuestTracker:SetGroupMode("level") end },
            { field = "_fsZoneBtn", text = "지역별", w = 42, tip = "지역별 분류 보기 (/fs quest zone)", sub = "현재 머무는 지역을 최상단에 고정하고 지역별로 묶습니다.", fn = function() QuestTracker:SetGroupMode("zone") end },
            { field = "_fsLockBtn", text = "잠금", w = 34, tip = "추적창 위치 잠금 (/fs quest lock)", sub = "켜면 드래그 이동만 차단하고 행 클릭·휠 스크롤은 유지합니다.", fn = function() QuestTracker:ToggleLocked() end },
        }) do
            local btn = ns.UI.CreatePillButton(f, ps.text, ps.w, 18, ps.tip, ps.sub, ps.fn)
            if btn then
                if not prevPill then btn:SetPoint("RIGHT", f, "TOPRIGHT", -6, -(HEADER_HEIGHT / 2)) else btn:SetPoint("RIGHT", prevPill, "LEFT", -3, 0) end
                f[ps.field], prevPill = btn, btn
            end
        end

        f._fsRows = {}
        for idx = 1, MAX_VISIBLE_ROWS do f._fsRows[idx] = CreateRowWidget(f, idx) end
        local scrollHint = ns.UI.CreateLabel(f, "", "GameFontHighlightSmall", ns.UI.COLORS.MUTED)
        if scrollHint then scrollHint:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PADDING_X, 3); f._fsScrollHint = scrollHint end
    end

    self.frame, self.headerTitle = f, f._fsHeaderTitle
    self.lockBtn, self.zoneBtn, self.levelBtn, self.hereBtn, self.minBtn = f._fsLockBtn, f._fsZoneBtn, f._fsLevelBtn, f._fsHereBtn, f._fsMinBtn
    self.scrollHint, self.rowWidgets = f._fsScrollHint, f._fsRows or {}
    self:ApplySavedAnchor(f)
    return f
end

function QuestTracker:RenderSnapshot(snapshot)
    if not (self.frame and snapshot) then return end
    if not (ns.ProfileManager:Get("quest", "trackerEnabled") and self.active) then
        if self.frame.Hide then self.frame:Hide() end
        self:SyncQuestItemButtons()
        return
    end
    if self.frame.Show then self.frame:Show() end

    local minimized = ns.ProfileManager:Get("quest", "trackerMinimized") and true or false
    ns.UI.StylePillButton(self.lockBtn, ns.ProfileManager:Get("quest", "trackerLocked") and true or false)
    ns.UI.StylePillButton(self.zoneBtn, snapshot.mode == "zone")
    ns.UI.StylePillButton(self.levelBtn, snapshot.mode == "level")
    ns.UI.StylePillButton(self.hereBtn, ns.ProfileManager:Get("quest", "currentZoneOnly") and true or false)
    ns.UI.StylePillButton(self.minBtn, minimized)
    if self.minBtn and self.minBtn._fsLabel then self.minBtn._fsLabel:SetText(minimized and "+" or "–") end

    if self.headerTitle then
        if snapshot.questLogUnavailable then
            self.headerTitle:SetText("퀘스트 |cff94a3b8—|r")
        elseif snapshot.visibleQuests == 0 then
            self.headerTitle:SetText("퀘스트 |cff94a3b80|r")
        elseif snapshot.visibleCompleted > 0 then
            self.headerTitle:SetText(string_format("퀘스트 |cff4ade80%d|r/|cffcbd5e1%d|r", snapshot.visibleCompleted, snapshot.visibleQuests))
        else
            self.headerTitle:SetText(string_format("퀘스트 |cffcbd5e1%d|r", snapshot.visibleQuests))
        end
    end

    if minimized then
        for i = 1, #self.rowWidgets do
            if self.rowWidgets[i].Hide then self.rowWidgets[i]:Hide() end
        end
        if self.scrollHint then self.scrollHint:SetText("") end
        self.lastFrameHeight = HEADER_HEIGHT
        self.frame:SetSize(TRACKER_WIDTH, HEADER_HEIGHT)
        self:SyncQuestItemButtons()
        return
    end

    local totalRows = #snapshot.rows
    local maxOffset = math_max(0, totalRows - MAX_VISIBLE_ROWS)
    if self.scrollOffset > maxOffset then self.scrollOffset = maxOffset end

    local shownCount = math_min(MAX_VISIBLE_ROWS, math_max(0, totalRows - self.scrollOffset))
    for i = 1, MAX_VISIBLE_ROWS do
        local widget = self.rowWidgets[i]
        local rowData = snapshot.rows[self.scrollOffset + i]
        if widget and i <= shownCount and rowData then
            widget._rowData = rowData
            if widget._leftText then widget._leftText:SetText(rowData.text or "") end
            if widget._rightText then widget._rightText:SetText(rowData.rightText or "") end
            ApplyRowRestingBg(widget._bg, rowData)
            if widget.Show then widget:Show() end
        elseif widget then
            widget._rowData = nil
            if widget.Hide then widget:Hide() end
        end
    end

    local footerExtra = 0
    if self.scrollHint then
        if totalRows > MAX_VISIBLE_ROWS then
            footerExtra = 14
            self.scrollHint:SetText(string_format("|cff94a3b8휠 스크롤 (%d~%d / %d줄)|r", self.scrollOffset + 1, self.scrollOffset + shownCount, totalRows))
        elseif snapshot.hiddenByFilter > 0 and snapshot.visibleQuests > 0 then
            footerExtra = 14
            self.scrollHint:SetText(string_format("|cff94a3b8타 지역 미완료 %d개 숨김|r", snapshot.hiddenByFilter))
        else
            self.scrollHint:SetText("")
        end
    end

    local totalHeight = HEADER_HEIGHT + 4 + math_max(1, shownCount) * ROW_HEIGHT + PADDING_BOTTOM + footerExtra
    self.lastFrameHeight = totalHeight
    self.frame:SetSize(TRACKER_WIDTH, totalHeight)
    self:SyncQuestItemButtons()
end

function QuestTracker:Refresh()
    if not self.active then return nil end
    local rawQuests, isAvailable = self:CollectLiveQuests()
    local snapshot = ns.QuestTrackerModel.BuildSnapshot(rawQuests, {
        groupMode = ns.ProfileManager:Get("quest", "groupMode") or "zone",
        playerLevel = self:QueryPlayerLevel(),
        currentZones = self:QueryCurrentZones(),
        superTrackedQuestID = self:QuerySuperTrackedQuestID(),
        currentZoneOnly = ns.ProfileManager:Get("quest", "currentZoneOnly") and true or false,
        watchedOnly = ns.ProfileManager:Get("quest", "watchedOnly") and true or false,
        questLogUnavailable = not isAvailable,
        isGroupCollapsed = function(groupKey) return ns.ProfileManager:IsQuestGroupCollapsed(groupKey) end,
        collapsedQuests = self.collapsedQuests,
    })
    self.lastSnapshot = snapshot
    self:RenderSnapshot(snapshot)
    self:SyncDefaultTrackerVisibility()
    return snapshot
end

function QuestTracker:Enable(ctx)
    self.active = true
    self:EnsureItemButtonPool()
    self:EnsureFrame(ctx)
    self:Refresh()
end

function QuestTracker:Disable()
    self.active = false
    self:SyncDefaultTrackerVisibility()
    self:SyncQuestItemButtons()
    local targetFrame = self.frame
    self.frame = nil
    if targetFrame and targetFrame.Hide then
        ns.CombatQueue:RunOrDefer("quest:hideTrackerFrame", function()
            if (not self.active) and targetFrame.Hide then targetFrame:Hide() end
        end)
    end
end
