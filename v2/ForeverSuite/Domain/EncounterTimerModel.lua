-- Module: Domain/EncounterTimerModel.lua
-- Responsibility: Pure Lua 5.1 state machine for L0 Combat/Boss/Instance Run Timer and /fs2 pull countdown.
-- Layer: Domain (ZERO _G / WoW API access; verified by fsx check).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local tonumber = tonumber
local tostring = tostring
local math_floor = math.floor
local math_max = math.max
local string_format = string.format
local string_lower = string.lower
local string_match = string.match

local MIN_PULL_SEC = 3
local MAX_PULL_SEC = 30

local EncounterTimerModel = {}
ns.Domain.EncounterTimerModel = EncounterTimerModel

function EncounterTimerModel.FormatMMSS(sec)
    if type(sec) ~= "number" or sec < 0 then
        return "00:00"
    end
    local total = math_floor(sec)
    local m = math_floor(total / 60)
    local s = total % 60
    return string_format("%02d:%02d", m, s)
end

function EncounterTimerModel.CreateState()
    return {
        inCombat = false,
        combatStart = nil,
        lastCombatElapsed = nil,
        bossName = nil,
        bossStart = nil,
        instance = nil, -- { name, instanceType, startedAt, bossKills, deaths }
        pull = nil, -- { startedAt, endAt, duration }
        pullGoUntil = nil, -- monotonic timestamp until "PULL_GO" banner auto-clears
    }
end

function EncounterTimerModel.OnCombatStart(state, nowSec)
    if type(state) ~= "table" or type(nowSec) ~= "number" then
        return
    end
    state.inCombat = true
    state.combatStart = nowSec
    state.pull = nil
    state.pullGoUntil = nil
end

function EncounterTimerModel.OnCombatEnd(state, nowSec)
    if type(state) ~= "table" then
        return nil
    end
    local elapsed = nil
    if state.combatStart and type(nowSec) == "number" then
        elapsed = math_max(0, nowSec - state.combatStart)
        state.lastCombatElapsed = elapsed
    end
    state.inCombat = false
    state.combatStart = nil
    return elapsed
end

function EncounterTimerModel.OnEncounterStart(state, encounterName, nowSec)
    if type(state) ~= "table" or type(nowSec) ~= "number" then
        return
    end
    state.bossName = (type(encounterName) == "string" and encounterName ~= "") and encounterName or "보스 전투"
    state.bossStart = nowSec
    state.pull = nil
    state.pullGoUntil = nil
end

function EncounterTimerModel.OnEncounterEnd(state, encounterName, success, nowSec)
    if type(state) ~= "table" then
        return nil
    end
    local name = (type(encounterName) == "string" and encounterName ~= "") and encounterName or state.bossName or "보스 전투"
    local elapsed = (state.bossStart and type(nowSec) == "number") and math_max(0, nowSec - state.bossStart) or nil
    local killed = (success == true or success == 1)
    if killed and state.instance then
        state.instance.bossKills = state.instance.bossKills + 1
    end
    state.bossName = nil
    state.bossStart = nil
    return { name = name, elapsed = elapsed, success = killed }
end

function EncounterTimerModel.OnInstanceChange(state, inInstance, instanceType, instanceName, nowSec, isDeadOrGhost)
    if type(state) ~= "table" or type(nowSec) ~= "number" then
        return nil
    end
    -- Fail-closed on unreadable/secret IsInInstance (nil): preserve active instance state without false exit!
    if type(inInstance) ~= "boolean" then
        return nil
    end
    local isDungeonOrRaid = (inInstance == true) and (instanceType == "party" or instanceType == "raid")
    local hasReadableName = (type(instanceName) == "string" and instanceName ~= "")

    if not isDungeonOrRaid then
        -- Ghost run-back OR unreadable dead/ghost state (nil): hold run state until confirmed alive outside!
        if isDeadOrGhost ~= false then
            return nil
        end
        state.bossName = nil
        state.bossStart = nil
        if state.instance then
            local finished = {
                name = state.instance.name,
                instanceType = state.instance.instanceType,
                elapsed = math_max(0, nowSec - state.instance.startedAt),
                bossKills = state.instance.bossKills,
                deaths = state.instance.deaths,
            }
            state.instance = nil
            return finished
        end
        return nil
    end

    -- If already inside an instance of the same type and the client returned an empty/unreadable name, keep current run
    if state.instance and state.instance.instanceType == instanceType and (not hasReadableName) then
        return nil
    end
    local cleanName = hasReadableName and instanceName or "인스턴스"
    if state.instance and state.instance.name == cleanName and state.instance.instanceType == instanceType then
        return nil
    end

    local prevFinished = nil
    if state.instance then
        prevFinished = {
            name = state.instance.name,
            instanceType = state.instance.instanceType,
            elapsed = math_max(0, nowSec - state.instance.startedAt),
            bossKills = state.instance.bossKills,
            deaths = state.instance.deaths,
        }
    end
    state.bossName = nil
    state.bossStart = nil
    state.instance = {
        name = cleanName,
        instanceType = instanceType,
        startedAt = nowSec,
        bossKills = 0,
        deaths = 0,
    }
    return prevFinished
end

function EncounterTimerModel.OnPlayerDead(state)
    if type(state) == "table" and state.instance then
        state.instance.deaths = state.instance.deaths + 1
    end
end

function EncounterTimerModel.StartPull(state, rawArg, nowSec)
    if type(state) ~= "table" or type(nowSec) ~= "number" then
        return false, "INVALID", 0
    end
    local s = string_lower(string_match(tostring(rawArg or ""), "^%s*(.-)%s*$") or "")
    if s == "0" or s == "clear" or s == "cancel" or s == "취소" then
        state.pull = nil
        state.pullGoUntil = nil
        return true, "CANCELLED", 0
    end
    local n = tonumber(s)
    -- Reject nil, NaN (n ~= n), +/-inf (n == math.huge), and negative numbers
    if (not n) or (n ~= n) or (n <= 0) or (n == 1 / 0) or (n == -1 / 0) then
        return false, "INVALID", 0
    end
    local clamped = math_floor(n + 0.5)
    if clamped < MIN_PULL_SEC then clamped = MIN_PULL_SEC end
    if clamped > MAX_PULL_SEC then clamped = MAX_PULL_SEC end
    state.pullGoUntil = nil
    state.pull = {
        startedAt = nowSec,
        endAt = nowSec + clamped,
        duration = clamped,
    }
    return true, "STARTED", clamped
end

function EncounterTimerModel.NeedsTicker(state)
    if type(state) ~= "table" then
        return false
    end
    return (state.pull ~= nil) or (state.pullGoUntil ~= nil) or (state.bossStart ~= nil) or (state.inCombat == true) or (state.instance ~= nil)
end

function EncounterTimerModel.EvaluateDisplay(state, nowSec)
    if type(state) ~= "table" or type(nowSec) ~= "number" then
        return { visible = false, mode = "IDLE", text = "", tone = "MUTED", expiredPull = false }
    end

    if state.pull then
        local rem = state.pull.endAt - nowSec
        if rem <= 0 then
            state.pull = nil
            state.pullGoUntil = nowSec + 2.0
            return { visible = true, mode = "PULL_GO", text = "풀링 시작!", tone = "SUCCESS", expiredPull = true }
        end
        return {
            visible = true,
            mode = "PULL",
            text = string_format("풀링  %.1f초", rem),
            tone = (rem <= 3.0) and "WARN" or "GOLD",
            expiredPull = false,
        }
    end

    if state.pullGoUntil then
        if nowSec < state.pullGoUntil then
            return { visible = true, mode = "PULL_GO", text = "풀링 시작!", tone = "SUCCESS", expiredPull = false }
        end
        state.pullGoUntil = nil
    end

    if state.bossStart then
        local elapsed = math_max(0, nowSec - state.bossStart)
        return {
            visible = true,
            mode = "BOSS",
            text = "[보스] " .. tostring(state.bossName or "보스") .. "  " .. EncounterTimerModel.FormatMMSS(elapsed),
            tone = "GOLD",
            expiredPull = false,
        }
    end

    if state.inCombat and state.combatStart then
        local elapsed = math_max(0, nowSec - state.combatStart)
        return {
            visible = true,
            mode = "COMBAT",
            text = "전투  " .. EncounterTimerModel.FormatMMSS(elapsed),
            tone = "PRIMARY",
            expiredPull = false,
        }
    end

    if state.instance then
        local elapsed = math_max(0, nowSec - state.instance.startedAt)
        return {
            visible = true,
            mode = "INSTANCE",
            text = string_format(
                "%s  %s · 보스 %d · 사망 %d",
                state.instance.name,
                EncounterTimerModel.FormatMMSS(elapsed),
                state.instance.bossKills,
                state.instance.deaths
            ),
            tone = "MUTED",
            expiredPull = false,
        }
    end

    return { visible = false, mode = "IDLE", text = "", tone = "MUTED", expiredPull = false }
end
