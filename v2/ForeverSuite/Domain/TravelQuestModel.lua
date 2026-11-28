-- Module: Domain/TravelQuestModel.lua
-- Responsibility: Pure KPI-11 Quest Progress Party Announcer diff engine & Special/Library Book guide filter.
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local ipairs = ipairs
local tostring = tostring
local string_lower = string.lower
local string_find = string.find
local table_insert = table.insert

local TravelQuestModel = {}
ns.Domain.TravelQuestModel = TravelQuestModel

-- Compares previous quest progress snapshot against current quest list and returns newly completed messages.
-- prevState: { [questID] = { isComplete = bool, objDone = { [idx] = bool } } }
-- Returns (announcements, nextState). When prevState is nil (initial prime), emits ZERO announcements.
function TravelQuestModel.DiffQuestProgress(prevState, currQuests)
    local nextState = {}
    local announcements = {}
    if type(currQuests) ~= "table" then
        return announcements, prevState
    end
    local isPrimed = (type(prevState) == "table")
    for _, q in ipairs(currQuests) do
        if type(q) == "table" and type(q.questID) == "number" and q.questID > 0 and type(q.title) == "string" then
            local prev = isPrimed and prevState[q.questID] or nil
            local curObj = {}
            local doneNow = (q.isComplete == true)
            for idx, o in ipairs(q.objectives or {}) do
                if type(o) == "table" then
                    local fin = (o.finished == true)
                    curObj[idx] = fin
                    if prev and fin and not (prev.objDone and prev.objDone[idx] == true) and not doneNow then
                        local txt = (type(o.text) == "string" and o.text ~= "") and o.text or ("목표 " .. tostring(idx))
                        table_insert(announcements, "[퀘스트 진행] " .. q.title .. " - " .. txt .. " 완료")
                    end
                end
            end
            if prev and doneNow and prev.isComplete ~= true then
                table_insert(announcements, "[퀘스트 완료] " .. q.title .. " (완료 보고 가능)")
            end
            nextState[q.questID] = {
                isComplete = doneNow,
                objDone = curObj,
            }
        end
    end
    return announcements, nextState
end

function TravelQuestModel.FilterSpecialGuides(entries, kindFilter, query)
    local out = {}
    if type(entries) ~= "table" then return out end
    local q = string_lower(tostring(query or ""))
    for _, e in ipairs(entries) do
        if type(e) == "table" and type(e.title) == "string" then
            local kOk = (not kindFilter) or kindFilter == "all" or e.kind == kindFilter
            if kOk then
                if q == "" then
                    table_insert(out, e)
                else
                    local hay = string_lower(e.title .. " " .. tostring(e.zone or "") .. " " .. tostring(e.note or "") .. " " .. tostring(e.altName or ""))
                    if string_find(hay, q, 1, true) then
                        table_insert(out, e)
                    end
                end
            end
        end
    end
    return out
end
