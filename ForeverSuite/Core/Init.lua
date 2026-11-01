local ADDON_NAME, ns = ...

ns = ns or {}
_G.ForeverSuite = ns

ns.ADDON_NAME = ADDON_NAME or "ForeverSuite"
ns.VERSION = "0.1.0"
ns.TARGET_TOC = 11701
ns.PREFIX = "|cffd4af37[ForeverSuite]|r "

local type = type
local tostring = tostring
local select = select
local ipairs = ipairs
local pairs = pairs
local math_floor = math.floor
local math_abs = math.abs
local string_format = string.format

function ns.Print(msg)
    local text = ns.PREFIX .. tostring(msg or "")
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(text)
    end
end

function ns.Warn(msg)
    ns.Print("|cffffb347" .. tostring(msg or "") .. "|r")
end

function ns.ErrorMsg(msg)
    ns.Print("|cffff5555" .. tostring(msg or "") .. "|r")
end

function ns.IsSecret(val)
    local fn = _G.issecretvalue
    if type(fn) == "function" then
        local ok, res = pcall(fn, val)
        return (ok and res) and true or false
    end
    return false
end

function ns.InCombat()
    if _G.InCombatLockdown then
        return _G.InCombatLockdown() and true or false
    end
    return false
end

function ns.GetNow()
    if _G.GetTime then
        return _G.GetTime()
    end
    return 0
end

function ns.FormatMoney(copper)
    if type(copper) ~= "number" or ns.IsSecret(copper) then
        return "—"
    end
    local sign = ""
    if copper < 0 then
        sign = "-"
        copper = math_abs(copper)
    end
    copper = math_floor(copper + 0.5)
    local gold = math_floor(copper / 10000)
    local silver = math_floor((copper % 10000) / 100)
    local rem = copper % 100
    if gold > 0 then
        return string_format("%s%d|cffffd700g|r %d|cffc7c7cfs|r %d|cffeda55fc|r", sign, gold, silver, rem)
    elseif silver > 0 then
        return string_format("%s%d|cffc7c7cfs|r %d|cffeda55fc|r", sign, silver, rem)
    end
    return string_format("%s%d|cffeda55fc|r", sign, rem)
end

function ns.WipeTable(tbl)
    if type(tbl) ~= "table" then
        return tbl
    end
    if _G.wipe then
        return _G.wipe(tbl)
    end
    for k in pairs(tbl) do
        tbl[k] = nil
    end
    return tbl
end

function ns.SafeGetCVar(name)
    if C_CVar and C_CVar.GetCVar then
        local ok, val = pcall(C_CVar.GetCVar, name)
        if ok then
            return val
        end
    elseif _G.GetCVar then
        local ok, val = pcall(_G.GetCVar, name)
        if ok then
            return val
        end
    end
    return nil
end

function ns.SafeSetCVar(name, value)
    local strVal = tostring(value)
    if C_CVar and C_CVar.SetCVar then
        local ok = pcall(C_CVar.SetCVar, name, strVal)
        return ok and true or false
    elseif _G.SetCVar then
        local ok = pcall(_G.SetCVar, name, strVal)
        return ok and true or false
    end
    return false
end

ns.PendingMoneyReasons = {}

local REASON_EXPECTED_SIGN = {
    REPAIR = -1,
    VENDOR_SELL = 1,
    QUEST = 1,
}

function ns.ClearPendingMoneyReasons()
    ns.WipeTable(ns.PendingMoneyReasons)
    ns.PendingMoneyReason = nil
    ns.PendingMoneyReasonAt = nil
end

function ns.SetPendingMoneyReason(reason, ttlSec, expectedSign, expectedDelta)
    if type(reason) ~= "string" or reason == "" then
        return
    end
    local now = ns.GetNow()
    local rawTtl = tonumber(ttlSec) or 1.5
    local ttl = (rawTtl > 0 and rawTtl <= 1.5) and rawTtl or 1.5
    local sign = expectedSign or REASON_EXPECTED_SIGN[reason] or 0
    local expDelta = (type(expectedDelta) == "number" and not ns.IsSecret(expectedDelta)) and expectedDelta or nil
    if expDelta == 0 then
        expDelta = nil
    end
    if expDelta ~= nil and expDelta ~= 0 then
        sign = expDelta > 0 and 1 or -1
    end
    local q = ns.PendingMoneyReasons
    local writeIdx = 1
    for readIdx = 1, #q do
        local item = q[readIdx]
        if item and now <= item.expiresAt then
            q[writeIdx] = item
            writeIdx = writeIdx + 1
        end
    end
    for i = writeIdx, #q do
        q[i] = nil
    end
    if #q >= 32 then
        for k = 1, #q - 1 do
            q[k] = q[k + 1]
        end
        q[#q] = nil
    end
    q[#q + 1] = {
        reason = reason,
        sign = sign,
        expectedDelta = expDelta,
        createdAt = now,
        expiresAt = now + ttl,
    }
    ns.PendingMoneyReason = reason
    ns.PendingMoneyReasonAt = now
end

function ns.ConsumePendingMoneyReason(deltaOrNil)
    local q = ns.PendingMoneyReasons
    if #q == 0 then
        ns.PendingMoneyReason = nil
        ns.PendingMoneyReasonAt = nil
        return nil
    end
    local now = ns.GetNow()
    local delta = (type(deltaOrNil) == "number" and not ns.IsSecret(deltaOrNil)) and deltaOrNil or nil

    -- First prune any expired entries strictly by item.expiresAt
    local liveWrite = 1
    for readIdx = 1, #q do
        local item = q[readIdx]
        if item and now <= item.expiresAt then
            q[liveWrite] = item
            liveWrite = liveWrite + 1
        end
    end
    for i = liveWrite, #q do
        q[i] = nil
    end
    if #q == 0 then
        ns.PendingMoneyReason = nil
        ns.PendingMoneyReasonAt = nil
        return nil
    end

    local matchedReason = nil
    local removeMask = {}

    -- Pass 1: Exact expectedDelta match (prevents VENDOR_SELL vs QUEST cross-consumption)
    if delta ~= nil then
        for i = 1, #q do
            local item = q[i]
            if item.expectedDelta ~= nil and item.expectedDelta == delta then
                matchedReason = item.reason
                removeMask[i] = true
                break
            end
        end
    end

    -- Pass 1b: Coalesced batch prefix match (e.g., server coalesced k VENDOR_SELL items into one PLAYER_MONEY)
    if not matchedReason and delta ~= nil then
        for startIdx = 1, #q do
            local first = q[startIdx]
            if first.expectedDelta ~= nil then
                local running = first.expectedDelta
                local indices = { startIdx }
                for nextIdx = startIdx + 1, #q do
                    local nxt = q[nextIdx]
                    if nxt.reason == first.reason and nxt.expectedDelta ~= nil then
                        running = running + nxt.expectedDelta
                        indices[#indices + 1] = nextIdx
                        if running == delta then
                            matchedReason = first.reason
                            for _, rmIdx in ipairs(indices) do
                                removeMask[rmIdx] = true
                            end
                            break
                        end
                    else
                        break
                    end
                end
                if matchedReason then
                    break
                end
            end
        end
    end

    -- Pass 2: Sign-based fallback ONLY for entries that did not specify an exact expectedDelta
    if not matchedReason then
        for i = 1, #q do
            local item = q[i]
            if item.expectedDelta == nil then
                local signOk = true
                if delta ~= nil and item.sign ~= 0 then
                    signOk = (delta > 0 and item.sign > 0) or (delta < 0 and item.sign < 0)
                end
                if signOk then
                    matchedReason = item.reason
                    removeMask[i] = true
                    break
                end
            end
        end
    end

    if matchedReason then
        local outIdx = 1
        for readIdx = 1, #q do
            if not removeMask[readIdx] then
                q[outIdx] = q[readIdx]
                outIdx = outIdx + 1
            end
        end
        for i = outIdx, #q do
            q[i] = nil
        end
    end

    if #q == 0 then
        ns.PendingMoneyReason = nil
        ns.PendingMoneyReasonAt = nil
    else
        ns.PendingMoneyReason = q[1].reason
        ns.PendingMoneyReasonAt = q[1].createdAt
    end
    return matchedReason
end

function ns.IsExternalAddonLoaded(addonName)
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        local loaded = C_AddOns.IsAddOnLoaded(addonName)
        return loaded and true or false
    end
    return false
end

-- CombatQueue: defers protected operations while InCombatLockdown() is active (AC-3)
local CombatQueue = {
    order = {},
    tasks = {},
    protectedBlockedCount = 0,
}
ns.CombatQueue = CombatQueue

function CombatQueue:RunOrDefer(key, fn)
    if type(fn) ~= "function" then
        return false
    end
    local taskKey = tostring(key or fn)
    if ns.InCombat() then
        if not self.tasks[taskKey] then
            self.order[#self.order + 1] = taskKey
        end
        self.tasks[taskKey] = fn
        self.protectedBlockedCount = self.protectedBlockedCount + 1
        return false
    end
    local ok, err = pcall(fn)
    if not ok then
        ns.Warn("CombatQueue 실행 오류(" .. taskKey .. "): " .. tostring(err))
        return false
    end
    return true
end

function CombatQueue:Flush()
    if ns.InCombat() then
        return 0
    end
    local total = #self.order
    if total == 0 then
        return 0
    end
    local batch = {}
    for i = 1, total do
        batch[i] = self.order[i]
    end
    ns.WipeTable(self.order)

    local executed = 0
    for i = 1, total do
        local key = batch[i]
        if ns.InCombat() then
            -- Re-entered combat mid-flush: preserve remaining unexecuted keys in order
            for r = i, total do
                local remKey = batch[r]
                if self.tasks[remKey] then
                    self.order[#self.order + 1] = remKey
                end
            end
            break
        end
        local fn = self.tasks[key]
        self.tasks[key] = nil
        if fn then
            local ok, err = pcall(fn)
            if ok then
                executed = executed + 1
            else
                ns.Warn("CombatQueue 지연 작업 오류(" .. tostring(key) .. "): " .. tostring(err))
            end
        end
    end
    return executed
end

function CombatQueue:PendingCount()
    return #self.order
end

-- Client & API Probe (Contract Clause 0: Ground-Truth In-Client Probe)
local PROBE_NAMESPACES = {
    "C_AddOns",
    "C_AddOnProfiler",
    "C_AuctionHouse",
    "C_Container",
    "C_CooldownViewer",
    "C_CVar",
    "C_DamageMeter",
    "C_EditMode",
    "C_EncounterTimeline",
    "C_EncounterWarnings",
    "C_Item",
    "C_Map",
    "C_MerchantFrame",
    "C_Minimap",
    "C_Navigation",
    "C_QuestLog",
    "C_Secrets",
    "C_Spell",
    "C_SuperTrack",
    "C_Timer",
    "C_TradeSkillUI",
    "C_UnitAuras",
}

local PROBE_GLOBALS = {
    "issecretvalue",
    "InCombatLockdown",
    "Settings",
    "TooltipDataProcessor",
    "AddonCompartmentFrame",
    "UiMapPoint",
    "Item",
}

function ns.RunClientProbe()
    local version, build, buildDate, tocVersion = "unknown", "unknown", "unknown", 0
    if _G.GetBuildInfo then
        local v, b, d, t = _G.GetBuildInfo()
        version = tostring(v or "unknown")
        build = tostring(b or "unknown")
        buildDate = tostring(d or "unknown")
        tocVersion = tonumber(t) or 0
    end

    local xpcallForwardsArgs = false
    local probeArg = nil
    xpcall(function(a)
        probeArg = a
    end, function(e)
        return e
    end, 42)
    if probeArg == 42 then
        xpcallForwardsArgs = true
    end

    local namespaces = {}
    for _, nsName in ipairs(PROBE_NAMESPACES) do
        local tbl = _G[nsName]
        if type(tbl) == "table" then
            local count = 0
            for k, v in pairs(tbl) do
                if type(k) == "string" and type(v) == "function" then
                    count = count + 1
                end
            end
            namespaces[nsName] = { present = true, fnCount = count }
        else
            namespaces[nsName] = { present = false, fnCount = 0 }
        end
    end

    local globals = {}
    for _, gName in ipairs(PROBE_GLOBALS) do
        globals[gName] = (_G[gName] ~= nil)
    end

    local report = {
        version = version,
        build = build,
        buildDate = buildDate,
        tocVersion = tocVersion,
        xpcallForwardsArgs = xpcallForwardsArgs,
        namespaces = namespaces,
        globals = globals,
        timestamp = ns.GetNow(),
    }

    if type(_G.ForeverSuiteDB) == "table" then
        _G.ForeverSuiteDB.lastProbe = report
    end
    return report
end

function ns.SummarizeStack(err)
    local msg = tostring(err or "unknown error")
    if _G.debugstack then
        local stack = tostring(_G.debugstack(2, 4, 0) or "")
        if stack ~= "" then
            return msg .. "\n" .. stack
        end
    end
    return msg
end
