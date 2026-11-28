-- Module: Api/AddonProbe.lua
-- Responsibility: Safe read-only WoW 1.60.1 external addon presence & load-state probing via verified C_AddOns APIs.
-- Layer: Api (no Frame creation, no upward references, zero forbidden legacy globals).
local _, ns = ...
ns.Api = ns.Api or {}

local type = type
local pcall = pcall
local ipairs = ipairs

local AddonProbe = {}
ns.Api.AddonProbe = AddonProbe

local function SafeRead(fn, ...)
    if ns.Api.SafeAPI and type(ns.Api.SafeAPI.SafeRead) == "function" then
        return ns.Api.SafeAPI.SafeRead(fn, ...)
    end
    if type(fn) ~= "function" then
        return nil
    end
    local ok, val = pcall(fn, ...)
    if not ok then
        return nil
    end
    return val
end

local function IsUnavailable(v)
    return ns.Api.SafeAPI and v == ns.Api.SafeAPI.UNAVAILABLE
end

function AddonProbe.Probe(addonName)
    if type(addonName) ~= "string" or addonName == "" then
        return { loaded = false, enabled = false, loadable = false, present = false }
    end

    local loaded = false
    if _G.C_AddOns and type(_G.C_AddOns.IsAddOnLoaded) == "function" then
        local v = SafeRead(_G.C_AddOns.IsAddOnLoaded, addonName)
        if not IsUnavailable(v) then
            loaded = v == true
        end
    end

    local exists = loaded
    if _G.C_AddOns and type(_G.C_AddOns.DoesAddOnExist) == "function" then
        local v = SafeRead(_G.C_AddOns.DoesAddOnExist, addonName)
        if not IsUnavailable(v) then
            exists = v == true
        end
    end

    return {
        loaded = loaded,
        enabled = exists,
        loadable = exists,
        present = loaded,
    }
end

function AddonProbe.Exists(addonName)
    local p = AddonProbe.Probe(addonName)
    return p.loadable == true
end

function AddonProbe.ProbeAll(addonNames)
    local out = {}
    for _, name in ipairs(addonNames or {}) do
        if type(name) == "string" and name ~= "" then
            out[name] = AddonProbe.Probe(name)
        end
    end
    return out
end

function AddonProbe.GetGlobal(globalName)
    if type(globalName) ~= "string" or globalName == "" then
        return nil
    end
    local v = _G[globalName]
    if ns.Api.SafeAPI and ns.Api.SafeAPI.IsSecret(v) then
        return nil
    end
    return v
end
