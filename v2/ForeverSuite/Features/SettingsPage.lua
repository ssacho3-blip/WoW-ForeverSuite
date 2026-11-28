-- Module: Features/SettingsPage.lua
-- Responsibility: ForeverSuite v3.0 Declarative Settings page with 3 One-Click Presets (Standard / Raid / Minimal),
--                 Profile Backup & Restore buttons, 2-line rich setting cards showing schema.desc + [비전투] badge,
--                 W.ScrollBar, and zero frame leak via widget pooling.
-- Layer: Features (uses UI/Widgets + CompositeWidgets only; zero raw CreateFrame).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs
local pairs = pairs
local tostring = tostring

local MAX_CONTENT_Y = 524

local SECTION_TABS = {
    { value = "all",         label = "전체",     width = 50 },
    { value = "quest",       label = "퀘스트",   width = 60 },
    { value = "merchant",    label = "상점",     width = 50 },
    { value = "combat",      label = "전투",     width = 50 },
    { value = "qol",         label = "편의",     width = 50 },
    { value = "ui",          label = "UI",       width = 44 },
    { value = "social_prof", label = "소셜·전문", width = 76 },
}

local PRESETS = {
    standard = {
        label = "표준 추천",
        values = {
            { "ui", "showStatusPill", true },
            { "ui", "showMinimapButton", true },
            { "ui", "showWorldMapOverlay", true },
            { "ui", "showWorldMapPins", true },
            { "ui", "enhanceTooltips", true },
            { "ui", "showCursorRing", false },
            { "ui", "showScreenClock", false },
            { "quest", "autoAccept", true },
            { "quest", "autoTurnIn", true },
            { "quest", "combatFade", true },
            { "merchant", "autoRepair", true },
            { "merchant", "autoSellJunk", true },
            { "combat", "showThreatMeter", true },
            { "combat", "showEncounterTimer", true },
            { "combat", "showComboHud", true },
            { "combat", "showRangeHud", true },
            { "combat", "showShortBuffHud", true },
            { "combat", "buffReminder", true },
            { "combat", "lowHealthAlert", true },
            { "profession", "showFishingCard", true },
            { "qol", "fastLoot", true },
            { "social", "autoGreetJoin", false },
            { "social", "autoGreetWelcome", false },
            { "social", "autoThankBuff", false },
        },
    },
    raid = {
        label = "레이드 집중",
        values = {
            { "ui", "showStatusPill", true },
            { "ui", "showWorldMapOverlay", true },
            { "ui", "showWorldMapPins", false },
            { "ui", "showCursorRing", true },
            { "ui", "cursorCombatOnly", true },
            { "ui", "showScreenClock", true },
            { "quest", "combatFade", true },
            { "merchant", "autoRepair", true },
            { "merchant", "useGuildRepair", true },
            { "merchant", "autoSellJunk", true },
            { "combat", "showThreatMeter", true },
            { "combat", "showEncounterTimer", true },
            { "combat", "showComboHud", true },
            { "combat", "showRangeHud", true },
            { "combat", "showShortBuffHud", true },
            { "combat", "buffReminder", true },
            { "combat", "lowHealthAlert", true },
            { "profession", "showFishingCard", false },
            { "qol", "fastLoot", true },
            { "social", "autoGreetJoin", false },
            { "social", "autoGreetWelcome", false },
            { "social", "questAnnounceParty", false },
        },
    },
    minimal = {
        label = "미니멀",
        values = {
            { "ui", "showStatusPill", false },
            { "ui", "showMinimapButton", true },
            { "ui", "showWorldMapOverlay", true },
            { "ui", "showWorldMapPins", false },
            { "ui", "enhanceTooltips", true },
            { "ui", "showCursorRing", false },
            { "ui", "showScreenClock", false },
            { "combat", "showThreatMeter", false },
            { "combat", "showEncounterTimer", false },
            { "combat", "showComboHud", false },
            { "combat", "showRangeHud", false },
            { "combat", "showShortBuffHud", false },
            { "combat", "buffReminder", false },
            { "combat", "lowHealthAlert", false },
            { "profession", "showFishingCard", false },
            { "merchant", "autoRepair", true },
            { "merchant", "autoSellJunk", true },
            { "qol", "fastLoot", true },
        },
    },
}

local SettingsPage = {
    id = "settings",
    label = "통합 설정",
    group = "system",
    host = nil,
    header = nil,
    tabBar = nil,
    scrollBar = nil,
    overflowLbl = nil,
    activeSection = "all",
    activePreset = nil,
    presetBtns = {},
    scrollOffset = 0,
    lastQuery = "",
    builtItems = {},
    visibleCount = 0,
}
ns.Features.SettingsPage = SettingsPage

function SettingsPage:SyncPresetButtons()
    for key, btn in pairs(self.presetBtns or {}) do
        local isAct = (self.activePreset == key)
        local bg = isAct and T.SURFACE.GOLD_TINT or T.SURFACE.ELEVATED
        local bd = isAct and T.BORDER.GOLD or T.BORDER.HAIRLINE
        local tc = isAct and T.TEXT.GOLD or T.TEXT.PRIMARY
        if btn._fsBg then btn._fsBg:SetColorTexture(bg[1], bg[2], bg[3], bg[4]) end
        W.SetBorderColor(btn, bd)
        if btn._label then btn._label:SetTextColor(tc[1], tc[2], tc[3], 1) end
    end
end

local function MatchesSection(section, activeSec)
    if activeSec == "all" then
        return true
    end
    if activeSec == "social_prof" or activeSec == "other" then
        return section == "profession" or section == "social" or (activeSec == "other" and section == "ui")
    end
    return section == activeSec
end

function SettingsPage:SyncControlsFromStore()
    for _, entry in ipairs(self.builtItems) do
        local val = ns.Api.ProfileStore:Get(entry.schema.section, entry.schema.key)
        if entry.kind == "boolean" and type(entry.main.SetChecked) == "function" then
            entry.main:SetChecked(val)
        elseif entry.kind == "enum" and type(entry.main.SetValue) == "function" then
            entry.main:SetValue(val)
        elseif entry.kind == "number" and entry.main._slider and type(entry.main._slider.SetValue) == "function" then
            local clamped = ns.Domain.SettingsSchemaModel.ClampSliderValue(entry.schema, val)
            if clamped ~= nil then
                entry.main._slider:SetValue(clamped)
            end
        end
    end
    self:RenderList(self.lastQuery)
end

function SettingsPage:ApplyPreset(presetKey)
    local preset = PRESETS[presetKey]
    if not preset then return false, 0 end
    local total = #preset.values
    local applied = 0
    for _, triple in ipairs(preset.values) do
        if ns.Api.ProfileStore:Set(triple[1], triple[2], triple[3]) then
            applied = applied + 1
        end
    end
    self:SyncControlsFromStore()
    if applied == 0 then
        self:SyncPresetButtons()
        ns.Api.SafeAPI.Print("설정 프리셋 [" .. preset.label .. "] 적용 실패 (읽기 전용 또는 전투 중)")
        W.Toast("프리셋 적용 실패", "읽기 전용 상태이거나 변경할 수 없습니다.", "DANGER", 3.5)
        return false, 0
    elseif applied < total then
        self.activePreset = nil
        self:SyncPresetButtons()
        ns.Api.SafeAPI.Print("설정 프리셋 [" .. preset.label .. "] 일부 적용 (" .. tostring(applied) .. "/" .. tostring(total) .. "개 · 비전투 제한 항목 제외)")
        W.Toast("프리셋 일부 적용", preset.label .. " (" .. tostring(applied) .. "/" .. tostring(total) .. "개 반영)", "WARN", 3.5)
        return false, applied
    end
    self.activePreset = presetKey
    self:SyncPresetButtons()
    ns.Api.SafeAPI.Print("설정 프리셋 [" .. preset.label .. "] 적용 완료 (" .. tostring(applied) .. "/" .. tostring(total) .. "개 항목)")
    W.Toast("프리셋 적용 완료", preset.label .. " (" .. tostring(applied) .. "개 항목 반영)", "SUCCESS", 3.0)
    return true, applied
end

function SettingsPage:Build(parent)
    self.host = parent
    if type(parent.EnableMouseWheel) == "function" then
        parent:EnableMouseWheel(true)
        local prevWheel = type(parent.GetScript) == "function" and parent:GetScript("OnMouseWheel") or nil
        parent:SetScript("OnMouseWheel", function(f, delta)
            if type(prevWheel) == "function" then pcall(prevWheel, f, delta) end
            if not delta or delta == 0 then return end
            SettingsPage.scrollOffset = SettingsPage.scrollOffset + (delta > 0 and -2 or 2)
            SettingsPage:RenderList(SettingsPage.lastQuery)
        end)
    end

    self.header = W.SectionHeader(parent, "통합 설정 · 원클릭 프리셋")
    self.header:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    self.header:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    -- 3-Preset Strip + Profile Export/Import buttons (y = -28)
    local pStd = W.Button(parent, "★ 표준 추천", 96, 24, function()
        SettingsPage:ApplyPreset("standard")
    end, true)
    pStd:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -28)

    local pRaid = W.Button(parent, "▶ 레이드 집중", 104, 24, function()
        SettingsPage:ApplyPreset("raid")
    end)
    pRaid:SetPoint("LEFT", pStd, "RIGHT", 6, 0)

    local pMin = W.Button(parent, "· 미니멀", 88, 24, function()
        SettingsPage:ApplyPreset("minimal")
    end)
    pMin:SetPoint("LEFT", pRaid, "RIGHT", 6, 0)
    self.presetBtns = { standard = pStd, raid = pRaid, minimal = pMin }
    for key, btn in pairs(self.presetBtns) do
        local k = key
        btn:SetScript("OnLeave", function()
            SettingsPage:SyncPresetButtons()
        end)
    end

    local importBtn = W.Button(parent, "프로필 복원", 88, 24, function()
        ns.UI.CommandHub:OpenProfileShareModal("import")
    end)
    importBtn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -28)

    local exportBtn = W.Button(parent, "프로필 백업", 88, 24, function()
        ns.UI.CommandHub:OpenProfileShareModal("export")
    end, true)
    exportBtn:SetPoint("RIGHT", importBtn, "LEFT", -6, 0)

    self.tabBar = W.PillBar(parent, SECTION_TABS, self.activeSection, function(sec)
        SettingsPage.activeSection = sec
        SettingsPage.scrollOffset = 0
        SettingsPage:RenderList(SettingsPage.lastQuery)
    end)
    self.tabBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -58)
    self.tabBar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -58)

    self.scrollBar = W.ScrollBar(parent, 434, function(newOff)
        SettingsPage.scrollOffset = newOff
        SettingsPage:RenderList(SettingsPage.lastQuery)
    end)
    self.scrollBar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -2, -90)
    self.scrollBar:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -2, 22)

    self.overflowLbl = W.Label(parent, "", "small", T.TEXT.MUTED)
    self.overflowLbl:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 4, 2)
    self.overflowLbl:Hide()

    -- Create pooled widgets ONCE per schema item (including schema.desc & [비전투] badge - Bug #5 Fix!)
    self.builtItems = {}
    for _, item in ipairs(ns.Api.ProfileStore.schemas) do
        local descText = (type(item.desc) == "string" and item.desc ~= "") and item.desc or nil
        local descLbl = descText and W.Label(parent, descText, "small", T.TEXT.MUTED, { justifyH = "LEFT", wordWrap = false }) or nil
        local combatTag = (item.combatSafe == false) and W.Label(parent, "[비전투 전용]", "small", T.SEMANTIC.WARN, { justifyH = "RIGHT", wordWrap = false }) or nil

        if item.type == "boolean" then
            local cur = ns.Api.ProfileStore:Get(item.section, item.key)
            local tgl = W.Toggle(parent, item.label, cur, function(v)
                return ns.Api.ProfileStore:Set(item.section, item.key, v)
            end)
            self.builtItems[#self.builtItems + 1] = {
                schema = item,
                kind = "boolean",
                main = tgl,
                descLbl = descLbl,
                combatTag = combatTag,
                height = descLbl and 38 or 26,
            }
        elseif item.type == "enum" then
            local cur = ns.Api.ProfileStore:Get(item.section, item.key)
            local lbl = W.Label(parent, item.label, "body", T.TEXT.PRIMARY)
            local bar = W.PillBar(parent, item.options, cur, function(v)
                return ns.Api.ProfileStore:Set(item.section, item.key, v)
            end)
            self.builtItems[#self.builtItems + 1] = {
                schema = item,
                kind = "enum",
                label = lbl,
                main = bar,
                descLbl = descLbl,
                combatTag = combatTag,
                height = descLbl and 58 or 48,
            }
        elseif item.type == "number" and ns.Domain.SettingsSchemaModel.ValidateSliderSchema(item) then
            local cur = ns.Domain.SettingsSchemaModel.ClampSliderValue(item, ns.Api.ProfileStore:Get(item.section, item.key))
            local sl = W.Slider(parent, item.label, item.min, item.max, item.step, cur, function(v)
                local c = ns.Domain.SettingsSchemaModel.ClampSliderValue(item, v)
                if c ~= nil then
                    local prev = ns.Api.ProfileStore:Get(item.section, item.key)
                    local eps = math.min(0.005, (item.step or 0.01) * 0.25)
                    if type(prev) ~= "number" or math.abs(c - prev) >= eps then
                        ns.Api.ProfileStore:Set(item.section, item.key, c)
                    end
                end
            end)
            self.builtItems[#self.builtItems + 1] = {
                schema = item,
                kind = "number",
                main = sl,
                descLbl = descLbl,
                combatTag = combatTag,
                height = descLbl and 56 or 44,
            }
        end
    end

    self:RenderList("")
end

function SettingsPage:RenderList(query)
    if not self.host then
        return
    end
    self.lastQuery = query or ""
    local filtered = ns.Domain.SettingsSchemaModel.FilterByQuery(ns.Api.ProfileStore.schemas, self.lastQuery)
    local allowSet = {}
    local matchCount = 0
    for _, item in ipairs(filtered) do
        if MatchesSection(item.section, self.activeSection) then
            allowSet[item.section .. "." .. item.key] = true
            matchCount = matchCount + 1
        end
    end

    if self.header and self.header._label then
        self.header._label:SetText("통합 설정 (" .. tostring(matchCount) .. "개 항목 · 설명 포함)")
    end

    local matched = {}
    for _, entry in ipairs(self.builtItems) do
        local keyId = entry.schema.section .. "." .. entry.schema.key
        if allowSet[keyId] then
            matched[#matched + 1] = entry
        end
        if entry.label then entry.label:Hide() end
        if entry.descLbl then entry.descLbl:Hide() end
        if entry.combatTag then entry.combatTag:Hide() end
        entry.main:Hide()
    end

    local maxOff = (#matched > 1) and (#matched - 1) or 0
    if self.scrollOffset < 0 then self.scrollOffset = 0 end
    if self.scrollOffset > maxOff then self.scrollOffset = maxOff end

    local qLower = string.lower(tostring(self.lastQuery or ""))
    local function HighlightMatch(rawTxt)
        local s = tostring(rawTxt or "")
        if qLower == "" then return s end
        local sl = string.lower(s)
        local p1, p2 = string.find(sl, qLower, 1, true)
        if not p1 then return s end
        return string.sub(s, 1, p1 - 1) .. "|cfff3d25e" .. string.sub(s, p1, p2) .. "|r" .. string.sub(s, p2 + 1)
    end

    local y = 86
    local shown = 0
    local firstIdx = self.scrollOffset + 1
    local rightMargin = -18
    for i = firstIdx, #matched do
        local entry = matched[i]
        if y + entry.height <= MAX_CONTENT_Y then
            shown = shown + 1
            if entry.kind == "boolean" then
                entry.main:ClearAllPoints()
                entry.main:SetPoint("TOPLEFT", self.host, "TOPLEFT", 4, -y)
                entry.main:SetPoint("TOPRIGHT", self.host, "TOPRIGHT", rightMargin, -y)
                entry.main:SetChecked(ns.Api.ProfileStore:Get(entry.schema.section, entry.schema.key))
                if entry.main._label then
                    entry.main._label:SetText(HighlightMatch(entry.schema.label))
                end
                entry.main:Show()
                if entry.combatTag then
                    entry.combatTag:ClearAllPoints()
                    entry.combatTag:SetPoint("TOPRIGHT", self.host, "TOPRIGHT", rightMargin, -(y + 5))
                    entry.combatTag:Show()
                end
                if entry.descLbl then
                    entry.descLbl:ClearAllPoints()
                    entry.descLbl:SetPoint("TOPLEFT", self.host, "TOPLEFT", 28, -(y + 22))
                    entry.descLbl:SetPoint("TOPRIGHT", self.host, "TOPRIGHT", rightMargin, -(y + 22))
                    entry.descLbl:SetText(HighlightMatch(entry.schema.desc))
                    entry.descLbl:Show()
                end
            elseif entry.kind == "enum" then
                entry.label:ClearAllPoints()
                entry.label:SetPoint("TOPLEFT", self.host, "TOPLEFT", 4, -y)
                entry.label:SetText(HighlightMatch(entry.schema.label))
                entry.label:Show()
                if entry.combatTag then
                    entry.combatTag:ClearAllPoints()
                    entry.combatTag:SetPoint("TOPRIGHT", self.host, "TOPRIGHT", rightMargin, -y)
                    entry.combatTag:Show()
                end
                entry.main:ClearAllPoints()
                entry.main:SetPoint("TOPLEFT", self.host, "TOPLEFT", 4, -(y + 18))
                entry.main:SetPoint("TOPRIGHT", self.host, "TOPRIGHT", rightMargin, -(y + 18))
                entry.main:Show()
                if entry.descLbl then
                    entry.descLbl:ClearAllPoints()
                    entry.descLbl:SetPoint("TOPLEFT", self.host, "TOPLEFT", 6, -(y + 44))
                    entry.descLbl:SetPoint("TOPRIGHT", self.host, "TOPRIGHT", rightMargin, -(y + 44))
                    entry.descLbl:SetText(HighlightMatch(entry.schema.desc))
                    entry.descLbl:Show()
                end
            elseif entry.kind == "number" then
                entry.main:ClearAllPoints()
                entry.main:SetPoint("TOPLEFT", self.host, "TOPLEFT", 4, -y)
                entry.main:SetPoint("TOPRIGHT", self.host, "TOPRIGHT", rightMargin, -y)
                entry.main:Show()
                if entry.descLbl then
                    entry.descLbl:ClearAllPoints()
                    entry.descLbl:SetPoint("TOPLEFT", self.host, "TOPLEFT", 6, -(y + 40))
                    entry.descLbl:SetPoint("TOPRIGHT", self.host, "TOPRIGHT", rightMargin, -(y + 40))
                    entry.descLbl:SetText(HighlightMatch(entry.schema.desc))
                    entry.descLbl:Show()
                end
            end
            y = y + entry.height
        else
            break
        end
    end

    if self.scrollBar then
        self.scrollBar:SetMetrics(self.scrollOffset, (shown > 0 and shown or 1), #matched)
    end

    if self.overflowLbl then
        if #matched > shown then
            local lastIdx = firstIdx + shown - 1
            self.overflowLbl:SetText(
                "스크롤: " .. tostring(firstIdx) .. "-" .. tostring(lastIdx)
                .. " / " .. tostring(#matched) .. "개 항목 (마우스 휠 · 우측 스크롤바)"
            )
            self.overflowLbl:Show()
        else
            self.overflowLbl:Hide()
        end
    end
    self.visibleCount = shown
end

function SettingsPage:OnShow()
    self:RenderList("")
end

function SettingsPage:OnSearch(query)
    if tostring(query or "") ~= "" and self.activeSection ~= "all" then
        self.activeSection = "all"
        if self.tabBar and type(self.tabBar.SetValue) == "function" then
            self.tabBar:SetValue("all")
        end
    end
    self.scrollOffset = 0
    self:RenderList(query)
end
