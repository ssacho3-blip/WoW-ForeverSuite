-- Module: Domain/MailboxModel.lua
-- Responsibility: Pure Lua 5.1 Mailbox inbox analyzer (totals, COD safety filter, lootable indices).
-- Layer: Domain (ZERO _G / WoW API access; verified by fsx check).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local ipairs = ipairs
local math_floor = math.floor

local MailboxModel = {}
ns.Domain.MailboxModel = MailboxModel

-- Analyze inbox entries ({ index, money, cod, codUnknown, hasItem, isGM, sender, subject }).
-- Fail-closed: strictly excludes COD > 0 OR unknown/non-numeric COD from lootableIndices
-- so batch open NEVER pays COD by accident, and rejects non-integer mail indices.
function MailboxModel.SummarizeInbox(items)
    local total = 0
    local codCount = 0
    local totalCopper = 0
    local lootableIndices = {}
    local itemCount = 0

    for idx, it in ipairs(items or {}) do
        if type(it) == "table" then
            total = total + 1
            local validIndex = true
            local mailIdx = idx
            if it.index ~= nil then
                if type(it.index) == "number" and it.index >= 1 and it.index == math_floor(it.index) then
                    mailIdx = it.index
                else
                    validIndex = false
                end
            end
            local isCodOrUnknown = (it.codUnknown == true) or (type(it.cod) ~= "number") or (it.cod > 0)
            local money = (type(it.money) == "number" and it.money > 0) and math_floor(it.money) or 0
            local attach = (type(it.hasItem) == "number" and it.hasItem > 0) and math_floor(it.hasItem) or 0
            if isCodOrUnknown then
                codCount = codCount + 1
            elseif validIndex then
                if money > 0 then
                    totalCopper = totalCopper + money
                end
                if attach > 0 then
                    itemCount = itemCount + attach
                end
                if money > 0 or attach > 0 then
                    lootableIndices[#lootableIndices + 1] = {
                        index = mailIdx,
                        money = money,
                        hasItem = attach,
                    }
                end
            end
        end
    end

    return {
        total = total,
        codCount = codCount,
        lootableCount = #lootableIndices,
        totalCopper = totalCopper,
        itemCount = itemCount,
        lootableIndices = lootableIndices,
    }
end
