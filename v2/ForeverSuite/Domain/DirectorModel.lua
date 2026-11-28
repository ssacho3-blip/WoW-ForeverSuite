-- Module: Domain/DirectorModel.lua
-- Responsibility: Pure 5-State (+ EDIT_OVERRIDE) Director State-Morphing priority resolver & HUD alpha matrix.
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G, zero CreateFrame).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type

local DirectorModel = {}
ns.Domain.DirectorModel = DirectorModel

DirectorModel.STATES = {
    EDIT_OVERRIDE = "EDIT_OVERRIDE",
    COMBAT        = "COMBAT",
    DEAD          = "DEAD",
    FISHING       = "FISHING",
    DIALOGUE      = "DIALOGUE",
    EXPLORATION   = "EXPLORATION",
}

-- V6_MASTER_DESIGN_SPEC C-1 canonical alpha matrix per non-secure HUD channel
DirectorModel.ALPHA_MATRIX = {
    EDIT_OVERRIDE = {
        questTracker = 1.00,
        navArrow     = 1.00,
        fishingCard  = 1.00,
        statusPill   = 1.00,
        combatAssist = 1.00,
        toast        = 1.00,
    },
    EXPLORATION = {
        questTracker = 1.00,
        navArrow     = 0.90,
        fishingCard  = 0.00,
        statusPill   = 0.88,
        combatAssist = 0.85,
        toast        = 1.00,
    },
    FISHING = {
        questTracker = 0.45,
        navArrow     = 0.85,
        fishingCard  = 1.00,
        statusPill   = 0.55,
        combatAssist = 0.00,
        toast        = 0.85,
    },
    DIALOGUE = {
        questTracker = 0.35,
        navArrow     = 0.00,
        fishingCard  = 0.00,
        statusPill   = 0.40,
        combatAssist = 0.00,
        toast        = 0.00,
    },
    COMBAT = {
        questTracker = 0.35,
        navArrow     = 0.65,
        fishingCard  = 0.00,
        statusPill   = 0.95,
        combatAssist = 1.00,
        toast        = 0.90,
    },
    DEAD = {
        questTracker = 0.25,
        navArrow     = 1.00,
        fishingCard  = 0.00,
        statusPill   = 0.50,
        combatAssist = 0.00,
        toast        = 0.85,
    },
}

-- Strict priority: EDIT_OVERRIDE > COMBAT > DEAD (excluding Feign Death!) > FISHING (excluding mounted!) > DIALOGUE > EXPLORATION
function DirectorModel.ResolveState(signals)
    local s = (type(signals) == "table") and signals or {}
    if s.isEditOverride == true then
        return "EDIT_OVERRIDE"
    end
    if s.inCombat == true then
        return "COMBAT"
    end
    if s.isDeadOrGhost == true and s.isFeignDeath ~= true then
        return "DEAD"
    end
    if s.hasFishingPole == true and s.isMounted ~= true then
        return "FISHING"
    end
    if s.isDialogueShown == true then
        return "DIALOGUE"
    end
    return "EXPLORATION"
end

function DirectorModel.GetAlphaMatrix(state)
    return DirectorModel.ALPHA_MATRIX[state] or DirectorModel.ALPHA_MATRIX.EXPLORATION
end

-- Returns recommended transition duration in seconds (0 = instant combat cut)
function DirectorModel.GetTransitionDuration(fromState, toState)
    if toState == "COMBAT" or toState == "EDIT_OVERRIDE" then
        return 0.0
    end
    if fromState == "COMBAT" then
        return 0.20
    end
    if toState == "FISHING" then
        return 0.20
    end
    return 0.25
end
