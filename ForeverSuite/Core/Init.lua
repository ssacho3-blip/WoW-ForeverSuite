-- Module: Core/Init.lua
-- Responsibility: Shared namespace bootstrap, C_Secrets/InCombatLockdown guards, CombatQueue, FeatureYields, and API probe.
-- Dependencies: None (first file in ForeverSuite.toc load order).
-- Public API: ns.Print, ns.Warn, ns.ErrorMsg, ns.IsSecret, ns.InCombat, ns.FormatMoney, ns.CombatQueue, ns.RunClientProbe.
-- Combat/Secret Safety: Wraps issecretvalue via pcall; CombatQueue defers protected actions with last-write-wins keying.
local ADDON_NAME, ns = ...

ns = ns or {}
_G.ForeverSuite = ns

local type = type
local tostring = tostring
local tonumber = tonumber
local ipairs = ipairs
local pairs = pairs
local pcall = pcall
local xpcall = xpcall
local math_floor = math.floor
local math_abs = math.abs
local string_format = string.format
local string_match = string.match

ns.ADDON_NAME = ADDON_NAME or "ForeverSuite"

local function ResolveRuntimeVersionMetadata(addonName)
    local ver = "0.3.0"
    local clientVer = "1.60.1"
    local targetToc = 16001
    if type(_G.GetAddOnMetadata) == "function" then
        local okV, rawV = pcall(_G.GetAddOnMetadata, addonName, "Version")
        if okV and type(rawV) == "string" and rawV ~= "" then
            ver = rawV
        end
        local okI, rawI = pcall(_G.GetAddOnMetadata, addonName, "Interface")
        if okI and type(rawI) == "string" and rawI ~= "" then
            local tok = string_match(rawI, "(160%d%d)") or string_match(rawI, "(%d+)")
            if tok then
                targetToc = tonumber(tok) or targetToc
            end
        end
    end
    if type(_G.GetBuildInfo) == "function" then
        local okB, bVer = pcall(_G.GetBuildInfo)
        if okB and type(bVer) == "string" and bVer ~= "" then
            clientVer = bVer
        end
    end
    return ver, clientVer, targetToc
end

ns.VERSION, ns.CLIENT_VERSION, ns.TARGET_TOC = ResolveRuntimeVersionMetadata(ns.ADDON_NAME)
ns.PREFIX = "|cffd4af37[ForeverSuite]|r "

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
        if not ok then
            return true
        end
        return res and true or false
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

function ns.IsExternalAddonLoaded(addonName)
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        local loaded = C_AddOns.IsAddOnLoaded(addonName)
        return loaded and true or false
    end
    return false
end

ns.FeatureYields = {}

function ns.SetFeatureYield(featureKey, yielded, ownerName)
    if type(featureKey) ~= "string" or featureKey == "" then
        return false
    end
    if yielded then
        ns.FeatureYields[featureKey] = tostring(ownerName or "ExternalAddon")
    else
        ns.FeatureYields[featureKey] = nil
    end
    return true
end

function ns.IsFeatureYielded(featureKey)
    if type(featureKey) ~= "string" then
        return false
    end
    return ns.FeatureYields[featureKey] ~= nil
end

function ns.GetFeatureYieldOwner(featureKey)
    if type(featureKey) ~= "string" then
        return nil
    end
    return ns.FeatureYields[featureKey]
end

function ns.HasExternalWayCommand()
    if ns.IsExternalAddonLoaded("TomTom") then
        return true, "TomTom"
    end
    local existingSlash = _G.SLASH_WAY1
    if type(existingSlash) == "string" and existingSlash ~= "" then
        return true, "SLASH_WAY1"
    end
    if type(_G.SlashCmdList) == "table" and type(_G.SlashCmdList["WAY"]) == "function" then
        return true, "SlashCmdList.WAY"
    end
    return false, nil
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
