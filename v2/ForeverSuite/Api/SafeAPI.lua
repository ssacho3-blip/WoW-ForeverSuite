-- Module: Api/SafeAPI.lua
-- Responsibility: Verified WoW Forever 1.60.1 API firewall (C_Secrets guard, fail-closed InCombat, KR empty-realm, NavPort).
-- Layer: Api
local _, ns = ...
ns.Api = ns.Api or {}

local type = type
local pcall = pcall
local tostring = tostring

local UNAVAILABLE = {}

local SafeAPI = {
    UNAVAILABLE = UNAVAILABLE,
}
ns.Api.SafeAPI = SafeAPI

function SafeAPI.IsSecret(val)
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

function SafeAPI.SafeRead(fn, ...)
    if type(fn) ~= "function" then
        return UNAVAILABLE
    end
    local ok, val = pcall(fn, ...)
    if not ok or SafeAPI.IsSecret(val) then
        return UNAVAILABLE
    end
    return val
end

-- Fail-closed combat check: if InCombatLockdown errors or returns a Secret value, assume combat=true.
function SafeAPI.InCombat()
    if type(_G.InCombatLockdown) == "function" then
        local ok, res = pcall(_G.InCombatLockdown)
        if not ok or SafeAPI.IsSecret(res) then
            return true
        end
        return res and true or false
    end
    return false
end

function SafeAPI.GetCanonicalRealm()
    local raw = SafeAPI.SafeRead(_G.GetNormalizedRealmName)
    if raw ~= UNAVAILABLE and type(raw) == "string" and raw ~= "" then
        return raw
    end
    local fb = SafeAPI.SafeRead(_G.GetRealmName)
    if fb ~= UNAVAILABLE and type(fb) == "string" and fb ~= "" then
        return fb
    end
    return "ForeverKR"
end

function SafeAPI.IsWorldMapShown()
    local wmf = _G.WorldMapFrame
    if type(wmf) == "table" and type(wmf.IsShown) == "function" then
        local shown = SafeAPI.SafeRead(wmf.IsShown, wmf)
        if shown == UNAVAILABLE then
            return true
        end
        return shown == true
    end
    return false
end

function SafeAPI.GetSuperTrackedQuestID()
    if C_SuperTrack and type(C_SuperTrack.GetSuperTrackedQuestID) == "function" then
        local v = SafeAPI.SafeRead(C_SuperTrack.GetSuperTrackedQuestID)
        if v ~= UNAVAILABLE and type(v) == "number" then
            return v
        end
    end
    return 0
end

function SafeAPI.IsQuestInLog(questID)
    if type(questID) ~= "number" or questID <= 0 then
        return false
    end
    if C_QuestLog and type(C_QuestLog.GetLogIndexForQuestID) == "function" then
        local idx = SafeAPI.SafeRead(C_QuestLog.GetLogIndexForQuestID, questID)
        return idx ~= UNAVAILABLE and type(idx) == "number" and idx > 0
    end
    return false
end

-- Single global registration entry point for sharded LoadOnDemand data packs (Contract I5).
function _G.ForeverSuite_RegisterPack(packId, schemaVer, meta, shardIdx, totalShards, entries)
    if type(packId) ~= "string" or packId == "" or schemaVer ~= 2 or type(entries) ~= "table" then
        return false, "INVALID_SCHEMA"
    end
    if type(shardIdx) ~= "number" or type(totalShards) ~= "number"
        or shardIdx ~= math.floor(shardIdx) or totalShards ~= math.floor(totalShards)
        or shardIdx < 1 or totalShards < 1 or shardIdx > totalShards
    then
        return false, "INVALID_SHARD"
    end
    local idx = shardIdx
    local tot = totalShards
    _G.ForeverSuiteData = _G.ForeverSuiteData or { version = "2.1.0", packs = {} }
    _G.ForeverSuiteData.packs = _G.ForeverSuiteData.packs or {}
    local pack = _G.ForeverSuiteData.packs[packId]
    if type(pack) ~= "table" or pack._schema ~= 2 then
        local m = type(meta) == "table" and meta or {}
        pack = {
            id = packId,
            _schema = 2,
            title = tostring(m.title or packId),
            category = tostring(m.category or "general"),
            source = tostring(m.source or "ForeverSuite"),
            license = tostring(m.license or "Personal-Local"),
            entries = {},
            _shardsSeen = {},
            _shardCount = 0,
            _totalShards = tot,
            _complete = false,
        }
        _G.ForeverSuiteData.packs[packId] = pack
    elseif pack._totalShards ~= tot then
        return false, "SHARD_MISMATCH"
    end
    if not pack._shardsSeen[idx] then
        pack._shardsSeen[idx] = true
        pack._shardCount = pack._shardCount + 1
        local dst = pack.entries
        for i = 1, #entries do
            dst[#dst + 1] = entries[i]
        end
    end
    pack._complete = (pack._shardCount == pack._totalShards)
    return true, pack._complete and "COMPLETE" or "PARTIAL"
end

-- Loads an optional LoadOnDemand data pack OOC only; returns (ok, 5-state status).
function SafeAPI.LoadDataPack(addonName)
    local target = (type(addonName) == "string" and addonName ~= "") and addonName or "ForeverSuite_Data"
    local presence = SafeAPI.GetAddOnPresenceState(target)
    if presence == "LOADED" then
        return true, "LOADED"
    end
    if presence == "NOT_INSTALLED" then
        return false, "NOT_INSTALLED"
    end
    if SafeAPI.InCombat() then
        return false, "IN_COMBAT"
    end
    if C_AddOns and type(C_AddOns.LoadAddOn) == "function" then
        local ok, loaded, reason = pcall(C_AddOns.LoadAddOn, target)
        if ok and (not SafeAPI.IsSecret(loaded)) and loaded == true then
            return true, "LOADED"
        end
        if ok and (not SafeAPI.IsSecret(reason)) and reason == "DISABLED" then
            return false, "DISABLED"
        end
        return false, "LOAD_FAILED"
    end
    return false, "LOAD_FAILED"
end

-- Returns 4-state presence: "LOADED" | "DISABLED" | "NOT_INSTALLED" | "UNKNOWN"
-- Checks C_AddOns.DoesAddOnExist first so uninstalled addons never trigger errors in C_AddOns.IsAddOnLoaded.
function SafeAPI.GetAddOnPresenceState(name)
    if type(name) ~= "string" or name == "" then
        return "UNKNOWN"
    end
    if C_AddOns and type(C_AddOns.DoesAddOnExist) == "function" then
        local exists = SafeAPI.SafeRead(C_AddOns.DoesAddOnExist, name)
        if exists == false then
            return "NOT_INSTALLED"
        elseif exists == UNAVAILABLE then
            return "UNKNOWN"
        end
    end
    if C_AddOns and type(C_AddOns.IsAddOnLoaded) == "function" then
        local loaded = SafeAPI.SafeRead(C_AddOns.IsAddOnLoaded, name)
        if loaded == UNAVAILABLE or type(loaded) ~= "boolean" then
            return "UNKNOWN"
        end
        return loaded and "LOADED" or "DISABLED"
    end
    return "UNKNOWN"
end

-- Returns tri-state: true (loaded), false (confirmed not loaded or not installed), nil (unreadable/error).
function SafeAPI.GetAddOnLoadedState(name)
    local p = SafeAPI.GetAddOnPresenceState(name)
    if p == "LOADED" then
        return true
    end
    if p == "DISABLED" or p == "NOT_INSTALLED" then
        return false
    end
    return nil
end

function SafeAPI.IsAddOnLoadedByName(name)
    return SafeAPI.GetAddOnLoadedState(name) == true
end

-- Legacy conflict check: only yields if obsolete ForeverSuite_GJBridge or preview ForeverSuiteV2 is loaded.
-- Never detects official ForeverSuite 2.0.0 as a conflict.
function SafeAPI.IsV1Loaded()
    return SafeAPI.GetAddOnLoadedState("ForeverSuite_GJBridge") == true
        or SafeAPI.GetAddOnLoadedState("ForeverSuiteV2") == true
end

function SafeAPI.GetBagFreeSlots()
    if not (C_Container and type(C_Container.GetContainerNumFreeSlots) == "function") then
        return nil
    end
    local total = 0
    local readAny = false
    for bag = 0, 4 do
        local free = SafeAPI.SafeRead(C_Container.GetContainerNumFreeSlots, bag)
        if free == UNAVAILABLE or type(free) ~= "number" then
            return nil
        end
        total = total + free
        readAny = true
    end
    return readAny and total or nil
end

function SafeAPI.GetPlayerMoney()
    if type(_G.GetMoney) ~= "function" then
        return nil
    end
    local m = SafeAPI.SafeRead(_G.GetMoney)
    if m == UNAVAILABLE or type(m) ~= "number" then
        return nil
    end
    return m
end

function SafeAPI.CollectQuestLog()
    if not (C_QuestLog and type(C_QuestLog.GetNumQuestLogEntries) == "function" and type(C_QuestLog.GetInfo) == "function") then
        return {}
    end
    local num = SafeAPI.SafeRead(C_QuestLog.GetNumQuestLogEntries)
    if num == UNAVAILABLE or type(num) ~= "number" or num <= 0 then
        return {}
    end
    local quests = {}
    local curZone = "기타"
    for i = 1, num do
        local info = SafeAPI.SafeRead(C_QuestLog.GetInfo, i)
        if info ~= UNAVAILABLE and type(info) == "table" then
            local isHeader = (not SafeAPI.IsSecret(info.isHeader)) and (info.isHeader == true)
            local isHidden = (not SafeAPI.IsSecret(info.isHidden)) and (info.isHidden == true)
            if isHeader then
                if (not SafeAPI.IsSecret(info.title)) and type(info.title) == "string" and info.title ~= "" then
                    curZone = info.title
                end
            elseif (not isHidden) and (not SafeAPI.IsSecret(info.questID)) and type(info.questID) == "number" and info.questID > 0 then
                local qid = info.questID
                local objs = {}
                if type(C_QuestLog.GetQuestObjectives) == "function" then
                    local rawObjs = SafeAPI.SafeRead(C_QuestLog.GetQuestObjectives, qid)
                    if rawObjs ~= UNAVAILABLE and type(rawObjs) == "table" then
                        for j = 1, #rawObjs do
                            local o = rawObjs[j]
                            if type(o) == "table" and not SafeAPI.IsSecret(o.text) then
                                local fin = (not SafeAPI.IsSecret(o.finished)) and (o.finished == true)
                                objs[#objs + 1] = { text = tostring(o.text or ""), finished = fin }
                            end
                        end
                    end
                end
                local isComplete = false
                if type(C_QuestLog.IsComplete) == "function" then
                    local comp = SafeAPI.SafeRead(C_QuestLog.IsComplete, qid)
                    if comp ~= UNAVAILABLE then
                        isComplete = (comp == true)
                    end
                end
                local isForever = false
                if type(C_QuestLog.GetQuestExpansion) == "function" then
                    local exp = SafeAPI.SafeRead(C_QuestLog.GetQuestExpansion, qid)
                    isForever = (exp ~= UNAVAILABLE and type(exp) == "number" and exp > 0)
                end
                local itemLink, itemIcon = nil, nil
                if type(_G.GetQuestLogSpecialItemInfo) == "function" then
                    local okIt, rawLink, rawIcon = pcall(_G.GetQuestLogSpecialItemInfo, i)
                    if okIt and (not SafeAPI.IsSecret(rawLink)) and type(rawLink) == "string" and rawLink ~= "" then
                        itemLink = rawLink
                        if (not SafeAPI.IsSecret(rawIcon)) and (type(rawIcon) == "number" or type(rawIcon) == "string") then
                            itemIcon = rawIcon
                        end
                    end
                end
                local isWatched = false
                if type(C_QuestLog.GetQuestWatchType) == "function" then
                    local wt = SafeAPI.SafeRead(C_QuestLog.GetQuestWatchType, qid)
                    if wt ~= UNAVAILABLE and wt ~= nil then
                        isWatched = true
                    end
                end
                local isFailed = (not SafeAPI.IsSecret(info.isFailed)) and (info.isFailed == true)
                quests[#quests + 1] = {
                    questID = qid,
                    title = ((not SafeAPI.IsSecret(info.title)) and type(info.title) == "string" and info.title) or ("퀘스트 #" .. tostring(qid)),
                    zone = curZone,
                    level = ((not SafeAPI.IsSecret(info.level)) and type(info.level) == "number") and info.level or 0,
                    isComplete = isComplete,
                    isFailed = isFailed,
                    isWatched = isWatched,
                    isForever = isForever,
                    itemLink = itemLink,
                    itemIcon = itemIcon,
                    objectives = objs,
                }
            end
        end
    end
    return quests
end

function SafeAPI.Print(msg)
    local frame = _G.DEFAULT_CHAT_FRAME
    if type(frame) == "table" and type(frame.AddMessage) == "function" then
        pcall(frame.AddMessage, frame, "|cffd4af37[ForeverSuite]|r " .. tostring(msg or ""))
    end
end

-- NavPort: Single write path for C_SuperTrack & C_Map.SetUserWaypoint.
-- Never calls C_QuestLog.SetSelectedQuest; retains pending state across BOTH InCombat() and WorldMapFrame:IsShown().
-- Tracks exact owned waypoint coordinates and re-verifies against C_Map.GetUserWaypoint() before clearing.
local math_abs = math.abs
local NavPort = {
    pendingSuperTrack = nil,
    pendingWaypoint = nil,
    pendingClearWaypoint = false,
    ownedWaypoint = nil, -- { mapID = number, x = number, y = number }
}
ns.Api.NavPort = NavPort

-- Returns 4-state: "OWNED" | "MISMATCH" | "UNVERIFIABLE" | "UNSUPPORTED"
-- Preserves NavPort.ownedWaypoint on transient "UNVERIFIABLE" so addon pins are not silently orphaned.
local function CheckOwnedWaypointState()
    local owned = NavPort.ownedWaypoint
    if not owned then
        return "MISMATCH"
    end
    if not (C_Map and type(C_Map.GetUserWaypoint) == "function") then
        return "UNSUPPORTED"
    end
    local cur = SafeAPI.SafeRead(C_Map.GetUserWaypoint)
    if cur == UNAVAILABLE then
        return "UNVERIFIABLE"
    end
    if cur == nil then
        NavPort.ownedWaypoint = nil
        return "MISMATCH"
    end
    if type(cur) ~= "table" then
        return "UNVERIFIABLE"
    end
    if SafeAPI.IsSecret(cur.uiMapID) or SafeAPI.IsSecret(cur.position) then
        return "UNVERIFIABLE"
    end
    local curMap = cur.uiMapID
    local curPos = cur.position
    if type(curMap) ~= "number" or type(curPos) ~= "table" then
        return "UNVERIFIABLE"
    end
    if SafeAPI.IsSecret(curPos.x) or SafeAPI.IsSecret(curPos.y) then
        return "UNVERIFIABLE"
    end
    local cx = curPos.x
    local cy = curPos.y
    if type(cx) ~= "number" or type(cy) ~= "number" then
        return "UNVERIFIABLE"
    end
    if curMap ~= owned.mapID or math_abs(cx - owned.x) > 0.0005 or math_abs(cy - owned.y) > 0.0005 then
        NavPort.ownedWaypoint = nil
        return "MISMATCH"
    end
    return "OWNED"
end

local function ApplySuperTrackNow(target)
    if target > 0 and not SafeAPI.IsQuestInLog(target) then
        return false, "NOT_IN_LOG"
    end
    if not (C_SuperTrack and type(C_SuperTrack.SetSuperTrackedQuestID) == "function") then
        return false, "UNSUPPORTED"
    end
    local ok = pcall(C_SuperTrack.SetSuperTrackedQuestID, target)
    return ok and true or false, ok and "APPLIED" or "FAILED"
end

local function ApplyWaypointNow(wp)
    if not (C_Map and type(C_Map.SetUserWaypoint) == "function") then
        return false, "UNSUPPORTED"
    end
    if type(C_Map.CanSetUserWaypointOnMap) == "function" then
        local canSet = SafeAPI.SafeRead(C_Map.CanSetUserWaypointOnMap, wp.mapID)
        if canSet ~= true then
            return false, "MAP_NOT_SUPPORTED"
        end
    end
    local ok = pcall(C_Map.SetUserWaypoint, { uiMapID = wp.mapID, position = { x = wp.x, y = wp.y } })
    if ok then
        NavPort.ownedWaypoint = { mapID = wp.mapID, x = wp.x, y = wp.y }
        NavPort.pendingClearWaypoint = false
        if C_SuperTrack and type(C_SuperTrack.SetSuperTrackedUserWaypoint) == "function" then
            pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
        end
    end
    return ok and true or false, ok and "APPLIED" or "FAILED"
end

local function ApplyClearWaypointNow()
    local state = CheckOwnedWaypointState()
    if state == "UNSUPPORTED" then
        return false, "UNSUPPORTED"
    end
    if state == "UNVERIFIABLE" then
        return false, "UNVERIFIABLE"
    end
    if state ~= "OWNED" then
        NavPort.ownedWaypoint = nil
        return true, "NOT_OWNED"
    end
    if not (C_Map and type(C_Map.ClearUserWaypoint) == "function") then
        NavPort.ownedWaypoint = nil
        return false, "UNSUPPORTED"
    end
    local ok = pcall(C_Map.ClearUserWaypoint)
    if ok then
        NavPort.ownedWaypoint = nil
    end
    return ok and true or false, ok and "CLEARED" or "FAILED"
end

function NavPort.RequestSuperTrack(questID)
    if not (C_SuperTrack and type(C_SuperTrack.SetSuperTrackedQuestID) == "function") then
        return false, "UNSUPPORTED"
    end
    local qid = (type(questID) == "number" and questID > 0) and questID or 0
    if SafeAPI.InCombat() or SafeAPI.IsWorldMapShown() then
        NavPort.pendingSuperTrack = qid
        return false, "DEFERRED"
    end
    NavPort.pendingSuperTrack = nil
    return ApplySuperTrackNow(qid)
end

function NavPort.SetWaypoint(mapID, x, y)
    if not (C_Map and type(C_Map.SetUserWaypoint) == "function") then
        return false, "UNSUPPORTED"
    end
    local wp = { mapID = mapID, x = x, y = y }
    if SafeAPI.InCombat() or SafeAPI.IsWorldMapShown() then
        NavPort.pendingWaypoint = wp
        return false, "DEFERRED"
    end
    NavPort.pendingWaypoint = nil
    return ApplyWaypointNow(wp)
end

function NavPort.ClearWaypoint()
    NavPort.pendingWaypoint = nil
    if not NavPort.ownedWaypoint then
        NavPort.pendingClearWaypoint = false
        return true, "NOT_OWNED"
    end
    if SafeAPI.InCombat() or SafeAPI.IsWorldMapShown() then
        NavPort.pendingClearWaypoint = true
        return false, "DEFERRED"
    end
    NavPort.pendingClearWaypoint = false
    local ok, reason = ApplyClearWaypointNow()
    if (not ok) and reason ~= "UNSUPPORTED" then
        NavPort.pendingClearWaypoint = true
    end
    return ok, reason
end

function NavPort.FlushIfSafe()
    if SafeAPI.InCombat() or SafeAPI.IsWorldMapShown() then
        return false
    end
    local flushedAny = false
    if NavPort.pendingSuperTrack ~= nil then
        local target = NavPort.pendingSuperTrack
        NavPort.pendingSuperTrack = nil
        local ok = ApplySuperTrackNow(target)
        if ok then flushedAny = true end
    end
    if NavPort.pendingClearWaypoint then
        local ok, reason = ApplyClearWaypointNow()
        if ok or reason == "UNSUPPORTED" then
            NavPort.pendingClearWaypoint = false
            if ok then flushedAny = true end
        end
    end
    if NavPort.pendingWaypoint ~= nil then
        local wp = NavPort.pendingWaypoint
        NavPort.pendingWaypoint = nil
        local ok = ApplyWaypointNow(wp)
        if ok then flushedAny = true end
    end
    return flushedAny
end
