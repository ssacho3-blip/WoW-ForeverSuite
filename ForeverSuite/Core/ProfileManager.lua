local _, ns = ...

local type = type
local pairs = pairs
local tostring = tostring
local tonumber = tonumber

local CURRENT_SCHEMA_VERSION = 2

local DEFAULT_ACCOUNT_SETTINGS = {
    modules = {
        Utility = { enabled = true },
        Inventory = { enabled = true },
        Map = { enabled = true },
        Quest = { enabled = true },
        Profession = { enabled = true },
        Economy = { enabled = true },
        Combat = { enabled = true },
    },
    utility = {
        autoRepair = true,
        useGuildRepair = true,
        autoSellJunk = true,
        maxSellBatch = 12,
        fastAutoLoot = true,
        applyQoLCVars = true,
        extraActionBars = true,
        extraActionBarMode = "STANDARD",
        protectedItems = {},
    },
    inventory = {
        showFreeSlotsHUD = true,
        showTooltipVendorPrice = true,
        showTooltipItemLevel = true,
    },
    map = {
        showCoordsOnWorldMap = true,
        enableWaySlash = true,
    },
    quest = {
        autoAccept = true,
        autoTurnIn = true,
        autoSuperTrack = true,
    },
    profession = {
        doubleClickFishing = true,
        fishingSoundBoost = true,
        trackGatherYield = true,
        remindMissingTracking = true,
    },
    economy = {
        trackSessionGold = true,
        showAuctionatorPrice = true,
    },
    combat = {
        remindMissingClassBuff = true,
        lowHealthAlert = true,
        lowHealthThreshold = 0.30,
    },
}

local function DeepCopy(src)
    if type(src) ~= "table" then
        return src
    end
    local copy = {}
    for k, v in pairs(src) do
        copy[DeepCopy(k)] = DeepCopy(v)
    end
    return copy
end

local function FillDefaults(target, defaults)
    if type(target) ~= "table" or type(defaults) ~= "table" then
        return target
    end
    for k, dv in pairs(defaults) do
        local tv = target[k]
        if tv == nil then
            target[k] = DeepCopy(dv)
        elseif type(tv) == "table" and type(dv) == "table" then
            FillDefaults(tv, dv)
        end
    end
    return target
end

local ProfileManager = {
    SCHEMA_VERSION = CURRENT_SCHEMA_VERSION,
    accountDB = nil,
    charDB = nil,
    runtimeAccount = nil,
    runtimeChar = nil,
    readOnly = false,
    corruptedRecovered = false,
    playerClass = "UNKNOWN",
    playerKey = "Unknown-Realm",
    changeListeners = {},
}
ns.ProfileManager = ProfileManager

function ProfileManager:OnSettingChanged(listener)
    if type(listener) == "function" then
        self.changeListeners[#self.changeListeners + 1] = listener
    end
end

function ProfileManager:NotifySettingChanged(section, key, value, scope)
    for i = 1, #self.changeListeners do
        local fn = self.changeListeners[i]
        if fn then
            pcall(fn, section, key, value, scope)
        end
    end
end

function ProfileManager:DetectPlayerIdentity()
    local name = "Player"
    local realm = "Forever"
    local classTag = "UNKNOWN"
    if _G.UnitName then
        local n = _G.UnitName("player")
        if type(n) == "string" and n ~= "" then
            name = n
        end
    end
    if _G.GetRealmName then
        local r = _G.GetRealmName()
        if type(r) == "string" and r ~= "" then
            realm = r
        end
    end
    if _G.UnitClass then
        local _, engClass = _G.UnitClass("player")
        if type(engClass) == "string" and engClass ~= "" then
            classTag = engClass
        end
    end
    self.playerClass = classTag
    self.playerKey = name .. "-" .. realm
end

local function MigrateV1ToV2(db)
    db._backup = db._backup or {}
    if not db._backup[1] then
        local snap = DeepCopy(db)
        snap._backup = nil
        db._backup[1] = snap
    end
    db.account = type(db.account) == "table" and db.account or {}
    if type(db.settings) == "table" then
        FillDefaults(db.account, db.settings)
        db.settings = nil
    end
    if type(db.modules) == "table" then
        db.account.modules = type(db.account.modules) == "table" and db.account.modules or {}
        FillDefaults(db.account.modules, db.modules)
        db.modules = nil
    end
    db.classes = type(db.classes) == "table" and db.classes or {}
    db.pendingCVarRestores = type(db.pendingCVarRestores) == "table" and db.pendingCVarRestores or {}
    db.schemaVersion = 2
end

function ProfileManager:Init()
    self:DetectPlayerIdentity()
    self.readOnly = false
    self.corruptedRecovered = false

    local rawAcct = _G.ForeverSuiteDB
    if rawAcct ~= nil and type(rawAcct) ~= "table" then
        self.corruptedRecovered = true
        rawAcct = {
            _corruptedBackup = tostring(rawAcct),
            schemaVersion = CURRENT_SCHEMA_VERSION,
        }
        _G.ForeverSuiteDB = rawAcct
    elseif rawAcct == nil then
        rawAcct = {
            schemaVersion = CURRENT_SCHEMA_VERSION,
        }
        _G.ForeverSuiteDB = rawAcct
    end

    local ver = tonumber(rawAcct.schemaVersion)
    if ver == nil then
        if next(rawAcct) ~= nil and rawAcct.account == nil then
            ver = 1
            rawAcct.schemaVersion = 1
        else
            ver = CURRENT_SCHEMA_VERSION
            rawAcct.schemaVersion = CURRENT_SCHEMA_VERSION
        end
    end

    if ver > CURRENT_SCHEMA_VERSION then
        -- Future schema detected: enter strict Read-Only mode without mutating SavedVariables (AC-5)
        self.readOnly = true
        self.accountDB = rawAcct
        self.runtimeAccount = DeepCopy(rawAcct.account or {})
        FillDefaults(self.runtimeAccount, DEFAULT_ACCOUNT_SETTINGS)
        ns.Warn("미래 스키마 버전(v" .. tostring(ver) .. ") 감지: 데이터 보호를 위해 읽기 전용 모드로 동작합니다.")
    else
        if ver < 1 or (rawAcct.account ~= nil and type(rawAcct.account) ~= "table") then
            self.corruptedRecovered = true
            local backupCopy = DeepCopy(rawAcct)
            ns.WipeTable(rawAcct)
            rawAcct._backup = { corrupted = backupCopy }
            rawAcct.schemaVersion = CURRENT_SCHEMA_VERSION
        elseif ver == 1 then
            MigrateV1ToV2(rawAcct)
        end

        rawAcct.account = type(rawAcct.account) == "table" and rawAcct.account or {}
        rawAcct.classes = type(rawAcct.classes) == "table" and rawAcct.classes or {}
        rawAcct.pendingCVarRestores = type(rawAcct.pendingCVarRestores) == "table" and rawAcct.pendingCVarRestores or {}
        FillDefaults(rawAcct.account, DEFAULT_ACCOUNT_SETTINGS)
        self.accountDB = rawAcct
        self.runtimeAccount = rawAcct.account
    end

    local rawChar = _G.ForeverSuiteCharDB
    if rawChar ~= nil and type(rawChar) ~= "table" then
        rawChar = { _corruptedBackup = tostring(rawChar), overrides = {}, ledger = {} }
        if not self.readOnly then
            _G.ForeverSuiteCharDB = rawChar
        end
    elseif rawChar == nil then
        rawChar = { overrides = {}, ledger = {} }
        if not self.readOnly then
            _G.ForeverSuiteCharDB = rawChar
        end
    end

    if self.readOnly then
        self.charDB = rawChar
        self.runtimeChar = DeepCopy(rawChar)
        self.runtimeChar.overrides = type(self.runtimeChar.overrides) == "table" and self.runtimeChar.overrides or {}
    else
        rawChar.overrides = type(rawChar.overrides) == "table" and rawChar.overrides or {}
        rawChar.ledger = type(rawChar.ledger) == "table" and rawChar.ledger or {}
        self.charDB = rawChar
        self.runtimeChar = rawChar
    end

    self:RecoverPendingCVars()
end

local function LookupPath(root, section, key)
    if type(root) ~= "table" then
        return nil
    end
    local sec = root[section]
    if type(sec) ~= "table" then
        return nil
    end
    return sec[key]
end

-- Hierarchy: Character > Class > Account > Defaults (AC-5)
function ProfileManager:Get(section, key)
    if self.runtimeChar and type(self.runtimeChar.overrides) == "table" then
        local cv = LookupPath(self.runtimeChar.overrides, section, key)
        if cv ~= nil then
            return cv
        end
    end
    if self.accountDB and type(self.accountDB.classes) == "table" then
        local classTbl = self.accountDB.classes[self.playerClass]
        local clv = LookupPath(classTbl, section, key)
        if clv ~= nil then
            return clv
        end
    end
    local av = LookupPath(self.runtimeAccount, section, key)
    if av ~= nil then
        return av
    end
    return LookupPath(DEFAULT_ACCOUNT_SETTINGS, section, key)
end

function ProfileManager:CanWrite()
    return not self.readOnly
end

function ProfileManager:Set(section, key, value, scope)
    if not self:CanWrite() then
        return false, "READ_ONLY"
    end
    local targetScope = scope or "account"
    if targetScope == "char" then
        local ov = self.runtimeChar.overrides
        ov[section] = type(ov[section]) == "table" and ov[section] or {}
        if ov[section][key] == value then
            return true
        end
        ov[section][key] = value
        self:NotifySettingChanged(section, key, value, targetScope)
        return true
    elseif targetScope == "class" then
        local classes = self.accountDB.classes
        classes[self.playerClass] = type(classes[self.playerClass]) == "table" and classes[self.playerClass] or {}
        local ct = classes[self.playerClass]
        ct[section] = type(ct[section]) == "table" and ct[section] or {}
        if ct[section][key] == value then
            return true
        end
        ct[section][key] = value
        self:NotifySettingChanged(section, key, value, targetScope)
        return true
    end
    self.runtimeAccount[section] = type(self.runtimeAccount[section]) == "table" and self.runtimeAccount[section] or {}
    if self.runtimeAccount[section][key] == value then
        return true
    end
    self.runtimeAccount[section][key] = value
    self:NotifySettingChanged(section, key, value, targetScope)
    return true
end

function ProfileManager:IsModuleEnabled(moduleName)
    if self.runtimeChar and type(self.runtimeChar.overrides) == "table" then
        local charMods = self.runtimeChar.overrides.modules
        if type(charMods) == "table" and type(charMods[moduleName]) == "table" and charMods[moduleName].enabled ~= nil then
            return charMods[moduleName].enabled and true or false
        end
    end
    if self.accountDB and type(self.accountDB.classes) == "table" then
        local classTbl = self.accountDB.classes[self.playerClass]
        if type(classTbl) == "table" and type(classTbl.modules) == "table" and type(classTbl.modules[moduleName]) == "table" and classTbl.modules[moduleName].enabled ~= nil then
            return classTbl.modules[moduleName].enabled and true or false
        end
    end
    if self.runtimeAccount and type(self.runtimeAccount.modules) == "table" and type(self.runtimeAccount.modules[moduleName]) == "table" then
        if self.runtimeAccount.modules[moduleName].enabled ~= nil then
            return self.runtimeAccount.modules[moduleName].enabled and true or false
        end
    end
    return true
end

function ProfileManager:SetModuleEnabled(moduleName, enabled, scope)
    if not self:CanWrite() then
        return false, "READ_ONLY"
    end
    local flag = enabled and true or false
    if scope == "char" then
        local ov = self.runtimeChar.overrides
        ov.modules = type(ov.modules) == "table" and ov.modules or {}
        ov.modules[moduleName] = type(ov.modules[moduleName]) == "table" and ov.modules[moduleName] or {}
        ov.modules[moduleName].enabled = flag
        return true
    end
    self.runtimeAccount.modules = type(self.runtimeAccount.modules) == "table" and self.runtimeAccount.modules or {}
    self.runtimeAccount.modules[moduleName] = type(self.runtimeAccount.modules[moduleName]) == "table" and self.runtimeAccount.modules[moduleName] or {}
    self.runtimeAccount.modules[moduleName].enabled = flag
    return true
end

function ProfileManager:IsProtectedItem(itemID)
    if not itemID or ns.IsSecret(itemID) then
        return false
    end
    local tbl = self:Get("utility", "protectedItems")
    if type(tbl) == "table" then
        return tbl[itemID] and true or false
    end
    return false
end

function ProfileManager:SetProtectedItem(itemID, isProtected)
    if not self:CanWrite() then
        return false, "READ_ONLY"
    end
    if not itemID or ns.IsSecret(itemID) then
        return false
    end
    local acctUtil = self.runtimeAccount.utility
    acctUtil.protectedItems = type(acctUtil.protectedItems) == "table" and acctUtil.protectedItems or {}
    if isProtected then
        acctUtil.protectedItems[itemID] = true
    else
        acctUtil.protectedItems[itemID] = nil
    end
    return true
end

-- Crash-Safe Temporary CVar Override Ledger (Contract Taint/CVar Rule #3)
function ProfileManager:ApplyTemporaryCVar(cvarName, tempValue)
    local current = ns.SafeGetCVar(cvarName)
    if current == nil then
        return false
    end
    if not self.readOnly and self.accountDB and type(self.accountDB.pendingCVarRestores) == "table" then
        if self.accountDB.pendingCVarRestores[cvarName] == nil then
            self.accountDB.pendingCVarRestores[cvarName] = tostring(current)
        end
    end
    return ns.SafeSetCVar(cvarName, tempValue)
end

function ProfileManager:RestoreTemporaryCVar(cvarName)
    if not self.accountDB or type(self.accountDB.pendingCVarRestores) ~= "table" then
        return false
    end
    local orig = self.accountDB.pendingCVarRestores[cvarName]
    if orig == nil then
        return false
    end
    local ok = ns.SafeSetCVar(cvarName, orig)
    if ok and not self.readOnly then
        self.accountDB.pendingCVarRestores[cvarName] = nil
    end
    return ok
end

function ProfileManager:RecoverPendingCVars()
    if not self:CanWrite() then
        return 0
    end
    if not self.accountDB or type(self.accountDB.pendingCVarRestores) ~= "table" then
        return 0
    end
    local restored = 0
    for cvarName, origVal in pairs(self.accountDB.pendingCVarRestores) do
        if ns.SafeSetCVar(cvarName, origVal) then
            restored = restored + 1
            self.accountDB.pendingCVarRestores[cvarName] = nil
        end
    end
    return restored
end
