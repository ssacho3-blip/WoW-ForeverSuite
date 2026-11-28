-- Module: Bridges/Syndicator.lua
-- Responsibility: Official Syndicator.API read-only bridge with BRIDGE_WARMING cold-boot promotion
--                 for cross-alt inventory, currency, and character queries (Zero Fabricated Status).
-- Layer: Bridges (Rank 3: 100% read-only).
local _, ns = ...
ns.Bridges = ns.Bridges or {}

local type = type
local pcall = pcall

local SyndicatorBridge = {
    subscribed = false,
}
ns.Bridges.Syndicator = SyndicatorBridge

local function GetAPI()
    local syn = ns.Api.AddonProbe.GetGlobal("Syndicator")
    return (type(syn) == "table" and type(syn.API) == "table") and syn.API or nil
end

function SyndicatorBridge:IsReady()
    local api = GetAPI()
    if not api or type(api.IsReady) ~= "function" then
        return false
    end
    local ok, ready = pcall(api.IsReady)
    return ok and ready == true
end

function SyndicatorBridge:Init()
    local api = GetAPI()
    if not api then
        return "WARMING"
    end
    if not self.subscribed then
        self.subscribed = true
        ns.Bridges.BridgeHost:Subscribe("syndicator", "BAG_UPDATE_DELAYED", function()
            if ns.Bridges.BridgeHost:GetState("syndicator") == "BRIDGE_WARMING" and SyndicatorBridge:IsReady() then
                ns.Bridges.BridgeHost:RecheckWarming()
            end
        end)
    end
    if not self:IsReady() then
        return "WARMING"
    end
    return "OK"
end

function SyndicatorBridge:GetItemInventory(itemID)
    if ns.Api.SafeAPI.IsSecret(itemID) or type(itemID) ~= "number" or itemID <= 0 then
        return nil, "INVALID_ITEM"
    end
    if not self:IsReady() then
        return nil, "WARMING"
    end
    local api = GetAPI()
    if not api or type(api.GetInventoryInfoByItemID) ~= "function" then
        return nil, "UNAVAILABLE"
    end
    local ok, info = pcall(api.GetInventoryInfoByItemID, itemID, true, true)
    if not ok or type(info) ~= "table" then
        return nil, "UNAVAILABLE"
    end
    return info, "OK"
end

function SyndicatorBridge:GetTotalItemCount(itemID)
    local info, status = self:GetItemInventory(itemID)
    if not info then
        return nil, status
    end
    local total = 0
    if type(info.characters) == "table" then
        for i = 1, #info.characters do
            local c = info.characters[i]
            if type(c) == "table" then
                total = total + (c.bags or 0) + (c.bank or 0) + (c.mail or 0) + (c.equipped or 0)
            end
        end
    end
    if type(info.warband) == "number" then
        total = total + info.warband
    elseif type(info.warband) == "table" then
        for i = 1, #info.warband do
            local w = info.warband[i]
            if type(w) == "number" then
                total = total + w
            elseif type(w) == "table" then
                total = total + (w.bank or 0)
            end
        end
    end
    return total, "OK"
end

function SyndicatorBridge:GetAllCharacters()
    if not self:IsReady() then
        return nil, "WARMING"
    end
    local api = GetAPI()
    if not api or type(api.GetAllCharacters) ~= "function" then
        return nil, "UNAVAILABLE"
    end
    local ok, chars = pcall(api.GetAllCharacters)
    if not ok or type(chars) ~= "table" then
        return nil, "UNAVAILABLE"
    end
    return chars, "OK"
end

function SyndicatorBridge:GetCurrencyInfo(currencyID)
    if ns.Api.SafeAPI.IsSecret(currencyID) or type(currencyID) ~= "number" or currencyID <= 0 then
        return nil, "INVALID_CURRENCY"
    end
    if not self:IsReady() then
        return nil, "WARMING"
    end
    local api = GetAPI()
    if not api or type(api.GetCurrencyInfo) ~= "function" then
        return nil, "UNAVAILABLE"
    end
    local ok, info = pcall(api.GetCurrencyInfo, currencyID, true, true)
    if not ok or type(info) ~= "table" then
        return nil, "UNAVAILABLE"
    end
    return info, "OK"
end

ns.Bridges.BridgeHost:Register({
    id = "syndicator",
    target = "Syndicator",
    mode = "bridge",
    protected = false,
    yields = { "alt_bag_scan" },
    init = function()
        return SyndicatorBridge:Init()
    end,
    onWarmCheck = function()
        return SyndicatorBridge:IsReady() and "OK" or "WARMING"
    end,
    teardown = function()
        SyndicatorBridge.subscribed = false
    end,
})
