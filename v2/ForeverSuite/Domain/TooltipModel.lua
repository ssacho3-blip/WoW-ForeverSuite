-- Module: Domain/TooltipModel.lua
-- Responsibility: Pure Lua 5.1 Item/Spell Tooltip metadata formatter (ID, vendor unit/stack price, sell-protection badge).
-- Layer: Domain (ZERO _G / WoW API access; verified by fsx check).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local tostring = tostring
local math_floor = math.floor

local TooltipModel = {}
ns.Domain.TooltipModel = TooltipModel

local function FormatCopperSafe(copper)
    if ns.Domain and ns.Domain.LedgerModel and type(ns.Domain.LedgerModel.FormatCopper) == "function" then
        return ns.Domain.LedgerModel.FormatCopper(copper)
    end
    return tostring(math_floor(copper)) .. "c"
end

-- Returns array of { left = string, right = string, tone = "MUTED"|"GOLD"|"WARN" }
-- Never fabricates price when sellPrice is nil/<=0.
function TooltipModel.BuildItemLines(itemID, sellPrice, stackCount, protectedSet, opts)
    local lines = {}
    if type(itemID) ~= "number" or itemID <= 0 then
        return lines
    end
    local showID = (type(opts) ~= "table") or (opts.showItemID ~= false)
    local showPrice = (type(opts) ~= "table") or (opts.showVendorPrice ~= false)

    local idPart = showID and ("#" .. tostring(math_floor(itemID))) or nil
    local pricePart = nil
    if showPrice and type(sellPrice) == "number" and sellPrice > 0 then
        local count = (type(stackCount) == "number" and stackCount > 1) and math_floor(stackCount) or 1
        if count > 1 then
            pricePart = FormatCopperSafe(sellPrice * count) .. " (x" .. tostring(count) .. ")"
        else
            pricePart = FormatCopperSafe(sellPrice)
        end
    end

    if idPart or pricePart then
        lines[#lines + 1] = {
            left = idPart and ("ForeverSuite ID: " .. idPart) or "ForeverSuite 상점가",
            right = pricePart or "",
            tone = pricePart and "GOLD" or "MUTED",
        }
    end

    if type(protectedSet) == "table" and protectedSet[math_floor(itemID)] == true then
        lines[#lines + 1] = {
            left = "[판매 보호 목록 등록됨]",
            right = "/fs2 protect",
            tone = "WARN",
        }
    end

    return lines
end

function TooltipModel.BuildSpellLines(spellID, showSpellID)
    local lines = {}
    if showSpellID == false or type(spellID) ~= "number" or spellID <= 0 then
        return lines
    end
    lines[#lines + 1] = {
        left = "ForeverSuite 주문 ID",
        right = "#" .. tostring(math_floor(spellID)),
        tone = "MUTED",
    }
    return lines
end
