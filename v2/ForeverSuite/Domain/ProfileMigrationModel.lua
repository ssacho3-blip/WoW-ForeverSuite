-- Module: Domain/ProfileMigrationModel.lua
-- Responsibility: Pure SavedVariables v2 initializer & optional read-only import from legacy v1 ForeverSuiteDB.
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local pairs = pairs

local ProfileMigrationModel = {
    TARGET_SCHEMA = 5,
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

        -- Schema < 5: ensure legacy/preview "coexist" defaults upgrade cleanly to "hide"
        -- so players never see Blizzard's default quest list overlapping ForeverSuite's QuestTracker,
        -- unless the user explicitly chose a mode in Settings (state.userExplicitTrackerMode == true).
        local userExplicit = type(db.v2.state) == "table" and db.v2.state.userExplicitTrackerMode == true
        if curSchema < 5 and (not userExplicit) and type(db.v2.settings.quest) == "table" and db.v2.settings.quest.defaultTrackerMode == "coexist" then
            db.v2.settings.quest.defaultTrackerMode = "hide"
        end
        if curSchema < 5 and type(db.v2.settings.ui) == "table" and db.v2.settings.ui.navArrowStyle == "classic" then
            db.v2.settings.ui.navArrowStyle = "gold_classic"
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
