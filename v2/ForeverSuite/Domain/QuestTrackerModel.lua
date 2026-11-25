-- Module: Domain/QuestTrackerModel.lua
-- Responsibility: Pure quest tracker grouping, sorting, dock slot assignment (1..6), and row view-model construction.
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G, zero CreateFrame).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local ipairs = ipairs
local tostring = tostring
local table_insert = table.insert
local table_sort = table.sort

local MAX_DOCK_SLOTS = 6

local QuestTrackerModel = {}
ns.Domain.QuestTrackerModel = QuestTrackerModel

function QuestTrackerModel.BuildSnapshot(quests, opts)
    opts = opts or {}
    local superQID = opts.superTrackedQuestID or 0
    local currentZone = opts.currentZone or ""
    local currentZoneOnly = opts.currentZoneOnly == true

    local filtered = {}
    for _, q in ipairs(quests or {}) do
        if type(q) == "table" and type(q.questID) == "number" then
            local zone = q.zone or "기타"
            if (not currentZoneOnly) or currentZone == "" or zone == currentZone then
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
        local az = a.zone or "기타"
        local bz = b.zone or "기타"
        if az ~= bz then
            return az < bz
        end
        return a.questID < b.questID
    end)

    local rows = {}
    local dockSlots = {}
    local slotByQuest = {}
    local lastZone = nil

    for _, q in ipairs(filtered) do
        local zone = q.zone or "기타"
        if zone ~= lastZone then
            table_insert(rows, {
                kind = "header",
                text = zone,
            })
            lastZone = zone
        end

        local dockSlot = nil
        if q.itemLink and q.itemLink ~= "" and #dockSlots < MAX_DOCK_SLOTS then
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

        local prefix = ""
        if dockSlot then
            prefix = "[" .. tostring(dockSlot) .. "] "
        end
        if q.isForever then
            prefix = prefix .. "[∞ 포에버] "
        end

        table_insert(rows, {
            kind = "quest",
            questID = q.questID,
            title = prefix .. (q.title or ("퀘스트 #" .. tostring(q.questID))),
            zone = zone,
            level = q.level or 0,
            isComplete = q.isComplete == true,
            isSuperTracked = (q.questID == superQID),
            dockSlot = dockSlot,
        })

        for _, obj in ipairs(q.objectives or {}) do
            table_insert(rows, {
                kind = "objective",
                questID = q.questID,
                text = tostring(obj.text or ""),
                finished = obj.finished == true,
            })
        end
    end

    return {
        rows = rows,
        dockSlots = dockSlots,
        slotByQuest = slotByQuest,
        questCount = #filtered,
    }
end
