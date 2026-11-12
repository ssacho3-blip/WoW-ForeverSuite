local _, ns = ...

local type = type
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local tonumber = tonumber
local pcall = pcall
local setmetatable = setmetatable
local math_max = math.max
local math_min = math.min
local math_floor = math.floor
local string_format = string.format

local TRACKER_WIDTH = 308
local HEADER_HEIGHT = 30
local ROW_HEIGHT = 19
local MAX_VISIBLE_ROWS = 18
local PADDING_X = 10
local PADDING_BOTTOM = 8

local hookedDefaultFrames = setmetatable and setmetatable({}, { __mode = "k" }) or {}
local hookedEditModeFrames = setmetatable and setmetatable({}, { __mode = "k" }) or {}
local hiddenByUs = setmetatable and setmetatable({}, { __mode = "k" }) or {}

local QuestTracker = {
    frame = nil,
    headerTitle = nil,
    zoneBtn = nil,
    levelBtn = nil,
    hereBtn = nil,
    minBtn = nil,
    scrollHint = nil,
    rowWidgets = {},
    collapsedQuests = {},
    scrollOffset = 0,
    lastSnapshot = nil,
    active = false,
    _suppressAutoRefresh = false,
}
ns.QuestTracker = QuestTracker

local ACTIVE_BTN_BG = { 0.30, 0.24, 0.08, 0.98 }
local ACTIVE_BTN_BORDER = { 0.88, 0.73, 0.25, 1.00 }
local INACTIVE_BTN_BG = { 0.13, 0.16, 0.20, 0.95 }
local INACTIVE_BTN_BORDER = { 0.30, 0.35, 0.43, 0.90 }

local function SafeNumber(val)
    if ns.IsSecret(val) or type(val) ~= "number" then
        return nil
    end
    if val ~= val then
        return nil
    end
    return val
end

local function SafeString(val)
    if ns.IsSecret(val) or type(val) ~= "string" or val == "" then
        return nil
    end
    return val
end

local function SafeBool(val)
    if ns.IsSecret(val) then
        return false
    end
    return (val == true or val == 1) and true or false
end

local function StylePillButton(btn, isSelected)
    if not btn then
        return
    end
    btn._fsSelected = isSelected and true or false
    local bg = isSelected and ACTIVE_BTN_BG or INACTIVE_BTN_BG
    local bd = isSelected and ACTIVE_BTN_BORDER or INACTIVE_BTN_BORDER
    if btn._fsBg and btn._fsBg.SetColorTexture then
        btn._fsBg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
    end
    if btn._fsBorders then
        for i = 1, #btn._fsBorders do
            local tex = btn._fsBorders[i]
            if tex and tex.SetColorTexture then
                tex:SetColorTexture(bd[1], bd[2], bd[3], bd[4])
            end
        end
    end
    if btn._fsLabel and btn._fsLabel.SetTextColor then
        if isSelected then
            btn._fsLabel:SetTextColor(1.00, 0.88, 0.42, 1.00)
        else
            btn._fsLabel:SetTextColor(0.80, 0.84, 0.90, 1.00)
        end
    end
end

local function CreatePillButton(parent, label, width, height, tooltipTitle, tooltipBody, onClick)
    if not _G.CreateFrame then
        return nil
    end
    local btn = _G.CreateFrame("Button", nil, parent)
    btn:SetSize(width, height)
    if btn.RegisterForClicks then
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    end

    if btn.CreateTexture then
        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(btn)
        bg:SetColorTexture(INACTIVE_BTN_BG[1], INACTIVE_BTN_BG[2], INACTIVE_BTN_BG[3], INACTIVE_BTN_BG[4])
        btn._fsBg = bg

        local top = btn:CreateTexture(nil, "BORDER")
        top:SetHeight(1)
        top:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
        top:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 0, 0)

        local bottom = btn:CreateTexture(nil, "BORDER")
        bottom:SetHeight(1)
        bottom:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
        bottom:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)

        local left = btn:CreateTexture(nil, "BORDER")
        left:SetWidth(1)
        left:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
        left:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)

        local right = btn:CreateTexture(nil, "BORDER")
        right:SetWidth(1)
        right:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 0, 0)
        right:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)

        btn._fsBorders = { top, bottom, left, right }
    end

    local txt = ns.UI.CreateLabel(btn, label, "GameFontHighlightSmall", ns.UI.COLORS.TEXT)
    if txt then
        txt:SetPoint("CENTER", btn, "CENTER", 0, 0)
        btn._fsLabel = txt
    end

    StylePillButton(btn, false)

    btn:SetScript("OnEnter", function(self)
        if self._fsBg and self._fsBg.SetColorTexture then
            if self._fsSelected then
                self._fsBg:SetColorTexture(0.38, 0.30, 0.10, 1.00)
            else
                self._fsBg:SetColorTexture(0.22, 0.26, 0.33, 1.00)
            end
        end
        if tooltipTitle and _G.GameTooltip and _G.GameTooltip.SetOwner then
            _G.GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
            _G.GameTooltip:AddLine(tooltipTitle, 1.0, 0.85, 0.35)
            if tooltipBody then
                _G.GameTooltip:AddLine(tooltipBody, 0.82, 0.86, 0.92)
            end
            _G.GameTooltip:Show()
        end
    end)
    btn:SetScript("OnLeave", function(self)
        StylePillButton(self, self._fsSelected)
        if _G.GameTooltip and _G.GameTooltip.Hide then
            _G.GameTooltip:Hide()
        end
    end)
    btn:SetScript("OnClick", function(self, mouseBtn)
        if onClick then
            onClick(self, mouseBtn)
        end
    end)
    return btn
end

function QuestTracker:QueryPlayerLevel()
    if _G.UnitLevel then
        local ok, lvl = pcall(_G.UnitLevel, "player")
        if ok then
            local clean = SafeNumber(lvl)
            if clean and clean > 0 then
                return math_floor(clean)
            end
        end
    end
    return nil
end

function QuestTracker:QueryCurrentZones()
    local zones = {}
    if _G.GetRealZoneText then
        local ok, rz = pcall(_G.GetRealZoneText)
        if ok and SafeString(rz) then
            zones[#zones + 1] = rz
        end
    end
    if _G.GetZoneText then
        local ok, z = pcall(_G.GetZoneText)
        if ok and SafeString(z) then
            zones[#zones + 1] = z
        end
    end
    if C_Map and C_Map.GetBestMapForUnit and C_Map.GetMapInfo then
        local okMap, mapID = pcall(C_Map.GetBestMapForUnit, "player")
        if okMap and SafeNumber(mapID) then
            local okInfo, info = pcall(C_Map.GetMapInfo, mapID)
            if okInfo and not ns.IsSecret(info) and type(info) == "table" and SafeString(info.name) then
                zones[#zones + 1] = info.name
            end
        end
    end
    return zones
end

function QuestTracker:QuerySuperTrackedQuestID()
    if C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID then
        local ok, qid = pcall(C_SuperTrack.GetSuperTrackedQuestID)
        if ok then
            local clean = SafeNumber(qid)
            if clean and clean > 0 then
                return math_floor(clean)
            end
        end
    end
    return nil
end

local function BuildQuestRecordFromInfo(info, fallbackHeader, watchedSet)
    if ns.IsSecret(info) or type(info) ~= "table" then
        return nil
    end
    if SafeBool(info.isHeader) or SafeBool(info.isHidden) then
        return nil
    end
    local qid = SafeNumber(info.questID)
    if not qid or qid <= 0 then
        return nil
    end
    qid = math_floor(qid)

    local title = SafeString(info.title)
    if not title then
        return nil
    end

    local isComplete = SafeBool(info.isComplete)
    if not isComplete and C_QuestLog then
        if C_QuestLog.ReadyForTurnIn then
            local okReady, rVal = pcall(C_QuestLog.ReadyForTurnIn, qid)
            if okReady and SafeBool(rVal) then
                isComplete = true
            end
        end
        if not isComplete and C_QuestLog.IsComplete then
            local okComp, cVal = pcall(C_QuestLog.IsComplete, qid)
            if okComp and SafeBool(cVal) then
                isComplete = true
            end
        end
    end

    local tagName = nil
    local isElite = false
    if C_QuestLog and C_QuestLog.GetQuestTagInfo then
        local okTag, tagInfo = pcall(C_QuestLog.GetQuestTagInfo, qid)
        if okTag and not ns.IsSecret(tagInfo) and type(tagInfo) == "table" then
            tagName = SafeString(tagInfo.tagName)
            isElite = SafeBool(tagInfo.isElite)
        end
    end

    local isOnMap = SafeBool(info.isOnMap)
    if not isOnMap and C_QuestLog and C_QuestLog.IsOnMap then
        local okOnMap, onMapVal = pcall(C_QuestLog.IsOnMap, qid)
        if okOnMap and SafeBool(onMapVal) then
            isOnMap = true
        end
    end

    local isWatched = true
    if watchedSet ~= nil then
        isWatched = watchedSet[qid] and true or false
    elseif C_QuestLog and C_QuestLog.GetQuestWatchType then
        local okWatch, wType = pcall(C_QuestLog.GetQuestWatchType, qid)
        if okWatch then
            if ns.IsSecret(wType) then
                isWatched = false
            else
                isWatched = (wType ~= nil)
            end
        end
    end

    local objectives = {}
    if C_QuestLog and C_QuestLog.GetQuestObjectives then
        local okObj, rawObjs = pcall(C_QuestLog.GetQuestObjectives, qid)
        if okObj and not ns.IsSecret(rawObjs) and type(rawObjs) == "table" then
            for oi = 1, math_min(#rawObjs, 12) do
                local o = rawObjs[oi]
                if not ns.IsSecret(o) and type(o) == "table" then
                    local oText = SafeString(o.text)
                    if oText then
                        objectives[#objectives + 1] = {
                            text = oText,
                            finished = SafeBool(o.finished),
                        }
                    end
                end
            end
        end
    end

    local qLevel = SafeNumber(info.level)
    if not qLevel or qLevel <= 0 then
        qLevel = SafeNumber(info.difficultyLevel)
    end
    if (not qLevel or qLevel <= 0) and C_QuestLog and C_QuestLog.GetQuestDifficultyLevel then
        local okDL, dl = pcall(C_QuestLog.GetQuestDifficultyLevel, qid)
        if okDL then
            qLevel = SafeNumber(dl)
        end
    end

    return {
        questID = qid,
        title = title,
        zone = fallbackHeader or "기타 퀘스트",
        level = qLevel,
        suggestedGroup = SafeNumber(info.suggestedGroup),
        frequency = SafeNumber(info.frequency),
        tagName = tagName,
        isElite = isElite,
        isComplete = isComplete,
        isFailed = SafeBool(info.isFailed),
        isOnMap = isOnMap,
        isWatched = isWatched,
        objectives = objectives,
    }
end

function QuestTracker:CollectLiveQuests()
    if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo) then
        return {}, false
    end

    local okNum, numShown = pcall(C_QuestLog.GetNumQuestLogEntries)
    local rawCount = okNum and SafeNumber(numShown) or nil
    if rawCount == nil then
        return {}, false
    end
    local count = math_max(0, math_min(math_floor(rawCount), 200))

    local watchedSet = nil
    local watchedOrder = {}
    if C_QuestLog.GetNumQuestWatches and C_QuestLog.GetQuestIDForQuestWatchIndex then
        local okNW, numWatches = pcall(C_QuestLog.GetNumQuestWatches)
        local nWatches = okNW and SafeNumber(numWatches) or nil
        if nWatches and nWatches >= 0 then
            watchedSet = {}
            for w = 1, math_min(math_floor(nWatches), 60) do
                local okWID, wQuestID = pcall(C_QuestLog.GetQuestIDForQuestWatchIndex, w)
                local cleanWID = okWID and SafeNumber(wQuestID) or nil
                if cleanWID and cleanWID > 0 then
                    local qid = math_floor(cleanWID)
                    watchedSet[qid] = true
                    watchedOrder[#watchedOrder + 1] = qid
                end
            end
        end
    end

    local quests = {}
    local seen = {}
    local currentHeader = "기타 퀘스트"

    for i = 1, count do
        local okInfo, info = pcall(C_QuestLog.GetInfo, i)
        if okInfo and not ns.IsSecret(info) and type(info) == "table" then
            if SafeBool(info.isHeader) then
                local hdrTitle = SafeString(info.title)
                if hdrTitle then
                    currentHeader = hdrTitle
                end
            else
                local rec = BuildQuestRecordFromInfo(info, currentHeader, watchedSet)
                if rec and not seen[rec.questID] then
                    seen[rec.questID] = true
                    quests[#quests + 1] = rec
                end
            end
        end
    end

    -- Recover any watched quest hidden beneath a collapsed header in Blizzard's Quest Log
    if C_QuestLog.GetLogIndexForQuestID then
        for i = 1, #watchedOrder do
            local qid = watchedOrder[i]
            if not seen[qid] then
                local okIdx, logIdx = pcall(C_QuestLog.GetLogIndexForQuestID, qid)
                local cleanIdx = okIdx and SafeNumber(logIdx) or nil
                if cleanIdx and cleanIdx > 0 then
                    local idxFloor = math_floor(cleanIdx)
                    local okInfo, info = pcall(C_QuestLog.GetInfo, idxFloor)
                    if okInfo and not ns.IsSecret(info) and type(info) == "table" then
                        local recoveredZone = "접힌 목록"
                        local minScan = math_max(1, idxFloor - 40)
                        for k = idxFloor - 1, minScan, -1 do
                            local okHdr, hdrInfo = pcall(C_QuestLog.GetInfo, k)
                            if okHdr and not ns.IsSecret(hdrInfo) and type(hdrInfo) == "table" and SafeBool(hdrInfo.isHeader) then
                                local hdrTitle = SafeString(hdrInfo.title)
                                if hdrTitle then
                                    recoveredZone = hdrTitle
                                end
                                break
                            end
                        end
                        local rec = BuildQuestRecordFromInfo(info, recoveredZone, watchedSet)
                        if rec then
                            seen[rec.questID] = true
                            quests[#quests + 1] = rec
                        end
                    end
                end
            end
        end
    end

    return quests, true
end

local function IsEditModeActive()
    local em = _G.EditModeManagerFrame
    if not ns.IsSecret(em) and type(em) == "table" and not ns.IsSecret(em.editModeActive) and em.editModeActive == true then
        return true
    end
    return false
end

local function EnsureEditModeExitHook()
    local em = _G.EditModeManagerFrame
    if not ns.IsSecret(em) and type(em) == "table" and not hookedEditModeFrames[em] and em.HookScript then
        hookedEditModeFrames[em] = true
        pcall(em.HookScript, em, "OnHide", function()
            QuestTracker:SyncDefaultTrackerVisibility()
        end)
    end
end

function QuestTracker:SyncDefaultTrackerVisibility()
    EnsureEditModeExitHook()
    local shouldHide = self.active
        and ns.ProfileManager:Get("quest", "trackerEnabled")
        and ns.ProfileManager:Get("quest", "hideDefaultTracker")
        and true
        or false

    local targets = { _G.ObjectiveTrackerFrame, _G.QuestWatchFrame }
    for i = 1, #targets do
        local targetFrame = targets[i]
        if not ns.IsSecret(targetFrame) and type(targetFrame) == "table" then
            if shouldHide and not hookedDefaultFrames[targetFrame] and targetFrame.HookScript then
                hookedDefaultFrames[targetFrame] = true
                pcall(targetFrame.HookScript, targetFrame, "OnShow", function(shownFrame)
                    if not QuestTracker.active then
                        return
                    end
                    if not ns.ProfileManager:Get("quest", "trackerEnabled") or not ns.ProfileManager:Get("quest", "hideDefaultTracker") then
                        return
                    end
                    if IsEditModeActive() then
                        return
                    end
                    ns.CombatQueue:RunOrDefer("quest:hideDefault:" .. tostring(i), function()
                        if QuestTracker.active
                            and ns.ProfileManager:Get("quest", "trackerEnabled")
                            and ns.ProfileManager:Get("quest", "hideDefaultTracker")
                            and not IsEditModeActive()
                            and shownFrame.Hide
                        then
                            hiddenByUs[shownFrame] = true
                            shownFrame:Hide()
                        end
                    end)
                end)
            end

            if shouldHide then
                local currentlyShown = (not targetFrame.IsShown) or (targetFrame:IsShown() and true or false)
                if currentlyShown and not IsEditModeActive() then
                    ns.CombatQueue:RunOrDefer("quest:syncDefault:" .. tostring(i), function()
                        if QuestTracker.active
                            and ns.ProfileManager:Get("quest", "trackerEnabled")
                            and ns.ProfileManager:Get("quest", "hideDefaultTracker")
                            and not IsEditModeActive()
                            and targetFrame.Hide
                        then
                            hiddenByUs[targetFrame] = true
                            targetFrame:Hide()
                        end
                    end)
                end
            elseif hiddenByUs[targetFrame] then
                -- Keep hiddenByUs ownership intact if EditMode is currently active; restore once EditMode ends!
                if not IsEditModeActive() then
                    ns.CombatQueue:RunOrDefer("quest:syncDefault:" .. tostring(i), function()
                        if not IsEditModeActive() then
                            hiddenByUs[targetFrame] = nil
                            if targetFrame.Show then
                                targetFrame:Show()
                            end
                        end
                    end)
                end
            end
        end
    end
end

function QuestTracker:ApplySavedAnchor(frame)
    frame = frame or self.frame
    if not frame or not frame.SetPoint then
        return
    end
    local point = ns.ProfileManager:Get("quest", "trackerPoint") or "TOPRIGHT"
    local relPoint = ns.ProfileManager:Get("quest", "trackerRelPoint") or "TOPRIGHT"
    local x = tonumber(ns.ProfileManager:Get("quest", "trackerX")) or -22
    local y = tonumber(ns.ProfileManager:Get("quest", "trackerY")) or -215
    if frame.ClearAllPoints then
        frame:ClearAllPoints()
    end
    frame:SetPoint(point, _G.UIParent, relPoint, x, y)
end

function QuestTracker:SetGroupMode(mode)
    local normalized = (not ns.IsSecret(mode) and mode == "level") and "level" or "zone"
    if not ns.ProfileManager:CanWrite() then
        ns.Warn("읽기 전용 프로필(미래 스키마)에서는 설정을 저장할 수 없습니다.")
        return false, ns.ProfileManager:Get("quest", "groupMode") or "zone"
    end
    self._suppressAutoRefresh = true
    local ok = ns.ProfileManager:Set("quest", "groupMode", normalized, "account")
    self._suppressAutoRefresh = false
    if not ok then
        ns.Warn("읽기 전용 프로필(미래 스키마)에서는 설정을 저장할 수 없습니다.")
        return false, ns.ProfileManager:Get("quest", "groupMode") or "zone"
    end
    self.scrollOffset = 0
    self:Refresh()
    return true, normalized
end

function QuestTracker:ToggleGroupMode()
    local cur = ns.ProfileManager:Get("quest", "groupMode")
    local nxt = (cur == "level") and "zone" or "level"
    return self:SetGroupMode(nxt)
end

function QuestTracker:ToggleCurrentZoneFilter()
    local cur = ns.ProfileManager:Get("quest", "currentZoneOnly") and true or false
    if not ns.ProfileManager:CanWrite() then
        ns.Warn("읽기 전용 프로필(미래 스키마)에서는 설정을 저장할 수 없습니다.")
        return false, cur
    end
    local nxt = not cur
    self._suppressAutoRefresh = true
    local ok = ns.ProfileManager:Set("quest", "currentZoneOnly", nxt, "account")
    self._suppressAutoRefresh = false
    if not ok then
        ns.Warn("읽기 전용 프로필(미래 스키마)에서는 설정을 저장할 수 없습니다.")
        return false, cur
    end
    self.scrollOffset = 0
    self:Refresh()
    return true, nxt
end

function QuestTracker:ToggleMinimized()
    local cur = ns.ProfileManager:Get("quest", "trackerMinimized") and true or false
    if not ns.ProfileManager:CanWrite() then
        ns.Warn("읽기 전용 프로필(미래 스키마)에서는 설정을 저장할 수 없습니다.")
        return false, cur
    end
    local nxt = not cur
    self._suppressAutoRefresh = true
    local ok = ns.ProfileManager:Set("quest", "trackerMinimized", nxt, "account")
    self._suppressAutoRefresh = false
    if not ok then
        ns.Warn("읽기 전용 프로필(미래 스키마)에서는 설정을 저장할 수 없습니다.")
        return false, cur
    end
    self:Refresh()
    return true, nxt
end

function QuestTracker:ResetLayout()
    if not ns.ProfileManager:CanWrite() then
        ns.Warn("읽기 전용 프로필(미래 스키마)에서는 설정을 초기화할 수 없습니다.")
        return false
    end
    self._suppressAutoRefresh = true
    ns.ProfileManager:Set("quest", "trackerEnabled", true, "account")
    ns.ProfileManager:Set("quest", "groupMode", "zone", "account")
    ns.ProfileManager:Set("quest", "currentZoneOnly", false, "account")
    ns.ProfileManager:Set("quest", "watchedOnly", true, "account")
    ns.ProfileManager:Set("quest", "trackerMinimized", false, "account")
    ns.ProfileManager:Set("quest", "trackerPoint", "TOPRIGHT", "account")
    ns.ProfileManager:Set("quest", "trackerRelPoint", "TOPRIGHT", "account")
    ns.ProfileManager:Set("quest", "trackerX", -22, "account")
    ns.ProfileManager:Set("quest", "trackerY", -215, "account")
    ns.ProfileManager:ClearCollapsedQuestGroups()
    self._suppressAutoRefresh = false
    ns.WipeTable(self.collapsedQuests)
    self.scrollOffset = 0
    self:ApplySavedAnchor()
    self:Refresh()
    return true
end

function QuestTracker:OnRowClicked(rowWidget, mouseBtn)
    local data = rowWidget and rowWidget._rowData
    if type(data) ~= "table" then
        return
    end

    if data.kind == "group" and data.groupKey then
        if not ns.ProfileManager:CanWrite() then
            ns.Warn("읽기 전용 프로필(미래 스키마)에서는 설정을 저장할 수 없습니다.")
            return
        end
        self._suppressAutoRefresh = true
        if mouseBtn == "RightButton" then
            local snap = self.lastSnapshot
            if snap and type(snap.groups) == "table" then
                local anyExpanded = false
                for i = 1, #snap.groups do
                    if not snap.groups[i].isCollapsed then
                        anyExpanded = true
                        break
                    end
                end
                if anyExpanded then
                    for i = 1, #snap.groups do
                        ns.ProfileManager:SetQuestGroupCollapsed(snap.groups[i].key, true)
                    end
                else
                    ns.ProfileManager:ClearCollapsedQuestGroups()
                end
            end
        else
            local nowCollapsed = ns.ProfileManager:IsQuestGroupCollapsed(data.groupKey)
            ns.ProfileManager:SetQuestGroupCollapsed(data.groupKey, not nowCollapsed)
        end
        self._suppressAutoRefresh = false
        self:Refresh()
        return
    end

    if (data.kind == "quest" or data.kind == "objective") and data.questID then
        local qid = data.questID
        if mouseBtn == "RightButton" then
            if self.collapsedQuests[qid] then
                self.collapsedQuests[qid] = nil
            else
                self.collapsedQuests[qid] = true
            end
            self:Refresh()
            return
        end

        local shiftDown = (_G.IsShiftKeyDown and _G.IsShiftKeyDown()) and true or false
        if shiftDown and C_QuestLog then
            if data.isWatched and C_QuestLog.RemoveQuestWatch then
                pcall(C_QuestLog.RemoveQuestWatch, qid)
            elseif (not data.isWatched) and C_QuestLog.AddQuestWatch then
                pcall(C_QuestLog.AddQuestWatch, qid)
            end
            self:Refresh()
            return
        end

        if C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID then
            local currentSuper = self:QuerySuperTrackedQuestID()
            if currentSuper == qid then
                pcall(C_SuperTrack.SetSuperTrackedQuestID, 0)
            else
                pcall(C_SuperTrack.SetSuperTrackedQuestID, qid)
            end
            if C_QuestLog and C_QuestLog.SetSelectedQuest then
                pcall(C_QuestLog.SetSelectedQuest, qid)
            end
            self:Refresh()
        end
    end
end

local function CreateRowWidget(parent, rowIndex)
    local row = _G.CreateFrame("Button", nil, parent)
    row:SetSize(TRACKER_WIDTH - (PADDING_X * 2), ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", PADDING_X, -(HEADER_HEIGHT + 4 + (rowIndex - 1) * ROW_HEIGHT))
    if row.RegisterForClicks then
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    end

    if row.CreateTexture then
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(row)
        bg:SetColorTexture(0, 0, 0, 0)
        row._bg = bg
    end

    local leftText = ns.UI.CreateLabel(row, "", "GameFontHighlightSmall", ns.UI.COLORS.TEXT)
    if leftText then
        leftText:SetPoint("LEFT", row, "LEFT", 4, 0)
        if leftText.SetJustifyH then
            leftText:SetJustifyH("LEFT")
        end
        if leftText.SetWordWrap then
            leftText:SetWordWrap(false)
        end
        if leftText.SetWidth then
            leftText:SetWidth(TRACKER_WIDTH - (PADDING_X * 2) - 42)
        end
        row._leftText = leftText
    end

    local rightText = ns.UI.CreateLabel(row, "", "GameFontHighlightSmall", ns.UI.COLORS.MUTED)
    if rightText then
        rightText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        if rightText.SetJustifyH then
            rightText:SetJustifyH("RIGHT")
        end
        row._rightText = rightText
    end

    row:SetScript("OnEnter", function(self)
        local d = self._rowData
        if self._bg and self._bg.SetColorTexture and d and d.kind ~= "empty" then
            self._bg:SetColorTexture(0.22, 0.26, 0.34, 0.55)
        end
        if d and _G.GameTooltip and _G.GameTooltip.SetOwner then
            if d.kind == "group" then
                _G.GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                _G.GameTooltip:AddLine("그룹 접기 / 펼치기", 1.0, 0.85, 0.35)
                _G.GameTooltip:AddLine("좌클릭: 현재 그룹 토글  |  우클릭: 전체 그룹 일괄 접기/펼치기", 0.80, 0.84, 0.90)
                _G.GameTooltip:Show()
            elseif d.kind == "quest" then
                _G.GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                _G.GameTooltip:AddLine("퀘스트 포커스 및 제어", 1.0, 0.85, 0.35)
                _G.GameTooltip:AddLine("좌클릭: 목표 화살표(SuperTrack) 지정/해제", 0.85, 0.90, 0.95)
                _G.GameTooltip:AddLine("우클릭: 세부 목표 접기  |  Shift+좌클릭: 추적 해제", 0.72, 0.78, 0.86)
                _G.GameTooltip:Show()
            end
        end
    end)

    row:SetScript("OnLeave", function(self)
        local d = self._rowData
        if self._bg and self._bg.SetColorTexture then
            if d and d.kind == "group" then
                if d.isCurrentZone then
                    self._bg:SetColorTexture(0.24, 0.20, 0.08, 0.72)
                else
                    self._bg:SetColorTexture(0.14, 0.17, 0.22, 0.72)
                end
            elseif d and d.kind == "quest" and d.isSuperTracked then
                self._bg:SetColorTexture(0.26, 0.22, 0.09, 0.45)
            else
                self._bg:SetColorTexture(0, 0, 0, 0)
            end
        end
        if _G.GameTooltip and _G.GameTooltip.Hide then
            _G.GameTooltip:Hide()
        end
    end)

    row:SetScript("OnClick", function(self, mouseBtn)
        QuestTracker:OnRowClicked(self, mouseBtn)
    end)

    return row
end

function QuestTracker:EnsureFrame(ctx)
    if self.frame then
        return self.frame
    end
    local f = ctx:CreateFrame("Frame", "ForeverSuiteQuestTracker", _G.UIParent)
    if not f then
        return nil
    end

    if not f._fsTrackerInitialized then
        f._fsTrackerInitialized = true
        f:SetSize(TRACKER_WIDTH, HEADER_HEIGHT + 36)
        if f.SetClampedToScreen then
            f:SetClampedToScreen(true)
        end
        if f.SetMovable then
            f:SetMovable(true)
            f:EnableMouse(true)
            f:RegisterForDrag("LeftButton")
            f:SetScript("OnDragStart", function(selfFrame)
                if not ns.InCombat() and selfFrame.StartMoving then
                    selfFrame:StartMoving()
                end
            end)
            f:SetScript("OnDragStop", function(selfFrame)
                if selfFrame.StopMovingOrSizing then
                    selfFrame:StopMovingOrSizing()
                end
                if selfFrame.GetPoint and ns.ProfileManager:CanWrite() then
                    local pt, _, relPt, xOfs, yOfs = selfFrame:GetPoint(1)
                    if type(pt) == "string" and type(relPt) == "string" and type(xOfs) == "number" and type(yOfs) == "number" then
                        ns.ProfileManager:Set("quest", "trackerPoint", pt, "account")
                        ns.ProfileManager:Set("quest", "trackerRelPoint", relPt, "account")
                        ns.ProfileManager:Set("quest", "trackerX", math_floor(xOfs + 0.5), "account")
                        ns.ProfileManager:Set("quest", "trackerY", math_floor(yOfs + 0.5), "account")
                    end
                end
            end)
        end

        if f.EnableMouseWheel then
            f:EnableMouseWheel(true)
            f:SetScript("OnMouseWheel", function(_, delta)
                local snap = QuestTracker.lastSnapshot
                if not snap or #snap.rows <= MAX_VISIBLE_ROWS then
                    return
                end
                local maxOffset = math_max(0, #snap.rows - MAX_VISIBLE_ROWS)
                local step = (type(delta) == "number" and delta > 0) and -2 or 2
                local nextOffset = math_max(0, math_min(maxOffset, QuestTracker.scrollOffset + step))
                if nextOffset ~= QuestTracker.scrollOffset then
                    QuestTracker.scrollOffset = nextOffset
                    QuestTracker:RenderSnapshot(snap)
                end
            end)
        end

        if f.CreateTexture then
            local bg = f:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints(f)
            bg:SetColorTexture(0.06, 0.07, 0.09, 0.86)

            local headerBg = f:CreateTexture(nil, "BORDER")
            headerBg:SetHeight(HEADER_HEIGHT)
            headerBg:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
            headerBg:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
            headerBg:SetColorTexture(0.10, 0.12, 0.16, 0.96)

            local topGold = f:CreateTexture(nil, "OVERLAY")
            topGold:SetHeight(1)
            topGold:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
            topGold:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
            topGold:SetColorTexture(0.83, 0.69, 0.22, 0.85)

            local sep = f:CreateTexture(nil, "OVERLAY")
            sep:SetHeight(1)
            sep:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -HEADER_HEIGHT)
            sep:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -HEADER_HEIGHT)
            sep:SetColorTexture(0.28, 0.32, 0.38, 0.80)
        end

        local title = ns.UI.CreateLabel(f, "퀘스트", "GameFontNormalSmall", ns.UI.COLORS.ACCENT)
        if title then
            title:SetPoint("LEFT", f, "TOPLEFT", PADDING_X, -(HEADER_HEIGHT / 2))
            f._fsHeaderTitle = title
        end

        local minBtn = CreatePillButton(
            f,
            "–",
            20,
            18,
            "퀘스트 추적창 접기/펼치기",
            "클릭하면 본문 목록을 최소화하거나 펼칩니다.",
            function()
                QuestTracker:ToggleMinimized()
            end
        )
        if minBtn then
            minBtn:SetPoint("RIGHT", f, "TOPRIGHT", -6, -(HEADER_HEIGHT / 2))
            f._fsMinBtn = minBtn
        end

        local hereBtn = CreatePillButton(
            f,
            "현지역",
            44,
            18,
            "현재 지역 퀘스트만 보기",
            "켜면 현재 지역 퀘스트와 완료(반납 가능) 퀘스트만 깔끔하게 표시합니다.",
            function()
                QuestTracker:ToggleCurrentZoneFilter()
            end
        )
        if hereBtn then
            hereBtn:SetPoint("RIGHT", minBtn, "LEFT", -4, 0)
            f._fsHereBtn = hereBtn
        end

        local levelBtn = CreatePillButton(
            f,
            "레벨별",
            44,
            18,
            "레벨별 분류 보기 (/fs quest level)",
            "내 레벨 대비 난이도 구간(수월·적정·도전) 및 레벨 순으로 퀘스트를 나눕니다.",
            function()
                QuestTracker:SetGroupMode("level")
            end
        )
        if levelBtn then
            levelBtn:SetPoint("RIGHT", hereBtn, "LEFT", -4, 0)
            f._fsLevelBtn = levelBtn
        end

        local zoneBtn = CreatePillButton(
            f,
            "지역별",
            44,
            18,
            "지역별 분류 보기 (/fs quest zone)",
            "현재 머무는 지역을 최상단에 고정하고 지역별로 퀘스트를 깔끔하게 묶습니다.",
            function()
                QuestTracker:SetGroupMode("zone")
            end
        )
        if zoneBtn then
            zoneBtn:SetPoint("RIGHT", levelBtn, "LEFT", -4, 0)
            f._fsZoneBtn = zoneBtn
        end

        f._fsRows = {}
        for idx = 1, MAX_VISIBLE_ROWS do
            f._fsRows[idx] = CreateRowWidget(f, idx)
        end

        local scrollHint = ns.UI.CreateLabel(f, "", "GameFontHighlightSmall", ns.UI.COLORS.MUTED)
        if scrollHint then
            scrollHint:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PADDING_X, 3)
            f._fsScrollHint = scrollHint
        end
    end

    self.frame = f
    self.headerTitle = f._fsHeaderTitle
    self.zoneBtn = f._fsZoneBtn
    self.levelBtn = f._fsLevelBtn
    self.hereBtn = f._fsHereBtn
    self.minBtn = f._fsMinBtn
    self.scrollHint = f._fsScrollHint
    self.rowWidgets = f._fsRows or {}

    self:ApplySavedAnchor(f)
    return f
end

function QuestTracker:RenderSnapshot(snapshot)
    if not self.frame or not snapshot then
        return
    end

    local trackerEnabled = ns.ProfileManager:Get("quest", "trackerEnabled") and true or false
    if not trackerEnabled or not self.active then
        if self.frame.Hide then
            self.frame:Hide()
        end
        return
    end

    if self.frame.Show then
        self.frame:Show()
    end

    local mode = snapshot.mode
    local currentZoneOnly = ns.ProfileManager:Get("quest", "currentZoneOnly") and true or false
    local minimized = ns.ProfileManager:Get("quest", "trackerMinimized") and true or false

    StylePillButton(self.zoneBtn, mode == "zone")
    StylePillButton(self.levelBtn, mode == "level")
    StylePillButton(self.hereBtn, currentZoneOnly)
    StylePillButton(self.minBtn, minimized)
    if self.minBtn and self.minBtn._fsLabel then
        self.minBtn._fsLabel:SetText(minimized and "+" or "–")
    end

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
            if self.rowWidgets[i].Hide then
                self.rowWidgets[i]:Hide()
            end
        end
        if self.scrollHint then
            self.scrollHint:SetText("")
        end
        self.frame:SetSize(TRACKER_WIDTH, HEADER_HEIGHT)
        return
    end

    local totalRows = #snapshot.rows
    local maxOffset = math_max(0, totalRows - MAX_VISIBLE_ROWS)
    if self.scrollOffset > maxOffset then
        self.scrollOffset = maxOffset
    end

    local shownCount = math_min(MAX_VISIBLE_ROWS, math_max(0, totalRows - self.scrollOffset))
    for i = 1, MAX_VISIBLE_ROWS do
        local widget = self.rowWidgets[i]
        local rowData = snapshot.rows[self.scrollOffset + i]
        if widget and i <= shownCount and rowData then
            widget._rowData = rowData
            if widget._leftText then
                widget._leftText:SetText(rowData.text or "")
            end
            if widget._rightText then
                widget._rightText:SetText(rowData.rightText or "")
            end
            if widget._bg and widget._bg.SetColorTexture then
                if rowData.kind == "group" then
                    if rowData.isCurrentZone then
                        widget._bg:SetColorTexture(0.24, 0.20, 0.08, 0.72)
                    else
                        widget._bg:SetColorTexture(0.14, 0.17, 0.22, 0.72)
                    end
                elseif rowData.kind == "quest" and rowData.isSuperTracked then
                    widget._bg:SetColorTexture(0.26, 0.22, 0.09, 0.45)
                else
                    widget._bg:SetColorTexture(0, 0, 0, 0)
                end
            end
            if widget.Show then
                widget:Show()
            end
        elseif widget then
            widget._rowData = nil
            if widget.Hide then
                widget:Hide()
            end
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

    local bodyHeight = math_max(1, shownCount) * ROW_HEIGHT + PADDING_BOTTOM + footerExtra
    self.frame:SetSize(TRACKER_WIDTH, HEADER_HEIGHT + 4 + bodyHeight)
end

function QuestTracker:Refresh()
    if not self.active then
        return nil
    end
    local rawQuests, isAvailable = self:CollectLiveQuests()
    local snapshot = ns.QuestTrackerModel.BuildSnapshot(rawQuests, {
        groupMode = ns.ProfileManager:Get("quest", "groupMode") or "zone",
        playerLevel = self:QueryPlayerLevel(),
        currentZones = self:QueryCurrentZones(),
        superTrackedQuestID = self:QuerySuperTrackedQuestID(),
        currentZoneOnly = ns.ProfileManager:Get("quest", "currentZoneOnly") and true or false,
        watchedOnly = ns.ProfileManager:Get("quest", "watchedOnly") and true or false,
        questLogUnavailable = not isAvailable,
        isGroupCollapsed = function(groupKey)
            return ns.ProfileManager:IsQuestGroupCollapsed(groupKey)
        end,
        collapsedQuests = self.collapsedQuests,
    })
    self.lastSnapshot = snapshot
    self:RenderSnapshot(snapshot)
    self:SyncDefaultTrackerVisibility()
    return snapshot
end

function QuestTracker:Enable(ctx)
    self.active = true
    self:EnsureFrame(ctx)
    self:Refresh()
end

function QuestTracker:Disable()
    self.active = false
    self:SyncDefaultTrackerVisibility()
    local targetFrame = self.frame
    self.frame = nil
    if targetFrame and targetFrame.Hide then
        ns.CombatQueue:RunOrDefer("quest:hideTrackerFrame", function()
            if (not self.active) and targetFrame.Hide then
                targetFrame:Hide()
            end
        end)
    end
end
