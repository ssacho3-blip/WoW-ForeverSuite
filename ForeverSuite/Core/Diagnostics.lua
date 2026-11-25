-- Module: Core/Diagnostics.lua
-- Responsibility: Phase 0 read-only Taint Canary (ADDON_ACTION_BLOCKED/FORBIDDEN) and GJ panel usage telemetry sink.
-- Dependencies: Core/Init.lua, Core/EventBus.lua, Core/ProfileManager.lua.
-- Public API: ns.Diagnostics (RecordTaint, RecordGJPanelShow, GetSummary, PrintReport, Reset).
-- Combat/Secret Safety: Pure data recording; guards all event payloads with ns.IsSecret; zero UI mutation or protected API calls.
local _, ns = ...

local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local pcall = pcall
local table_insert = table.insert
local table_remove = table.remove
local table_sort = table.sort
local string_format = string.format
local string_match = string.match
local string_lower = string.lower

local MAX_RECENT_TAINT = 100
local MAX_TAINT_KEYS = 200

local Diagnostics = {
    sessionBlocked = 0,
    sessionForbidden = 0,
}
ns.Diagnostics = Diagnostics

local function SafeText(val, fallback)
    if ns.IsSecret(val) or val == nil then
        return fallback or "UNKNOWN"
    end
    local ok, s = pcall(tostring, val)
    if not ok or type(s) ~= "string" or s == "" then
        return fallback or "UNKNOWN"
    end
    return s
end

local function SafeNowTimestamp()
    if type(_G.time) == "function" then
        local ok, t = pcall(_G.time)
        if ok and type(t) == "number" and not ns.IsSecret(t) then
            return t
        end
    end
    return ns.GetNow()
end

local function SafeZoneName()
    if type(_G.GetRealZoneText) == "function" then
        local ok, z = pcall(_G.GetRealZoneText)
        if ok and type(z) == "string" and not ns.IsSecret(z) and z ~= "" then
            return z
        end
    end
    return "UNKNOWN"
end

local function EnsureStore(createIfMissing)
    local pm = ns.ProfileManager
    if not pm or type(pm.accountDB) ~= "table" then
        return nil
    end
    if createIfMissing and not pm:CanWrite() then
        return nil
    end
    local root = pm.accountDB._diagnostics
    if type(root) ~= "table" then
        if not createIfMissing then
            return nil
        end
        root = {
            schemaVersion = 1,
            taintTotal = 0,
            taintCounts = {},
            taintRecent = {},
            gjUsage = {},
        }
        pm.accountDB._diagnostics = root
    end
    if createIfMissing then
        if type(root.taintCounts) ~= "table" then root.taintCounts = {} end
        if type(root.taintRecent) ~= "table" then root.taintRecent = {} end
        if type(root.gjUsage) ~= "table" then root.gjUsage = {} end
        if type(root.taintTotal) ~= "number" then root.taintTotal = 0 end
    end
    return root
end

function Diagnostics:RecordTaint(kind, addonName, funcName)
    local safeKind = SafeText(kind, "ADDON_ACTION_BLOCKED")
    local safeAddon = SafeText(addonName, "UNKNOWN_ADDON")
    local safeFunc = SafeText(funcName, "UNKNOWN_FUNC")

    if safeKind == "ADDON_ACTION_FORBIDDEN" then
        self.sessionForbidden = self.sessionForbidden + 1
    else
        self.sessionBlocked = self.sessionBlocked + 1
    end

    local store = EnsureStore(true)
    if not store then
        return false
    end

    local key = safeAddon .. ":" .. safeFunc
    store.taintTotal = (store.taintTotal or 0) + 1
    if store.taintCounts[key] ~= nil then
        store.taintCounts[key] = store.taintCounts[key] + 1
    else
        local keyCount = 0
        for _ in pairs(store.taintCounts) do
            keyCount = keyCount + 1
        end
        if keyCount < MAX_TAINT_KEYS then
            store.taintCounts[key] = 1
        end
    end

    table_insert(store.taintRecent, {
        kind = safeKind,
        addon = safeAddon,
        func = safeFunc,
        inCombat = ns.InCombat(),
        zone = SafeZoneName(),
        ts = SafeNowTimestamp(),
        ver = ns.VERSION,
    })
    while #store.taintRecent > MAX_RECENT_TAINT do
        table_remove(store.taintRecent, 1)
    end
    return true
end

function Diagnostics:RecordGJPanelShow(frameName)
    local safeName = SafeText(frameName, "")
    if safeName == "" then
        return false
    end
    local store = EnsureStore(true)
    if not store then
        return false
    end
    local row = store.gjUsage[safeName]
    if type(row) ~= "table" then
        row = { count = 0, lastSeen = 0 }
        store.gjUsage[safeName] = row
    end
    row.count = (row.count or 0) + 1
    row.lastSeen = SafeNowTimestamp()
    return true
end

function Diagnostics:GetSummary()
    local store = EnsureStore(false)
    local totalTaint = (store and store.taintTotal) or 0
    local gjPanels = 0
    if store and type(store.gjUsage) == "table" then
        for _ in pairs(store.gjUsage) do
            gjPanels = gjPanels + 1
        end
    end
    return {
        sessionBlocked = self.sessionBlocked,
        sessionForbidden = self.sessionForbidden,
        totalTaint = totalTaint,
        gjTrackedPanels = gjPanels,
    }
end

function Diagnostics:Reset()
    local store = EnsureStore(true)
    if not store then
        return false
    end
    store.taintTotal = 0
    store.taintCounts = {}
    store.taintRecent = {}
    store.gjUsage = {}
    self.sessionBlocked = 0
    self.sessionForbidden = 0
    return true
end

function Diagnostics:PrintReport()
    local sum = self:GetSummary()
    ns.Print(string_format(
        "진단 카나리 | 세션 Blocked=%d Forbidden=%d | 누적 Taint=%d | 계측된 GJ 패널=%d종",
        sum.sessionBlocked, sum.sessionForbidden, sum.totalTaint, sum.gjTrackedPanels
    ))
    local store = EnsureStore(false)
    if not store then
        return
    end
    local topGJ = {}
    for name, info in pairs(store.gjUsage or {}) do
        if type(info) == "table" and (info.count or 0) > 0 then
            table_insert(topGJ, { name = name, count = info.count })
        end
    end
    table_sort(topGJ, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
    end)
    for i = 1, (#topGJ < 5 and #topGJ or 5) do
        ns.Print(string_format(" - GJ 사용 Top%d: %s (%d회)", i, topGJ[i].name, topGJ[i].count))
    end
end

if ns.EventBus and ns.EventBus.RegisterEvent then
    ns.EventBus:RegisterEvent("__DIAG__", "ADDON_ACTION_BLOCKED", function(_, addonName, funcName)
        Diagnostics:RecordTaint("ADDON_ACTION_BLOCKED", addonName, funcName)
    end)
    ns.EventBus:RegisterEvent("__DIAG__", "ADDON_ACTION_FORBIDDEN", function(_, addonName, funcName)
        Diagnostics:RecordTaint("ADDON_ACTION_FORBIDDEN", addonName, funcName)
    end)
end

if type(_G.SlashCmdList) == "table" then
    _G.SLASH_FOREVERSUITEDIAG1 = "/fsdiag"
    _G.SlashCmdList["FOREVERSUITEDIAG"] = function(msg)
        local cmd = string_lower(string_match(tostring(msg or ""), "^%s*(%S*)") or "")
        if cmd == "reset" then
            if Diagnostics:Reset() then
                ns.Print("진단 카나리 및 GJ 사용 카운터를 초기화했습니다.")
            else
                ns.Warn("읽기 전용 상태에서는 진단 데이터를 초기화할 수 없습니다.")
            end
            return
        end
        Diagnostics:PrintReport()
    end
end
