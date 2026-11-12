-- Module: Core/MoneyLedgerQueue.lua
-- Responsibility: Bounded TTL attribution queue matching PLAYER_MONEY deltas to REPAIR, VENDOR_SELL, and QUEST causes.
-- Dependencies: Core/Init.lua (ns.GetNow, ns.IsSecret, ns.WipeTable).
-- Public API: ns.PendingMoneyReasons, ns.ClearPendingMoneyReasons, ns.SetPendingMoneyReason, ns.ConsumePendingMoneyReason.
-- Combat/Secret Safety: Guards all numeric deltas via ns.IsSecret; performs zero protected UI or CVar calls.
local _, ns = ...

local type = type
local ipairs = ipairs
local tonumber = tonumber

ns.PendingMoneyReasons = {}

local REASON_EXPECTED_SIGN = {
    REPAIR = -1,
    VENDOR_SELL = 1,
    QUEST = 1,
}

function ns.ClearPendingMoneyReasons()
    ns.WipeTable(ns.PendingMoneyReasons)
    ns.PendingMoneyReason = nil
    ns.PendingMoneyReasonAt = nil
end

function ns.SetPendingMoneyReason(reason, ttlSec, expectedSign, expectedDelta)
    if type(reason) ~= "string" or reason == "" then
        return
    end
    local now = ns.GetNow()
    local rawTtl = tonumber(ttlSec) or 1.5
    local ttl = (rawTtl > 0 and rawTtl <= 1.5) and rawTtl or 1.5
    local sign = expectedSign or REASON_EXPECTED_SIGN[reason] or 0
    local expDelta = (type(expectedDelta) == "number" and not ns.IsSecret(expectedDelta)) and expectedDelta or nil
    if expDelta == 0 then
        expDelta = nil
    end
    if expDelta ~= nil and expDelta ~= 0 then
        sign = expDelta > 0 and 1 or -1
    end
    local q = ns.PendingMoneyReasons
    local writeIdx = 1
    for readIdx = 1, #q do
        local item = q[readIdx]
        if item and now <= item.expiresAt then
            q[writeIdx] = item
            writeIdx = writeIdx + 1
        end
    end
    for i = writeIdx, #q do
        q[i] = nil
    end
    if #q >= 32 then
        for k = 1, #q - 1 do
            q[k] = q[k + 1]
        end
        q[#q] = nil
    end
    q[#q + 1] = {
        reason = reason,
        sign = sign,
        expectedDelta = expDelta,
        createdAt = now,
        expiresAt = now + ttl,
    }
    ns.PendingMoneyReason = reason
    ns.PendingMoneyReasonAt = now
end

function ns.ConsumePendingMoneyReason(deltaOrNil)
    local q = ns.PendingMoneyReasons
    if #q == 0 then
        ns.PendingMoneyReason = nil
        ns.PendingMoneyReasonAt = nil
        return nil
    end
    local now = ns.GetNow()
    local delta = (type(deltaOrNil) == "number" and not ns.IsSecret(deltaOrNil)) and deltaOrNil or nil

    -- First prune any expired entries strictly by item.expiresAt
    local liveWrite = 1
    for readIdx = 1, #q do
        local item = q[readIdx]
        if item and now <= item.expiresAt then
            q[liveWrite] = item
            liveWrite = liveWrite + 1
        end
    end
    for i = liveWrite, #q do
        q[i] = nil
    end
    if #q == 0 then
        ns.PendingMoneyReason = nil
        ns.PendingMoneyReasonAt = nil
        return nil
    end

    local matchedReason = nil
    local removeMask = {}

    -- Pass 1: Exact expectedDelta match (prevents VENDOR_SELL vs QUEST cross-consumption)
    if delta ~= nil then
        for i = 1, #q do
            local item = q[i]
            if item.expectedDelta ~= nil and item.expectedDelta == delta then
                matchedReason = item.reason
                removeMask[i] = true
                break
            end
        end
    end

    -- Pass 1b: Coalesced batch prefix match (e.g., server coalesced k VENDOR_SELL items into one PLAYER_MONEY)
    if not matchedReason and delta ~= nil then
        for startIdx = 1, #q do
            local first = q[startIdx]
            if first.expectedDelta ~= nil then
                local running = first.expectedDelta
                local indices = { startIdx }
                for nextIdx = startIdx + 1, #q do
                    local nxt = q[nextIdx]
                    if nxt.reason == first.reason and nxt.expectedDelta ~= nil then
                        running = running + nxt.expectedDelta
                        indices[#indices + 1] = nextIdx
                        if running == delta then
                            matchedReason = first.reason
                            for _, rmIdx in ipairs(indices) do
                                removeMask[rmIdx] = true
                            end
                            break
                        end
                    else
                        break
                    end
                end
                if matchedReason then
                    break
                end
            end
        end
    end

    -- Pass 2: Sign-based fallback ONLY for entries that did not specify an exact expectedDelta
    if not matchedReason then
        for i = 1, #q do
            local item = q[i]
            if item.expectedDelta == nil then
                local signOk = true
                if delta ~= nil and item.sign ~= 0 then
                    signOk = (delta > 0 and item.sign > 0) or (delta < 0 and item.sign < 0)
                end
                if signOk then
                    matchedReason = item.reason
                    removeMask[i] = true
                    break
                end
            end
        end
    end

    if matchedReason then
        local outIdx = 1
        for readIdx = 1, #q do
            if not removeMask[readIdx] then
                q[outIdx] = q[readIdx]
                outIdx = outIdx + 1
            end
        end
        for i = outIdx, #q do
            q[i] = nil
        end
    end

    if #q == 0 then
        ns.PendingMoneyReason = nil
        ns.PendingMoneyReasonAt = nil
    else
        ns.PendingMoneyReason = q[1].reason
        ns.PendingMoneyReasonAt = q[1].createdAt
    end
    return matchedReason
end
