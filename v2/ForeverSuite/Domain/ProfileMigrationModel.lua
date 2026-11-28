-- Module: Domain/ProfileMigrationModel.lua
-- Responsibility: Pure SavedVariables v5 -> v6 3-tier (account/devices/chars) Expand-Migrate-Contract initializer,
--                 read-only v1 import, _backup_v5 snapshot & rollback, and fail-closed future-schema guard.
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local pairs = pairs
local tonumber = tonumber
local math_floor = math.floor
local string_format = string.format

local ProfileMigrationModel = {
    TARGET_SCHEMA = 6,
}
ns.Domain.ProfileMigrationModel = ProfileMigrationModel

local function DeepCopy(src, seen)
    if type(src) ~= "table" then
        return src
    end
    seen = seen or {}
    if seen[src] then
        return seen[src]
    end
    local dst = {}
    seen[src] = dst
    for k, v in pairs(src) do
        dst[k] = DeepCopy(v, seen)
    end
    return dst
end

function ProfileMigrationModel.MakeDeviceKey(physW, physH, uiScale, isMac)
    local w = math_floor(tonumber(physW) or 1920)
    local h = math_floor(tonumber(physH) or 1080)
    if w <= 0 then w = 1920 end
    if h <= 0 then h = 1080 end
    local sc = tonumber(uiScale) or 1.0
    if sc <= 0 then sc = 1.0 end
    local osTag = isMac and "MAC" or "WIN"
    return string_format("%dx%d@%.2f:%s", w, h, sc, osTag)
end

local function EnsureShape(db, defaults)
    if type(db.v2) ~= "table" then
        db.v2 = {}
    end
    if type(db.v2.settings) ~= "table" then
        db.v2.settings = {}
    end
    if type(db.v2.layout) ~= "table" then
        db.v2.layout = {}
    end
    if type(db.v2.ledger) ~= "table" then
        db.v2.ledger = {}
    end
    if type(db.v2.protectedItems) ~= "table" then
        db.v2.protectedItems = {}
    end
    if type(db.v2.state) ~= "table" then
        db.v2.state = {}
    end
    if type(db.v2.altCooldowns) ~= "table" then
        db.v2.altCooldowns = {}
    end
    if type(db.v2.diagnostics) ~= "table" then
        db.v2.diagnostics = {}
    end
    if type(db.v2.diagnostics.taintTotal) ~= "number" then
        db.v2.diagnostics.taintTotal = 0
    end
    if type(db.v2.diagnostics.taintCounts) ~= "table" then
        db.v2.diagnostics.taintCounts = {}
    end

    for sec, secDefaults in pairs(defaults or {}) do
        if type(db.v2.settings[sec]) ~= "table" then
            db.v2.settings[sec] = {}
        end
        for k, v in pairs(secDefaults) do
            if db.v2.settings[sec][k] == nil then
                db.v2.settings[sec][k] = v
            end
        end
    end

    -- v6 3-tier profiles (Expand phase: DeepCopy prevents WoW SV shared-reference divergence after /reload)
    if type(db.v2.profiles) ~= "table" then
        db.v2.profiles = {}
    end
    if type(db.v2.profiles.account) ~= "table" then
        db.v2.profiles.account = DeepCopy(db.v2.settings)
    end
    if type(db.v2.profiles.devices) ~= "table" then
        db.v2.profiles.devices = {}
    end
    if type(db.v2.profiles.devices.legacy) ~= "table" then
        db.v2.profiles.devices.legacy = DeepCopy(db.v2.layout)
    end
    if type(db.v2.profiles.chars) ~= "table" then
        db.v2.profiles.chars = {}
    end
end

function ProfileMigrationModel.Migrate(rawV2DB, defaults, optionalLegacyV1DB)
    if rawV2DB ~= nil and type(rawV2DB) ~= "table" then
        return nil, true, "INVALID_DB"
    end
    local src = (type(rawV2DB) == "table") and rawV2DB or {}
    local curSchema = (type(src.schemaVersion) == "number") and src.schemaVersion or 0

    if curSchema > ProfileMigrationModel.TARGET_SCHEMA then
        return src, true, "FUTURE_SCHEMA_READONLY"
    end

    -- Work on a clean DeepCopy so any failure leaves rawV2DB untouched (atomic swap)
    local db = DeepCopy(src)

    if curSchema < ProfileMigrationModel.TARGET_SCHEMA then
        local hasAnyKey = false
        for _ in pairs(db) do
            hasAnyKey = true
            break
        end
        if hasAnyKey and type(db._v1_backup) ~= "table" then
            db._v1_backup = DeepCopy(src)
        end

        -- Preserve dedicated _backup_v5 (with exact source schema version) excluding nested _v1_backup to avoid bloat
        if curSchema >= 1 and curSchema < 6 and type(db.v2) == "table" and type(db._backup_v5) ~= "table" then
            db._backup_v5 = DeepCopy(db.v2)
            db._backup_v5_schema = curSchema
        end

        EnsureShape(db, defaults)

        -- Non-destructive one-time import from legacy v1 ForeverSuiteDB if provided
        local srcLegacy = (type(optionalLegacyV1DB) == "table") and optionalLegacyV1DB or db
        if type(srcLegacy.account) == "table" and not db._legacyImported then
            local acct = srcLegacy.account
            if type(acct.utility) == "table" and type(acct.utility.protectedItems) == "table" then
                db.v2.protectedItems = DeepCopy(acct.utility.protectedItems)
            end
            if type(srcLegacy._diagnostics) == "table" and type(srcLegacy._diagnostics.taintCounts) == "table" then
                db.v2.diagnostics.importedV1TaintCounts = DeepCopy(srcLegacy._diagnostics.taintCounts)
            end
            db._legacyImported = true
        end

        -- Schema < 5: ensure legacy/preview "coexist" defaults upgrade cleanly to "hide"
        local userExplicit = type(db.v2.state) == "table" and db.v2.state.userExplicitTrackerMode == true
        if curSchema < 5 and (not userExplicit) and type(db.v2.settings.quest) == "table" and db.v2.settings.quest.defaultTrackerMode == "coexist" then
            db.v2.settings.quest.defaultTrackerMode = "hide"
        end
        if curSchema < 5 and type(db.v2.settings.ui) == "table" and db.v2.settings.ui.navArrowStyle == "classic" then
            db.v2.settings.ui.navArrowStyle = "gold_classic"
        end

        -- Seed v6 3-tier profiles as independent DeepCopies from migrated v5 settings & layout
        db.v2.profiles.account = DeepCopy(db.v2.settings)
        db.v2.profiles.devices.legacy = DeepCopy(db.v2.layout)

        db.schemaVersion = ProfileMigrationModel.TARGET_SCHEMA
    end

    EnsureShape(db, defaults)
    return db, false, "OK"
end

-- Priority: chars[charKey] > devices[deviceKey] > account > v2.settings > defaultVal
function ProfileMigrationModel.ResolveSetting(db, section, key, charKey, deviceKey, defaultVal)
    if type(db) ~= "table" or type(db.v2) ~= "table" or type(section) ~= "string" or type(key) ~= "string" then
        return defaultVal
    end
    local profiles = db.v2.profiles
    if type(profiles) == "table" then
        if type(charKey) == "string" and charKey ~= "" and type(profiles.chars) == "table" then
            local c = profiles.chars[charKey]
            local cSec = type(c) == "table" and c[section] or nil
            if type(cSec) == "table" and cSec[key] ~= nil then
                return cSec[key]
            end
        end
        if type(deviceKey) == "string" and deviceKey ~= "" and type(profiles.devices) == "table" then
            local d = profiles.devices[deviceKey]
            local dSec = type(d) == "table" and d.settings and d.settings[section] or nil
            if type(dSec) == "table" and dSec[key] ~= nil then
                return dSec[key]
            end
        end
        if type(profiles.account) == "table" then
            local aSec = profiles.account[section]
            if type(aSec) == "table" and aSec[key] ~= nil then
                return aSec[key]
            end
        end
    end
    local sSec = type(db.v2.settings) == "table" and db.v2.settings[section] or nil
    if type(sSec) == "table" and sSec[key] ~= nil then
        return sSec[key]
    end
    return defaultVal
end

-- Copy-on-first-sight multi-device layout resolver (non-mutating when readOnly or future-schema)
function ProfileMigrationModel.ResolveDeviceLayout(db, widgetId, deviceKey, readOnly)
    if type(db) ~= "table" or type(db.v2) ~= "table" or type(widgetId) ~= "string" or widgetId == "" then
        return nil
    end
    local isReadOnly = (readOnly == true)
        or (type(db.schemaVersion) == "number" and db.schemaVersion > ProfileMigrationModel.TARGET_SCHEMA)
    local devices = type(db.v2.profiles) == "table" and db.v2.profiles.devices or nil
    if type(devices) == "table" and type(deviceKey) == "string" and deviceKey ~= "" then
        if type(devices[deviceKey]) == "table" and type(devices[deviceKey][widgetId]) == "table" then
            return devices[deviceKey][widgetId]
        end
        if type(devices.legacy) == "table" and type(devices.legacy[widgetId]) == "table" then
            local copied = DeepCopy(devices.legacy[widgetId])
            if not isReadOnly then
                devices[deviceKey] = devices[deviceKey] or {}
                devices[deviceKey][widgetId] = copied
            end
            return copied
        end
    end
    return type(db.v2.layout) == "table" and db.v2.layout[widgetId] or nil
end

function ProfileMigrationModel.RestoreBackup(db)
    if type(db) ~= "table" or type(db._v1_backup) ~= "table" then
        return nil, false
    end
    return DeepCopy(db._v1_backup), true
end

function ProfileMigrationModel.RestoreV5Backup(db)
    if type(db) ~= "table" then
        return nil, false, "NO_DB"
    end
    if type(db.schemaVersion) == "number" and db.schemaVersion > ProfileMigrationModel.TARGET_SCHEMA then
        return nil, false, "READ_ONLY"
    end
    if type(db._backup_v5) ~= "table" then
        return nil, false, "NO_V5_BACKUP"
    end
    local restored = DeepCopy(db)
    -- Preserve live pre-restore v6 state ONCE (never overwrite on repeated RestoreV5 calls!)
    if type(restored._pre_restore_v6) ~= "table" and db.schemaVersion == ProfileMigrationModel.TARGET_SCHEMA and type(db.v2) == "table" then
        restored._pre_restore_v6 = DeepCopy(db.v2)
    end
    restored.v2 = DeepCopy(db._backup_v5)
    local srcSchema = (type(db._backup_v5_schema) == "number" and db._backup_v5_schema >= 1 and db._backup_v5_schema < 6)
        and db._backup_v5_schema or 5
    restored.schemaVersion = srcSchema
    return restored, true, "RESTORED_V5"
end
