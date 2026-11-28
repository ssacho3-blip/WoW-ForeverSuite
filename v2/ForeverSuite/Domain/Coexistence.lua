-- Module: Domain/Coexistence.lua
-- Responsibility: Pure 5-state x 8-event (40-cell) CoexistenceRegistry state machine & external 9-addon policy table.
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G, zero CreateFrame).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local pairs = pairs
local ipairs = ipairs

local Coexistence = {}
ns.Domain.Coexistence = Coexistence

Coexistence.STATES = {
    SELF = "SELF",
    YIELDED = "YIELDED",
    BRIDGE_WARMING = "BRIDGE_WARMING",
    BRIDGE_ONLY = "BRIDGE_ONLY",
    FAULTED = "FAULTED",
}

Coexistence.EVENTS = {
    ABSENT = "ABSENT",
    PRESENT = "PRESENT",
    BRIDGE_WAIT = "BRIDGE_WAIT",
    BRIDGE_OK = "BRIDGE_OK",
    BRIDGE_FAIL = "BRIDGE_FAIL",
    CONFLICT = "CONFLICT",
    OVERRIDE_SELF = "OVERRIDE_SELF",
    RESET = "RESET",
}

-- Canonical Option-C ("길 C") coexistence policies for the 9 verified external specialist addons.
Coexistence.DEFAULT_POLICIES = {
    baganator = {
        id = "baganator",
        target = "Baganator",
        mode = "bridge",
        yields = {},
    },
    syndicator = {
        id = "syndicator",
        target = "Syndicator",
        mode = "bridge",
        yields = { "alt_bag_scan" },
    },
    auctionator = {
        id = "auctionator",
        target = "Auctionator",
        mode = "bridge",
        yields = { "tooltip_vendor_price" },
    },
    dialogue_ui = {
        id = "dialogue_ui",
        target = "DialogueUI",
        mode = "bridge",
        yields = { "quest_automation" },
    },
    spoken = {
        id = "spoken",
        target = "Spoken",
        mode = "bridge",
        yields = { "quest_automation" },
    },
    platynator = {
        id = "platynator",
        target = "Platynator",
        mode = "bridge",
        yields = { "nameplates" },
    },
    forever_totems = {
        id = "forever_totems",
        target = "ForeverTotems",
        mode = "yield",
        classOnly = "SHAMAN",
        yields = { "shaman_assist" },
    },
    rare_scanner = {
        id = "rare_scanner",
        target = "RareScanner",
        mode = "yield",
        yields = { "rare_alerts" },
    },
    what_the_whisper = {
        id = "what_the_whisper",
        target = "WhatTheWhisper",
        mode = "yield",
        yields = { "whisper_tabs" },
    },
}

local VALID_STATES = {
    SELF = true,
    YIELDED = true,
    BRIDGE_WARMING = true,
    BRIDGE_ONLY = true,
    FAULTED = true,
}

local VALID_EVENTS = {
    ABSENT = true,
    PRESENT = true,
    BRIDGE_WAIT = true,
    BRIDGE_OK = true,
    BRIDGE_FAIL = true,
    CONFLICT = true,
    OVERRIDE_SELF = true,
    RESET = true,
}

-- Deterministic 5-state x 8-event (40-cell) transition table (V6_MASTER_DESIGN_SPEC A-3).
-- FAULTED is strictly absorbing until RESET.
function Coexistence.Transition(state, event, policy)
    if not VALID_STATES[state] then
        return "FAULTED", "INVALID_STATE"
    end
    if not VALID_EVENTS[event] then
        return "FAULTED", "INVALID_EVENT"
    end

    -- Absorbing FAULTED state: only RESET can exit.
    if state == "FAULTED" then
        if event == "RESET" then
            return "SELF", "RESET_FROM_FAULTED"
        end
        return "FAULTED", "ABSORBING_FAULTED"
    end

    if event == "RESET" then
        return "SELF", "RESET"
    end
    if event == "CONFLICT" or event == "BRIDGE_FAIL" then
        return "FAULTED", event
    end
    if event == "ABSENT" then
        return "SELF", "TARGET_ABSENT"
    end
    if event == "OVERRIDE_SELF" then
        return "SELF", "USER_OVERRIDE_SELF"
    end

    local mode = (type(policy) == "table" and policy.mode) or "yield"

    if state == "SELF" then
        if event == "PRESENT" then
            if mode == "bridge" then
                return "BRIDGE_WARMING", "BRIDGE_INIT_PENDING"
            end
            return "YIELDED", "YIELD_TO_EXTERNAL"
        elseif event == "BRIDGE_WAIT" then
            return "BRIDGE_WARMING", "BRIDGE_WARMING"
        elseif event == "BRIDGE_OK" then
            return "BRIDGE_ONLY", "BRIDGE_ACTIVE"
        end
    elseif state == "YIELDED" then
        if event == "PRESENT" then
            return "YIELDED", "STAY_YIELDED"
        elseif event == "BRIDGE_WAIT" or event == "BRIDGE_OK" then
            return "FAULTED", "ILLEGAL_BRIDGE_FROM_YIELDED"
        end
    elseif state == "BRIDGE_WARMING" then
        if event == "PRESENT" or event == "BRIDGE_WAIT" then
            return "BRIDGE_WARMING", "STILL_WARMING"
        elseif event == "BRIDGE_OK" then
            return "BRIDGE_ONLY", "BRIDGE_READY"
        end
    elseif state == "BRIDGE_ONLY" then
        if event == "PRESENT" or event == "BRIDGE_OK" then
            return "BRIDGE_ONLY", "STAY_BRIDGE_ONLY"
        elseif event == "BRIDGE_WAIT" then
            return "BRIDGE_WARMING", "BRIDGE_REWARMING"
        end
    end

    return "FAULTED", "UNHANDLED_TRANSITION"
end

-- Pure bulk resolver (Fail-Closed when probes is not a table).
-- Priority: FAULTED (unless RESET) > explicit override > probe result > SELF.
function Coexistence.ResolveAll(probes, overrides, context, prevStates, policies)
    if type(probes) ~= "table" then
        return nil, "INVALID_PROBES"
    end
    local policyMap = (type(policies) == "table") and policies or Coexistence.DEFAULT_POLICIES
    local ov = (type(overrides) == "table") and overrides or {}
    local ctx = (type(context) == "table") and context or {}
    local prev = (type(prevStates) == "table") and prevStates or {}

    local resolved = {}
    for id, pol in pairs(policyMap) do
        local curState = prev[id] or "SELF"
        local overrideMode = ov[id]

        if curState == "FAULTED" then
            if overrideMode == "reset" then
                local nextSt, rsn = Coexistence.Transition("FAULTED", "RESET", pol)
                resolved[id] = { state = nextSt, reason = rsn, target = pol.target }
            else
                resolved[id] = { state = "FAULTED", reason = "ABSORBING_FAULTED", target = pol.target }
            end
        elseif overrideMode == "self" then
            local nextSt, rsn = Coexistence.Transition(curState, "OVERRIDE_SELF", pol)
            resolved[id] = { state = nextSt, reason = rsn, target = pol.target }
        else
            local classMismatch = type(pol.classOnly) == "string"
                and pol.classOnly ~= ""
                and ctx.playerClass ~= pol.classOnly
            local p = probes[pol.target]
            local present = (not classMismatch) and type(p) == "table" and (p.loaded == true or p.present == true)
            local ev = present and "PRESENT" or "ABSENT"
            local nextSt, rsn = Coexistence.Transition(curState, ev, pol)
            resolved[id] = { state = nextSt, reason = rsn, target = pol.target }
        end
    end
    return resolved, "OK"
end

-- Pure helper: determines whether a built-in ForeverSuite feature must yield to an active external specialist.
function Coexistence.ShouldYieldFeature(resolvedMap, featureId, policies)
    if type(resolvedMap) ~= "table" or type(featureId) ~= "string" or featureId == "" then
        return false, nil
    end
    local policyMap = (type(policies) == "table") and policies or Coexistence.DEFAULT_POLICIES
    for id, pol in pairs(policyMap) do
        local rec = resolvedMap[id]
        if type(rec) == "table" and (rec.state == "YIELDED" or rec.state == "BRIDGE_ONLY" or rec.state == "BRIDGE_WARMING") then
            for _, y in ipairs(pol.yields or {}) do
                if y == featureId then
                    return true, pol.target
                end
            end
        end
    end
    return false, nil
end
