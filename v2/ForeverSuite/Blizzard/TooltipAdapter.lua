-- Module: Blizzard/TooltipAdapter.lua
-- Responsibility: Zero-Taint read-only Item/Spell tooltip post-call hook (TooltipDataProcessor or HookScript fallback; guards IsForbidden & C_Secrets).
-- Layer: Blizzard (NEVER calls SetScript, NEVER writes fields on Blizzard frames).
local _, ns = ...
ns.Blizzard = ns.Blizzard or {}

local pcall = pcall
local type = type
local tonumber = tonumber
local string_match = string.match

local TooltipAdapter = {
    hooked = false,
    cursorHooked = false,
    cursorAnchorPredicate = nil,
    onItemCallback = nil,
    onSpellCallback = nil,
}
ns.Blizzard.TooltipAdapter = TooltipAdapter

function TooltipAdapter:InitCursorAnchor(predicateFn)
    self.cursorAnchorPredicate = predicateFn
    if self.cursorHooked then
        return true
    end
    if type(_G.hooksecurefunc) == "function" and type(_G.GameTooltip_SetDefaultAnchor) == "function" then
        local ok = pcall(_G.hooksecurefunc, "GameTooltip_SetDefaultAnchor", function(tt, parent)
            if type(TooltipAdapter.cursorAnchorPredicate) ~= "function" then return end
            if not TooltipAdapter.cursorAnchorPredicate() then return end
            if IsTooltipForbidden(tt) then return end
            if ns.Api and ns.Api.SafeAPI and ns.Api.SafeAPI.InCombat() then return end
            if type(tt.SetOwner) == "function" and parent then
                pcall(tt.SetOwner, tt, parent, "ANCHOR_CURSOR")
            end
        end)
        self.cursorHooked = ok and true or false
        return self.cursorHooked
    end
    return false
end

local function IsTooltipForbidden(tt)
    if type(tt) ~= "table" then
        return true
    end
    if type(tt.IsForbidden) == "function" then
        local ok, forb = pcall(tt.IsForbidden, tt)
        if (not ok) or (ns.Api and ns.Api.SafeAPI and ns.Api.SafeAPI.IsSecret(forb)) or forb == true then
            return true
        end
    end
    return false
end

function TooltipAdapter.AddLine(tt, leftText, rightText, color)
    if IsTooltipForbidden(tt) then
        return false
    end
    local r = (color and color[1]) or 0.85
    local g = (color and color[2]) or 0.85
    local b = (color and color[3]) or 0.85
    if rightText and rightText ~= "" and type(tt.AddDoubleLine) == "function" then
        local ok = pcall(tt.AddDoubleLine, tt, leftText, rightText, r, g, b, r, g, b)
        return ok and true or false
    end
    if type(tt.AddLine) == "function" then
        local ok = pcall(tt.AddLine, tt, leftText, r, g, b)
        return ok and true or false
    end
    return false
end

local function DispatchItem(tt, rawID)
    if not TooltipAdapter.onItemCallback or IsTooltipForbidden(tt) then
        return
    end
    if ns.Api and ns.Api.SafeAPI and ns.Api.SafeAPI.IsSecret(rawID) then
        return
    end
    local id = tonumber(rawID)
    if id and id > 0 then
        TooltipAdapter.onItemCallback(tt, id)
    end
end

local function DispatchSpell(tt, rawID)
    if not TooltipAdapter.onSpellCallback or IsTooltipForbidden(tt) then
        return
    end
    if ns.Api and ns.Api.SafeAPI and ns.Api.SafeAPI.IsSecret(rawID) then
        return
    end
    local id = tonumber(rawID)
    if id and id > 0 then
        TooltipAdapter.onSpellCallback(tt, id)
    end
end

function TooltipAdapter:Init(onItem, onSpell)
    self.onItemCallback = onItem
    self.onSpellCallback = onSpell
    if self.hooked then
        return true
    end

    local tdp = _G.TooltipDataProcessor
    local enumTypes = _G.Enum and _G.Enum.TooltipDataType
    if type(tdp) == "table" and type(tdp.AddTooltipPostCall) == "function" and type(enumTypes) == "table" then
        local okI = true
        if enumTypes.Item ~= nil then
            okI = pcall(tdp.AddTooltipPostCall, enumTypes.Item, function(tt, data)
                if type(data) == "table" then
                    DispatchItem(tt, data.id)
                end
            end)
        end
        local okS = true
        if enumTypes.Spell ~= nil then
            okS = pcall(tdp.AddTooltipPostCall, enumTypes.Spell, function(tt, data)
                if type(data) == "table" then
                    DispatchSpell(tt, data.id)
                end
            end)
        end
        if okI and okS then
            self.hooked = true
            return true
        end
    end

    -- Fallback for clients using HookScript on GameTooltip
    local gt = _G.GameTooltip
    if type(gt) == "table" and type(gt.HookScript) == "function" then
        local ok1 = pcall(gt.HookScript, gt, "OnTooltipSetItem", function(tt)
            if type(tt.GetItem) == "function" then
                local okG, _, link = pcall(tt.GetItem, tt)
                if okG and type(link) == "string" and not (ns.Api and ns.Api.SafeAPI and ns.Api.SafeAPI.IsSecret(link)) then
                    local id = string_match(link, "item:(%d+)")
                    DispatchItem(tt, id)
                end
            end
        end)
        local ok2 = pcall(gt.HookScript, gt, "OnTooltipSetSpell", function(tt)
            if type(tt.GetSpell) == "function" then
                local okG, _, spellID = pcall(tt.GetSpell, tt)
                if okG then
                    DispatchSpell(tt, spellID)
                end
            end
        end)
        if ok1 or ok2 then
            self.hooked = true
            return true
        end
    end
    return false
end
