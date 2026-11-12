-- Module: UI/SettingsPanel.lua
-- Responsibility: Unified /fs control panel (ESC special frame, 3 tabs: Modules+Detail Drawer, GJ Bridge, Gold Ledger) & slash router.
-- Dependencies: Core/Init.lua, Core/EventBus.lua, Core/ProfileManager.lua, Core/ModuleManager.lua, UI/Framework.lua.
-- Public API: ns.SettingsPanel (Show, Hide, Toggle, SelectTab, SelectDetailModule, Refresh, GetDrawerBooleanKeySet), ns.HandleSlashCommand.
-- Combat/Secret Safety: Contains zero secure child frames so ESC Hide never blocks in combat; enforces CanWrite() + UI rollback.
local _, ns = ...

local type, ipairs, pairs, tostring = type, ipairs, pairs, tostring
local string_format, string_lower, string_match = string.format, string.lower, string.match

local READONLY_MSG = "읽기 전용 프로필(미래 스키마)에서는 설정을 변경할 수 없습니다."

local MODULE_OPTION_SPECS = {
    Utility = {
        { section = "utility", key = "autoRepair", label = "자동 수리" },
        { section = "utility", key = "useGuildRepair", label = "길드 수리 우선" },
        { section = "utility", key = "autoSellJunk", label = "회색템 자동판매(≤12)" },
        { section = "utility", key = "fastAutoLoot", label = "고속 자동 전리품" },
        { section = "utility", key = "applyQoLCVars", label = "쿨다운 숫자 표시" },
        { section = "ui", key = "hudUnlocked", label = "HUD 이동 잠금해제" },
    },
    Inventory = {
        { section = "inventory", key = "showFreeSlotsHUD", label = "가방 여유 슬롯 HUD" },
        { section = "inventory", key = "showTooltipVendorPrice", label = "툴팁 상점가·묶음가" },
        { section = "inventory", key = "showTooltipItemLevel", label = "툴팁 아이템 레벨" },
        { section = "ui", key = "hudUnlocked", label = "HUD 이동 잠금해제" },
    },
    Map = {
        { section = "map", key = "showCoordsOnWorldMap", label = "월드맵 플레이어·커서 좌표" },
        { section = "map", key = "enableWaySlash", label = "/way 목표 화살표" },
    },
    Quest = {
        { section = "quest", key = "autoAccept", label = "자동 퀘스트 수락" },
        { section = "quest", key = "autoTurnIn", label = "자동 퀘스트 완료" },
        { section = "quest", key = "autoSuperTrack", label = "수락 시 자동 포커스" },
        { section = "quest", key = "trackerEnabled", label = "추적창 HUD 사용" },
        { section = "quest", key = "watchedOnly", label = "추적 중 퀘스트만" },
        { section = "quest", key = "currentZoneOnly", label = "현재 지역 필터" },
        { section = "quest", key = "trackerMinimized", label = "추적창 최소화" },
        { section = "quest", key = "trackerLocked", label = "추적창 위치 잠금" },
        { section = "quest", key = "hideDefaultTracker", label = "기본 추적기 숨김" },
    },
    Profession = {
        { section = "profession", key = "doubleClickFishing", label = "더블 우클릭 낚시" },
        { section = "profession", key = "fishingSoundBoost", label = "낚시 효과음 부스트" },
        { section = "profession", key = "trackGatherYield", label = "채집·전리품 집계" },
        { section = "profession", key = "remindMissingTracking", label = "채집 추적 누락 알림" },
    },
    Economy = {
        { section = "economy", key = "trackSessionGold", label = "세션 골드 원장 집계" },
        { section = "economy", key = "showAuctionatorPrice", label = "Auctionator 공존 연동" },
    },
    Combat = {
        { section = "combat", key = "remindMissingClassBuff", label = "9직업 비전투 버프 체크" },
        { section = "combat", key = "lowHealthAlert", label = "생명력 위험 경고 배너" },
        { section = "ui", key = "hudUnlocked", label = "HUD 이동 잠금해제" },
    },
}

local HUD_RESET_DEFAULTS = {
    { "hudUnlocked", false }, { "bagHudPoint", "BOTTOMRIGHT" }, { "bagHudRelPoint", "BOTTOMRIGHT" },
    { "bagHudX", -16 }, { "bagHudY", 46 }, { "healthAlertPoint", "CENTER" },
    { "healthAlertRelPoint", "CENTER" }, { "healthAlertX", 0 }, { "healthAlertY", 140 },
}

local SLASH_MODULE_DISPATCH = {
    protect = { "Utility", "HandleProtectCommand", true },
    sell = { "Utility", "ManualSellBatch", false },
    gold = { "Economy", "PrintLedgerSummary", false },
    yield = { "Profession", "PrintSessionYield", false },
    gather = { "Profession", "PrintSessionYield", false },
    bars = { "Utility", "CleanActionBarsNow", false },
    cleanbars = { "Utility", "CleanActionBarsNow", false },
    actionbars = { "Utility", "CleanActionBarsNow", false },
    quest = { "Quest", "HandleSlash", true },
    quests = { "Quest", "HandleSlash", true },
    q = { "Quest", "HandleSlash", true },
}

local SettingsPanel = {
    MODULE_OPTION_SPECS = MODULE_OPTION_SPECS,
    activeTab = "modules", selectedModule = "Quest",
    tabButtons = {}, tabPanels = {}, rows = {}, drawerCheckboxes = {},
    lastMemUpdateAt = -999,
}
ns.SettingsPanel = SettingsPanel

local function RegisterSpecialFrameOnce(frameName)
    local specials = _G.UISpecialFrames
    if type(specials) ~= "table" or type(frameName) ~= "string" or frameName == "" then return false end
    for i = 1, #specials do
        if specials[i] == frameName then return false end
    end
    specials[#specials + 1] = frameName
    return true
end

function SettingsPanel:GetDrawerBooleanKeySet()
    local set = {}
    for _, specs in pairs(MODULE_OPTION_SPECS) do
        for i = 1, #specs do set[specs[i].section .. "." .. specs[i].key] = true end
    end
    return set
end

function SettingsPanel:FormatVersionBanner()
    return string_format(
        "ForeverSuite  |cff94a3b8v%s · %s (%s)|r",
        tostring(ns.VERSION), tostring(ns.CLIENT_VERSION or "1.60.1"), tostring(ns.TARGET_TOC or 16001)
    )
end

function SettingsPanel:QueryPerformanceText()
    local now = ns.GetNow()
    local memText = "측정 불가"
    if _G.GetAddOnMemoryUsage then
        if (not ns.InCombat()) and ((now - self.lastMemUpdateAt) >= 5.0 or self.cachedMemKB == nil) then
            if _G.UpdateAddOnMemoryUsage then _G.UpdateAddOnMemoryUsage() end
            local kb = _G.GetAddOnMemoryUsage(ns.ADDON_NAME)
            if type(kb) == "number" and not ns.IsSecret(kb) then
                self.cachedMemKB, self.lastMemUpdateAt = kb, now
            end
        end
        if type(self.cachedMemKB) == "number" then
            memText = (self.cachedMemKB >= 1024) and string_format("%.2f MB", self.cachedMemKB / 1024) or string_format("%.0f KB", self.cachedMemKB)
        end
    end

    local cpuText = "측정 불가"
    if C_AddOnProfiler and C_AddOnProfiler.GetAddOnMetric and C_AddOnProfiler.IsEnabled then
        local metricEnum = (_G.Enum and _G.Enum.AddOnProfilerMetric and _G.Enum.AddOnProfilerMetric.RecentAverageTime) or nil
        if C_AddOnProfiler.IsEnabled() and metricEnum ~= nil then
            local avgMs = C_AddOnProfiler.GetAddOnMetric(ns.ADDON_NAME, metricEnum)
            if type(avgMs) == "number" and not ns.IsSecret(avgMs) then cpuText = string_format("%.3f ms/f", avgMs) end
        end
    end

    return string_format(
        "메모리: %s  |  평균 CPU: %s  |  활성 이벤트: %d  |  활성 Ticker: %d",
        memText, cpuText, ns.EventBus:ActiveEventCount(), ns.ModuleManager:TotalActiveTickers()
    )
end

local function ApplyPostToggleSideEffects(section, key)
    local inv = ns.ModuleManager:GetModule("Inventory")
    local comb = ns.ModuleManager:GetModule("Combat")
    if section == "ui" and key == "hudUnlocked" then
        if inv and inv.definition and inv.definition.SyncHUDLockState then inv.definition:SyncHUDLockState() end
        if comb and comb.definition and comb.definition.SyncAlertLockState then comb.definition:SyncAlertLockState() end
    elseif section == "inventory" and key == "showFreeSlotsHUD" then
        if inv and inv.definition and inv.definition.UpdateHUD then inv.definition:UpdateHUD() end
    elseif section == "combat" then
        if comb and comb.state == "ENABLED" and comb.definition then
            if key == "lowHealthAlert" and comb.definition.EvaluatePlayerHealth then
                comb.definition:EvaluatePlayerHealth()
            elseif key == "remindMissingClassBuff" then
                if ns.ProfileManager:Get("combat", "remindMissingClassBuff") then
                    if comb.definition.CheckOutOfCombatBuffs then comb.definition:CheckOutOfCombatBuffs() end
                else
                    comb.definition.lastBuffMissing = false
                end
            end
        end
    elseif section == "map" then
        local mapRec = ns.ModuleManager:GetModule("Map")
        if mapRec and mapRec.state == "ENABLED" and mapRec.definition and mapRec.definition.SyncSettings then
            mapRec.definition:SyncSettings(mapRec.ctx)
        end
    elseif section == "utility" and key == "applyQoLCVars" then
        local uRec = ns.ModuleManager:GetModule("Utility")
        if uRec and uRec.state == "ENABLED" and uRec.definition then
            if ns.ProfileManager:Get("utility", "applyQoLCVars") then
                if uRec.definition.ApplyQoLCVars then uRec.definition:ApplyQoLCVars() end
            else
                if uRec.definition.RestoreQoLCVars then uRec.definition:RestoreQoLCVars() end
            end
        end
    elseif section == "profession" then
        local pRec = ns.ModuleManager:GetModule("Profession")
        if pRec and pRec.state == "ENABLED" and pRec.definition then
            if key == "doubleClickFishing" and not ns.ProfileManager:Get("profession", "doubleClickFishing") then
                if pRec.definition.ClearFishingBindingSafe then pRec.definition:ClearFishingBindingSafe() end
            elseif key == "fishingSoundBoost" and pRec.definition.SyncFishingSoundBoost then
                pRec.definition:SyncFishingSoundBoost()
            end
        end
    elseif section == "quest" then
        local qMod = ns.ModuleManager:GetModule("Quest")
        if qMod and qMod.state == "ENABLED" and ns.QuestTracker and ns.QuestTracker.Refresh then ns.QuestTracker:Refresh() end
    end
end

function SettingsPanel:SelectTab(tabKey)
    if tabKey ~= "modules" and tabKey ~= "bridge" and tabKey ~= "ledger" then tabKey = "modules" end
    self.activeTab = tabKey
    for key, panel in pairs(self.tabPanels) do
        if panel then if key == tabKey then panel:Show() else panel:Hide() end end
    end
    for key, btn in pairs(self.tabButtons) do ns.UI.StylePillButton(btn, key == tabKey) end
    self:Refresh()
end

function SettingsPanel:SelectDetailModule(moduleName)
    if MODULE_OPTION_SPECS[moduleName] then self.selectedModule = moduleName; self:Refresh() end
end

local function BuildBridgeStatusText()
    local bridge = _G.ForeverSuite_GJBridge
    if type(bridge) ~= "table" then
        return "|cff94a3b8ForeverSuite_GJBridge 미로드 상태입니다.|r\n\n단독(Standalone) 모드로 ForeverSuite 전체 기능이 직접 동작합니다."
    end
    local out = string_format(
        "브리지 상태: |cff4ade80%s|r  (Upstream Pin: v%s · Bridge v%s)\n\n|cffffd23f[개인화 브랜딩 오버라이드 6종]|r",
        tostring(bridge.status or "—"), tostring(bridge.UPSTREAM_PIN or "—"), tostring(bridge.VERSION or "—")
    )
    local targets = type(bridge.targets) == "table" and bridge.targets or {}
    for _, k in ipairs({ "sayPrefix", "youtubeLink", "homeScreen", "launcherIcon", "tradeWhisper", "questSound" }) do
        out = out .. string_format("\n • %-14s : %s", k, tostring(targets[k] or "—"))
    end
    out = out .. "\n\n|cffffd23f[단일 소유자 중재 (Single-Owner Arbitration) 5종]|r"
    local own = type(bridge.ownership) == "table" and bridge.ownership or {}
    for _, k in ipairs({ "repair", "sell", "questAuto", "fishing", "way" }) do
        out = out .. string_format("\n • %-14s : %s", k, tostring(own[k] or "—"))
    end
    return out
end

local function BuildLedgerStatusText()
    local econRec = ns.ModuleManager:GetModule("Economy")
    if not econRec or econRec.state ~= "ENABLED" or not econRec.definition then
        return "세션 골드 원장: |cff94a3b8— (Economy 모듈 비활성 또는 외부 애드온 양보 상태)|r"
    end
    if not ns.ProfileManager:Get("economy", "trackSessionGold") then
        return "세션 골드 원장: |cff94a3b8— (세션 골드 집계가 꺼져 있습니다)|r"
    end
    local econ = econRec.definition
    if not econ.initializedBaseline then return "세션 골드 원장: |cff94a3b8— (초기 기준선 대기 중)|r" end
    return string_format(
        "|cffffd23f[현재 세션 실시간 골드 수지 원장]|r\n\n"
            .. " • 세션 순증감   : %s\n • 상점 잡템 판매 : %s\n • 장비 수리 지출 : %s\n • 퀘스트 보상금  : %s\n • 기타(우편/거래): %s",
        ns.FormatMoney(econ:GetNetDelta()), ns.FormatMoney(econ.ledger.vendorSell),
        ns.FormatMoney(econ.ledger.repair), ns.FormatMoney(econ.ledger.quest), ns.FormatMoney(econ.ledger.other)
    )
end

local function CreateInfoTabPanel(parent, btnLabel, btnWidth, onActionClick)
    local panel = ns.UI.CreatePanel(nil, parent, 604, 446, true)
    if not panel then return nil, nil end
    panel:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, -88)
    local bodyLbl = ns.UI.CreateLabel(panel, "", "GameFontHighlightSmall", ns.UI.COLORS.TEXT)
    if bodyLbl then
        bodyLbl:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
        if bodyLbl.SetJustifyH then bodyLbl:SetJustifyH("LEFT") end
    end
    local actionBtn = ns.UI.CreateButton(panel, btnLabel, btnWidth, 24, onActionClick)
    if actionBtn then actionBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 16, 14) end
    panel:Hide()
    return panel, bodyLbl
end

local function DispatchModuleMethod(modName, methodName, arg)
    local rec = ns.ModuleManager:GetModule(modName)
    if rec and rec.definition and rec.definition[methodName] then
        return rec.definition[methodName](rec.definition, arg)
    end
    ns.Warn(modName .. " 모듈이 비활성화 상태입니다.")
end

function SettingsPanel:EnsureFrame()
    RegisterSpecialFrameOnce("ForeverSuiteSettingsFrame")
    if self.frame then return self.frame end
    local f = ns.UI.CreatePanel("ForeverSuiteSettingsFrame", _G.UIParent, 640, 590, false)
    if not f then return nil end
    f:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 20)
    if f.SetClampedToScreen then f:SetClampedToScreen(true) end
    if f.SetMovable then
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", function(sf) if not ns.InCombat() and sf.StartMoving then sf:StartMoving() end end)
        f:SetScript("OnDragStop", function(sf) if sf.StopMovingOrSizing then sf:StopMovingOrSizing() end end)
    end

    local title = ns.UI.CreateLabel(f, self:FormatVersionBanner(), "GameFontNormalLarge", ns.UI.COLORS.ACCENT)
    if title then title:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -14); self.titleLabel = title end
    local closeBtn = ns.UI.CreateButton(f, "닫기 (ESC)", 78, 22, function() SettingsPanel:Hide() end)
    if closeBtn then closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -12) end
    local perf = ns.UI.CreateLabel(f, "성능 지표 대기 중...", "GameFontHighlightSmall", ns.UI.COLORS.MUTED)
    if perf then perf:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -38); self.perfLabel = perf end

    local prevTabBtn = nil
    for _, ts in ipairs({
        { key = "modules", label = "모듈 · 세부설정", width = 132 },
        { key = "bridge", label = "GJ 브리지 상태", width = 126 },
        { key = "ledger", label = "골드 원장", width = 106 },
    }) do
        local tKey = ts.key
        local tb = ns.UI.CreatePillButton(f, ts.label, ts.width, 22, nil, nil, function() SettingsPanel:SelectTab(tKey) end)
        if tb then
            if not prevTabBtn then tb:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -60) else tb:SetPoint("LEFT", prevTabBtn, "RIGHT", 6, 0) end
            self.tabButtons[tKey], prevTabBtn = tb, tb
        end
    end

    local modPanel = _G.CreateFrame("Frame", nil, f)
    modPanel:SetSize(604, 456)
    modPanel:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -88)
    self.tabPanels.modules = modPanel

    local yOffset = 0
    for i, rec in ipairs(ns.ModuleManager:ListModules()) do
        local card = ns.UI.CreatePanel(nil, modPanel, 604, 42, true)
        if card then
            card:SetPoint("TOPLEFT", modPanel, "TOPLEFT", 0, yOffset)
            local modName = rec.name
            local chk
            chk = ns.UI.CreateCheckbox(card, "[" .. rec.priority .. "] " .. rec.title, ns.ProfileManager:IsModuleEnabled(modName), function(checked)
                if not ns.ProfileManager:CanWrite() then
                    local liveRec = ns.ModuleManager:GetModule(modName)
                    if chk then chk:SetChecked(liveRec and liveRec.state == "ENABLED") end
                    ns.Warn(READONLY_MSG)
                    return
                end
                ns.ProfileManager:SetModuleEnabled(modName, checked, "account")
                if checked then ns.ModuleManager:EnableModule(modName, true) else ns.ModuleManager:DisableModule(modName) end
                SettingsPanel:Refresh()
            end)
            if chk then chk:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -5) end
            local detailBtn = ns.UI.CreateButton(card, "세부 ▾", 54, 18, function() SettingsPanel:SelectDetailModule(modName) end)
            if detailBtn then detailBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -5) end
            local badge = ns.UI.CreateLabel(card, "", "GameFontNormalSmall", ns.UI.COLORS.TEXT)
            if badge then badge:SetPoint("RIGHT", detailBtn, "LEFT", -10, 0) end
            local desc = ns.UI.CreateLabel(card, rec.description, "GameFontHighlightSmall", ns.UI.COLORS.MUTED)
            if desc then desc:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 36, 4) end
            self.rows[i] = { moduleName = modName, checkbox = chk, descLabel = desc, badgeLabel = badge, detailBtn = detailBtn }
            yOffset = yOffset - 45
        end
    end

    local drawer = ns.UI.CreatePanel(nil, modPanel, 604, 134, true)
    if drawer then
        drawer:SetPoint("BOTTOMLEFT", modPanel, "BOTTOMLEFT", 0, 0)
        local dTitle = ns.UI.CreateLabel(drawer, "세부 설정", "GameFontNormalSmall", ns.UI.COLORS.ACCENT)
        if dTitle then dTitle:SetPoint("TOPLEFT", drawer, "TOPLEFT", 12, -8); self.drawerTitle = dTitle end
        for slotIdx = 1, 9 do
            local col = (slotIdx - 1) % 3
            local rIdx = (slotIdx - 1 - col) / 3
            local optChk
            optChk = ns.UI.CreateCheckbox(drawer, "", false, function(checked)
                local spec = optChk and optChk._fsSpec
                if not spec then return end
                if not ns.ProfileManager:CanWrite() then
                    optChk:SetChecked(ns.ProfileManager:Get(spec.section, spec.key) and true or false)
                    ns.Warn(READONLY_MSG)
                    return
                end
                ns.ProfileManager:Set(spec.section, spec.key, checked and true or false, "account")
                ApplyPostToggleSideEffects(spec.section, spec.key)
                SettingsPanel:Refresh()
            end)
            if optChk then
                optChk:SetPoint("TOPLEFT", drawer, "TOPLEFT", 12 + (col * 196), -(30 + (rIdx * 30)))
                self.drawerCheckboxes[slotIdx] = optChk
            end
        end
    end

    self.tabPanels.bridge, self.bridgeSummaryLabel = CreateInfoTabPanel(f, "소유권 재동기화 (/fsgj sync)", 186, function()
        local bridge = _G.ForeverSuite_GJBridge
        if type(bridge) == "table" and type(bridge.SyncOwnership) == "function" then
            bridge.SyncOwnership()
            if type(bridge.TrySkinLauncher) == "function" then bridge.TrySkinLauncher() end
            ns.Print("GJ 브리지 단일 소유권 및 런처 상태 재동기화 완료.")
        end
        SettingsPanel:Refresh()
    end)

    self.tabPanels.ledger, self.ledgerSummaryLabel = CreateInfoTabPanel(f, "세션 기준선 초기화", 150, function()
        local econ = ns.ModuleManager:GetModule("Economy")
        if econ and econ.state == "ENABLED" and econ.definition and econ.definition.ResetSessionBaseline then
            econ.definition:ResetSessionBaseline()
            ns.Print("세션 골드 원장 기준선을 현재 보유 골드로 초기화했습니다.")
        end
        SettingsPanel:Refresh()
    end)

    local prevFooterBtn = nil
    for _, fs in ipairs({
        { label = "API 프로브", w = 92, fn = function() local r = ns.RunClientProbe(); ns.Print(string_format("클라이언트 프로브 완료: v%s (%s, TOC %d)", r.version, r.build, r.tocVersion)); SettingsPanel:Refresh() end },
        { label = "가방 정렬", w = 82, fn = function() if C_Container and C_Container.SortBags and not ns.InCombat() then C_Container.SortBags() end end },
        { label = "스킬창 정리", w = 92, fn = function() DispatchModuleMethod("Utility", "CleanActionBarsNow") end },
        { label = "퀘스트: 지역별", w = 118, saveKey = "questModeBtn", fn = function() DispatchModuleMethod("Quest", "HandleSlash", "mode"); SettingsPanel:Refresh() end },
        { label = "HUD 이동", w = 82, fn = function() ns.HandleSlashCommand("move"); SettingsPanel:Refresh() end },
    }) do
        local fb = ns.UI.CreateButton(f, fs.label, fs.w, 24, fs.fn)
        if fb then
            if not prevFooterBtn then fb:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 12) else fb:SetPoint("LEFT", prevFooterBtn, "RIGHT", 6, 0) end
            if fs.saveKey then self[fs.saveKey] = fb end
            prevFooterBtn = fb
        end
    end
    local refreshBtn = ns.UI.CreateButton(f, "새로고침", 82, 24, function() SettingsPanel:Refresh() end)
    if refreshBtn then refreshBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -18, 12) end

    f:Hide()
    self.frame = f
    self:SelectTab(self.activeTab)
    return f
end

function SettingsPanel:Refresh()
    local f = self:EnsureFrame()
    if not f then return end
    if self.titleLabel then self.titleLabel:SetText(self:FormatVersionBanner()) end
    if self.perfLabel then self.perfLabel:SetText(self:QueryPerformanceText()) end
    if self.questModeBtn and self.questModeBtn._fsLabel then
        local qMode = ns.ProfileManager:Get("quest", "groupMode")
        self.questModeBtn._fsLabel:SetText("퀘스트: " .. ((qMode == "level") and "레벨별" or "지역별"))
    end
    for _, row in ipairs(self.rows) do
        local rec = ns.ModuleManager:GetModule(row.moduleName)
        if rec then
            if row.checkbox then row.checkbox:SetChecked(rec.state == "ENABLED") end
            if row.badgeLabel then row.badgeLabel:SetText(ns.UI.FormatStateBadge(rec.state, rec.yieldedBy)) end
            if row.descLabel then
                if rec.state == "FAULTED" and rec.lastError then
                    local firstLine = string_match(rec.lastError, "^([^\n\r]+)") or rec.lastError
                    row.descLabel:SetText("|cfff87171오류 격리: " .. firstLine .. "|r")
                else
                    row.descLabel:SetText(rec.description)
                end
            end
        end
    end

    local specs = MODULE_OPTION_SPECS[self.selectedModule] or MODULE_OPTION_SPECS.Quest
    if self.drawerTitle then self.drawerTitle:SetText("세부 설정 — [" .. tostring(self.selectedModule) .. "]") end
    for idx = 1, #self.drawerCheckboxes do
        local chk, spec = self.drawerCheckboxes[idx], specs[idx]
        if chk then
            if spec then
                chk._fsSpec = spec
                if chk._fsLabel then chk._fsLabel:SetText(spec.label) end
                chk:SetChecked(ns.ProfileManager:Get(spec.section, spec.key) and true or false)
                chk:Show()
            else
                chk._fsSpec = nil
                chk:Hide()
            end
        end
    end
    if self.bridgeSummaryLabel then self.bridgeSummaryLabel:SetText(BuildBridgeStatusText()) end
    if self.ledgerSummaryLabel then self.ledgerSummaryLabel:SetText(BuildLedgerStatusText()) end
end

function SettingsPanel:Show()
    local f = self:EnsureFrame()
    if f then f:Show(); self:Refresh() end
end

function SettingsPanel:Hide()
    if self.frame then self.frame:Hide() end
end

function SettingsPanel:Toggle()
    local f = self:EnsureFrame()
    if f then if f.IsShown and f:IsShown() then self:Hide() else self:Show() end end
end

function SettingsPanel:RegisterBlizzardSettingsCategory()
    if _G.Settings and _G.Settings.RegisterCanvasLayoutCategory and _G.Settings.RegisterAddOnCategory and _G.CreateFrame then
        local canvas = _G.CreateFrame("Frame", nil, _G.UIParent)
        canvas.name = "ForeverSuite"
        local openBtn = ns.UI.CreateButton(canvas, "ForeverSuite 통합 제어판 열기 (/fs)", 240, 30, function() SettingsPanel:Show() end)
        if openBtn then openBtn:SetPoint("TOPLEFT", canvas, "TOPLEFT", 20, -20) end
        _G.Settings.RegisterAddOnCategory(_G.Settings.RegisterCanvasLayoutCategory(canvas, "ForeverSuite"))
    end
end

local function PrintStatusSummary()
    ns.Print("버전 v" .. ns.VERSION .. " | 스키마 v" .. tostring(ns.ProfileManager.SCHEMA_VERSION) .. (ns.ProfileManager.readOnly and " (READ-ONLY)" or ""))
    for _, rec in ipairs(ns.ModuleManager:ListModules()) do
        ns.Print(" - " .. rec.name .. ": " .. ns.UI.FormatStateBadge(rec.state, rec.yieldedBy))
    end
end

local function HandleMoveCommand(rest)
    if not ns.ProfileManager:CanWrite() then
        ns.Warn("읽기 전용 프로필(미래 스키마)에서는 HUD 위치를 변경할 수 없습니다.")
        return false
    end
    local sub = string_lower(string_match(tostring(rest or ""), "^%s*(%S*)") or "")
    if sub == "reset" then
        for _, kv in ipairs(HUD_RESET_DEFAULTS) do ns.ProfileManager:Set("ui", kv[1], kv[2], "account") end
        ApplyPostToggleSideEffects("ui", "hudUnlocked")
        ns.Print("가방·생명력 HUD 위치를 기본값으로 초기화하고 잠갔습니다.")
        return true
    end
    local nxt = not (ns.ProfileManager:Get("ui", "hudUnlocked") and true or false)
    ns.ProfileManager:Set("ui", "hudUnlocked", nxt, "account")
    ApplyPostToggleSideEffects("ui", "hudUnlocked")
    ns.Print("HUD 이동 모드: " .. (nxt and "잠금 해제 (마우스 드래그 가능)" or "잠금 완료 (클릭 투과 보호)"))
    return true
end

function ns.HandleSlashCommand(rawMsg)
    local msg = string_match(tostring(rawMsg or ""), "^%s*(.-)%s*$") or ""
    local cmd, rest = string_match(msg, "^(%S+)%s*(.*)$")
    cmd = cmd and string_lower(cmd) or ""

    local route = SLASH_MODULE_DISPATCH[cmd]
    if cmd == "" or cmd == "ui" or cmd == "config" then
        SettingsPanel:Toggle()
    elseif cmd == "status" then
        PrintStatusSummary()
    elseif cmd == "perf" then
        ns.Print(SettingsPanel:QueryPerformanceText())
    elseif cmd == "probe" then
        local rep = ns.RunClientProbe()
        ns.Print(string_format("API 프로브 저장 완료: Build=%s, TOC=%d", rep.build, rep.tocVersion))
    elseif (cmd == "enable" or cmd == "disable") and rest ~= "" then
        if not ns.ProfileManager:CanWrite() then
            ns.Warn("읽기 전용 프로필(미래 스키마)에서는 모듈 상태를 변경할 수 없습니다.")
            return
        end
        local flag = cmd == "enable"
        ns.ProfileManager:SetModuleEnabled(rest, flag, "account")
        if flag then
            ns.Print("모듈 활성화 요청 [" .. rest .. "] → " .. (ns.ModuleManager:EnableModule(rest, true) and "ENABLED" or "YIELDED/FAILED"))
        else
            ns.ModuleManager:DisableModule(rest)
            ns.Print("모듈 비활성화 완료 [" .. rest .. "]")
        end
    elseif cmd == "move" then
        HandleMoveCommand(rest)
    elseif route then
        DispatchModuleMethod(route[1], route[2], route[3] and rest or nil)
    else
        ns.Print("명령어: /fs [ui | status | perf | probe | quest | gold | gather | protect | sell | move | bars | enable <모듈> | disable <모듈>]")
    end
end

function _G.ForeverSuite_OnAddonCompartmentClick(_, buttonName)
    if buttonName == "RightButton" then PrintStatusSummary() else SettingsPanel:Toggle() end
end

function _G.ForeverSuite_OnAddonCompartmentEnter(_, menuButtonFrame)
    if _G.GameTooltip and menuButtonFrame then
        _G.GameTooltip:SetOwner(menuButtonFrame, "ANCHOR_LEFT")
        _G.GameTooltip:AddLine("ForeverSuite v" .. ns.VERSION)
        _G.GameTooltip:AddLine("좌클릭: 통합 설정 열기 | 우클릭: 모듈 상태 요약", 0.8, 0.8, 0.8)
        _G.GameTooltip:Show()
    end
end

function _G.ForeverSuite_OnAddonCompartmentLeave()
    if _G.GameTooltip then _G.GameTooltip:Hide() end
end

ns.EventBus:RegisterEvent("__CORE__", "ADDON_LOADED", function(_, addonName)
    if addonName == ns.ADDON_NAME then ns.ProfileManager:Init() else ns.ModuleManager:OnExternalAddonLoaded(addonName) end
end)

ns.EventBus:RegisterEvent("__CORE__", "PLAYER_LOGIN", function()
    if not ns.ProfileManager.accountDB then ns.ProfileManager:Init() end
    if not _G.SLASH_FOREVERSUITE1 then
        _G.SLASH_FOREVERSUITE1, _G.SLASH_FOREVERSUITE2 = "/fs", "/forever"
        if type(_G.SlashCmdList) == "table" then _G.SlashCmdList["FOREVERSUITE"] = ns.HandleSlashCommand end
    end
    ns.ModuleManager:BootstrapAll()
    SettingsPanel:RegisterBlizzardSettingsCategory()
end)

ns.EventBus:RegisterEvent("__CORE__", "PLAYER_REGEN_ENABLED", function() ns.CombatQueue:Flush() end)
