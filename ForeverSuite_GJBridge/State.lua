local ADDON_NAME, ns = ...

ns = ns or {}
_G.ForeverSuite_GJBridge = ns

local type = type
local tonumber = tonumber
local tostring = tostring
local pcall = pcall
local select = select
local setmetatable = setmetatable
local math_abs = math.abs

ns.ADDON_NAME = ADDON_NAME or "ForeverSuite_GJBridge"
ns.VERSION = "0.3.9"
ns.PERSONAL_ICON_ID = 134063
ns.PERSONAL_PREFIX = "|cffffd36a[포에버]:|r "
ns.CLEAN_QUEST_ALARM_SOUND = "dingdong"
ns.GJ_PREFIX_TAG = "[갓존슨]"
ns.FS_PREFIX_TAG = "[포에버]"
ns.NAV_ARROW_DEFAULT_X = 0.5
ns.NAV_ARROW_DEFAULT_Y = 0.74
ns.RANGE_DEFAULT_X = 0.5
ns.RANGE_DEFAULT_Y = 0.36

local GJ_FACTORY_NAV_X = 0.5
local GJ_FACTORY_NAV_Y = 0.417
local GJ_FACTORY_RANGE_X = 0.5
local GJ_FACTORY_RANGE_Y = 0.42
local OVERLAP_X_THRESHOLD = 0.16
local OVERLAP_Y_THRESHOLD = 0.14
local NAV_HIGH_Y_MIN = 0.58

local FALLBACK_MAX_SUPPORTED_FS_SCHEMA = 2

local function ResolveSupportedFsSchema()
    local FS = _G.ForeverSuite
    if type(FS) == "table" and type(FS.ProfileManager) == "table" then
        local schema = tonumber(FS.ProfileManager.SCHEMA_VERSION)
        if schema ~= nil then
            return schema
        end
    end
    return FALLBACK_MAX_SUPPORTED_FS_SCHEMA
end

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
local pendingLayoutPromote = false

ns._wrappedTargets = wrappedTargets

ns.status = "UNINITIALIZED"
ns.targets = {
    sayPrefix = "MISSING",
    youtubeLink = "MISSING",
    homeScreen = "MISSING",
    launcherIcon = "MISSING",
    tradeWhisper = "MISSING",
    questSound = "MISSING",
    navRangeLayout = "PENDING",
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
        if ver ~= nil and ver > ResolveSupportedFsSchema() then
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
            schemaVersion = ResolveSupportedFsSchema(),
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
    if pendingLayoutPromote and not store.navRangeLayoutSeeded then
        store.navRangeLayoutSeeded = true
        pendingLayoutPromote = false
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

function ns._AreNavAndRangeOverlapping(navPos, rangePos)
    local navX = (type(navPos) == "table" and tonumber(navPos.x)) or GJ_FACTORY_NAV_X
    local navY = (type(navPos) == "table" and tonumber(navPos.y)) or GJ_FACTORY_NAV_Y
    local rngX = (type(rangePos) == "table" and tonumber(rangePos.x)) or GJ_FACTORY_RANGE_X
    local rngY = (type(rangePos) == "table" and tonumber(rangePos.y)) or GJ_FACTORY_RANGE_Y
    return math_abs(navX - rngX) < OVERLAP_X_THRESHOLD and math_abs(navY - rngY) < OVERLAP_Y_THRESHOLD
end

local function ApplyLiveNavRangeRefresh(C, forceCommit)
    local guide = _G.GodJohnsonFrontGuide
    if type(guide) == "table" and type(guide.RestorePosition) == "function" then
        pcall(guide.RestorePosition, guide)
    end
    if type(C.RefreshRangeDisplay) == "function" then
        pcall(C.RefreshRangeDisplay)
    end
    if forceCommit and type(C.CommitSettings) == "function" then
        pcall(C.CommitSettings)
    end
end

function ns._ResetNavRangeLayoutSeed(store)
    pendingLayoutPromote = false
    ns.targets.navRangeLayout = "PENDING"
    if type(store) == "table" then
        store.navRangeLayoutSeeded = false
    end
end

function ns._ReconcileNavRangeLayout(C, store, forceReset)
    if type(C) ~= "table" or ns._IsForeverSuiteReadOnly() then
        return false
    end
    if type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown() == true then
        return false
    end
    local fsdb = _G.ForeverSuiteDB
    local savedSeeded = type(fsdb) == "table" and type(fsdb.gjBridge) == "table" and fsdb.gjBridge.navRangeLayoutSeeded == true
    if not forceReset and (savedSeeded or (store and store.navRangeLayoutSeeded) or pendingLayoutPromote) then
        ns.targets.navRangeLayout = "APPLIED"
        return false
    end

    local nav = nil
    if type(C.NavigationSettings) == "function" then
        local okNav, navTbl = pcall(C.NavigationSettings)
        if okNav and type(navTbl) == "table" then
            nav = navTbl
        end
    end
    local rd = nil
    if type(C.ExtraSettings) == "function" then
        local okRd, rdTbl = pcall(C.ExtraSettings, "rangeDisplay")
        if okRd and type(rdTbl) == "table" and (rdTbl.x ~= nil or rdTbl.y ~= nil or rdTbl.enabled ~= nil) then
            rd = rdTbl
        end
    end
    if type(nav) ~= "table" and type(rd) ~= "table" then
        return false
    end

    local changed = false
    if forceReset then
        if type(nav) == "table" then
            nav.arrowPosition = { x = ns.NAV_ARROW_DEFAULT_X, y = ns.NAV_ARROW_DEFAULT_Y }
            changed = true
        end
        if type(rd) == "table" then
            rd.x = ns.RANGE_DEFAULT_X
            rd.y = ns.RANGE_DEFAULT_Y
            changed = true
        end
    else
        local navPos = type(nav) == "table" and nav.arrowPosition or nil
        local overlapping = ns._AreNavAndRangeOverlapping(navPos, rd)
        if type(nav) == "table" and (navPos == nil or (overlapping and ((tonumber(navPos.y) or GJ_FACTORY_NAV_Y) < NAV_HIGH_Y_MIN))) then
            nav.arrowPosition = { x = ns.NAV_ARROW_DEFAULT_X, y = ns.NAV_ARROW_DEFAULT_Y }
            changed = true
        end
        local postNavPos = type(nav) == "table" and nav.arrowPosition or nil
        if type(rd) == "table" and ns._AreNavAndRangeOverlapping(postNavPos, rd) then
            rd.x = tonumber(rd.x) or ns.RANGE_DEFAULT_X
            rd.y = ns.RANGE_DEFAULT_Y
            changed = true
        end
    end

    if store then
        store.navRangeLayoutSeeded = true
    else
        pendingLayoutPromote = true
    end
    ns.targets.navRangeLayout = "APPLIED"
    if changed then
        ApplyLiveNavRangeRefresh(C, forceReset == true)
    end
    return changed
end
