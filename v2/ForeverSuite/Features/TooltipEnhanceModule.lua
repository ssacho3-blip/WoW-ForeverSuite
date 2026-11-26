-- Module: Features/TooltipEnhanceModule.lua
-- Responsibility: Zero-Taint Item/Spell ID, iLvl, vendor price, sell-protection badge, EN->KR item/clause translation,
--                 inline dungeon/BiS/profession-material source lookup, and Cursor-Anchored Tooltip option.
-- Layer: Features (delegates hooking to Blizzard/TooltipAdapter and formatting to Domain/TooltipModel).
local _, ns = ...
ns.Features = ns.Features or {}

local T = ns.UI.Tokens
local ipairs = ipairs
local type = type
local tostring = tostring

local TooltipEnhanceModule = {
    initialized = false,
    sourceIndex = nil,
    bisIndex = nil,
    profMatIndex = nil,
    itemTransMap = nil,
    clauseTransMap = nil,
}
ns.Features.TooltipEnhanceModule = TooltipEnhanceModule

local function ToneColor(tone)
    if tone == "GOLD" then return T.TEXT.GOLD end
    if tone == "WARN" then return T.SEMANTIC.WARN end
    return T.TEXT.MUTED
end

local PROF_KIND_LABELS = {
    herb = "약초채집 · 연금술",
    gem = "광석 · 보석",
    leather = "무두질 · 가죽세공",
    food = "요리 재료",
    reagent = "전문기술 재료",
    cloth = "재봉술 · 응급치료",
    ore = "채광 · 대장/기공",
}

function TooltipEnhanceModule:EnsureIndexes()
    local packs = _G.ForeverSuiteData and _G.ForeverSuiteData.packs
    if type(packs) ~= "table" then return end

    if (not self.sourceIndex) and type(packs.dungeon_loot) == "table" and type(packs.dungeon_loot.entries) == "table" then
        local idx = {}
        for _, it in ipairs(packs.dungeon_loot.entries) do
            if type(it.itemID) == "number" and it.itemID > 0 then
                local src = (type(it.dungeon) == "string" and it.dungeon ~= "")
                    and (it.dungeon .. ((type(it.boss) == "string" and it.boss ~= "") and (" · " .. it.boss) or ""))
                    or nil
                if src then idx[it.itemID] = src end
            end
        end
        self.sourceIndex = idx
    end

    if (not self.bisIndex) and type(packs.bis) == "table" and type(packs.bis.entries) == "table" then
        local idx = {}
        for _, it in ipairs(packs.bis.entries) do
            if type(it.itemID) == "number" and it.itemID > 0 then
                idx[it.itemID] = (type(it.acq) == "string" and it.acq ~= "") and it.acq or tostring(it.slot or "BiS")
            end
        end
        self.bisIndex = idx
    end

    if (not self.profMatIndex) and type(packs.prof_materials) == "table" and type(packs.prof_materials.entries) == "table" then
        local idx = {}
        for _, m in ipairs(packs.prof_materials.entries) do
            if type(m.itemID) == "number" and m.itemID > 0 then
                idx[m.itemID] = PROF_KIND_LABELS[m.kind] or tostring(m.kind or "재료")
            end
        end
        self.profMatIndex = idx
    end

    if (not self.itemTransMap) and type(packs.item_translations) == "table" and type(packs.item_translations.entries) == "table" then
        self.itemTransMap, self.clauseTransMap = ns.Domain.TooltipModel.BuildTranslationLookup(packs.item_translations.entries)
    end
end

function TooltipEnhanceModule:OnItemTooltip(tooltip, itemID)
    if ns.Api.ProfileStore:Get("ui", "enhanceTooltips") == false then
        return 0
    end
    self:EnsureIndexes()
    local sellPrice = ns.Api.GameAdapters.GetItemSellPrice(itemID)
    local itemLevel = ns.Api.GameAdapters.GetItemLevel(itemID)
    local protected = ns.Api.ProfileStore.db and ns.Api.ProfileStore.db.v2 and ns.Api.ProfileStore.db.v2.protectedItems

    local wantSources = ns.Api.ProfileStore:Get("ui", "tooltipItemSources") ~= false
    local wantTrans = ns.Api.ProfileStore:Get("ui", "tooltipTranslation") ~= false

    local dropSource = wantSources and self.sourceIndex and self.sourceIndex[itemID] or nil
    local bisNote = wantSources and self.bisIndex and self.bisIndex[itemID] or nil
    local profMatTag = wantSources and self.profMatIndex and self.profMatIndex[itemID] or nil
    local koTrans = wantTrans and self.itemTransMap and self.itemTransMap[itemID] or nil

    local lines = ns.Domain.TooltipModel.BuildItemLines(itemID, sellPrice, 1, protected, {
        showItemID = true,
        showVendorPrice = true,
        itemLevel = itemLevel,
        dropSource = dropSource,
        isBiS = (bisNote ~= nil),
        bisNote = bisNote,
        profMaterialTag = profMatTag,
        koTranslation = koTrans,
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

function TooltipEnhanceModule:TranslateClause(enText)
    self:EnsureIndexes()
    return ns.Domain.TooltipModel.TranslateClause(enText, self.clauseTransMap)
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
    ns.Blizzard.TooltipAdapter:InitCursorAnchor(function()
        return ns.Api.ProfileStore and ns.Api.ProfileStore:Get("ui", "cursorTooltip") == true
    end)
    self.initialized = ok
    return ok
end
