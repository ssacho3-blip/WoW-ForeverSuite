-- Module: Domain/GdkpModel.lua
-- Responsibility: Pure integer-copper GDKP pot ledger & exact split calculator
--                 (Invariant: organizerCut + perMember * memberCount + remainder == totalPot; rejects 0/negative/overflow).
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local ipairs = ipairs
local tostring = tostring
local math_floor = math.floor
local table_insert = table.insert

local MAX_COPPER = 99999999999 -- ~9,999,999g safe exact integer limit in IEEE-754 double
local MAX_MEMBERS = 40
local MAX_CUT_PCT = 50

local GdkpModel = {
    MAX_COPPER = MAX_COPPER,
    MAX_MEMBERS = MAX_MEMBERS,
    MAX_CUT_PCT = MAX_CUT_PCT,
}
ns.Domain.GdkpModel = GdkpModel

function GdkpModel.AddSale(sales, itemName, buyer, copperPrice)
    if type(sales) ~= "table" then
        return false, "INVALID_LIST"
    end
    if type(itemName) ~= "string" or itemName == "" then
        return false, "INVALID_ITEM"
    end
    if type(copperPrice) ~= "number" or copperPrice ~= copperPrice or copperPrice <= 0 or copperPrice > MAX_COPPER then
        return false, "INVALID_PRICE"
    end
    local exact = math_floor(copperPrice)
    if exact ~= copperPrice then
        return false, "NON_INTEGER_COPPER"
    end
    table_insert(sales, {
        item = itemName,
        buyer = (type(buyer) == "string" and buyer ~= "") and buyer or "미상",
        copper = exact,
        paid = false,
    })
    return true, "ADDED"
end

-- H2: Auto-match completed trade gold against unpaid GDKP sales for a buyer
function GdkpModel.MatchBuyerTradePayment(sales, partnerName, receivedCopper)
    if type(sales) ~= "table" or type(partnerName) ~= "string" or partnerName == "" then return 0, 0 end
    if type(receivedCopper) ~= "number" or receivedCopper <= 0 then return 0, 0 end
    local remaining = math_floor(receivedCopper)
    local settledCount = 0
    local settledCopper = 0
    local pLow = string.lower(partnerName)
    for _, s in ipairs(sales) do
        if type(s) == "table" and not s.paid and type(s.buyer) == "string" and string.lower(s.buyer) == pLow
            and type(s.copper) == "number" and s.copper > 0 and s.copper <= remaining
        then
            s.paid = true
            remaining = remaining - s.copper
            settledCount = settledCount + 1
            settledCopper = settledCopper + s.copper
        end
    end
    return settledCount, settledCopper
end

-- H2: Payout distribution checklist tracker (per-member paid status)
function GdkpModel.MarkMemberPayout(payoutMap, memberName, givenCopper, perMemberCopper)
    if type(payoutMap) ~= "table" or type(memberName) ~= "string" or memberName == "" then return false end
    if type(givenCopper) ~= "number" or givenCopper <= 0 then return false end
    if type(perMemberCopper) == "number" and perMemberCopper > 0 and givenCopper < math_floor(perMemberCopper * 0.9) then
        return false
    end
    payoutMap[memberName] = { paid = true, copper = math_floor(givenCopper) }
    return true
end

function GdkpModel.ComputeSplit(sales, memberCount, organizerCutPct)
    if type(memberCount) ~= "number" or memberCount ~= memberCount then
        return nil, "INVALID_MEMBERS"
    end
    local n = math_floor(memberCount)
    if n < 1 or n > MAX_MEMBERS or n ~= memberCount then
        return nil, "INVALID_MEMBERS"
    end

    local cutPct = 0
    if organizerCutPct ~= nil then
        if type(organizerCutPct) ~= "number" or organizerCutPct ~= organizerCutPct then
            return nil, "INVALID_CUT"
        end
        cutPct = math_floor(organizerCutPct)
        if cutPct < 0 or cutPct > MAX_CUT_PCT or cutPct ~= organizerCutPct then
            return nil, "INVALID_CUT"
        end
    end

    if sales ~= nil and type(sales) ~= "table" then
        return nil, "INVALID_LIST"
    end

    local totalPot = 0
    local saleCount = 0
    for _, s in ipairs(sales or {}) do
        if type(s) == "table" and type(s.copper) == "number" and s.copper > 0 then
            local c = math_floor(s.copper)
            if totalPot + c > MAX_COPPER then
                return nil, "POT_OVERFLOW"
            end
            totalPot = totalPot + c
            saleCount = saleCount + 1
        end
    end

    local organizerCut = math_floor((totalPot * cutPct) / 100)
    local distributable = totalPot - organizerCut
    local perMember = math_floor(distributable / n)
    local remainder = distributable - (perMember * n)

    return {
        saleCount = saleCount,
        totalPot = totalPot,
        organizerCutPct = cutPct,
        organizerCut = organizerCut,
        memberCount = n,
        perMember = perMember,
        remainder = remainder,
        -- Conservation identity verified mathematically: organizerCut + perMember * n + remainder == totalPot
        balanced = (organizerCut + (perMember * n) + remainder == totalPot),
    }, "OK"
end

-- KPI-7 Live GDKP Auction Engine (integer copper only, anti-snipe extension)
function GdkpModel.StartAuction(itemName, startGold, minIncGold, durationSec, now)
    if type(itemName) ~= "string" or itemName == "" then
        return nil, "INVALID_ITEM"
    end
    if type(startGold) ~= "number" or startGold ~= math_floor(startGold) or startGold < 1 then
        return nil, "INVALID_START"
    end
    local inc = (type(minIncGold) == "number" and minIncGold == math_floor(minIncGold) and minIncGold >= 1) and minIncGold or 10
    local dur = (type(durationSec) == "number" and durationSec >= 5 and durationSec <= 120) and math_floor(durationSec) or 20
    local t0 = (type(now) == "number") and now or 0
    local startCopper = startGold * 10000
    local incCopper = inc * 10000
    if startCopper > MAX_COPPER or incCopper > MAX_COPPER then
        return nil, "OVERFLOW"
    end
    return {
        item = itemName,
        startCopper = startCopper,
        minIncCopper = incCopper,
        highBidCopper = 0,
        highBidder = nil,
        bidCount = 0,
        startedAt = t0,
        endsAt = t0 + dur,
        status = "OPEN",
    }, "OPEN"
end

function GdkpModel.ParseChatBidCopper(rawMsg)
    if type(rawMsg) ~= "string" or rawMsg == "" then
        return nil
    end
    local trimmed = string.match(rawMsg, "^%s*(.-)%s*$") or ""
    local numStr = string.match(trimmed, "^(%d+)$")
        or string.match(trimmed, "^(%d+)%s*[gG]$")
        or string.match(trimmed, "^(%d+)%s*골$")
        or string.match(trimmed, "^(%d+)%s*골드$")
    if not numStr then
        return nil
    end
    local gold = tonumber(numStr)
    if not gold or gold <= 0 or gold ~= math_floor(gold) then
        return nil
    end
    local copper = gold * 10000
    if copper > MAX_COPPER then
        return nil
    end
    return copper
end

function GdkpModel.SubmitBid(auction, bidderName, bidCopper, now)
    if type(auction) ~= "table" or auction.status ~= "OPEN" then
        return false, "NOT_OPEN"
    end
    if type(bidderName) ~= "string" or bidderName == "" then
        return false, "INVALID_BIDDER"
    end
    if type(bidCopper) ~= "number" or bidCopper ~= math_floor(bidCopper) or bidCopper <= 0 or bidCopper > MAX_COPPER then
        return false, "INVALID_BID"
    end
    if type(now) == "number" and now >= auction.endsAt then
        return false, "EXPIRED"
    end
    local required = (auction.highBidCopper == 0)
        and auction.startCopper
        or (auction.highBidCopper + auction.minIncCopper)
    if bidCopper < required then
        return false, "TOO_LOW"
    end
    auction.highBidCopper = bidCopper
    auction.highBidder = bidderName
    auction.bidCount = (auction.bidCount or 0) + 1
    -- Anti-snipe: extend 5s if bid lands in last 5s
    if type(now) == "number" and (auction.endsAt - now) < 5 then
        auction.endsAt = now + 5
    end
    return true, "ACCEPTED"
end

function GdkpModel.CloseAuction(auction, salesList)
    if type(auction) ~= "table" or auction.status ~= "OPEN" then
        return false, "NOT_OPEN"
    end
    auction.status = "CLOSED"
    if auction.highBidCopper > 0 and auction.highBidder then
        local ok, st = GdkpModel.AddSale(salesList, auction.item, auction.highBidder, auction.highBidCopper)
        return ok, ok and "SOLD" or st
    end
    return true, "UNSOLD"
end
