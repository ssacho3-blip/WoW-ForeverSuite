-- Module: Features/SettingsPage.lua
-- Responsibility: Declarative schema-driven Settings page with section PillBar + search inside L2 /fs2 Command Hub (zero frame leak via widget pooling).
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs
local tostring = tostring

local MAX_CONTENT_Y = 396

local SECTION_TABS = {
    { value = "all", label = "전체", width = 56 },
    { value = "quest", label = "퀘스트", width = 64 },
    { value = "merchant", label = "상점", width = 56 },
    { value = "combat", label = "전투", width = 56 },
    { value = "qol", label = "편의", width = 56 },
    { value = "other", label = "UI·전문", width = 68 },
}

local SettingsPage = {
    id = "settings",
    label = "설정",
    host = nil,
    header = nil,
    tabBar = nil,
    overflowLbl = nil,
    activeSection = "all",
    builtItems = {},
    visibleCount = 0,
}
ns.Features.SettingsPage = SettingsPage

local function MatchesSection(section, activeSec)
    if activeSec == "all" then
        return true
    end
    if activeSec == "other" then
        return section == "ui" or section == "profession"
    end
    return section == activeSec
end

function SettingsPage:Build(parent)
    self.host = parent
    self.header = W.SectionHeader(parent, "통합 설정")
    self.header:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    self.header:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    self.tabBar = W.PillBar(parent, SECTION_TABS, self.activeSection, function(sec)
        SettingsPage.activeSection = sec
        SettingsPage:RenderList(ns.UI.CommandHub.lastQuery or "")
    end)
    self.tabBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -30)
    self.tabBar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -30)

    self.overflowLbl = W.Label(parent, "", "small", T.TEXT.MUTED)
    self.overflowLbl:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 4, 2)
    self.overflowLbl:Hide()

    -- Create widgets ONCE per declared schema item and reuse them on search/tab/OnShow (zero frame leak!)
    self.builtItems = {}
    for _, item in ipairs(ns.Api.ProfileStore.schemas) do
        if item.type == "boolean" then
            local cur = ns.Api.ProfileStore:Get(item.section, item.key)
            local tgl = W.Toggle(parent, item.label, cur, function(v)
                return ns.Api.ProfileStore:Set(item.section, item.key, v)
            end)
            self.builtItems[#self.builtItems + 1] = { schema = item, kind = "boolean", main = tgl, height = 28 }
        elseif item.type == "enum" then
            local cur = ns.Api.ProfileStore:Get(item.section, item.key)
            local lbl = W.Label(parent, item.label, "small", T.TEXT.SECONDARY)
            local bar = W.PillBar(parent, item.options, cur, function(v)
                return ns.Api.ProfileStore:Set(item.section, item.key, v)
            end)
            self.builtItems[#self.builtItems + 1] = { schema = item, kind = "enum", label = lbl, main = bar, height = 50 }
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
    local matchCount = 0
    for _, item in ipairs(filtered) do
        if MatchesSection(item.section, self.activeSection) then
            allowSet[item.section .. "." .. item.key] = true
            matchCount = matchCount + 1
        end
    end

    if self.header and self.header._label then
        self.header._label:SetText("통합 설정 (" .. tostring(matchCount) .. "개 항목)")
    end

    local y = 64
    local shown = 0
    local hiddenOverflow = 0
    for _, entry in ipairs(self.builtItems) do
        local keyId = entry.schema.section .. "." .. entry.schema.key
        if allowSet[keyId] and (y + entry.height <= MAX_CONTENT_Y) then
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
            if allowSet[keyId] then
                hiddenOverflow = hiddenOverflow + 1
            end
            if entry.label then entry.label:Hide() end
            entry.main:Hide()
        end
    end
    if self.overflowLbl then
        if hiddenOverflow > 0 then
            self.overflowLbl:SetText("위 섹션 탭 또는 검색창으로 나머지 " .. tostring(hiddenOverflow) .. "개 항목을 확인하세요.")
            self.overflowLbl:Show()
        else
            self.overflowLbl:Hide()
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
