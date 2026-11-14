-- Module: UI/QuestTrackerModel.lua
-- Responsibility: Pure MVVM ViewModel transforming raw quest records into zone/level groups, difficulty bands, progress summaries, and flat HUD rows.
-- Dependencies: Core/Init.lua (ns.IsSecret).
-- Public API: ns.QuestTrackerModel (ComputeGreenRange, ComputeDifficulty, FormatQuestTagBadge, ParseObjectiveProgress, BuildSnapshot).
-- Combat/Secret Safety: 100% pure computation (zero WoW Frame/C_* calls); strips secret fields cleanly without math/comparison traps.
local _, ns = ...

local type, ipairs, pairs = type, ipairs, pairs
local tostring, tonumber = tostring, tonumber
local math_floor = math.floor
local string_format, string_gsub, string_match = string.format, string.gsub, string.match

local function SortList(list, lessFn)
    for i = 2, #list do
        local cur = list[i]
        local j = i - 1
        while j >= 1 and lessFn(cur, list[j]) do
            list[j + 1] = list[j]
            j = j - 1
        end
        list[j + 1] = cur
    end
end

local QuestTrackerModel = {}
ns.QuestTrackerModel = QuestTrackerModel

local DIFFICULTY_STYLES = {
    trivial    = { tier = "trivial",    band = "low",     bandOrder = 1, hex = "|cff94a3b8", rgb = { 0.58, 0.64, 0.72 } },
    easy       = { tier = "easy",       band = "low",     bandOrder = 1, hex = "|cff4ade80", rgb = { 0.29, 0.87, 0.50 } },
    standard   = { tier = "standard",   band = "mid",     bandOrder = 2, hex = "|cffffd23f", rgb = { 1.00, 0.82, 0.25 } },
    hard       = { tier = "hard",       band = "high",    bandOrder = 3, hex = "|cffff8c38", rgb = { 1.00, 0.55, 0.22 } },
    impossible = { tier = "impossible", band = "high",    bandOrder = 3, hex = "|cffff4d4d", rgb = { 1.00, 0.30, 0.30 } },
    unknown    = { tier = "unknown",    band = "unknown", bandOrder = 4, hex = "|cffcbd5e1", rgb = { 0.80, 0.84, 0.88 } },
}

local LEVEL_BAND_LABELS = {
    low = "수월 · 저레벨",
    mid = "적정 레벨",
    high = "도전 · 고레벨",
    unknown = "기타 레벨",
}

local LEVEL_BAND_ACCENT = {
    low = "|cff4ade80",
    mid = "|cffffd23f",
    high = "|cffff8c38",
    unknown = "|cff94a3b8",
}

local function SafeNumber(val)
    if ns.IsSecret(val) or type(val) ~= "number" or val ~= val then return nil end
    return val
end

local function SafeString(val)
    if ns.IsSecret(val) or type(val) ~= "string" then return nil end
    local trimmed = string_match(val, "^%s*(.-)%s*$")
    return (trimmed and trimmed ~= "") and trimmed or nil
end

local function SafeBool(val)
    if ns.IsSecret(val) then return false end
    return (val == true or val == 1) and true or false
end

local function StripColorCodes(text)
    if type(text) ~= "string" then return "" end
    local cleaned = string_gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    cleaned = string_gsub(cleaned, "|r", "")
    return string_match(cleaned, "^%s*(.-)%s*$") or ""
end

function QuestTrackerModel.ComputeGreenRange(playerLevel)
    local pLvl = SafeNumber(playerLevel) or 1
    if pLvl < 1 then pLvl = 1 end
    if pLvl <= 5 then return 4 end
    if pLvl <= 39 then return 5 + math_floor(pLvl / 10) end
    return 1 + math_floor(pLvl / 5)
end

function QuestTrackerModel.ComputeDifficulty(questLevel, playerLevel)
    local qLvl, pLvl = SafeNumber(questLevel), SafeNumber(playerLevel)
    if not qLvl or qLvl <= 0 or not pLvl or pLvl <= 0 then
        return DIFFICULTY_STYLES.unknown
    end
    local diff = qLvl - pLvl
    if diff >= 5 then return DIFFICULTY_STYLES.impossible end
    if diff >= 3 then return DIFFICULTY_STYLES.hard end
    if diff >= -2 then return DIFFICULTY_STYLES.standard end
    if diff >= -QuestTrackerModel.ComputeGreenRange(pLvl) then return DIFFICULTY_STYLES.easy end
    return DIFFICULTY_STYLES.trivial
end

function QuestTrackerModel.ParseObjectiveProgress(text)
    if ns.IsSecret(text) or type(text) ~= "string" then return nil, nil end
    local clean = StripColorCodes(text)
    if clean == "" then return nil, nil end
    local pre, cStr, mStr = string_match(clean, "^(.-)(%d+)%s*/%s*(%d+)%s*$")
    if cStr and pre ~= "" and string_match(pre, "[%d%.%-/]$") then
        cStr, mStr = nil, nil
    end
    if not cStr then
        cStr, mStr = string_match(clean, "^%(?(%d+)%s*/%s*(%d+)%)?%s+")
    end
    if not cStr then
        local c2, m2, post = string_match(clean, ":%s*(%d+)%s*/%s*(%d+)(.*)")
        if c2 and (post == "" or not string_match(post, "^[%d%.%/]")) then
            cStr, mStr = c2, m2
        end
    end
    if not cStr or not mStr then return nil, nil end
    local c, m = tonumber(cStr), tonumber(mStr)
    if not c or not m or m <= 0 or c < 0 then return nil, nil end
    return math_floor(c), math_floor(m)
end

function QuestTrackerModel.FormatQuestTagBadge(quest)
    if ns.IsSecret(quest) or type(quest) ~= "table" then return "" end
    local tagName = SafeString(quest.tagName)
    local isElite = SafeBool(quest.isElite)
    local groupSize = SafeNumber(quest.suggestedGroup) or 0
    local parts = {}

    if tagName then
        local color = "|cffcbd5e1"
        if string_match(tagName, "던전") or string_match(tagName, "Dungeon") then
            color = "|cff60a5fa"
        elseif string_match(tagName, "공격대") or string_match(tagName, "Raid") then
            color = "|cfff472b6"
        elseif string_match(tagName, "정예") or string_match(tagName, "Elite") or isElite then
            color = "|cffff8c38"
        end
        if groupSize >= 2 and not string_match(tagName, "%d") then
            parts[#parts + 1] = string_format("%s[%s %d인]|r", color, tagName, math_floor(groupSize))
        else
            parts[#parts + 1] = string_format("%s[%s]|r", color, tagName)
        end
    elseif isElite then
        if groupSize >= 2 then
            parts[#parts + 1] = string_format("|cffff8c38[정예 %d인]|r", math_floor(groupSize))
        else
            parts[#parts + 1] = "|cffff8c38[정예]|r"
        end
    elseif groupSize >= 2 then
        parts[#parts + 1] = string_format("|cffff8c38[%d인]|r", math_floor(groupSize))
    end

    local freq = SafeNumber(quest.frequency)
    if freq and freq >= 2 then parts[#parts + 1] = "|cff38bdf8[일일]|r" end
    if #parts == 0 then return "" end

    local joined = parts[1]
    for i = 2, #parts do joined = joined .. " " .. parts[i] end
    return joined
end

local function BuildZoneMatchSet(currentZones)
    local set = {}
    if ns.IsSecret(currentZones) then return set end
    if type(currentZones) == "table" then
        for _, z in ipairs(currentZones) do
            local clean = SafeString(z)
            if clean then set[StripColorCodes(clean)] = true end
        end
    elseif type(currentZones) == "string" then
        local clean = SafeString(currentZones)
        if clean then set[StripColorCodes(clean)] = true end
    end
    return set
end

local function NormalizeQuestEntry(raw, index, playerLevel, zoneMatchSet, superTrackedID)
    if ns.IsSecret(raw) or type(raw) ~= "table" then return nil end
    local qid = SafeNumber(raw.questID)
    if not qid or qid <= 0 then return nil end
    local title = SafeString(raw.title)
    if not title then return nil end
    local plainTitle = StripColorCodes(title)
    if plainTitle == "" then plainTitle = "퀘스트 #" .. tostring(math_floor(qid)) end

    local zone = SafeString(raw.zone) or "기타 퀘스트"
    local plainZone = StripColorCodes(zone)
    if plainZone == "" then plainZone = "기타 퀘스트" end

    local level = SafeNumber(raw.level)
    if level and level <= 0 then level = nil end

    local isComplete = SafeBool(raw.isComplete)
    local isFailed = SafeBool(raw.isFailed)
    local isOnMap = SafeBool(raw.isOnMap)
    local isWatched
    if ns.IsSecret(raw.isWatched) then
        isWatched = false
    elseif raw.isWatched == nil then
        isWatched = true
    else
        isWatched = SafeBool(raw.isWatched)
    end
    local isZoneNameMatch = zoneMatchSet[plainZone] and true or false
    local isCurrentZone = isZoneNameMatch or isOnMap
    local isSuperTracked = (superTrackedID ~= nil and qid == superTrackedID) and true or false

    local objectives = {}
    if not ns.IsSecret(raw.objectives) and type(raw.objectives) == "table" then
        for i = 1, #raw.objectives do
            local obj = raw.objectives[i]
            if not ns.IsSecret(obj) and type(obj) == "table" then
                local oText = SafeString(obj.text)
                if oText then
                    local cleanObj = StripColorCodes(oText)
                    local pCur, pMax = QuestTrackerModel.ParseObjectiveProgress(cleanObj)
                    objectives[#objectives + 1] = {
                        text = cleanObj,
                        finished = SafeBool(obj.finished),
                        progressCur = pCur,
                        progressMax = pMax,
                    }
                end
            end
        end
    end

    local logIndex = SafeNumber(raw.logIndex)
    if logIndex and logIndex <= 0 then logIndex = nil end

    return {
        questID = math_floor(qid),
        logIndex = logIndex and math_floor(logIndex) or nil,
        orderIndex = index,
        title = plainTitle,
        zone = plainZone,
        level = level and math_floor(level) or nil,
        difficulty = QuestTrackerModel.ComputeDifficulty(level, playerLevel),
        tagBadge = QuestTrackerModel.FormatQuestTagBadge(raw),
        isComplete = isComplete,
        isFailed = isFailed,
        isOnMap = isOnMap,
        isWatched = isWatched,
        isZoneNameMatch = isZoneNameMatch,
        isCurrentZone = isCurrentZone,
        isSuperTracked = isSuperTracked,
        specialItemLink = SafeString(raw.specialItemLink),
        specialItemIcon = (not ns.IsSecret(raw.specialItemIcon)) and raw.specialItemIcon or nil,
        objectives = objectives,
    }
end

local function CheckCollapsed(checker, key)
    if type(checker) == "function" then return checker(key) and true or false end
    if type(checker) == "table" then return checker[key] and true or false end
    return false
end

local function SortQuestsInZoneGroup(a, b)
    if a.isComplete ~= b.isComplete then return a.isComplete end
    if a.isSuperTracked ~= b.isSuperTracked then return a.isSuperTracked end
    local la, lb = a.level or 999, b.level or 999
    if la ~= lb then return la < lb end
    if a.title ~= b.title then return a.title < b.title end
    return a.questID < b.questID
end

local function SortQuestsInLevelGroup(a, b)
    local la, lb = a.level or 999, b.level or 999
    if la ~= lb then return la < lb end
    if a.isComplete ~= b.isComplete then return a.isComplete end
    if a.isCurrentZone ~= b.isCurrentZone then return a.isCurrentZone end
    if a.zone ~= b.zone then return a.zone < b.zone end
    if a.title ~= b.title then return a.title < b.title end
    return a.questID < b.questID
end

local function SortZoneGroups(a, b)
    if a.isCurrentZone ~= b.isCurrentZone then return a.isCurrentZone end
    if a.hasOnMap ~= b.hasOnMap then return a.hasOnMap end
    if a.hasSuperTracked ~= b.hasSuperTracked then return a.hasSuperTracked end
    local aHasDone, bHasDone = a.completedCount > 0, b.completedCount > 0
    if aHasDone ~= bHasDone then return aHasDone end
    local ma, mb = a.minLevel or 999, b.minLevel or 999
    if ma ~= mb then return ma < mb end
    if a.title ~= b.title then return a.title < b.title end
    return a.key < b.key
end

local function SortLevelGroups(a, b)
    if a.bandOrder ~= b.bandOrder then return a.bandOrder < b.bandOrder end
    return a.key < b.key
end

local function FormatQuestTitleLine(q, mode)
    local prefix = q.isComplete and "|cff4ade80●|r "
        or (q.isFailed and "|cfff87171×|r " or (q.isSuperTracked and "|cffffd23f▶|r " or "|cfffbbf24◆|r "))
    local lvlStr = q.level and string_format("%s[%d]|r ", q.difficulty.hex, q.level) or "|cff94a3b8[-]|r "
    local titleColor = q.isComplete and "|cffbbf7d0"
        or (q.isFailed and "|cfffca5a5" or (q.isSuperTracked and "|cfffff3a3" or "|cfffde68a"))
    local line = prefix .. lvlStr .. titleColor .. q.title .. "|r"

    if q.tagBadge ~= "" then line = line .. " " .. q.tagBadge end
    if mode == "level" and q.zone and q.zone ~= "" then
        local zColor = q.isCurrentZone and "|cffffd23f" or "|cff94a3b8"
        line = line .. " " .. zColor .. "· " .. q.zone .. "|r"
    end
    if q.isComplete then
        line = line .. " |cff4ade80[완료]|r"
    elseif q.isFailed then
        line = line .. " |cfff87171[실패]|r"
    end
    return line
end

local function FormatQuestRightBadge(q, questFolded)
    local summary = ""
    if questFolded then
        summary = q.isComplete and "|cff4ade80●|r |cffcbd5e1[+]|r"
            or (q.isFailed and "|cfff87171×|r |cffcbd5e1[+]|r" or "|cffcbd5e1[+]|r")
    elseif q.isComplete then
        summary = "|cff4ade80완료|r"
    elseif q.isFailed then
        summary = "|cfff87171실패|r"
    elseif #q.objectives == 1 then
        local o1 = q.objectives[1]
        if o1.progressCur ~= nil and o1.progressMax ~= nil then
            local col = o1.finished and "|cff4ade80" or ((o1.progressCur > 0) and "|cfffbbf24" or "|cff94a3b8")
            summary = string_format("%s%d/%d|r", col, o1.progressCur, o1.progressMax)
        elseif o1.finished then
            summary = "|cff4ade801/1|r"
        end
    elseif #q.objectives >= 2 then
        local doneCount, anyProgress = 0, false
        for i = 1, #q.objectives do
            local obj = q.objectives[i]
            if obj.finished then
                doneCount = doneCount + 1
                anyProgress = true
            elseif obj.progressCur and obj.progressCur > 0 then
                anyProgress = true
            end
        end
        local col = (doneCount == #q.objectives) and "|cff4ade80" or (anyProgress and "|cfffbbf24" or "|cff94a3b8")
        summary = string_format("%s%d/%d|r", col, doneCount, #q.objectives)
    end

    if q.specialItemLink then
        return (summary ~= "") and ("|cffffd23f[아이템]|r " .. summary) or "|cffffd23f[아이템]|r"
    end
    return summary
end

local function FormatGroupHeaderLine(g, mode)
    local arrow = g.isCollapsed and "|cffcbd5e1▶|r " or "|cffffd23f▼|r "
    local countBadge = (g.completedCount > 0)
        and string_format("|cff4ade80%d|r/|cfff8fafc%d|r", g.completedCount, g.count)
        or string_format("|cffcbd5e1%d|r", g.count)

    if mode == "level" then
        local accent = LEVEL_BAND_ACCENT[g.band] or "|cffcbd5e1"
        local rangeText = ""
        if g.minLevel and g.maxLevel then
            rangeText = (g.minLevel == g.maxLevel)
                and string_format(" |cffcbd5e1(Lv.%d)|r", g.minLevel)
                or string_format(" |cffcbd5e1(Lv.%d~%d)|r", g.minLevel, g.maxLevel)
        end
        return arrow .. accent .. g.title .. "|r" .. rangeText, countBadge
    end

    if g.isCurrentZone then
        return arrow .. "|cffffd23f" .. g.title .. "|r |cfffef08a[현재 지역]|r", countBadge
    end
    return arrow .. "|cfff8fafc" .. g.title .. "|r", countBadge
end

local function ComputeProgressStateAndFlashes(allNormalized, prevState)
    local nextState, flashQuests, flashObjs = {}, {}, {}
    local hasPrev = (not ns.IsSecret(prevState)) and type(prevState) == "table"
    for i = 1, #allNormalized do
        local q = allNormalized[i]
        local qid = q.questID
        local pq = hasPrev and prevState[qid] or nil
        local objsState = {}
        if type(pq) == "table" and q.isComplete and not pq.done then
            flashQuests[qid] = true
        end
        for oi = 1, #q.objectives do
            local obj = q.objectives[oi]
            objsState[oi] = { cur = obj.progressCur, fin = obj.finished }
            local po = (type(pq) == "table" and type(pq.objs) == "table") and pq.objs[oi] or nil
            if type(po) == "table" then
                local gained = (obj.finished and not po.fin)
                    or (obj.progressCur ~= nil and po.cur ~= nil and obj.progressCur > po.cur)
                if gained then
                    flashObjs[tostring(qid) .. ":" .. tostring(oi)] = true
                    flashQuests[qid] = true
                end
            end
        end
        nextState[qid] = { done = q.isComplete, objs = objsState }
    end
    return nextState, flashQuests, flashObjs
end

function QuestTrackerModel.BuildSnapshot(rawQuests, opts)
    opts = (not ns.IsSecret(opts) and type(opts) == "table") and opts or {}
    local mode = (not ns.IsSecret(opts.groupMode) and opts.groupMode == "level") and "level" or "zone"
    local playerLevel = SafeNumber(opts.playerLevel)
    local superTrackedID = SafeNumber(opts.superTrackedQuestID)
    local currentZoneOnly = SafeBool(opts.currentZoneOnly)
    local watchedOnly = SafeBool(opts.watchedOnly)
    local questLogUnavailable = SafeBool(opts.questLogUnavailable)
    local collapsedChecker = (not ns.IsSecret(opts.isGroupCollapsed)) and opts.isGroupCollapsed or nil
    local collapsedQuests = (not ns.IsSecret(opts.collapsedQuests) and type(opts.collapsedQuests) == "table") and opts.collapsedQuests or {}
    local zoneMatchSet = BuildZoneMatchSet(opts.currentZones)

    local allNormalized = {}
    local totalCompleted = 0
    if not questLogUnavailable and not ns.IsSecret(rawQuests) and type(rawQuests) == "table" then
        for i = 1, #rawQuests do
            local entry = NormalizeQuestEntry(rawQuests[i], i, playerLevel, zoneMatchSet, superTrackedID)
            if entry then
                allNormalized[#allNormalized + 1] = entry
                if entry.isComplete then totalCompleted = totalCompleted + 1 end
            end
        end
    end

    local progressState, flashQuests, flashObjs = ComputeProgressStateAndFlashes(allNormalized, opts.prevProgressState)

    local filtered = {}
    local visibleCompleted, hiddenByWatch, hiddenByZone = 0, 0, 0
    for i = 1, #allNormalized do
        local q = allNormalized[i]
        if watchedOnly and (not q.isWatched) and (not q.isSuperTracked) then
            hiddenByWatch = hiddenByWatch + 1
        elseif currentZoneOnly and (not q.isCurrentZone) and (not q.isComplete) and (not q.isSuperTracked) then
            hiddenByZone = hiddenByZone + 1
        else
            filtered[#filtered + 1] = q
            if q.isComplete then visibleCompleted = visibleCompleted + 1 end
        end
    end
    local hiddenByFilter = hiddenByWatch + hiddenByZone

    local groupsMap, groups = {}, {}
    for i = 1, #filtered do
        local q = filtered[i]
        local gKey, gTitle, band, bandOrder
        if mode == "level" then
            band, bandOrder = q.difficulty.band, q.difficulty.bandOrder
            gKey = "level:" .. band
            gTitle = LEVEL_BAND_LABELS[band] or "기타 레벨"
        else
            band, bandOrder = nil, 0
            gKey = "zone:" .. q.zone
            gTitle = q.zone
        end

        local grp = groupsMap[gKey]
        if not grp then
            grp = {
                key = gKey, title = gTitle, band = band, bandOrder = bandOrder,
                count = 0, completedCount = 0, minLevel = nil, maxLevel = nil,
                isCurrentZone = false, hasOnMap = false, hasSuperTracked = false,
                isCollapsed = CheckCollapsed(collapsedChecker, gKey), quests = {},
            }
            groupsMap[gKey] = grp
            groups[#groups + 1] = grp
        end

        grp.count = grp.count + 1
        if q.isComplete then grp.completedCount = grp.completedCount + 1 end
        if q.level then
            if not grp.minLevel or q.level < grp.minLevel then grp.minLevel = q.level end
            if not grp.maxLevel or q.level > grp.maxLevel then grp.maxLevel = q.level end
        end
        if mode == "zone" then
            if q.isZoneNameMatch then grp.isCurrentZone = true end
            if q.isOnMap then grp.hasOnMap = true end
        elseif q.isCurrentZone then
            grp.isCurrentZone = true
        end
        if q.isSuperTracked then grp.hasSuperTracked = true end
        grp.quests[#grp.quests + 1] = q
    end

    local questSorter = (mode == "level") and SortQuestsInLevelGroup or SortQuestsInZoneGroup
    for i = 1, #groups do SortList(groups[i].quests, questSorter) end
    SortList(groups, (mode == "level") and SortLevelGroups or SortZoneGroups)

    local rows = {}
    if #groups == 0 then
        local emptyMsg
        if questLogUnavailable then
            emptyMsg = "|cfff87171퀘스트 로그 데이터를 읽을 수 없습니다.|r"
        elseif #allNormalized == 0 then
            emptyMsg = "|cff94a3b8진행 중인 퀘스트가 없습니다.|r"
        elseif hiddenByWatch > 0 and hiddenByZone > 0 then
            emptyMsg = string_format("|cff94a3b8표시할 퀘스트 없음 (미추적 %d · 타 지역 %d 숨김)|r", hiddenByWatch, hiddenByZone)
        elseif hiddenByZone > 0 then
            emptyMsg = string_format("|cff94a3b8현재 지역 퀘스트 없음 (타 지역 %d개 숨김)|r", hiddenByZone)
        else
            emptyMsg = string_format("|cff94a3b8추적 중인 퀘스트 없음 (미추적 %d개 · /fs quest all)|r", hiddenByWatch)
        end
        rows[#rows + 1] = { kind = "empty", visualState = "empty", fontTier = "body", text = emptyMsg, rightText = "" }
    else
        for gi = 1, #groups do
            local grp = groups[gi]
            local headerLeft, headerRight = FormatGroupHeaderLine(grp, mode)
            rows[#rows + 1] = {
                kind = "group",
                visualState = grp.isCurrentZone and "group_current" or "group_other",
                fontTier = "header",
                groupKey = grp.key,
                text = headerLeft,
                rightText = headerRight,
                isCollapsed = grp.isCollapsed,
                isCurrentZone = grp.isCurrentZone,
            }

            if not grp.isCollapsed then
                for qi = 1, #grp.quests do
                    local q = grp.quests[qi]
                    local questFolded = collapsedQuests[q.questID] and true or false
                    local qState = q.isSuperTracked and "quest_super"
                        or (q.isComplete and "quest_complete" or (q.isFailed and "quest_failed" or "quest_active"))
                    rows[#rows + 1] = {
                        kind = "quest",
                        visualState = qState,
                        fontTier = "header",
                        questID = q.questID,
                        questTitle = q.title,
                        logIndex = q.logIndex,
                        groupKey = grp.key,
                        text = FormatQuestTitleLine(q, mode),
                        rightText = FormatQuestRightBadge(q, questFolded),
                        isComplete = q.isComplete,
                        isFailed = q.isFailed,
                        isSuperTracked = q.isSuperTracked,
                        isWatched = q.isWatched,
                        specialItemLink = q.specialItemLink,
                        specialItemIcon = q.specialItemIcon,
                        isFlashed = flashQuests[q.questID] and true or false,
                    }

                    if not questFolded then
                        if q.isComplete then
                            rows[#rows + 1] = {
                                kind = "objective",
                                visualState = "obj_done",
                                fontTier = "body",
                                questID = q.questID,
                                questTitle = q.title,
                                fullObjectiveText = "목표 달성 - NPC에게 완료 보고 가능",
                                text = "|cff4ade80● 목표 달성 - NPC에게 완료 보고 가능|r",
                                rightText = "",
                                finished = true,
                                isWatched = q.isWatched,
                                isFlashed = flashQuests[q.questID] and true or false,
                            }
                        else
                            for oi = 1, #q.objectives do
                                local obj = q.objectives[oi]
                                local inProgress = (not obj.finished) and (obj.progressCur ~= nil) and (obj.progressCur > 0)
                                local oState, oLine
                                if obj.finished then
                                    oState = "obj_done"
                                    oLine = "|cff4ade80●|r |cff94a3b8" .. obj.text .. "|r"
                                elseif inProgress then
                                    oState = "obj_progress"
                                    oLine = "|cfffbbf24▷|r |cfff8fafc" .. obj.text .. "|r"
                                else
                                    oState = "obj_pending"
                                    oLine = "|cff94a3b8·|r |cffe2e8f0" .. obj.text .. "|r"
                                end
                                rows[#rows + 1] = {
                                    kind = "objective",
                                    visualState = oState,
                                    fontTier = "body",
                                    questID = q.questID,
                                    questTitle = q.title,
                                    fullObjectiveText = obj.text,
                                    text = oLine,
                                    rightText = "",
                                    finished = obj.finished,
                                    isWatched = q.isWatched,
                                    isFlashed = flashObjs[tostring(q.questID) .. ":" .. tostring(oi)] and true or false,
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    return {
        mode = mode,
        questLogUnavailable = questLogUnavailable,
        totalQuests = #allNormalized,
        totalCompleted = totalCompleted,
        visibleQuests = #filtered,
        visibleCompleted = visibleCompleted,
        hiddenByWatch = hiddenByWatch,
        hiddenByZone = hiddenByZone,
        hiddenByFilter = hiddenByFilter,
        progressState = progressState,
        groups = groups,
        rows = rows,
    }
end
