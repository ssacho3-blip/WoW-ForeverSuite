-- Module: Bridges/Auctionator.lua
-- Responsibility: Official Auctionator.API.v1 bridge — cached AH/DE/vendor price lookup (nil on miss, never 0c),
--                 RegisterForDBUpdate cache invalidation, OOC-only CreateShoppingList, and tooltip vendor-price yield.
-- Layer: Bridges (Rank 3).
local _, ns = ...
ns.Bridges = ns.Bridges or {}

local type = type
local pcall = pcall

local CALLER_ID = "ForeverSuite"

local AuctionatorBridge = {
    registered = false,
    cacheEpoch = 0,
    priceCache = {},
}
ns.Bridges.Auctionator = AuctionatorBridge

local function GetAPIv1()
    local auc = ns.Api.AddonProbe.GetGlobal("Auctionator")
    if type(auc) == "table" and type(auc.API) == "table" and type(auc.API.v1) == "table" then
        return auc.API.v1
    end
    return nil
end

function AuctionatorBridge:InvalidateCache()
    self.cacheEpoch = self.cacheEpoch + 1
    self.priceCache = {}
end

function AuctionatorBridge:Init()
    local api = GetAPIv1()
    if not api then
        return "WARMING"
    end
    if not self.registered then
        if type(api.RegisterForDBUpdate) == "function" then
            pcall(api.RegisterForDBUpdate, CALLER_ID, function()
                AuctionatorBridge:InvalidateCache()
            end)
        end
        self.registered = true
    end
    return "OK"
end

function AuctionatorBridge:GetAuctionPrice(itemID)
    if ns.Api.SafeAPI.IsSecret(itemID) or type(itemID) ~= "number" or itemID <= 0 then
        return nil
    end
    local cached = self.priceCache[itemID]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end
    local api = GetAPIv1()
    if not api or type(api.GetAuctionPriceByItemID) ~= "function" then
        return nil
    end
    local ok, price = pcall(api.GetAuctionPriceByItemID, CALLER_ID, itemID)
    if ok and type(price) == "number" and price > 0 then
        self.priceCache[itemID] = price
        return price
    end
    -- Negative cache false -> returns nil (never fabricated 0c)
    self.priceCache[itemID] = false
    return nil
end

function AuctionatorBridge:GetDisenchantPrice(itemID)
    if ns.Api.SafeAPI.IsSecret(itemID) or type(itemID) ~= "number" or itemID <= 0 then
        return nil
    end
    local api = GetAPIv1()
    if not api or type(api.GetDisenchantPriceByItemID) ~= "function" then
        return nil
    end
    local ok, price = pcall(api.GetDisenchantPriceByItemID, CALLER_ID, itemID)
    if ok and type(price) == "number" and price > 0 then
        return price
    end
    return nil
end

function AuctionatorBridge:GetVendorPrice(itemID)
    if ns.Api.SafeAPI.IsSecret(itemID) or type(itemID) ~= "number" or itemID <= 0 then
        return nil
    end
    local api = GetAPIv1()
    if not api or type(api.GetVendorPriceByItemID) ~= "function" then
        return nil
    end
    local ok, price = pcall(api.GetVendorPriceByItemID, CALLER_ID, itemID)
    if ok and type(price) == "number" and price > 0 then
        return price
    end
    return nil
end

function AuctionatorBridge:CreateShoppingList(listName, searchStrings)
    if ns.Api.SafeAPI.InCombat() then
        return false, "IN_COMBAT"
    end
    if type(listName) ~= "string" or listName == "" or type(searchStrings) ~= "table" or #searchStrings == 0 then
        return false, "INVALID_ARGS"
    end
    local api = GetAPIv1()
    if not api or type(api.CreateShoppingList) ~= "function" then
        return false, "API_UNAVAILABLE"
    end
    local ok, err = pcall(api.CreateShoppingList, CALLER_ID, listName, searchStrings)
    return ok and true or false, err
end

function AuctionatorBridge:ShouldYieldTooltipVendorPrice()
    return ns.Bridges.BridgeHost:GetState("auctionator") == "BRIDGE_ONLY"
end

ns.Bridges.BridgeHost:Register({
    id = "auctionator",
    target = "Auctionator",
    mode = "bridge",
    protected = false,
    yields = { "tooltip_vendor_price" },
    init = function()
        return AuctionatorBridge:Init()
    end,
    teardown = function()
        AuctionatorBridge.registered = false
        AuctionatorBridge:InvalidateCache()
    end,
})
