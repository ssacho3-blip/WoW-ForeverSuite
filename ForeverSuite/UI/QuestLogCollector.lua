-- Module: UI/QuestLogCollector.lua
-- Responsibility: Live WoW 1.60.1 quest log reader, collapsed Blizzard header recovery, and quest special item metadata query.
-- Dependencies: Core/Init.lua (ns.IsSecret).
-- Public API: ns.QuestTracker:QueryPlayerLevel, QueryCurrentZones, QuerySuperTrackedQuestID, ResolveLiveSpecialItem, CollectLiveQuests.
-- Combat/Secret Safety: Read-only C_QuestLog/C_Map/C_SuperTrack/GetQuestLogSpecialItemInfo queries guarded by pcall and ns.IsSecret.
local _, ns = ...

local type = type
local pcall = pcall
local math_max = math.max
local math_min = math.min
local math_floor = math.floor

local QuestTracker = ns.QuestTracker or {}
ns.QuestTracker = QuestTracker

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

function QuestTracker:QueryQuestSpecialItemByLogIndex(logIndex)
    local cleanIdx = SafeNumber(logIndex)
    if not cleanIdx or cleanIdx <= 0 or type(_G.GetQuestLogSpecialItemInfo) ~= "function" then
        return nil, nil
    end
    local ok, itemLink, icon = pcall(_G.GetQuestLogSpecialItemInfo, math_floor(cleanIdx))
    if not ok then
        return nil, nil
    end
    local cleanLink = SafeString(itemLink)
    if not cleanLink then
        return nil, nil
    end
    local cleanIcon = (not ns.IsSecret(icon)) and icon or nil
    return cleanLink, cleanIcon
end

function QuestTracker:ResolveLiveSpecialItem(questID)
    local cleanQID = SafeNumber(questID)
    if not cleanQID or cleanQID <= 0 then
        return nil, nil
    end
    if C_QuestLog and C_QuestLog.GetLogIndexForQuestID then
        local okIdx, logIdx = pcall(C_QuestLog.GetLogIndexForQuestID, math_floor(cleanQID))
        local cleanIdx = okIdx and SafeNumber(logIdx) or nil
        if cleanIdx and cleanIdx > 0 then
            return self:QueryQuestSpecialItemByLogIndex(cleanIdx)
        end
    end
    return nil, nil
end

local function ResolveHeaderViaAPI(questID)
    if not (C_QuestLog and C_QuestLog.GetHeaderIndexForQuest and C_QuestLog.GetInfo) then
        return nil
    end
    local okHdrIdx, hdrIdx = pcall(C_QuestLog.GetHeaderIndexForQuest, questID)
    local cleanHdrIdx = okHdrIdx and SafeNumber(hdrIdx) or nil
    if not cleanHdrIdx or cleanHdrIdx <= 0 then
        return nil
    end
    local okHdr, hdrInfo = pcall(C_QuestLog.GetInfo, math_floor(cleanHdrIdx))
    if okHdr and not ns.IsSecret(hdrInfo) and type(hdrInfo) == "table"
        and SafeBool(hdrInfo.isHeader) and (not SafeBool(hdrInfo.isHidden)) then
        return SafeString(hdrInfo.title)
    end
    return nil
end

local function BuildQuestRecordFromInfo(tracker, info, logIndex, fallbackHeader, watchedSet)
    if ns.IsSecret(info) or type(info) ~= "table" then
        return nil
    end
    if SafeBool(info.isHeader) or SafeBool(info.isHidden) or SafeBool(info.isBounty)
        or SafeBool(info.isTask) or SafeBool(info.isInternalOnly) then
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

    local resolvedZone = ResolveHeaderViaAPI(qid) or fallbackHeader or "기타 퀘스트"
    local specialLink, specialIcon = tracker:QueryQuestSpecialItemByLogIndex(logIndex)

    return {
        questID = qid,
        logIndex = logIndex,
        title = title,
        zone = resolvedZone,
        level = qLevel,
        suggestedGroup = SafeNumber(info.suggestedGroup),
        frequency = SafeNumber(info.frequency),
        tagName = tagName,
        isElite = isElite,
        isComplete = isComplete,
        isFailed = SafeBool(info.isFailed),
        isOnMap = isOnMap,
        isWatched = isWatched,
        specialItemLink = specialLink,
        specialItemIcon = specialIcon,
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
    local nilStreak = 0

    for i = 1, 200 do
        local okInfo, info = pcall(C_QuestLog.GetInfo, i)
        if okInfo and not ns.IsSecret(info) and type(info) == "table" then
            nilStreak = 0
            if SafeBool(info.isHeader) then
                if not SafeBool(info.isHidden) then
                    local hdrTitle = SafeString(info.title)
                    if hdrTitle then
                        currentHeader = hdrTitle
                    end
                end
            else
                local rec = BuildQuestRecordFromInfo(self, info, i, currentHeader, watchedSet)
                if rec and not seen[rec.questID] then
                    seen[rec.questID] = true
                    quests[#quests + 1] = rec
                end
            end
        elseif i > count then
            nilStreak = nilStreak + 1
            if nilStreak >= 3 then
                break
            end
        end
    end

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
                            if okHdr and not ns.IsSecret(hdrInfo) and type(hdrInfo) == "table"
                                and SafeBool(hdrInfo.isHeader) and (not SafeBool(hdrInfo.isHidden)) then
                                local hdrTitle = SafeString(hdrInfo.title)
                                if hdrTitle then
                                    recoveredZone = hdrTitle
                                end
                                break
                            end
                        end
                        local rec = BuildQuestRecordFromInfo(self, info, idxFloor, recoveredZone, watchedSet)
                        if rec and not seen[rec.questID] then
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
