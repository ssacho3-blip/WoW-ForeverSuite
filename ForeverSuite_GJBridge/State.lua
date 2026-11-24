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
ns.VERSION = "0.5.4"
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
local hookedEditModeFrames = NewWeakKeyTable()
local editModeRegistryHooked = false
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
    tooltipItemLevel = "OWNED_BY_FS",
    way = "OWNED_BY_FS",
}
ns.externalCoexistence = {
    auction = "OWNED_BY_GJ",
    nameplates = "OWNED_BY_GJ",
    inventoryTooltips = "OWNED_BY_GJ",
    questDialog = "OWNED_BY_GJ",
    questTracker = "OWNED_BY_GJ",
    baganatorBadges = "UNAVAILABLE",
}
ns._pendingNameplateRefresh = false
ns._pendingThreatRefresh = false
ns._pendingHighlightRefresh = false
ns._pendingQuestTrackerRefresh = false
ns._pendingIdentityIconRefresh = false
ns._baganatorWidgetsRegistered = false

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

local function CreateBaganatorBadgeText(itemButton)
    local text = itemButton:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    local C = _G.GJCompanion
    local fontPath = (type(C) == "table" and type(C.UIFontPath) == "string" and C.UIFontPath ~= "" and C.UIFontPath)
        or _G.STANDARD_TEXT_FONT
    if type(fontPath) == "string" and fontPath ~= "" and type(text.SetFont) == "function" then
        pcall(text.SetFont, text, fontPath, 11, "OUTLINE")
    end
    text.sizeFont = true
    return text
end

local function ResolveMaterialColor(C, kind)
    if type(C.BagMaterialSettings) == "function" then
        local okCfg, cfg = pcall(C.BagMaterialSettings)
        if okCfg and type(cfg) == "table" and type(cfg.reagentColors) == "table" and type(cfg.reagentColors[kind]) == "table" then
            local col = cfg.reagentColors[kind]
            if type(col[1]) == "number" and type(col[2]) == "number" and type(col[3]) == "number" then
                return col[1], col[2], col[3]
            end
        end
    end
    if type(C.ProfessionMaterialGroups) == "table" and type(C.ProfessionMaterialGroups[kind]) == "table" then
        local col = C.ProfessionMaterialGroups[kind][2]
        if type(col) == "table" and type(col[1]) == "number" and type(col[2]) == "number" and type(col[3]) == "number" then
            return col[1], col[2], col[3]
        end
    end
    return 1, 0.86, 0.4
end

local function IsSecretBridgeValue(val)
    local fn = _G.issecretvalue
    if type(fn) ~= "function" then
        return false
    end
    local ok, res = pcall(fn, val)
    if not ok then
        return true
    end
    return res == true
end
ns._IsSecretBridgeValue = IsSecretBridgeValue

local function UpdateBaganatorMaterialCorner(labelObj, details)
    local C = _G.GJCompanion
    if type(C) ~= "table" or type(C.BagMaterialMatch) ~= "function" then
        return false
    end
    if IsSecretBridgeValue(details) or type(details) ~= "table" then
        return false
    end
    local itemID = details.itemID
    if IsSecretBridgeValue(itemID) or type(itemID) ~= "number" or itemID <= 0 then
        return false
    end
    local ok, matches, kind, label = pcall(C.BagMaterialMatch, itemID)
    if not ok or not matches or type(label) ~= "string" or label == "" then
        return false
    end
    local r, g, b = ResolveMaterialColor(C, kind)
    labelObj:SetText(label)
    labelObj:SetTextColor(r, g, b)
    return true
end

local function UpdateBaganatorBadgeCorner(labelObj, details)
    if IsSecretBridgeValue(details) or type(details) ~= "table" then
        return false
    end
    local itemID = details.itemID
    if IsSecretBridgeValue(itemID) or type(itemID) ~= "number" or itemID <= 0 then
        return false
    end
    local caption, r, g, b = nil, 1, 1, 1

    local FS = _G.ForeverSuite
    if type(FS) == "table" and type(FS.ProfileManager) == "table" and type(FS.ProfileManager.IsProtectedItem) == "function" then
        local okProt, isProt = pcall(FS.ProfileManager.IsProtectedItem, FS.ProfileManager, itemID)
        if okProt and isProt == true then
            caption, r, g, b = "보호", 0.38, 0.85, 1.0
        end
    end

    local C = _G.GJCompanion
    if not caption and type(C) == "table" then
        if type(C.DarkmoonGoods) == "table" and C.DarkmoonGoods[itemID] then
            caption, r, g, b = "다크문", 1, 0.55, 1
        elseif type(C.BagReputationItem) == "function" then
            local okRep, isRep = pcall(C.BagReputationItem, itemID)
            if okRep and isRep then
                caption, r, g, b = "평판", 1, 0.79, 0.32
            end
        end
        if not caption and type(C.BagLibraryBookInfo471) == "function" then
            local okBook, book = pcall(C.BagLibraryBookInfo471, itemID)
            if okBook and book then
                caption, r, g, b = "책", 1, 0.82, 0.25
            end
        end
        if not caption and type(C.BagBuffItem) == "function" then
            local link = IsSecretBridgeValue(details.itemLink) and nil or details.itemLink
            local okBuff, isBuff = pcall(C.BagBuffItem, itemID, link)
            if okBuff and isBuff then
                caption, r, g, b = "버프", 0.74, 0.65, 1
            end
        end
    end
    if not caption then
        return false
    end
    labelObj:SetText(caption)
    labelObj:SetTextColor(r, g, b)
    return true
end

function ns.RegisterBaganatorWidgets()
    if ns._baganatorWidgetsRegistered then
        ns.externalCoexistence.baganatorBadges = "REGISTERED"
        return true
    end
    local bagApi = type(_G.Baganator) == "table" and _G.Baganator.API or nil
    if type(bagApi) ~= "table" or type(bagApi.RegisterCornerWidget) ~= "function" then
        ns.externalCoexistence.baganatorBadges = "UNAVAILABLE"
        return false
    end
    local okMat = pcall(
        bagApi.RegisterCornerWidget,
        "갓존슨 재료 (요리·약초·가죽)",
        "fsgj_material",
        UpdateBaganatorMaterialCorner,
        CreateBaganatorBadgeText,
        { corner = "bottom_left", priority = 1 },
        true
    )
    local okBadge = pcall(
        bagApi.RegisterCornerWidget,
        "갓존슨·보호 배지 (보호·버프·평판·다크문·책)",
        "fsgj_badge",
        UpdateBaganatorBadgeCorner,
        CreateBaganatorBadgeText,
        { corner = "top_right", priority = 1 },
        true
    )
    if okMat or okBadge then
        ns._baganatorWidgetsRegistered = true
        ns.externalCoexistence.baganatorBadges = "REGISTERED"
        return true
    end
    ns.externalCoexistence.baganatorBadges = "FAILED"
    return false
end

local function IsQuestTrackerPreLoginIntended(FS)
    if type(FS.ModuleManager) ~= "table" or type(FS.ModuleManager.GetModule) ~= "function" then
        return false
    end
    local okMod, qMod = pcall(FS.ModuleManager.GetModule, FS.ModuleManager, "Quest")
    if not okMod or type(qMod) ~= "table" or qMod.state ~= "REGISTERED" then
        return false
    end
    if type(FS.IsExternalAddonLoaded) ~= "function" then
        return false
    end
    for _, ext in ipairs({ "Questie", "!KalielsTracker", "KalielsTracker" }) do
        local okExt, loaded = pcall(FS.IsExternalAddonLoaded, ext)
        if not okExt or IsSecretBridgeValue(loaded) or loaded ~= false then
            return false
        end
    end
    local db = _G.ForeverSuiteDB
    local acct = type(db) == "table" and type(db.account) == "table" and db.account or nil
    if type(acct) == "table" then
        local qModCfg = type(acct.modules) == "table" and type(acct.modules.Quest) == "table" and acct.modules.Quest or nil
        if type(qModCfg) == "table" and qModCfg.enabled == false then
            return false
        end
        local qCfg = type(acct.quest) == "table" and acct.quest or nil
        if type(qCfg) == "table" and (qCfg.trackerEnabled == false or qCfg.hideDefaultTracker == false) then
            return false
        end
    end
    return true
end

function ns._IsForeverSuiteQuestTrackerActive()
    local FS = _G.ForeverSuite
    if type(FS) ~= "table" or type(FS.ProfileManager) ~= "table" or type(FS.ProfileManager.Get) ~= "function" then
        return false
    end
    if type(FS.IsFeatureYielded) == "function" then
        local okYield, yielded = pcall(FS.IsFeatureYielded, "questTrackerHud")
        if okYield and yielded == true then
            return false
        end
    end
    if type(FS.QuestTracker) == "table" and FS.QuestTracker.active == true then
        local okEn, enabled = pcall(FS.ProfileManager.Get, FS.ProfileManager, "quest", "trackerEnabled")
        local okHide, hideDef = pcall(FS.ProfileManager.Get, FS.ProfileManager, "quest", "hideDefaultTracker")
        return okEn and enabled == true and okHide and hideDef == true
    end
    return IsQuestTrackerPreLoginIntended(FS)
end

function ns._IsEditModeActiveSafe()
    local em = _G.EditModeManagerFrame
    if em == nil then
        return false
    end
    if IsSecretBridgeValue(em) or type(em) ~= "table" then
        return true
    end
    if type(em.IsEditModeActive) == "function" then
        local ok, active = pcall(em.IsEditModeActive, em)
        -- Blizzard leaves editModeActive nil until the first visit to Edit Mode.
        if not ok or IsSecretBridgeValue(active) or (active ~= nil and (type(active) ~= "boolean" or active == true)) then
            return true
        end
    end
    local okProp, propVal = pcall(function()
        return em.editModeActive
    end)
    if not okProp or IsSecretBridgeValue(propVal) or (propVal ~= nil and (type(propVal) ~= "boolean" or propVal == true)) then
        return true
    end
    return false
end

function ns._EnsureEditModeExitHook(flushFn)
    if type(flushFn) ~= "function" then
        return
    end
    local function ScheduleDeferredFlush()
        if not ns._IsEditModeActiveSafe() then
            flushFn()
        elseif type(_G.C_Timer) == "table" and type(_G.C_Timer.After) == "function" then
            pcall(_G.C_Timer.After, 0, flushFn)
        end
    end
    local reg = _G.EventRegistry
    if not editModeRegistryHooked and not IsSecretBridgeValue(reg) and type(reg) == "table" and type(reg.RegisterCallback) == "function" then
        local okReg = pcall(reg.RegisterCallback, reg, "EditMode.Exit", ScheduleDeferredFlush, ns)
        if okReg then
            editModeRegistryHooked = true
        end
    end
    local em = _G.EditModeManagerFrame
    if not IsSecretBridgeValue(em) and type(em) == "table" and not hookedEditModeFrames[em] and type(em.HookScript) == "function" then
        local okHook = pcall(em.HookScript, em, "OnHide", ScheduleDeferredFlush)
        if okHook then
            hookedEditModeFrames[em] = true
        end
    end
end

function ns._ApplyGJQuestTrackerYield(C, retryAttempt)
    if type(C) ~= "table" then
        return false
    end
    local inCombat = type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown() == true
    if inCombat or ns._IsEditModeActiveSafe() then
        ns._pendingQuestTrackerRefresh = true
        ns._EnsureEditModeExitHook(function()
            if ns._pendingQuestTrackerRefresh then
                ns._ApplyGJQuestTrackerYield(_G.GJCompanion, 0)
            end
        end)
        return false
    end
    if type(C.RefreshQuestTrackerSelection300) == "function" then
        pcall(C.RefreshQuestTrackerSelection300)
    elseif type(C.SetOwnedQuestTrackerActive302) == "function" then
        pcall(C.SetOwnedQuestTrackerActive302, false)
    end
    local stillEnabled = false
    if type(C.GodJohnsonTrackerEnabled299) == "function" then
        local okEn, en = pcall(C.GodJohnsonTrackerEnabled299)
        stillEnabled = okEn and en == true
    end
    if stillEnabled then
        ns._pendingQuestTrackerRefresh = true
        local attempt = tonumber(retryAttempt) or 0
        if attempt < 3 and type(_G.C_Timer) == "table" and type(_G.C_Timer.After) == "function" then
            pcall(_G.C_Timer.After, 0.15, function()
                if ns._pendingQuestTrackerRefresh then
                    ns._ApplyGJQuestTrackerYield(_G.GJCompanion, attempt + 1)
                end
            end)
        end
        return false
    end
    ns._pendingQuestTrackerRefresh = false
    local FS = _G.ForeverSuite
    if type(FS) == "table" and type(FS.QuestTracker) == "table" and type(FS.QuestTracker.SyncDefaultTrackerVisibility) == "function" then
        pcall(FS.QuestTracker.SyncDefaultTrackerVisibility, FS.QuestTracker)
    end
    return true
end

function ns._ResolveGJQuestTrackerStatus(C)
    if type(C) ~= "table" then
        return "UNAVAILABLE"
    end
    if type(C.GodJohnsonTrackerEnabled299) == "function" then
        local okEn, en = pcall(C.GodJohnsonTrackerEnabled299)
        if okEn and type(en) == "boolean" then
            return en and "OWNED_BY_GJ" or "NATIVE_TRACKER"
        end
    end
    if type(C.QuestRegionSettings248) == "function" then
        local okQrs, qrs = pcall(C.QuestRegionSettings248)
        if okQrs and type(qrs) == "table" then
            return (qrs.useNativeTracker299 == true) and "NATIVE_TRACKER" or "OWNED_BY_GJ"
        end
    end
    return "UNKNOWN"
end
