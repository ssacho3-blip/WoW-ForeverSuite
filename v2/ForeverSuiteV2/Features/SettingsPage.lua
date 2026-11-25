-- Module: Features/SettingsPage.lua
-- Responsibility: Declarative schema-driven Settings page inside L2 /fs Command Hub (zero frame leak via widget pooling).
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs

local SettingsPage = {
    id = "settings",
    label = "설정",
    host = nil,
    header = nil,
    builtItems = {},
    visibleCount = 0,
}
ns.Features.SettingsPage = SettingsPage

function SettingsPage:Build(parent)
    self.host = parent
    self.header = W.SectionHeader(parent, "통합 설정")
    self.header:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    self.header:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    -- Create widgets ONCE per declared schema item and reuse them on search/OnShow (zero frame leak!)
    self.builtItems = {}
    for _, item in ipairs(ns.Api.ProfileStore.schemas) do
        if item.type == "boolean" then
            local cur = ns.Api.ProfileStore:Get(item.section, item.key)
            local tgl = W.Toggle(parent, item.label, cur, function(v)
                return ns.Api.ProfileStore:Set(item.section, item.key, v)
            end)
            self.builtItems[#self.builtItems + 1] = { schema = item, kind = "boolean", main = tgl, height = 30 }
        elseif item.type == "enum" then
            local cur = ns.Api.ProfileStore:Get(item.section, item.key)
            local lbl = W.Label(parent, item.label, "small", T.TEXT.SECONDARY)
            local bar = W.PillBar(parent, item.options, cur, function(v)
                return ns.Api.ProfileStore:Set(item.section, item.key, v)
            end)
            self.builtItems[#self.builtItems + 1] = { schema = item, kind = "enum", label = lbl, main = bar, height = 52 }
        end
    end

    self:RenderList("")
end

function SettingsPage:RenderList(query)
    if not self.host then
        return
    end
    local filtered = ns.Domain.SettingsSchemaModel.FilterByQuery(ns.Api.ProfileStore.schemas, query)
    local allowSet = {}
    for _, item in ipairs(filtered) do
        allowSet[item.section .. "." .. item.key] = true
    end

    if self.header and self.header._label then
        self.header._label:SetText("통합 설정 (" .. tostring(#filtered) .. "개 항목)")
    end

    local y = 32
    local shown = 0
    for _, entry in ipairs(self.builtItems) do
        local keyId = entry.schema.section .. "." .. entry.schema.key
        if allowSet[keyId] then
            shown = shown + 1
            if entry.kind == "boolean" then
                entry.main:ClearAllPoints()
                entry.main:SetPoint("TOPLEFT", self.host, "TOPLEFT", 4, -y)
                entry.main:SetPoint("TOPRIGHT", self.host, "TOPRIGHT", -4, -y)
                entry.main:SetChecked(ns.Api.ProfileStore:Get(entry.schema.section, entry.schema.key))
                entry.main:Show()
            elseif entry.kind == "enum" then
                entry.label:ClearAllPoints()
                entry.label:SetPoint("TOPLEFT", self.host, "TOPLEFT", 4, -y)
                entry.label:Show()
                entry.main:ClearAllPoints()
                entry.main:SetPoint("TOPLEFT", self.host, "TOPLEFT", 4, -(y + 18))
                entry.main:SetPoint("TOPRIGHT", self.host, "TOPRIGHT", -4, -(y + 18))
                entry.main:Show()
            end
            y = y + entry.height
        else
            if entry.label then entry.label:Hide() end
            entry.main:Hide()
        end
    end
    self.visibleCount = shown
end

function SettingsPage:OnShow()
    self:RenderList(ns.UI.CommandHub.lastQuery or "")
end

function SettingsPage:OnSearch(query)
    self:RenderList(query)
end
