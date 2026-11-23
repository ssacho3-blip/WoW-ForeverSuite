-- Module: UI/FishingTargetModel.lua
-- Responsibility: Pure ViewModel for current-zone fishing target species, recommended skill, quest fish highlights, and GJ/Standalone DB lookup.
-- Dependencies: Core/Init.lua (ns.IsSecret).
-- Public API: ns.FishingTargetModel (ZONE_FISHING_SKILL, QUEST_FISH_ITEMS, BUILTIN_ZONE_FISH, ReadPlayerFishingSkill, ReadCurrentZoneContext, CollectActiveQuestContext, CollectZoneFishEntries, BuildViewModel, FormatChatSummary).
-- Combat/Secret Safety: Pure read-only data transformation; zero Frame creation; guards all WoW API return values with ns.IsSecret and pcall.
local _, ns = ...

local type = type
local pairs = pairs
local ipairs = ipairs
local pcall = pcall
local tonumber = tonumber
local tostring = tostring
local table_sort = table.sort
local string_find = string.find
local string_format = string.format

local MAX_VISIBLE_DEFAULT = 8
local FISHING_PROFESSION_ID = 356
local FISHING_BASE_SPELL_ID = 7620

local ZONE_FISHING_SKILL = {
    [1411] = 25,  [1412] = 25,  [1413] = 75,  [1416] = 225, [1417] = 225,
    [1420] = 25,  [1421] = 75,  [1422] = 300, [1423] = 425, [1424] = 150,
    [1425] = 300, [1426] = 25,  [1428] = 425, [1429] = 25,  [1430] = 425,
    [1431] = 150, [1432] = 75,  [1433] = 150, [1434] = 225, [1435] = 225,
    [1436] = 75,  [1437] = 150, [1438] = 25,  [1439] = 75,  [1440] = 150,
    [1441] = 225, [1442] = 150, [1443] = 225, [1444] = 300, [1445] = 225,
    [1446] = 300, [1447] = 300, [1448] = 300, [1449] = 300, [1450] = 300,
    [1451] = 425, [1452] = 425, [1453] = 75,  [1454] = 75,  [1455] = 75,
    [1456] = 75,  [1457] = 75,  [1458] = 75,
}

-- Nat Pagle's Master Angler quest targets (Quest #6607)
local QUEST_FISH_ITEMS = {
    [16967] = { questID = 6607, label = "내트 페이글 퀘스트 · 베르단티스 강" },
    [16968] = { questID = 6607, label = "내트 페이글 퀘스트 · 살데리스 해안" },
    [16969] = { questID = 6607, label = "내트 페이글 퀘스트 · 폭풍 해안" },
    [16970] = { questID = 6607, label = "내트 페이글 퀘스트 · 안개갈대 해안" },
}

-- Compact standalone fallback when GodJohnsonProfessionData is not loaded
local BUILTIN_ZONE_FISH = {
    [1411] = {
        { itemID = 6291, name = "비단잉어", use = "요리 1 · 내륙 수역" },
        { itemID = 6303, name = "줄무늬고등어", use = "요리 1 · 해안 수역" },
        { itemID = 6289, name = "긴주둥이진흙퉁돔", use = "요리 50 · 내륙 수역" },
    },
    [1412] = {
        { itemID = 6291, name = "비단잉어", use = "요리 1 · 호수/내륙" },
        { itemID = 6289, name = "긴주둥이진흙퉁돔", use = "요리 50 · 호수/내륙" },
    },
    [1413] = {
        { itemID = 6289, name = "긴주둥이진흙퉁돔", use = "요리 50 · 오아시스/내륙" },
        { itemID = 6358, name = "기름기 많은 아귀", use = "연금술(자유 행동) · 해안 어군", schoolPointCount = 1 },
        { itemID = 6359, name = "불지느러미퉁돔", use = "연금술(화염 오일) · 해안 어군", schoolPointCount = 1 },
        { itemID = 6522, name = "돌연변이 물고기", use = "요리(별미) · 통곡의 동굴/오아시스" },
    },
    [1420] = {
        { itemID = 6291, name = "비단잉어", use = "요리 1 · 청명 호수" },
        { itemID = 6289, name = "긴주둥이진흙퉁돔", use = "요리 50 · 청명 호수" },
    },
    [1424] = {
        { itemID = 6308, name = "표범메기", use = "요리 100 · 강/내륙" },
        { itemID = 6358, name = "기름기 많은 아귀", use = "연금술 · 해안" },
        { itemID = 21071, name = "총명어", use = "요리(마나 회복) · 강 어군", schoolPointCount = 1 },
    },
    [1426] = {
        { itemID = 6291, name = "비단잉어", use = "요리 1 · 얼음 호수" },
        { itemID = 6289, name = "긴주둥이진흙퉁돔", use = "요리 50 · 얼음 호수" },
    },
    [1429] = {
        { itemID = 6291, name = "비단잉어", use = "요리 1 · 수정 호수/돌무덤 호수" },
        { itemID = 6289, name = "긴주둥이진흙퉁돔", use = "요리 50 · 내륙 호수" },
    },
    [1432] = {
        { itemID = 6289, name = "긴주둥이진흙퉁돔", use = "요리 50 · 모단 호수" },
        { itemID = 6317, name = "모단호수 프렌지", use = "요리 50 · 모단 호수 특산" },
    },
    [1434] = {
        { itemID = 8365, name = "미스릴송어", use = "요리 175 · 내륙 강" },
        { itemID = 13422, name = "돌비늘뱀장어", use = "연금술(돌방패) · 해안" },
        { itemID = 16969, name = "폭풍 해안 참치", use = "내트 페이글 퀘스트 · 폭풍 해안" },
    },
    [1435] = {
        { itemID = 8365, name = "미스릴송어", use = "요리 175 · 내륙" },
        { itemID = 16970, name = "안개갈대 마히마히", use = "내트 페이글 퀘스트 · 안개갈대 해안" },
    },
    [1440] = {
        { itemID = 6308, name = "표범메기", use = "요리 100 · 내륙 수역" },
        { itemID = 21071, name = "총명어", use = "요리(마나 회복) · 강 어군", schoolPointCount = 1 },
    },
    [1443] = {
        { itemID = 6359, name = "불지느러미퉁돔", use = "연금술 · 해안" },
        { itemID = 16968, name = "살데리스 송어", use = "내트 페이글 퀘스트 · 살데리스 해안" },
    },
    [1444] = {
        { itemID = 13759, name = "밤비늘퉁돔", use = "요리(마나 회복) · 내륙(야간)" },
        { itemID = 13760, name = "성난태양연어", use = "요리(체력 회복) · 내륙(주간)" },
        { itemID = 16967, name = "페랄라스 아히", use = "내트 페이글 퀘스트 · 베르단티스 강" },
    },
    [1445] = {
        { itemID = 8365, name = "미스릴송어", use = "요리 175 · 내륙 수역" },
        { itemID = 6362, name = "돌비늘대구", use = "요리 175 · 해안 수역" },
    },
    [1446] = {
        { itemID = 13422, name = "돌비늘뱀장어", use = "연금술(돌방패) · 해안" },
        { itemID = 4603, name = "점박이놀래기", use = "요리 225 · 해안" },
        { itemID = 13757, name = "겨울오징어", use = "요리(민첩) · 해안(겨울)" },
        { itemID = 13756, name = "여름농어", use = "요리(체력) · 해안(여름)" },
    },
    [1447] = {
        { itemID = 13422, name = "돌비늘뱀장어", use = "연금술(돌방패) · 해안" },
        { itemID = 4603, name = "점박이놀래기", use = "요리 225 · 해안" },
        { itemID = 13757, name = "겨울오징어", use = "요리(민첩) · 해안(겨울)" },
    },
    [1453] = {
        { itemID = 6289, name = "긴주둥이진흙퉁돔", use = "요리 50 · 운하" },
        { itemID = 6308, name = "표범메기", use = "요리 100 · 운하" },
    },
    [1454] = {
        { itemID = 6289, name = "긴주둥이진흙퉁돔", use = "요리 50 · 명예의 골짜기" },
        { itemID = 6308, name = "표범메기", use = "요리 100 · 명예의 골짜기" },
    },
}

local FishingTargetModel = {
    ZONE_FISHING_SKILL = ZONE_FISHING_SKILL,
    QUEST_FISH_ITEMS = QUEST_FISH_ITEMS,
    BUILTIN_ZONE_FISH = BUILTIN_ZONE_FISH,
    MAX_VISIBLE_DEFAULT = MAX_VISIBLE_DEFAULT,
}
ns.FishingTargetModel = FishingTargetModel

local function SafeNumber(val)
    if val == nil or ns.IsSecret(val) then
        return nil
    end
    local n = tonumber(val)
    if n == nil or ns.IsSecret(n) or n ~= n then
        return nil
    end
    return n
end

local function SafeString(val)
    if type(val) ~= "string" or ns.IsSecret(val) or val == "" then
        return nil
    end
    return val
end

local function ResolveFishingSpellName()
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, FISHING_BASE_SPELL_ID)
        if ok and type(info) == "table" and not ns.IsSecret(info) then
            local nm = SafeString(info.name)
            if nm then
                return nm
            end
        end
    end
    return "낚시"
end

function FishingTargetModel:ReadPlayerFishingSkill()
    local fishingName = ResolveFishingSpellName()
    local getProfs = _G.GetProfessions
    local getProfInfo = _G.GetProfessionInfo
    if type(getProfs) == "function" and type(getProfInfo) == "function" then
        local ok, p1, p2, p3, p4, p5, p6 = pcall(getProfs)
        if ok then
            local slots = { p1, p2, p3, p4, p5, p6 }
            for i = 1, 6 do
                local idx = SafeNumber(slots[i])
                if idx and idx > 0 then
                    local okInfo, name, _, rank, maxRank, _, _, skillLine = pcall(getProfInfo, idx)
                    if okInfo then
                        local lineNum = SafeNumber(skillLine)
                        local nm = SafeString(name)
                        if lineNum == FISHING_PROFESSION_ID or nm == fishingName then
                            local r = SafeNumber(rank)
                            local m = SafeNumber(maxRank)
                            if r and r > 0 then
                                return r, m
                            end
                        end
                    end
                end
            end
        end
    end

    local getNumSkills = _G.GetNumSkillLines
    local getSkillInfo = _G.GetSkillLineInfo
    if type(getNumSkills) == "function" and type(getSkillInfo) == "function" then
        local okTotal, rawTotal = pcall(getNumSkills)
        local total = okTotal and SafeNumber(rawTotal) or nil
        if total and total > 0 then
            local cap = total > 300 and 300 or total
            for i = 1, cap do
                local okRow, name, isHeader, _, rank, _, _, maxRank = pcall(getSkillInfo, i)
                if okRow and not ns.IsSecret(isHeader) and not isHeader then
                    if SafeString(name) == fishingName then
                        local r = SafeNumber(rank)
                        local m = SafeNumber(maxRank)
                        if r and r > 0 then
                            return r, m
                        end
                    end
                end
            end
        end
    end

    return nil, nil
end

function FishingTargetModel:ReadCurrentZoneContext()
    local mapID = nil
    if C_Map and C_Map.GetBestMapForUnit then
        local ok, rawMap = pcall(C_Map.GetBestMapForUnit, "player")
        if ok then
            mapID = SafeNumber(rawMap)
        end
    end

    local zoneName = nil
    if type(_G.GetRealZoneText) == "function" then
        local ok, rz = pcall(_G.GetRealZoneText)
        zoneName = ok and SafeString(rz) or nil
    end
    if not zoneName and mapID and C_Map and C_Map.GetMapInfo then
        local okInfo, info = pcall(C_Map.GetMapInfo, mapID)
        if okInfo and type(info) == "table" and not ns.IsSecret(info) then
            zoneName = SafeString(info.name)
        end
    end
    if not zoneName and type(_G.GetZoneText) == "function" then
        local ok, z = pcall(_G.GetZoneText)
        zoneName = ok and SafeString(z) or nil
    end

    local subZone = nil
    if type(_G.GetSubZoneText) == "function" then
        local ok, sz = pcall(_G.GetSubZoneText)
        subZone = ok and SafeString(sz) or nil
    end

    return mapID, zoneName or "미확인 지역", subZone
end

function FishingTargetModel:CollectActiveQuestContext()
    local activeIDs = {}
    local objectiveTexts = {}
    if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo) then
        return activeIDs, objectiveTexts
    end

    local okNum, rawCount = pcall(C_QuestLog.GetNumQuestLogEntries)
    local count = okNum and SafeNumber(rawCount) or 0
    if not count or count <= 0 then
        return activeIDs, objectiveTexts
    end
    if count > 200 then
        count = 200
    end

    for idx = 1, count do
        local okInfo, info = pcall(C_QuestLog.GetInfo, idx)
        if okInfo and type(info) == "table" and not ns.IsSecret(info) then
            local isHeader = (not ns.IsSecret(info.isHeader)) and (info.isHeader == true)
            local qid = SafeNumber(info.questID)
            if (not isHeader) and qid and qid > 0 then
                activeIDs[qid] = true
                if C_QuestLog.GetQuestObjectives then
                    local okObj, objs = pcall(C_QuestLog.GetQuestObjectives, qid)
                    if okObj and type(objs) == "table" and not ns.IsSecret(objs) then
                        for j = 1, #objs do
                            local o = objs[j]
                            if type(o) == "table" and not ns.IsSecret(o) then
                                local finished = (not ns.IsSecret(o.finished)) and (o.finished == true)
                                local txt = SafeString(o.text)
                                if (not finished) and txt then
                                    objectiveTexts[#objectiveTexts + 1] = txt
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return activeIDs, objectiveTexts
end

function FishingTargetModel:CollectZoneFishEntries(mapID, gjCompanion)
    local mid = SafeNumber(mapID)
    if not mid then
        return {}, "NONE"
    end

    local gj = gjCompanion
    if gj == nil then
        gj = _G.GJCompanion
    end

    local out = {}
    local seen = {}
    local gjData = type(gj) == "table" and type(gj.ProfessionData472) == "table" and gj.ProfessionData472 or nil
    local gjByID = gjData and type(gjData.byID) == "table" and gjData.byID[FISHING_PROFESSION_ID] or nil
    local gatherings = gjByID and type(gjByID.gatherings) == "table" and gjByID.gatherings or nil
    local practicalItems = type(gj) == "table"
        and type(gj.ProfessionPracticalData5165) == "table"
        and type(gj.ProfessionPracticalData5165[FISHING_PROFESSION_ID]) == "table"
        and gj.ProfessionPracticalData5165[FISHING_PROFESSION_ID].items
        or nil

    if gatherings then
        for i = 1, #gatherings do
            local entry = gatherings[i]
            if type(entry) == "table" and type(entry.zones) == "table" then
                local matchedZone = nil
                for j = 1, #entry.zones do
                    local z = entry.zones[j]
                    if type(z) == "table" and SafeNumber(z.mapID) == mid then
                        matchedZone = z
                        break
                    end
                end
                if matchedZone then
                    local itemID = SafeNumber(entry.itemID)
                    local name = SafeString(entry.name)
                    local dedupeKey = itemID or name
                    if name and dedupeKey and not seen[dedupeKey] then
                        seen[dedupeKey] = true
                        local schoolCount = 0
                        local schoolPoints = {}
                        if type(matchedZone.points) == "table" then
                            for p = 1, #matchedZone.points do
                                local pt = matchedZone.points[p]
                                if type(pt) == "table" and pt.schoolPoint then
                                    schoolCount = schoolCount + 1
                                    local px = SafeNumber(pt.x)
                                    local py = SafeNumber(pt.y)
                                    if px and py and px >= 0 and px <= 100 and py >= 0 and py <= 100 then
                                        schoolPoints[#schoolPoints + 1] = { x = px, y = py }
                                    end
                                end
                            end
                        end
                        local prac = (itemID and type(practicalItems) == "table") and practicalItems[itemID] or nil
                        out[#out + 1] = {
                            itemID = itemID,
                            name = name,
                            icon = SafeString(entry.icon),
                            use = prac and SafeString(prac.use) or SafeString(entry.note),
                            levelNote = prac and SafeString(prac.level) or nil,
                            sourceNote = prac and SafeString(prac.source) or SafeString(matchedZone.note),
                            waterNote = SafeString(entry.fishingWater) or SafeString(matchedZone.note) or SafeString(entry.note),
                            schoolPointCount = schoolCount,
                            schoolPoints = schoolPoints,
                            requiredSkill = SafeNumber(matchedZone.requiredSkill) or SafeNumber(entry.requiredSkill),
                        }
                    end
                end
            end
        end
        if #out > 0 then
            return out, "GJ_DB"
        end
    end

    local fallback = BUILTIN_ZONE_FISH[mid]
    if type(fallback) == "table" and #fallback > 0 then
        for i = 1, #fallback do
            local f = fallback[i]
            out[#out + 1] = {
                itemID = f.itemID,
                name = f.name,
                use = f.use,
                waterNote = f.use,
                schoolPointCount = f.schoolPointCount or 0,
            }
        end
        return out, "BUILTIN"
    end

    return {}, "NONE"
end

local function IsQuestTargetFish(itemID, fishName, activeQuestIDs, activeObjectiveTexts)
    local qMeta = itemID and QUEST_FISH_ITEMS[itemID] or nil
    if qMeta and type(activeQuestIDs) == "table" and activeQuestIDs[qMeta.questID] then
        return true, qMeta.label
    end
    if type(fishName) == "string" and #fishName >= 4 and type(activeObjectiveTexts) == "table" then
        for i = 1, #activeObjectiveTexts do
            local txt = activeObjectiveTexts[i]
            if type(txt) == "string" and string_find(txt, fishName, 1, true) then
                return true, txt
            end
        end
    end
    return false, nil
end

local function CompareFishRows(a, b)
    if a.isQuestTarget ~= b.isQuestTarget then
        return a.isQuestTarget
    end
    local aCaught = (a.caughtCount or 0) > 0
    local bCaught = (b.caughtCount or 0) > 0
    if aCaught ~= bCaught then
        return aCaught
    end
    if a.hasSchool ~= b.hasSchool then
        return a.hasSchool
    end
    return tostring(a.name or "") < tostring(b.name or "")
end

function FishingTargetModel:BuildViewModel(opts)
    opts = type(opts) == "table" and opts or {}

    local mapID = SafeNumber(opts.mapID)
    local zoneName = SafeString(opts.zoneName)
    local subZone = SafeString(opts.subZone)
    if mapID == nil or zoneName == nil then
        local liveMap, liveZone, liveSub = self:ReadCurrentZoneContext()
        if mapID == nil then
            mapID = liveMap
        end
        if zoneName == nil then
            zoneName = liveZone
        end
        if subZone == nil then
            subZone = liveSub
        end
    end

    local skillRank = SafeNumber(opts.skillRank)
    local skillMax = SafeNumber(opts.skillMax)
    if opts.skillRank == nil and opts.useLiveSkill ~= false then
        skillRank, skillMax = self:ReadPlayerFishingSkill()
    end

    local activeQuestIDs = opts.activeQuestIDs
    local activeObjectiveTexts = opts.activeObjectiveTexts
    if activeQuestIDs == nil or activeObjectiveTexts == nil then
        local liveIDs, liveObjs = self:CollectActiveQuestContext()
        activeQuestIDs = activeQuestIDs or liveIDs
        activeObjectiveTexts = activeObjectiveTexts or liveObjs
    end

    local sessionByItemID = type(opts.sessionByItemID) == "table" and opts.sessionByItemID or {}
    local rawEntries, sourceKind = self:CollectZoneFishEntries(mapID, opts.gjCompanion)
    local recommendedSkill = mapID and ZONE_FISHING_SKILL[mapID] or nil

    local skillStatus = "UNKNOWN"
    local skillDelta = nil
    if skillRank and recommendedSkill then
        skillDelta = skillRank - recommendedSkill
        skillStatus = (skillDelta >= 0) and "OK" or "LOW"
    end

    local allRows = {}
    local questTargetCount = 0
    for i = 1, #rawEntries do
        local e = rawEntries[i]
        local isQT, questReason = IsQuestTargetFish(e.itemID, e.name, activeQuestIDs, activeObjectiveTexts)
        if isQT then
            questTargetCount = questTargetCount + 1
        end
        local caught = (e.itemID and SafeNumber(sessionByItemID[e.itemID])) or 0
        allRows[#allRows + 1] = {
            itemID = e.itemID,
            name = e.name,
            icon = e.icon,
            use = e.use,
            levelNote = e.levelNote,
            sourceNote = e.sourceNote,
            waterNote = e.waterNote,
            schoolPointCount = e.schoolPointCount or 0,
            schoolPoints = type(e.schoolPoints) == "table" and e.schoolPoints or {},
            hasSchool = (e.schoolPointCount or 0) > 0,
            requiredSkill = e.requiredSkill,
            isQuestTarget = isQT,
            questReason = questReason,
            caughtCount = caught,
        }
    end

    table_sort(allRows, CompareFishRows)

    local maxVisible = SafeNumber(opts.maxVisible) or MAX_VISIBLE_DEFAULT
    if maxVisible < 1 then
        maxVisible = 1
    end
    local visibleRows = {}
    for i = 1, #allRows do
        if i <= maxVisible then
            visibleRows[i] = allRows[i]
        else
            break
        end
    end

    local hiddenCount = #allRows - #visibleRows
    if hiddenCount < 0 then
        hiddenCount = 0
    end

    return {
        mapID = mapID,
        zoneName = zoneName or "미확인 지역",
        subZone = subZone,
        recommendedSkill = recommendedSkill,
        skillRank = skillRank,
        skillMax = skillMax,
        skillStatus = skillStatus,
        skillDelta = skillDelta,
        sourceKind = sourceKind,
        questTargetCount = questTargetCount,
        totalCount = #allRows,
        hiddenCount = hiddenCount,
        rows = visibleRows,
        allRows = allRows,
    }
end

function FishingTargetModel:FormatSkillBadge(vm)
    if type(vm) ~= "table" then
        return "|cff94a3b8숙련 —|r"
    end
    local rec = vm.recommendedSkill
    local rank = vm.skillRank
    if rank and rec then
        if vm.skillStatus == "OK" then
            return string_format("|cff4ade80숙련 %d|r |cff94a3b8/ 권장 %d|r", rank, rec)
        end
        return string_format("|cfffacc15숙련 %d|r |cfff87171/ 권장 %d (미끼 권장)|r", rank, rec)
    elseif rec then
        return string_format("|cff94a3b8권장 숙련 %d|r", rec)
    elseif rank then
        return string_format("|cffcbd5e1숙련 %d|r", rank)
    end
    return "|cff94a3b8숙련 자료 없음|r"
end

function FishingTargetModel:FormatChatSummary(vm)
    if type(vm) ~= "table" then
        return "현재 지역 낚시 정보를 확인할 수 없습니다."
    end
    local skillPart = vm.recommendedSkill and ("권장 숙련 " .. tostring(vm.recommendedSkill)) or "권장 숙련 미확인"
    if vm.skillRank then
        skillPart = "내 숙련 " .. tostring(vm.skillRank) .. " / " .. skillPart
    end
    if vm.totalCount == 0 then
        return string_format("[%s] (%s) — 등록된 대상어 기록이 없습니다.", vm.zoneName, skillPart)
    end
    local names = {}
    for i = 1, #vm.allRows do
        local r = vm.allRows[i]
        local tag = r.name
        if r.isQuestTarget then
            tag = "[퀘스트]" .. tag
        elseif r.hasSchool then
            tag = tag .. "(어군)"
        end
        if (r.caughtCount or 0) > 0 then
            tag = tag .. "x" .. tostring(r.caughtCount)
        end
        names[#names + 1] = tag
    end
    return string_format("[%s] (%s) 대상어 %d종: %s", vm.zoneName, skillPart, vm.totalCount, table.concat(names, ", "))
end

function FishingTargetModel:FindNearestSchoolPoint(row, playerX, playerY)
    if type(row) ~= "table" or type(row.schoolPoints) ~= "table" or #row.schoolPoints == 0 then
        return nil
    end
    local px = SafeNumber(playerX)
    local py = SafeNumber(playerY)
    local hasPlayer = (px ~= nil and py ~= nil and px >= 0 and px <= 100 and py >= 0 and py <= 100)
    local best = nil
    local bestDistSq = nil
    for i = 1, #row.schoolPoints do
        local pt = row.schoolPoints[i]
        if type(pt) == "table" then
            local x = SafeNumber(pt.x)
            local y = SafeNumber(pt.y)
            if x and y and x >= 0 and x <= 100 and y >= 0 and y <= 100 then
                if not hasPlayer then
                    return { x = x, y = y, dist = nil }
                end
                local dx = x - px
                local dy = y - py
                local dSq = (dx * dx) + (dy * dy)
                if bestDistSq == nil or dSq < bestDistSq then
                    bestDistSq = dSq
                    best = { x = x, y = y, dist = dSq ^ 0.5 }
                end
            end
        end
    end
    return best
end
