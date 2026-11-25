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
}
ns.Api.ProfileStore = ProfileStore

function ProfileStore:RegisterSchema(schemaList)
    for i = 1, #(schemaList or {}) do
        self.schemas[#self.schemas + 1] = schemaList[i]
    end
end

function ProfileStore:Init()
    local defaults = ns.Domain.SettingsSchemaModel.BuildDefaults(self.schemas)
    local migrated, ro = ns.Domain.ProfileMigrationModel.Migrate(
        _G.ForeverSuiteV2DB,
        defaults,
        _G.ForeverSuiteDB
    )
    _G.ForeverSuiteV2DB = migrated
    if type(_G.ForeverSuiteV2CharDB) ~= "table" then
        _G.ForeverSuiteV2CharDB = { realm = ns.Api.SafeAPI.GetCanonicalRealm() }
    end
    self.db = migrated
    self.charDB = _G.ForeverSuiteV2CharDB
    self.readOnly = ro and true or false
    return self.db
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
        return false
    end
    self.db.v2.settings[section] = self.db.v2.settings[section] or {}
    self.db.v2.settings[section][key] = val
    if ns.Api.EventBus then
        ns.Api.EventBus:Publish("setting:changed", section, key, val)
    end
    return true
end

function ProfileStore:GetLayout(widgetId)
    if type(self.db) ~= "table" or type(self.db.v2) ~= "table" then
        return nil
    end
    return self.db.v2.layout and self.db.v2.layout[widgetId]
end

function ProfileStore:SetLayout(widgetId, anchor)
    if not self:CanWrite() then
        return false
    end
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
