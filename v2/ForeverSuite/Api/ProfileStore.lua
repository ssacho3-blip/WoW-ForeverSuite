-- Module: Api/ProfileStore.lua
-- Responsibility: Versioned v2 SavedVariables adapter (ForeverSuiteV2DB + ForeverSuiteV2CharDB, read-only v1 import).
-- Layer: Api
local _, ns = ...
ns.Api = ns.Api or {}

local type = type

local ProfileStore = {
    db = nil,
    charDB = nil,
    readOnly = false,
    schemas = {},
    schemaByKey = {},
    cvarJournalGen = {},
}
ns.Api.ProfileStore = ProfileStore

function ProfileStore:RegisterSchema(schemaList)
    for i = 1, #(schemaList or {}) do
        local sc = schemaList[i]
        self.schemas[#self.schemas + 1] = sc
        if type(sc) == "table" and type(sc.section) == "string" and type(sc.key) == "string" then
            self.schemaByKey[sc.section .. "." .. sc.key] = sc
        end
    end
end

function ProfileStore:Init()
    local defaults = ns.Domain.SettingsSchemaModel.BuildDefaults(self.schemas)
    local migrated, ro = ns.Domain.ProfileMigrationModel.Migrate(
        _G.ForeverSuiteV2DB,
        defaults,
        _G.ForeverSuiteDB
    )
    -- Preserve invalid/non-table SavedVariables untouched rather than clobbering global with nil
    if type(migrated) == "table" then
        _G.ForeverSuiteV2DB = migrated
        self.db = migrated
    else
        self.db = nil
    end
    if type(_G.ForeverSuiteV2CharDB) ~= "table" then
        _G.ForeverSuiteV2CharDB = { realm = ns.Api.SafeAPI.GetCanonicalRealm() }
    end
    self.charDB = _G.ForeverSuiteV2CharDB
    self.readOnly = (ro == true) or (self.db == nil)
    -- D2 / A7: Absorb PresetManager syncedSharedSettings ONCE into v6 chars[charKey] + settings, then clear flag
    if (not self.readOnly) and type(self.charDB.syncedSharedSettings) == "table" and self.charDB.applySyncedOnNextLogin == true then
        self.charDB.applySyncedOnNextLogin = false
        local charKey = self:GetCharKey()
        self.db.v2.profiles = self.db.v2.profiles or { account = self.db.v2.settings, devices = {}, chars = {} }
        self.db.v2.profiles.chars = self.db.v2.profiles.chars or {}
        self.db.v2.profiles.chars[charKey] = self.db.v2.profiles.chars[charKey] or {}
        for sec, tbl in pairs(self.charDB.syncedSharedSettings) do
            if type(tbl) == "table" then
                self.db.v2.settings[sec] = self.db.v2.settings[sec] or {}
                self.db.v2.profiles.chars[charKey][sec] = self.db.v2.profiles.chars[charKey][sec] or {}
                for k, v in pairs(tbl) do
                    self.db.v2.settings[sec][k] = v
                    self.db.v2.profiles.chars[charKey][sec][k] = v
                end
            end
        end
    end
    return self.db
end

function ProfileStore:GetCharKey()
    local name = (type(_G.UnitName) == "function") and ns.Api.SafeAPI.SafeRead(_G.UnitName, "player") or nil
    if name == ns.Api.SafeAPI.UNAVAILABLE or type(name) ~= "string" or name == "" then
        name = "Player"
    end
    local realm = (self.charDB and type(self.charDB.realm) == "string" and self.charDB.realm ~= "")
        and self.charDB.realm or ns.Api.SafeAPI.GetCanonicalRealm()
    return name .. "-" .. realm
end

function ProfileStore:GetDeviceKey()
    local physW, physH = 1920, 1080
    if type(_G.GetPhysicalScreenSize) == "function" then
        local ok, w, h = pcall(_G.GetPhysicalScreenSize)
        if ok and type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then
            physW, physH = w, h
        end
    end
    local scale = 1.0
    if _G.UIParent and type(_G.UIParent.GetEffectiveScale) == "function" then
        local ok, s = pcall(_G.UIParent.GetEffectiveScale, _G.UIParent)
        if ok and type(s) == "number" and s > 0 then
            scale = s
        end
    end
    local isMac = (type(_G.IsMacClient) == "function") and (pcall(_G.IsMacClient) and _G.IsMacClient() == true) or false
    return ns.Domain.ProfileMigrationModel.MakeDeviceKey(physW, physH, scale, isMac)
end

function ProfileStore:RestoreV5()
    if self.readOnly then
        return false, "READ_ONLY"
    end
    if type(self.db) ~= "table" then
        return false, "NO_DB"
    end
    local restored, ok, reason = ns.Domain.ProfileMigrationModel.RestoreV5Backup(self.db)
    if not ok or type(restored) ~= "table" then
        return false, reason or "NO_V5_BACKUP"
    end
    _G.ForeverSuiteV2DB = restored
    self.db = restored
    self.readOnly = false
    return true, "RESTORED_V5"
end

function ProfileStore:CanWrite()
    return (not self.readOnly) and type(self.db) == "table" and type(self.db.v2) == "table"
end

function ProfileStore:Get(section, key)
    if type(self.db) ~= "table" or type(self.db.v2) ~= "table" then
        return nil
    end
    local sec = self.db.v2.settings and self.db.v2.settings[section]
    return sec and sec[key]
end

function ProfileStore:Set(section, key, val)
    if not self:CanWrite() then
        return false, "READ_ONLY"
    end
    local sc = (type(section) == "string" and type(key) == "string") and self.schemaByKey[section .. "." .. key] or nil
    if sc and sc.combatSafe == false and ns.Api.SafeAPI and ns.Api.SafeAPI.InCombat() then
        return false, "IN_COMBAT"
    end
    self.db.v2.settings[section] = self.db.v2.settings[section] or {}
    self.db.v2.settings[section][key] = val
    -- B1 Expand sync: keep independent profiles.account table in sync across /reload
    if type(self.db.v2.profiles) == "table" and type(self.db.v2.profiles.account) == "table" then
        self.db.v2.profiles.account[section] = self.db.v2.profiles.account[section] or {}
        self.db.v2.profiles.account[section][key] = val
    end
    if ns.Api.EventBus then
        ns.Api.EventBus:Publish("setting:changed", section, key, val)
    end
    return true
end

function ProfileStore:GetLayout(widgetId)
    if type(self.db) ~= "table" or type(self.db.v2) ~= "table" then
        return nil
    end
    local devKey = self:GetDeviceKey()
    return ns.Domain.ProfileMigrationModel.ResolveDeviceLayout(self.db, widgetId, devKey, self.readOnly)
end

function ProfileStore:SetLayout(widgetId, anchor)
    if not self:CanWrite() then
        return false
    end
    local devKey = self:GetDeviceKey()
    self.db.v2.profiles = self.db.v2.profiles or { account = self.db.v2.settings, devices = {}, chars = {} }
    self.db.v2.profiles.devices = self.db.v2.profiles.devices or {}
    self.db.v2.profiles.devices[devKey] = self.db.v2.profiles.devices[devKey] or {}
    self.db.v2.profiles.devices[devKey][widgetId] = anchor
    -- Expand phase: mirror into legacy layout key so rollback stays seamless
    self.db.v2.layout[widgetId] = anchor
    return true
end

function ProfileStore:GetState(key)
    if type(self.db) ~= "table" or type(self.db.v2) ~= "table" or type(self.db.v2.state) ~= "table" then
        return nil
    end
    return self.db.v2.state[key]
end

function ProfileStore:SetState(key, val)
    if not self:CanWrite() then
        return false
    end
    self.db.v2.state = self.db.v2.state or {}
    self.db.v2.state[key] = val
    return true
end

-- C7: Crash-safe CVar restore journal stored strictly inside active ForeverSuiteV2DB.v2.state.
function ProfileStore:RecordCvarJournal(cvarName, originalValue)
    if (not self:CanWrite()) or type(cvarName) ~= "string" or cvarName == "" or originalValue == nil then
        return false
    end
    self.db.v2.state = self.db.v2.state or {}
    local journal = self.db.v2.state.cvarRestoreJournal
    if type(journal) ~= "table" then
        journal = {}
        self.db.v2.state.cvarRestoreJournal = journal
    end
    if journal[cvarName] == nil then
        journal[cvarName] = originalValue
        self.cvarJournalGen[cvarName] = (self.cvarJournalGen[cvarName] or 0) + 1
    end
    return true
end

function ProfileStore:ClearCvarJournal(cvarName)
    if (not self:CanWrite()) or type(self.db.v2.state) ~= "table" then
        return false
    end
    local journal = self.db.v2.state.cvarRestoreJournal
    if type(journal) ~= "table" then
        return false
    end
    if cvarName == nil then
        for k in pairs(journal) do
            self.cvarJournalGen[k] = (self.cvarJournalGen[k] or 0) + 1
        end
        self.db.v2.state.cvarRestoreJournal = nil
        return true
    end
    journal[cvarName] = nil
    self.cvarJournalGen[cvarName] = (self.cvarJournalGen[cvarName] or 0) + 1
    if next(journal) == nil then
        self.db.v2.state.cvarRestoreJournal = nil
    end
    return true
end

function ProfileStore:RestoreCvarJournal(deferFn)
    if (not self:CanWrite()) or type(self.db.v2.state) ~= "table" then
        return 0, 0
    end
    local journal = self.db.v2.state.cvarRestoreJournal
    if type(journal) ~= "table" then
        return 0, 0
    end
    local applied = 0
    local deferred = 0
    local keys = {}
    for k in pairs(journal) do
        keys[#keys + 1] = k
    end
    local expectedDb = self.db
    local expectedJournal = journal
    local useDefer = type(deferFn) == "function"
    for i = 1, #keys do
        local cvarName = keys[i]
        local origVal = journal[cvarName]
        local expectedGen = self.cvarJournalGen[cvarName] or 0
        local function applyRestore()
            -- Re-verify writability, active DB/journal identity & per-key generation (ABA-safe)
            if (not ProfileStore:CanWrite())
                or ProfileStore.db ~= expectedDb
                or type(ProfileStore.db.v2.state) ~= "table"
                or ProfileStore.db.v2.state.cvarRestoreJournal ~= expectedJournal
                or expectedJournal[cvarName] ~= origVal
                or (ProfileStore.cvarJournalGen[cvarName] or 0) ~= expectedGen
            then
                return false
            end
            if ns.Api.SafeAPI and ns.Api.SafeAPI.InCombat() then
                if useDefer then
                    error("CVAR_RESTORE_IN_COMBAT:" .. tostring(cvarName))
                end
                return false
            end
            local setter = (_G.C_CVar and type(_G.C_CVar.SetCVar) == "function") and _G.C_CVar.SetCVar or _G.SetCVar
            if type(setter) ~= "function" then
                if useDefer then
                    error("CVAR_SETTER_UNAVAILABLE:" .. tostring(cvarName))
                end
                return false
            end
            local ok, res = pcall(setter, cvarName, origVal)
            if ok and res ~= false then
                ProfileStore:ClearCvarJournal(cvarName)
                applied = applied + 1
                return true
            end
            if useDefer then
                error("CVAR_RESTORE_FAILED:" .. tostring(cvarName))
            end
            return false
        end
        if useDefer then
            local ran, reason = deferFn("cvar:restore:" .. cvarName, applyRestore)
            if (not ran) and reason == "DEFERRED" then
                deferred = deferred + 1
            end
        else
            applyRestore()
        end
    end
    return applied, deferred
end
