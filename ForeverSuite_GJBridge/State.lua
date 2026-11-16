local ADDON_NAME, ns = ...

ns = ns or {}
_G.ForeverSuite_GJBridge = ns

local type = type
local tonumber = tonumber
local tostring = tostring
local pcall = pcall
local select = select
local setmetatable = setmetatable

ns.ADDON_NAME = ADDON_NAME or "ForeverSuite_GJBridge"
ns.VERSION = "0.3.2"
ns.PERSONAL_ICON_ID = 134063
ns.PERSONAL_PREFIX = "|cffffd36a[포에버]:|r "
ns.CLEAN_QUEST_ALARM_SOUND = "dingdong"
ns.GJ_PREFIX_TAG = "[갓존슨]"
ns.FS_PREFIX_TAG = "[포에버]"

local MAX_SUPPORTED_FS_SCHEMA = 2

local function NewWeakKeyTable()
    if type(setmetatable) == "function" then
        return setmetatable({}, { __mode = "k" })
    end
    return {}
end

local wrappedTargets = NewWeakKeyTable()
local ephemeralTradeSeeded = NewWeakKeyTable()
local ephemeralStarterSeeded = NewWeakKeyTable()
local pendingTradePromote = false
local pendingStarterPromote = false

ns._wrappedTargets = wrappedTargets

ns.status = "UNINITIALIZED"
ns.targets = {
    sayPrefix = "MISSING",
    youtubeLink = "MISSING",
    homeScreen = "MISSING",
    launcherIcon = "MISSING",
    tradeWhisper = "MISSING",
    questSound = "MISSING",
}
ns.ownership = {
    repair = "OWNED_BY_FS",
    sell = "OWNED_BY_FS",
    questAutoAccept = "OWNED_BY_FS",
    questAutoTurnIn = "OWNED_BY_FS",
    fishing = "OWNED_BY_FS",
    way = "OWNED_BY_FS",
}

local function PrintBridge(msg)
    local text = "|cffd4af37[FS-GJBridge]|r " .. tostring(msg or "")
    if _G.DEFAULT_CHAT_FRAME and _G.DEFAULT_CHAT_FRAME.AddMessage then
        _G.DEFAULT_CHAT_FRAME:AddMessage(text)
    end
end
ns.Print = PrintBridge

function ns._PackCallResults(ok, ...)
    return ok, select("#", ...), { ... }
end

function ns._UnpackResults(list, count, idx)
    idx = idx or 1
    if idx > count then
        return
    end
    return list[idx], ns._UnpackResults(list, count, idx + 1)
end

function ns._IsForeverSuiteReadOnly()
    local FS = _G.ForeverSuite
    if type(FS) == "table" and type(FS.ProfileManager) == "table" and FS.ProfileManager.readOnly then
        return true
    end
    local fsdb = _G.ForeverSuiteDB
    if fsdb ~= nil and type(fsdb) ~= "table" then
        return true
    end
    if type(fsdb) == "table" then
        local ver = tonumber(fsdb.schemaVersion)
        if ver ~= nil and ver > MAX_SUPPORTED_FS_SCHEMA then
            return true
        end
    end
    return false
end

function ns._ReadBridgeSeedFlags()
    local fsdb = _G.ForeverSuiteDB
    if type(fsdb) == "table" and type(fsdb.gjBridge) == "table" then
        return fsdb.gjBridge.tradeNotifySeeded == true, fsdb.gjBridge.starterLootSeeded == true
    end
    return false, false
end

function ns._GetBridgeStore(allowStandaloneCreate)
    if ns._IsForeverSuiteReadOnly() then
        return nil
    end
    local fsdb = _G.ForeverSuiteDB
    if type(fsdb) ~= "table" then
        if not allowStandaloneCreate or fsdb ~= nil then
            return nil
        end
        _G.ForeverSuiteDB = {
            schemaVersion = MAX_SUPPORTED_FS_SCHEMA,
            account = {},
            gjBridge = {},
        }
        fsdb = _G.ForeverSuiteDB
    else
        local ver = tonumber(fsdb.schemaVersion)
        if ver == nil and fsdb.account == nil and not allowStandaloneCreate then
            return nil
        end
    end
    if type(fsdb.gjBridge) ~= "table" then
        fsdb.gjBridge = {}
    end
    local store = fsdb.gjBridge
    if pendingTradePromote and not store.tradeNotifySeeded then
        store.tradeNotifySeeded = true
        pendingTradePromote = false
    end
    if pendingStarterPromote and not store.starterLootSeeded then
        store.starterLootSeeded = true
        pendingStarterPromote = false
    end
    return store
end

function ns._RecordTradeSeeded(targetTable, store)
    if store then
        store.tradeNotifySeeded = true
    elseif not ns._IsForeverSuiteReadOnly() then
        ephemeralTradeSeeded[targetTable] = true
        pendingTradePromote = true
    end
end

function ns._RecordStarterSeeded(targetTable, store)
    if store then
        store.starterLootSeeded = true
    elseif not ns._IsForeverSuiteReadOnly() then
        ephemeralStarterSeeded[targetTable] = true
        pendingStarterPromote = true
    end
end

function ns._IsStarterSeededOrPending(store)
    local _, savedStarterSeeded = ns._ReadBridgeSeedFlags()
    return savedStarterSeeded or (store and store.starterLootSeeded) or pendingStarterPromote or ns._IsForeverSuiteReadOnly()
end

function ns._ReconcileTradeConfigTable(d, store)
    if type(d) ~= "table" or ns._IsForeverSuiteReadOnly() then
        return
    end
    local savedTradeSeeded = ns._ReadBridgeSeedFlags()
    if d._fsgjUserInitialized ~= nil then
        if store then
            store.tradeNotifySeeded = true
        else
            ephemeralTradeSeeded[d] = true
            pendingTradePromote = true
        end
        d._fsgjUserInitialized = nil
        return
    end
    if savedTradeSeeded or (store and store.tradeNotifySeeded) then
        return
    end
    if store then
        store.tradeNotifySeeded = true
        d.notify = false
    elseif not ephemeralTradeSeeded[d] then
        ephemeralTradeSeeded[d] = true
        pendingTradePromote = true
        d.notify = false
    end
end

function ns._ReconcileStarterLootDefault(C, store)
    if type(C) ~= "table" or type(C.ExtraSettings) ~= "function" or ns._IsForeverSuiteReadOnly() then
        return
    end
    local _, savedStarterSeeded = ns._ReadBridgeSeedFlags()
    if savedStarterSeeded or (store and store.starterLootSeeded) then
        return
    end
    local okQa, qa = pcall(C.ExtraSettings, "questAnnounce")
    if not okQa or type(qa) ~= "table" then
        return
    end
    if store then
        store.starterLootSeeded = true
        qa.starterLoot = false
    elseif not ephemeralStarterSeeded[qa] then
        ephemeralStarterSeeded[qa] = true
        pendingStarterPromote = true
        qa.starterLoot = false
    end
end
