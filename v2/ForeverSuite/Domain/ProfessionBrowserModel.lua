-- Module: Domain/ProfessionBrowserModel.lua
-- Responsibility: Pure 13-Profession Guide model (routes, recipes by profession, trainers/directions filter).
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local ipairs = ipairs
local tostring = tostring
local string_lower = string.lower
local string_find = string.find
local table_insert = table.insert

local ProfessionBrowserModel = {}
ns.Domain.ProfessionBrowserModel = ProfessionBrowserModel

function ProfessionBrowserModel.FilterRecipes(allRecipes, profGuide, query)
    local out = {}
    if type(profGuide) ~= "table" then return out end
    local pid = profGuide.profID
    local pname = profGuide.title
    local q = string_lower(tostring(query or ""))
    for _, r in ipairs(allRecipes or {}) do
        if type(r) == "table" and ((pid and pid > 0 and r.profID == pid) or r.prof == pname) then
            if q == "" then
                table_insert(out, r)
            else
                local hay = string_lower(tostring(r.title or "") .. " " .. tostring(r.note or ""))
                if string_find(hay, q, 1, true) then
                    table_insert(out, r)
                end
            end
        end
    end
    return out
end

function ProfessionBrowserModel.FilterTrainers(allTrainers, profGuide, query)
    local out = {}
    if type(profGuide) ~= "table" then return out end
    local pid = profGuide.profID
    local pname = profGuide.title
    local q = string_lower(tostring(query or ""))
    for _, t in ipairs(allTrainers or {}) do
        if type(t) == "table" and ((pid and pid > 0 and t.profID == pid) or t.prof == pname) then
            if q == "" then
                table_insert(out, t)
            else
                local hay = string_lower(tostring(t.title or "") .. " " .. tostring(t.zone or "") .. " " .. tostring(t.note or ""))
                if string_find(hay, q, 1, true) then
                    table_insert(out, t)
                end
            end
        end
    end
    return out
end
