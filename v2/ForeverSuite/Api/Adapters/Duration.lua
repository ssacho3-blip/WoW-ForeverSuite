-- Module: Api/Adapters/Duration.lua
-- Responsibility: Strangler Fig v6 combat duration adapter using verified WoW Forever 1.60.1 C_Secrets-safe APIs
--                 (C_UnitAuras.GetAuraDuration, C_Spell.GetSpellCooldownDuration, C_DurationUtil.CreateDurationTextBinding,
--                  C_UnitAuras.GetAuraApplicationDisplayCount). Zero arithmetic/comparisons on secret values (I1/I2).
-- Layer: Api (Rank 1).
local _, ns = ...
ns.Api = ns.Api or {}
ns.Api.Adapters = ns.Api.Adapters or {}

local type = type
local pcall = pcall

local DurationAdapter = {}
ns.Api.Adapters.Duration = DurationAdapter

-- Bind a combat aura's duration directly to a FontString via C_DurationUtil without touching secret numbers.
function DurationAdapter.BindAuraDuration(unit, auraInstanceID, fontString)
    if type(unit) ~= "string" or auraInstanceID == nil or type(fontString) ~= "table" then
        return false, "INVALID_ARGS"
    end
    if not (_G.C_UnitAuras and type(_G.C_UnitAuras.GetAuraDuration) == "function") then
        return false, "API_UNAVAILABLE"
    end
    if not (_G.C_DurationUtil and type(_G.C_DurationUtil.CreateDurationTextBinding) == "function") then
        return false, "DURATION_UTIL_UNAVAILABLE"
    end
    local okDur, durObj = pcall(_G.C_UnitAuras.GetAuraDuration, unit, auraInstanceID)
    if not okDur or durObj == nil then
        return false, "NO_DURATION"
    end
    local okBind, binding = pcall(_G.C_DurationUtil.CreateDurationTextBinding, durObj, fontString)
    if not okBind then
        return false, "BIND_FAILED"
    end
    return true, binding
end

-- Bind a spell cooldown duration directly to a FontString via C_Spell.GetSpellCooldownDuration + C_DurationUtil.
function DurationAdapter.BindSpellCooldown(spellID, fontString)
    if (ns.Api.SafeAPI and ns.Api.SafeAPI.IsSecret(spellID)) or type(spellID) ~= "number" or spellID <= 0 or type(fontString) ~= "table" then
        return false, "INVALID_ARGS"
    end
    if not (_G.C_Spell and type(_G.C_Spell.GetSpellCooldownDuration) == "function") then
        return false, "API_UNAVAILABLE"
    end
    if not (_G.C_DurationUtil and type(_G.C_DurationUtil.CreateDurationTextBinding) == "function") then
        return false, "DURATION_UTIL_UNAVAILABLE"
    end
    local okDur, durObj = pcall(_G.C_Spell.GetSpellCooldownDuration, spellID)
    if not okDur or durObj == nil then
        return false, "NO_DURATION"
    end
    local okBind, binding = pcall(_G.C_DurationUtil.CreateDurationTextBinding, durObj, fontString)
    if not okBind then
        return false, "BIND_FAILED"
    end
    return true, binding
end

-- Display-safe stack count pass-through directly into FontString:SetText (zero comparisons on secret values).
function DurationAdapter.BindAuraStacks(unit, auraInstanceID, fontString)
    if type(unit) ~= "string" or auraInstanceID == nil or type(fontString) ~= "table" then
        return false
    end
    if not (_G.C_UnitAuras and type(_G.C_UnitAuras.GetAuraApplicationDisplayCount) == "function") then
        return false
    end
    local ok, displayVal = pcall(_G.C_UnitAuras.GetAuraApplicationDisplayCount, unit, auraInstanceID, 1, 99)
    if ok and displayVal ~= nil and type(fontString.SetText) == "function" then
        local okSet = pcall(fontString.SetText, fontString, displayVal)
        return okSet == true
    end
    return false
end
