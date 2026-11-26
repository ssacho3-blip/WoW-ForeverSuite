-- Module: Features/TooltipEnhanceModule.lua
-- Responsibility: Zero-Taint Item/Spell ID, vendor price, and sell-protection badge tooltip enhancer.
-- Layer: Features (delegates hooking to Blizzard/TooltipAdapter and formatting to Domain/TooltipModel).
local _, ns = ...
ns.Features = ns.Features or {}

local T = ns.UI.Tokens
local ipairs = ipairs

local TooltipEnhanceModule = {
    initialized = false,
}
ns.Features.TooltipEnhanceModule = TooltipEnhanceModule

local function ToneColor(tone)
    if tone == "GOLD" then return T.TEXT.GOLD end
    if tone == "WARN" then return T.SEMANTIC.WARN end
    return T.TEXT.MUTED
end

function TooltipEnhanceModule:OnItemTooltip(tooltip, itemID)
    if ns.Api.ProfileStore:Get("ui", "enhanceTooltips") == false then
        return 0
    end
    local sellPrice = ns.Api.GameAdapters.GetItemSellPrice(itemID)
    local itemLevel = ns.Api.GameAdapters.GetItemLevel(itemID)
    local protected = ns.Api.ProfileStore.db and ns.Api.ProfileStore.db.v2 and ns.Api.ProfileStore.db.v2.protectedItems
    local lines = ns.Domain.TooltipModel.BuildItemLines(itemID, sellPrice, 1, protected, {
        showItemID = true,
        showVendorPrice = true,
        itemLevel = itemLevel,
    })
    local added = 0
    for _, ln in ipairs(lines) do
        if ns.Blizzard.TooltipAdapter.AddLine(tooltip, ln.left, ln.right, ToneColor(ln.tone)) then
            added = added + 1
        end
    end
    return added
end

function TooltipEnhanceModule:OnSpellTooltip(tooltip, spellID)
    if ns.Api.ProfileStore:Get("ui", "enhanceTooltips") == false then
        return 0
    end
    local lines = ns.Domain.TooltipModel.BuildSpellLines(spellID, true)
    local added = 0
    for _, ln in ipairs(lines) do
        if ns.Blizzard.TooltipAdapter.AddLine(tooltip, ln.left, ln.right, ToneColor(ln.tone)) then
            added = added + 1
        end
    end
    return added
end

function TooltipEnhanceModule:Init()
    if self.initialized then
        return true
    end
    local ok = ns.Blizzard.TooltipAdapter:Init(
        function(tt, itemID)
            TooltipEnhanceModule:OnItemTooltip(tt, itemID)
        end,
        function(tt, spellID)
            TooltipEnhanceModule:OnSpellTooltip(tt, spellID)
        end
    )
    self.initialized = ok
    return ok
end
