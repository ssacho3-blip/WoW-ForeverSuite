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
    local itemLevel = (type(opts) == "table" and type(opts.itemLevel) == "number" and opts.itemLevel > 0)
        and math_floor(opts.itemLevel) or nil

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

    if itemLevel then
        lines[#lines + 1] = {
            left = "아이템 레벨",
            right = "iLvl " .. tostring(itemLevel),
            tone = "GOLD",
        }
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
            right = "/fs protect",
            tone = "WARN",
        }
    end

    if type(opts) == "table" then
        if type(opts.koTranslation) == "string" and opts.koTranslation ~= "" then
            lines[#lines + 1] = {
                left = "한글명",
                right = opts.koTranslation,
                tone = "GOLD",
            }
        end
        if type(opts.dropSource) == "string" and opts.dropSource ~= "" then
            lines[#lines + 1] = {
                left = "획득처",
                right = opts.dropSource,
                tone = "GOLD",
            }
        end
        if opts.isBiS == true then
            lines[#lines + 1] = {
                left = "★ BiS 추천 장비",
                right = tostring(opts.bisNote or "ForeverSuite BiS"),
                tone = "GOLD",
            }
        end
        if type(opts.profMaterialTag) == "string" and opts.profMaterialTag ~= "" then
            lines[#lines + 1] = {
                left = "전문기술 재료",
                right = opts.profMaterialTag,
                tone = "MUTED",
            }
        end
        if type(opts.questStarterHint) == "string" and opts.questStarterHint ~= "" then
            lines[#lines + 1] = {
                left = "! 퀘스트 시작 아이템",
                right = opts.questStarterHint,
                tone = "GOLD",
            }
        end
    end

    return lines
end

function TooltipModel.BuildTranslationLookup(entries)
    local byItem, byClause = {}, {}
    for _, r in ipairs(entries or {}) do
        if type(r) == "table" then
            if r.kind == "item" and type(r.itemID) == "number" and type(r.ko) == "string" then
                byItem[r.itemID] = r.ko
            elseif r.kind == "clause" and type(r.en) == "string" and type(r.ko) == "string" then
                byClause[r.en] = r.ko
            end
        end
    end
    return byItem, byClause
end

function TooltipModel.TranslateClause(text, byClause)
    if type(text) ~= "string" or type(byClause) ~= "table" then return nil end
    return byClause[text]
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
