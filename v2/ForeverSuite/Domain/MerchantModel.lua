-- Module: Domain/MerchantModel.lua
-- Responsibility: Pure buyback-budgeted (<=12) junk sell selector, guild-budget repair policy, durability %, and XP/h math.
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local ipairs = ipairs
local math_floor = math.floor
local table_insert = table.insert
local table_sort = table.sort

local BUYBACK_CAP = 12
local POOR_QUALITY = 0

local MerchantModel = {
    BUYBACK_CAP = BUYBACK_CAP,
}
ns.Domain.MerchantModel = MerchantModel

function MerchantModel.SelectJunkToSell(items, protectedSet, maxBatch, existingBuybackCount)
    -- Fail-closed if protectedSet or existingBuybackCount is missing/unreadable
    if type(protectedSet) ~= "table" or type(existingBuybackCount) ~= "number" or existingBuybackCount < 0 then
        return {}, 0, 0
    end
    local availSlots = BUYBACK_CAP - existingBuybackCount
    local cap = (availSlots > 0) and ((type(maxBatch) == "number" and maxBatch > 0 and maxBatch < availSlots) and maxBatch or availSlots) or 0

    local candidates = {}
    for _, it in ipairs(items or {}) do
        if type(it) == "table"
            and it.quality == POOR_QUALITY
            and it.isLocked == false
            and type(it.itemID) == "number"
            and not protectedSet[it.itemID]
            and type(it.unitPrice) == "number"
            and it.unitPrice > 0
        then
            local stack = (type(it.stackCount) == "number" and it.stackCount > 0) and it.stackCount or 1
            table_insert(candidates, {
                bag = it.bag,
                slot = it.slot,
                itemID = it.itemID,
                name = it.name or "",
                totalPrice = it.unitPrice * stack,
            })
        end
    end

    if cap <= 0 then
        return {}, 0, #candidates
    end

    table_sort(candidates, function(a, b)
        if a.totalPrice ~= b.totalPrice then
            return a.totalPrice > b.totalPrice
        end
        if a.bag ~= b.bag then return a.bag < b.bag end
        return a.slot < b.slot
    end)

    local batch = {}
    local expectedCopper = 0
    for i = 1, #candidates do
        if i <= cap then
            table_insert(batch, candidates[i])
            expectedCopper = expectedCopper + candidates[i].totalPrice
        end
    end
    local residual = (#candidates > cap) and (#candidates - cap) or 0
    return batch, expectedCopper, residual
end

function MerchantModel.SelectCheapestItems(items, protectedSet, limit)
    if type(protectedSet) ~= "table" then
        return {}
    end
    local cap = (type(limit) == "number" and limit > 0) and limit or 5
    local sellable = {}
    for _, it in ipairs(items or {}) do
        if type(it) == "table"
            and type(it.itemID) == "number"
            and not protectedSet[it.itemID]
            and it.isLocked == false
            and type(it.unitPrice) == "number"
            and it.unitPrice > 0
            and (it.quality or 0) <= 2
        then
            local stack = (type(it.stackCount) == "number" and it.stackCount > 0) and it.stackCount or 1
            table_insert(sellable, {
                bag = it.bag,
                slot = it.slot,
                itemID = it.itemID,
                name = it.name or ("#" .. tostring(it.itemID)),
                totalPrice = it.unitPrice * stack,
            })
        end
    end
    table_sort(sellable, function(a, b)
        if a.totalPrice ~= b.totalPrice then return a.totalPrice < b.totalPrice end
        return a.itemID < b.itemID
    end)
    local out = {}
    for i = 1, #sellable do
        if i <= cap then out[i] = sellable[i] end
    end
    return out
end

-- Parse item ID safely from either an item link ("|Hitem:1014:...|h") or a purely numeric string ("1014").
function MerchantModel.ParseItemIDArg(raw)
    if type(raw) ~= "string" then
        return nil
    end
    local fromLink = raw:match("item:(%d+)")
    if fromLink then
        return tonumber(fromLink)
    end
    local pureNum = raw:match("^%s*(%d+)%s*$")
    if pureNum then
        return tonumber(pureNum)
    end
    return nil
end

function MerchantModel.DecideRepair(cost, canRepair, canGuildRepair, useGuildSetting, playerMoney, guildWithdrawLimit, guildBankMoney)
    if not canRepair or type(cost) ~= "number" or cost <= 0 then
        return "NONE"
    end
    if useGuildSetting and canGuildRepair then
        local withdrawOk = (guildWithdrawLimit == nil) or (guildWithdrawLimit == -1) or (type(guildWithdrawLimit) == "number" and guildWithdrawLimit >= cost)
        local bankOk = (guildBankMoney == nil) or (type(guildBankMoney) == "number" and guildBankMoney >= cost)
        if withdrawOk and bankOk then
            return "GUILD"
        end
    end
    if type(playerMoney) == "number" and playerMoney >= cost then
        return "PERSONAL"
    end
    return "INSUFFICIENT_FUNDS"
end

function MerchantModel.ComputeDurabilityPct(slots)
    local curSum = 0
    local maxSum = 0
    for _, s in ipairs(slots or {}) do
        if type(s) == "table" and type(s.cur) == "number" and type(s.max) == "number" and s.max > 0 then
            curSum = curSum + s.cur
            maxSum = maxSum + s.max
        end
    end
    if maxSum <= 0 then
        return nil
    end
    return math_floor((curSum / maxSum) * 100 + 0.5)
end
