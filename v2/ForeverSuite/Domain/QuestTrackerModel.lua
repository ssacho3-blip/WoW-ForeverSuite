-- Module: Domain/QuestTrackerModel.lua
-- Responsibility: Pure quest tracker grouping (zone/level), filtering, group/quest collapse, 18-row scroll viewport,
--                 6-state visual classification, and dock slot assignment (1..6).
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G, zero CreateFrame).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
local math_max = math.max
local math_min = math.min
local math_floor = math.floor
local string_match = string.match
local table_insert = table.insert
local table_sort = table.sort

local MAX_DOCK_SLOTS = 6
local DEFAULT_MAX_VISIBLE_ROWS = 18

local QuestTrackerModel = {
    DEFAULT_MAX_VISIBLE_ROWS = DEFAULT_MAX_VISIBLE_ROWS,
}
ns.Domain.QuestTrackerModel = QuestTrackerModel

-- WoW Classic Original Quest Difficulty Colors (matching Blizzard QuestDifficultyColors)
QuestTrackerModel.CLASSIC_DIFFICULTY_COLORS = {
    red    = { 1.00, 0.10, 0.10, 1.00 }, -- 매우 어려움 (delta >= +5)
    orange = { 1.00, 0.50, 0.25, 1.00 }, -- 어려움 (delta >= +3)
    yellow = { 1.00, 1.00, 0.00, 1.00 }, -- 적정 - 현 레벨 (delta -2 .. +2)
    green  = { 0.25, 0.75, 0.25, 1.00 }, -- 쉬움 (delta > -greenRange)
    gray   = { 0.55, 0.55, 0.55, 1.00 }, -- 회색/낮음 (delta <= -greenRange)
}

-- Exact WoW Classic GetQuestGreenRange(playerLevel) table
function QuestTrackerModel.GetQuestGreenRange(playerLevel)
    local lv = (type(playerLevel) == "number" and playerLevel > 0) and math_floor(playerLevel) or 1
    if lv <= 5 then return 4 end
    if lv <= 9 then return 5 end
    if lv <= 19 then return 6 end
    if lv <= 29 then return 7 end
    if lv <= 39 then return 8 end
    if lv <= 49 then return 9 end
    if lv <= 54 then return 10 end
    if lv <= 59 then return 11 end
    return 12
end

-- Returns tone ("red"|"orange"|"yellow"|"green"|"gray") and Classic RGBA table {r, g, b, 1}
function QuestTrackerModel.GetClassicDifficulty(questLevel, playerLevel)
    local qLv = (type(questLevel) == "number" and questLevel > 0) and math_floor(questLevel) or 0
    local pLv = (type(playerLevel) == "number" and playerLevel > 0) and math_floor(playerLevel) or 0
    if qLv <= 0 or pLv <= 0 then
        return "yellow", QuestTrackerModel.CLASSIC_DIFFICULTY_COLORS.yellow
    end
    local delta = qLv - pLv
    if delta >= 5 then
        return "red", QuestTrackerModel.CLASSIC_DIFFICULTY_COLORS.red
    elseif delta >= 3 then
        return "orange", QuestTrackerModel.CLASSIC_DIFFICULTY_COLORS.orange
    elseif delta >= -2 then
        return "yellow", QuestTrackerModel.CLASSIC_DIFFICULTY_COLORS.yellow
    elseif delta > -QuestTrackerModel.GetQuestGreenRange(pLv) then
        return "green", QuestTrackerModel.CLASSIC_DIFFICULTY_COLORS.green
    end
    return "gray", QuestTrackerModel.CLASSIC_DIFFICULTY_COLORS.gray
end

local function LevelBucket(level)
    local lv = (type(level) == "number" and level > 0) and math_floor(level) or 0
    if lv <= 0 then
        return 0, "레벨 미상"
    end
    local low = math_floor((lv - 1) / 10) * 10 + 1
    local high = low + 9
    return low, "Lv." .. tostring(low) .. "-" .. tostring(high)
end

local function DetectObjectiveState(obj)
    if obj.finished == true then
        return "obj_done"
    end
    local txt = tostring(obj.text or ""):gsub(",", "")
    local cur, req = string_match(txt, "(%d+)%s*/%s*(%d+)")
    if cur and req then
        local c = tonumber(cur) or 0
        local r = tonumber(req) or 0
        if r > 0 and c > 0 then
            return "obj_progress"
        end
    end
    return "obj_pending"
end

function QuestTrackerModel.NormalizeGroupMode(raw)
    return (raw == "level") and "level" or "zone"
end

function QuestTrackerModel.ClampScrollOffset(offset, totalRows, maxVisible)
    local cap = (type(maxVisible) == "number" and maxVisible >= 1) and math_floor(maxVisible) or DEFAULT_MAX_VISIBLE_ROWS
    local total = (type(totalRows) == "number" and totalRows >= 0) and math_floor(totalRows) or 0
    local maxScroll = math_max(0, total - cap)
    local cur = (type(offset) == "number" and offset == offset) and math_floor(offset) or 0
    if cur < 0 then cur = 0 end
    if cur > maxScroll then cur = maxScroll end
    return cur, maxScroll
end

function QuestTrackerModel.BuildSnapshot(quests, opts)
    opts = type(opts) == "table" and opts or {}
    local superQID = (type(opts.superTrackedQuestID) == "number") and opts.superTrackedQuestID or 0
    local currentZone = (type(opts.currentZone) == "string") and opts.currentZone or ""
    local currentZoneOnly = opts.currentZoneOnly == true
    local watchedOnly = opts.watchedOnly == true
    local groupMode = QuestTrackerModel.NormalizeGroupMode(opts.groupMode)
    local collapsedGroups = (type(opts.collapsedGroups) == "table") and opts.collapsedGroups or {}
    local collapsedQuests = (type(opts.collapsedQuests) == "table") and opts.collapsedQuests or {}
    local minimized = opts.minimized == true
    local maxVisible = (type(opts.maxVisibleRows) == "number" and opts.maxVisibleRows >= 1)
        and math_floor(opts.maxVisibleRows) or DEFAULT_MAX_VISIBLE_ROWS

    local filtered = {}
    local totalAll = 0
    for _, q in ipairs(quests or {}) do
        if type(q) == "table" and type(q.questID) == "number" and q.questID > 0 then
            totalAll = totalAll + 1
            local zone = (type(q.zone) == "string" and q.zone ~= "") and q.zone or "기타"
            local zonePass = (not currentZoneOnly) or (currentZone == "") or (zone == currentZone)
            local watchPass = (not watchedOnly) or (q.isWatched == true) or (q.questID == superQID)
            if zonePass and watchPass then
                table_insert(filtered, q)
            end
        end
    end

    table_sort(filtered, function(a, b)
        local aSuper = (a.questID == superQID) and 1 or 0
        local bSuper = (b.questID == superQID) and 1 or 0
        if aSuper ~= bSuper then
            return aSuper > bSuper
        end
        if groupMode == "level" then
            local al = (type(a.level) == "number") and a.level or 0
            local bl = (type(b.level) == "number") and b.level or 0
            if al ~= bl then
                return al < bl
            end
        else
            local az = (type(a.zone) == "string" and a.zone ~= "") and a.zone or "기타"
            local bz = (type(b.zone) == "string" and b.zone ~= "") and b.zone or "기타"
            local aCur = (currentZone ~= "" and az == currentZone) and 1 or 0
            local bCur = (currentZone ~= "" and bz == currentZone) and 1 or 0
            if aCur ~= bCur then
                return aCur > bCur
            end
            if az ~= bz then
                return az < bz
            end
        end
        return a.questID < b.questID
    end)

    -- Group quests while preserving sorted order
    local groups = {}
    local groupMap = {}
    local dockSlots = {}
    local slotByQuest = {}

    for _, q in ipairs(filtered) do
        local zone = (type(q.zone) == "string" and q.zone ~= "") and q.zone or "기타"
        local gKey, gLabel, isCurZone
        if groupMode == "level" then
            local bLow, bLabel = LevelBucket(q.level)
            gKey = "lvl:" .. tostring(bLow)
            gLabel = bLabel
            isCurZone = false
        else
            gKey = "zone:" .. zone
            gLabel = zone
            isCurZone = (currentZone ~= "" and zone == currentZone)
        end

        local grp = groupMap[gKey]
        if not grp then
            grp = {
                key = gKey,
                label = gLabel,
                isCurrentZone = isCurZone,
                isCollapsed = collapsedGroups[gKey] == true,
                quests = {},
            }
            groupMap[gKey] = grp
            table_insert(groups, grp)
        end

        local dockSlot = nil
        if type(q.itemLink) == "string" and q.itemLink ~= "" and #dockSlots < MAX_DOCK_SLOTS then
            table_insert(dockSlots, {
                slot = #dockSlots + 1,
                questID = q.questID,
                itemLink = q.itemLink,
                itemIcon = q.itemIcon,
                title = q.title or ("퀘스트 #" .. tostring(q.questID)),
            })
            dockSlot = #dockSlots
            slotByQuest[q.questID] = dockSlot
        end

        table_insert(grp.quests, { quest = q, dockSlot = dockSlot, zone = zone })
    end

    local rows = {}
    if not minimized then
        for _, grp in ipairs(groups) do
            local marker = grp.isCollapsed and "▶ " or "▼ "
            table_insert(rows, {
                kind = "header",
                groupKey = grp.key,
                text = marker .. grp.label,
                rightText = "(" .. tostring(#grp.quests) .. ")",
                isCurrentZone = grp.isCurrentZone,
                isCollapsed = grp.isCollapsed,
                visualState = grp.isCurrentZone and "group_current" or "group_other",
            })

            if not grp.isCollapsed then
                for _, item in ipairs(grp.quests) do
                    local q = item.quest
                    local dockSlot = item.dockSlot
                    local prefix = ""
                    if dockSlot then
                        prefix = "[" .. tostring(dockSlot) .. "] "
                    end
                    if q.isForever then
                        prefix = prefix .. "[∞ 포에버] "
                    end
                    local isSuper = (q.questID == superQID)
                    local isComplete = q.isComplete == true
                    local isFailed = q.isFailed == true
                    local qCollapsed = collapsedQuests[q.questID] == true
                    local vState = isSuper and "quest_super"
                        or (isComplete and "quest_complete"
                        or (isFailed and "quest_failed" or "quest_active"))

                    local objs = type(q.objectives) == "table" and q.objectives or {}
                    local lvNum = (type(q.level) == "number" and q.level > 0) and math_floor(q.level) or 0
                    local rightTag = isComplete and "완료" or (isFailed and "실패" or (lvNum > 0 and ("Lv." .. tostring(lvNum)) or ""))
                    local playerLv = tonumber(opts.playerLevel) or 0
                    local diffTone, diffColor = QuestTrackerModel.GetClassicDifficulty(lvNum, playerLv)

                    table_insert(rows, {
                        kind = "quest",
                        questID = q.questID,
                        title = prefix .. (q.title or ("퀘스트 #" .. tostring(q.questID))),
                        rawTitle = q.title or ("퀘스트 #" .. tostring(q.questID)),
                        zone = item.zone,
                        level = lvNum,
                        difficultyTone = diffTone,
                        difficultyColor = diffColor,
                        rightText = rightTag,
                        isComplete = isComplete,
                        isFailed = isFailed,
                        isSuperTracked = isSuper,
                        isWatched = q.isWatched == true,
                        isCollapsed = qCollapsed,
                        dockSlot = dockSlot,
                        itemLink = q.itemLink,
                        objectives = objs,
                        visualState = vState,
                    })

                    if not qCollapsed then
                        for _, obj in ipairs(objs) do
                            local oState = DetectObjectiveState(obj)
                            table_insert(rows, {
                                kind = "objective",
                                questID = q.questID,
                                rawTitle = q.title or ("퀘스트 #" .. tostring(q.questID)),
                                zone = item.zone,
                                level = lvNum,
                                isComplete = isComplete,
                                isFailed = isFailed,
                                isWatched = q.isWatched == true,
                                text = tostring(obj.text or ""),
                                finished = obj.finished == true,
                                objectives = objs,
                                visualState = oState,
                            })
                        end
                    end
                end
            end
        end

        if #rows == 0 then
            table_insert(rows, {
                kind = "empty",
                text = currentZoneOnly and "현재 지역에 진행 중인 퀘스트가 없습니다." or "진행 중인 퀘스트가 없습니다.",
                rightText = "",
                visualState = "empty",
            })
        end
    end

    local totalRows = #rows
    local clampedScroll, maxScroll = QuestTrackerModel.ClampScrollOffset(opts.scrollOffset or 0, totalRows, maxVisible)
    local visibleRows = {}
    local startIdx = clampedScroll + 1
    local endIdx = math_min(totalRows, clampedScroll + maxVisible)
    for i = startIdx, endIdx do
        table_insert(visibleRows, rows[i])
    end

    return {
        rows = rows,
        visibleRows = visibleRows,
        totalRows = totalRows,
        scrollOffset = clampedScroll,
        maxScroll = maxScroll,
        groups = groups,
        dockSlots = dockSlots,
        slotByQuest = slotByQuest,
        questCount = #filtered,
        totalQuestCount = totalAll,
        hiddenCount = math_max(0, totalAll - #filtered),
        minimized = minimized,
        groupMode = groupMode,
    }
end
