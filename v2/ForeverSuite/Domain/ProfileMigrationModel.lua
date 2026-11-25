-- Module: Domain/ProfileMigrationModel.lua
-- Responsibility: Pure SavedVariables v2 initializer & optional read-only import from legacy v1 ForeverSuiteDB.
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local pairs = pairs

local ProfileMigrationModel = {
    TARGET_SCHEMA = 4,
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
end

function ProfileMigrationModel.Migrate(rawV2DB, defaults, optionalLegacyV1DB)
    local db = (type(rawV2DB) == "table") and rawV2DB or {}
    local curSchema = (type(db.schemaVersion) == "number") and db.schemaVersion or 0

    if curSchema > ProfileMigrationModel.TARGET_SCHEMA then
        return db, true, "FUTURE_SCHEMA_READONLY"
    end

    -- Preserve read-only backup if upgrading any existing non-empty table
    if curSchema < ProfileMigrationModel.TARGET_SCHEMA then
        local hasAnyKey = false
        for _ in pairs(db) do
            hasAnyKey = true
            break
        end
        if hasAnyKey and type(db._v1_backup) ~= "table" then
            db._v1_backup = DeepCopy(db)
        end

        EnsureShape(db, defaults)

        -- Non-destructive one-time import from legacy v1 ForeverSuiteDB if provided
        -- Note: never auto-imports hideDefaultTracker so v2 defaults safely to hands-off "coexist"
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

        -- Schema 3 -> 4 (Phase 3 standalone cutover): switch preview-era "coexist" default to "hide"
        -- so players never see duplicate Blizzard + ForeverSuite quest trackers after v1 removal.
        if curSchema == 3 and type(db.v2.settings.quest) == "table" and db.v2.settings.quest.defaultTrackerMode == "coexist" then
            db.v2.settings.quest.defaultTrackerMode = "hide"
        end

        db.schemaVersion = ProfileMigrationModel.TARGET_SCHEMA
    end

    -- Always repair shape on every boot (even when schemaVersion == TARGET_SCHEMA)
    EnsureShape(db, defaults)
    return db, false, "OK"
end

function ProfileMigrationModel.RestoreBackup(db)
    if type(db) ~= "table" or type(db._v1_backup) ~= "table" then
        return nil, false
    end
    return DeepCopy(db._v1_backup), true
end
