-- Module: Domain/DungeonBrowserModel.lua
-- Responsibility: Pure 2-pane Dungeon Browser model (dungeon filter, boss->drop join, quest readiness checklist,
--                 and dungeon run report summary).
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
local math_floor = math.floor
local string_lower = string.lower
local string_find = string.find
local string_gmatch = string.gmatch
local string_format = string.format
local table_insert = table.insert

local DungeonBrowserModel = {}
ns.Domain.DungeonBrowserModel = DungeonBrowserModel

function DungeonBrowserModel.ParseIdCsv(csv)
    local out = {}
    if type(csv) ~= "string" or csv == "" then
        return out
    end
    for tok in string_gmatch(csv, "%d+") do
        local n = tonumber(tok)
        if n and n > 0 then
            table_insert(out, n)
        end
    end
    return out
end

function DungeonBrowserModel.FilterDungeons(dungeons, query, raidFilter)
    local out = {}
    if type(dungeons) ~= "table" then return out end
    local q = string_lower(tostring(query or ""))
    for _, d in ipairs(dungeons) do
        if type(d) == "table" and type(d.title) == "string" then
            local modeOk = true
            if raidFilter == "dungeon" then
                modeOk = (d.isRaid ~= true)
            elseif raidFilter == "raid" then
                modeOk = (d.isRaid == true)
            end
            if modeOk then
                if q == "" then
                    table_insert(out, d)
                else
                    local hay = string_lower(d.title .. " " .. tostring(d.zone or "") .. " " .. tostring(d.levels or ""))
                    if string_find(hay, q, 1, true) then
                        table_insert(out, d)
                    end
                end
            end
        end
    end
    return out
end

function DungeonBrowserModel.GetBossesForDungeon(allBosses, dungeon)
    local out = {}
    if type(dungeon) ~= "table" then
        return out
    end
    local dKey = tostring(dungeon.id or "")
    local dName = tostring(dungeon.title or "")
    local dInst = (type(dungeon.instance) == "number" and dungeon.instance > 0) and dungeon.instance or nil
    for _, b in ipairs(allBosses or {}) do
        if type(b) == "table" then
            local match = (dInst and b.instance == dInst)
                or (dKey ~= "" and b.dungeonKey == dKey)
                or (dName ~= "" and b.dungeonName == dName)
            if match then
                table_insert(out, b)
            end
        end
    end
    return out
end

function DungeonBrowserModel.IndexLootByItemID(allLoot)
    local idx = {}
    for _, it in ipairs(allLoot or {}) do
        if type(it) == "table" and type(it.itemID) == "number" and it.itemID > 0 then
            idx[it.itemID] = it
        end
    end
    return idx
end

function DungeonBrowserModel.GetDropsForBoss(boss, lootByID)
    local out = {}
    if type(boss) ~= "table" then
        return out
    end
    local ids = DungeonBrowserModel.ParseIdCsv(boss.itemsCsv)
    local map = type(lootByID) == "table" and lootByID or {}
    for _, iid in ipairs(ids) do
        local it = map[iid]
        if it then
            table_insert(out, it)
        else
            table_insert(out, {
                itemID = iid,
                title = "아이템 #" .. tostring(iid),
                quality = nil,
                placeholder = true,
                itemLevel = 0,
                slot = "",
                zone = boss.title or "보스 드랍",
            })
        end
    end
    return out
end

-- Evaluates live quest preparation checklist for a dungeon.
-- statusMap: { completed = { [qid]=true|false|nil }, inLog = { [qid]=true } }
function DungeonBrowserModel.BuildQuestReadiness(allQuests, dungeon, statusMap)
    local rows = {}
    local counts = { total = 0, completed = 0, inLog = 0, available = 0, prereq = 0 }
    if type(dungeon) ~= "table" then
        return rows, counts
    end
    local dKey = tostring(dungeon.id or "")
    local dName = tostring(dungeon.title or "")
    local st = type(statusMap) == "table" and statusMap or {}
    local comp = type(st.completed) == "table" and st.completed or {}
    local inLog = type(st.inLog) == "table" and st.inLog or {}

    for _, q in ipairs(allQuests or {}) do
        if type(q) == "table" and (q.dungeonKey == dKey or q.dungeonName == dName) then
            local qid = q.questID
            local state = "AVAILABLE"
            if comp[qid] == true then
                state = "COMPLETED"
                counts.completed = counts.completed + 1
            elseif inLog[qid] == true then
                state = "IN_LOG"
                counts.inLog = counts.inLog + 1
            elseif type(q.prereqID) == "number" and q.prereqID > 0 and comp[q.prereqID] == false then
                state = "PREREQ_NEEDED"
                counts.prereq = counts.prereq + 1
            else
                counts.available = counts.available + 1
            end
            counts.total = counts.total + 1
            table_insert(rows, {
                quest = q,
                state = state,
            })
        end
    end
    return rows, counts
end

function DungeonBrowserModel.FormatDuration(sec)
    if type(sec) ~= "number" or sec < 0 or sec ~= sec then
        return "00:00"
    end
    local s = math_floor(sec)
    local m = math_floor(s / 60)
    local r = s - m * 60
    return string_format("%02d:%02d", m, r)
end
