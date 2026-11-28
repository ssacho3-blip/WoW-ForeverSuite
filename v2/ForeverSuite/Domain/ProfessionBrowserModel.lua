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

function ProfessionBrowserModel.ComputeDeficit(requiredQty, ownedQty)
    local req = (type(requiredQty) == "number" and requiredQty > 0) and requiredQty or 0
    local own = (type(ownedQty) == "number" and ownedQty > 0) and ownedQty or 0
    local diff = req - own
    return (diff > 0) and diff or 0
end

-- Build Auctionator shopping list terms for missing materials (owned < targetQty, default targetQty = 1).
-- Zero fabricated prices: estimatedCopper sums only entries with real positive AH prices.
function ProfessionBrowserModel.BuildShoppingEntries(materialRows, getOwnedFn, getPriceFn, getNameFn, maxItems)
    local terms = {}
    local seen = {}
    local missingCount = 0
    local pricedCount = 0
    local estimatedCopper = 0
    local cap = (type(maxItems) == "number" and maxItems > 0) and maxItems or 40

    for _, m in ipairs(materialRows or {}) do
        if type(m) == "table" and type(m.itemID) == "number" and m.itemID > 0 then
            local targetQty = (type(m.qty) == "number" and m.qty > 0) and m.qty or 1
            local owned = (type(getOwnedFn) == "function") and (getOwnedFn(m.itemID) or 0) or 0
            local deficit = ProfessionBrowserModel.ComputeDeficit(targetQty, owned)
            if deficit > 0 then
                missingCount = missingCount + 1
                local name = (type(getNameFn) == "function") and getNameFn(m.itemID) or nil
                if type(name) == "string" and name ~= "" and not seen[name] and #terms < cap then
                    seen[name] = true
                    table_insert(terms, '"' .. name .. '"')
                    local unitPrice = (type(getPriceFn) == "function") and getPriceFn(m.itemID) or nil
                    if type(unitPrice) == "number" and unitPrice > 0 then
                        pricedCount = pricedCount + 1
                        estimatedCopper = estimatedCopper + (unitPrice * deficit)
                    end
                end
            end
        end
    end

    return {
        searchStrings = terms,
        missingCount = missingCount,
        pricedCount = pricedCount,
        estimatedCopper = estimatedCopper,
    }
end
