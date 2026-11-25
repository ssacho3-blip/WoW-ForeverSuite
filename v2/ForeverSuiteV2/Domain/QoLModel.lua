-- Module: Domain/QoLModel.lua
-- Responsibility: Pure Lua 5.1 decision rules for safe QoL automation (Fast Loot, BG-only Release, OOC Res, Friend/Guild Invite) and Session XP/h tracking.
-- Layer: Domain (ZERO _G / WoW API access; verified by fsx check).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local math_floor = math.floor
local math_max = math.max
local string_format = string.format
local string_gsub = string.gsub
local tostring = tostring

local QoLModel = {}
ns.Domain.QoLModel = QoLModel

function QoLModel.ShouldFastLoot(enabled, v1Loaded, autoLootCVarBool, modifierDown)
    if (enabled ~= true) or (v1Loaded == true) then
        return false, "DISABLED_OR_YIELDED"
    end
    -- Fail-closed if autoLootDefault CVar OR modifier state is unreadable (nil)
    if type(autoLootCVarBool) ~= "boolean" then
        return false, "CVAR_UNREADABLE"
    end
    if type(modifierDown) ~= "boolean" then
        return false, "MODIFIER_UNREADABLE"
    end
    -- Standard WoW XOR: if autoLootDefault=true, modifier suppresses auto-loot; if false, modifier activates it.
    if autoLootCVarBool ~= modifierDown then
        return true, "LOOT"
    end
    return false, "MODIFIER_SKIP"
end

function QoLModel.ShouldAutoReleaseSpirit(enabled, v1Loaded, shiftDown, inInstance, instanceType, hasSelfRes)
    if (enabled ~= true) or (v1Loaded == true) then
        return false, "DISABLED_OR_YIELDED"
    end
    if shiftDown ~= false then
        return false, (shiftDown == true) and "SHIFT_BYPASS" or "SHIFT_UNREADABLE"
    end
    if inInstance ~= true or instanceType ~= "pvp" then
        return false, "NOT_BATTLEGROUND"
    end
    -- Fail-closed: if self-res capability (Soulstone / Reincarnation via HasSoulstone) cannot be verified, do NOT release!
    if type(hasSelfRes) ~= "boolean" then
        return false, "SELF_RES_UNREADABLE"
    end
    if hasSelfRes == true then
        return false, "HAS_SELF_RES"
    end
    return true, "RELEASE"
end

function QoLModel.ShouldAutoAcceptRes(enabled, v1Loaded, shiftDown, inCombat)
    if (enabled ~= true) or (v1Loaded == true) then
        return false, "DISABLED_OR_YIELDED"
    end
    if shiftDown ~= false then
        return false, (shiftDown == true) and "SHIFT_BYPASS" or "SHIFT_UNREADABLE"
    end
    if inCombat ~= false then
        -- Fail-closed on true OR nil combat state (never auto-accept combat res!)
        return false, "IN_COMBAT"
    end
    return true, "ACCEPT"
end

function QoLModel.ShouldAutoAcceptInvite(enabled, v1Loaded, shiftDown, isFriendOrGuild)
    if (enabled ~= true) or (v1Loaded == true) then
        return false, "DISABLED_OR_YIELDED"
    end
    if shiftDown ~= false then
        return false, (shiftDown == true) and "SHIFT_BYPASS" or "SHIFT_UNREADABLE"
    end
    if isFriendOrGuild ~= true then
        return false, "UNTRUSTED_SENDER"
    end
    return true, "ACCEPT"
end

function QoLModel.CreateXPState(nowSec)
    return {
        initialized = false,
        startedAt = (type(nowSec) == "number") and nowSec or 0,
        lastLevel = 0,
        lastXP = 0,
        lastMaxXP = 0,
        sessionGained = 0,
        lastGain = 0,
        secretGap = false,
        pendingLevelUp = false,
        waitCount = 0,
    }
end

function QoLModel.UpdateXPState(state, xp, maxXP, level, nowSec)
    if type(state) ~= "table" then
        return 0, "INVALID_STATE"
    end
    if type(xp) ~= "number" or type(maxXP) ~= "number" or type(level) ~= "number" then
        state.secretGap = true
        return 0, "UNREADABLE"
    end
    if not state.initialized then
        state.initialized = true
        state.startedAt = (type(nowSec) == "number") and nowSec or state.startedAt
        state.lastLevel = level
        state.lastXP = xp
        state.lastMaxXP = maxXP
        return 0, "INITIALIZED"
    end

    local delta = 0
    if level > state.lastLevel then
        if state.pendingLevelUp then
            state.pendingLevelUp = false
            state.waitCount = 0
            delta = math_max(0, xp - state.lastXP)
        elseif level == state.lastLevel + 1 and (xp == state.lastXP or (xp > state.lastXP and maxXP == state.lastMaxXP)) and state.waitCount < 1 then
            -- PLAYER_LEVEL_UP can fire once before UnitXP wraps to the new level
            state.waitCount = state.waitCount + 1
            return 0, "DEFERRED_WRAP"
        else
            state.waitCount = 0
            delta = math_max(0, (state.lastMaxXP - state.lastXP) + xp)
        end
    elseif level == state.lastLevel then
        state.waitCount = 0
        if xp >= state.lastXP then
            delta = xp - state.lastXP
        else
            -- Classic/Forever PLAYER_XP_UPDATE can wrap XP before UnitLevel increments
            delta = math_max(0, (state.lastMaxXP - state.lastXP) + xp)
            state.pendingLevelUp = true
        end
    else
        state.waitCount = 0
        state.pendingLevelUp = false
    end

    state.lastLevel = level
    state.lastXP = xp
    state.lastMaxXP = maxXP
    if delta > 0 then
        state.sessionGained = state.sessionGained + delta
        state.lastGain = delta
    end
    return delta, "UPDATED"
end

function QoLModel.ComputeXPStats(state, xp, maxXP, level, maxLevel, restedXP, nowSec)
    if type(state) ~= "table" or type(xp) ~= "number" or type(maxXP) ~= "number" or type(level) ~= "number" then
        return nil
    end
    local isMaxLevel = (maxXP <= 0) or (type(maxLevel) == "number" and maxLevel > 0 and level >= maxLevel)
    local elapsedSec = (type(nowSec) == "number") and math_max(0, nowSec - state.startedAt) or 0
    local remainingXP = isMaxLevel and 0 or math_max(0, maxXP - xp)
    local pct = (not isMaxLevel and maxXP > 0) and ((xp / maxXP) * 100) or 100
    local xpPerHour = (state.sessionGained > 0 and elapsedSec >= 1)
        and math_floor((state.sessionGained / elapsedSec) * 3600 + 0.5)
        or nil
    local etaSec = (not isMaxLevel and xpPerHour and xpPerHour > 0 and remainingXP > 0)
        and math_floor((remainingXP / xpPerHour) * 3600 + 0.5)
        or nil

    return {
        level = level,
        xp = xp,
        maxXP = maxXP,
        remainingXP = remainingXP,
        pct = pct,
        isMaxLevel = isMaxLevel,
        sessionGained = state.sessionGained,
        elapsedSec = elapsedSec,
        xpPerHour = xpPerHour,
        etaSec = etaSec,
        restedXP = (type(restedXP) == "number" and restedXP > 0) and math_floor(restedXP) or 0,
        secretGap = state.secretGap == true,
    }
end

function QoLModel.FormatNumberWithCommas(n)
    if type(n) ~= "number" then
        return "0"
    end
    local s = tostring(math_floor(n + 0.5))
    while true do
        local nextS, k = string_gsub(s, "^(-?%d+)(%d%d%d)", "%1,%2")
        s = nextS
        if k == 0 then
            break
        end
    end
    return s
end

function QoLModel.FormatDuration(sec)
    if type(sec) ~= "number" or sec < 0 then
        return "—"
    end
    local total = math_floor(sec + 0.5)
    local h = math_floor(total / 3600)
    local m = math_floor((total % 3600) / 60)
    local s = total % 60
    if h > 0 then
        return string_format("%d시간 %02d분", h, m)
    end
    return string_format("%02d:%02d", m, s)
end
