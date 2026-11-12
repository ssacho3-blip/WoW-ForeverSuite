local _, ns = ...

local type = type
local ipairs = ipairs
local tostring = tostring
local string_format = string.format
local string_lower = string.lower
local string_match = string.match

local SettingsPanel = {
    frame = nil,
    perfLabel = nil,
    questModeBtn = nil,
    rows = {},
    lastMemUpdateAt = -999,
    cachedMemKB = nil,
}
ns.SettingsPanel = SettingsPanel

function SettingsPanel:QueryPerformanceText()
    local now = ns.GetNow()
    local memText = "측정 불가"
    if _G.GetAddOnMemoryUsage then
        if (not ns.InCombat()) and ((now - self.lastMemUpdateAt) >= 5.0 or self.cachedMemKB == nil) then
            if _G.UpdateAddOnMemoryUsage and not ns.InCombat() then
                _G.UpdateAddOnMemoryUsage()
            end
            local kb = _G.GetAddOnMemoryUsage(ns.ADDON_NAME)
            if type(kb) == "number" and not ns.IsSecret(kb) then
                self.cachedMemKB = kb
                self.lastMemUpdateAt = now
            end
        end
        if type(self.cachedMemKB) == "number" then
            if self.cachedMemKB >= 1024 then
                memText = string_format("%.2f MB", self.cachedMemKB / 1024)
            else
                memText = string_format("%.0f KB", self.cachedMemKB)
            end
        end
    end

    local cpuText = "측정 불가"
    if C_AddOnProfiler and C_AddOnProfiler.GetAddOnMetric and C_AddOnProfiler.IsEnabled then
        local enabled = C_AddOnProfiler.IsEnabled() and true or false
        local metricEnum = (_G.Enum and _G.Enum.AddOnProfilerMetric and _G.Enum.AddOnProfilerMetric.RecentAverageTime) or nil
        if enabled and metricEnum ~= nil then
            local avgMs = C_AddOnProfiler.GetAddOnMetric(ns.ADDON_NAME, metricEnum)
            if type(avgMs) == "number" and not ns.IsSecret(avgMs) then
                cpuText = string_format("%.3f ms/f", avgMs)
            end
        end
    end

    local activeTickers = ns.ModuleManager:TotalActiveTickers()
    local activeEvents = ns.EventBus:ActiveEventCount()
    return string_format("메모리: %s  |  평균 CPU: %s  |  활성 이벤트: %d  |  활성 Ticker: %d", memText, cpuText, activeEvents, activeTickers)
end

function SettingsPanel:EnsureFrame()
    if self.frame then
        return self.frame
    end
    local f = ns.UI.CreatePanel("ForeverSuiteSettingsFrame", _G.UIParent, 620, 490, false)
    if not f then
        return nil
    end
    f:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 20)
    if f.SetMovable then
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", function(selfFrame)
            if not ns.InCombat() and selfFrame.StartMoving then
                selfFrame:StartMoving()
            end
        end)
        f:SetScript("OnDragStop", function(selfFrame)
            if selfFrame.StopMovingOrSizing then
                selfFrame:StopMovingOrSizing()
            end
        end)
    end

    local title = ns.UI.CreateLabel(f, "ForeverSuite  |cff94a3b8v" .. ns.VERSION .. " · WoW Forever (11701)|r", "GameFontNormalLarge", ns.UI.COLORS.ACCENT)
    if title then
        title:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -16)
    end

    local closeBtn = ns.UI.CreateButton(f, "닫기", 58, 22, function()
        SettingsPanel:Hide()
    end)
    if closeBtn then
        closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -14)
    end

    local perf = ns.UI.CreateLabel(f, "성능 지표 대기 중...", "GameFontHighlightSmall", ns.UI.COLORS.MUTED)
    if perf then
        perf:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -44)
        self.perfLabel = perf
    end

    local modules = ns.ModuleManager:ListModules()
    local yOffset = -74
    for i, rec in ipairs(modules) do
        local card = ns.UI.CreatePanel(nil, f, 584, 48, true)
        if card then
            card:SetPoint("TOPLEFT", f, "TOPLEFT", 18, yOffset)
            local modName = rec.name
            local chk = ns.UI.CreateCheckbox(card, "[" .. rec.priority .. "] " .. rec.title, ns.ProfileManager:IsModuleEnabled(modName), function(checked)
                if not ns.ProfileManager:CanWrite() then
                    ns.Warn("읽기 전용 프로필(미래 스키마)에서는 설정을 저장할 수 없습니다.")
                else
                    ns.ProfileManager:SetModuleEnabled(modName, checked, "account")
                end
                if checked then
                    ns.ModuleManager:EnableModule(modName, true)
                else
                    ns.ModuleManager:DisableModule(modName)
                end
                SettingsPanel:Refresh()
            end)
            if chk then
                chk:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -8)
            end

            local desc = ns.UI.CreateLabel(card, rec.description, "GameFontHighlightSmall", ns.UI.COLORS.MUTED)
            if desc then
                desc:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 38, 7)
            end

            local badge = ns.UI.CreateLabel(card, "", "GameFontNormalSmall", ns.UI.COLORS.TEXT)
            if badge then
                badge:SetPoint("TOPRIGHT", card, "TOPRIGHT", -14, -10)
            end

            self.rows[i] = {
                moduleName = modName,
                checkbox = chk,
                descLabel = desc,
                badgeLabel = badge,
            }
            yOffset = yOffset - 54
        end
    end

    local probeBtn = ns.UI.CreateButton(f, "API 프로브", 106, 24, function()
        local rep = ns.RunClientProbe()
        ns.Print(string_format("클라이언트 프로브 완료: v%s (%s, TOC %d)", rep.version, rep.build, rep.tocVersion))
        SettingsPanel:Refresh()
    end)
    if probeBtn then
        probeBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 14)
    end

    local sortBtn = ns.UI.CreateButton(f, "가방 정렬", 88, 24, function()
        if C_Container and C_Container.SortBags and not ns.InCombat() then
            C_Container.SortBags()
        end
    end)
    if sortBtn then
        sortBtn:SetPoint("LEFT", probeBtn, "RIGHT", 6, 0)
    end

    local cleanBarsBtn = ns.UI.CreateButton(f, "스킬창 정리", 104, 24, function()
        local util = ns.ModuleManager:GetModule("Utility")
        if util and util.definition and util.definition.CleanActionBarsNow then
            util.definition:CleanActionBarsNow()
        end
    end)
    if cleanBarsBtn then
        cleanBarsBtn:SetPoint("LEFT", sortBtn, "RIGHT", 6, 0)
    end

    local questModeBtn = ns.UI.CreateButton(f, "퀘스트: 지역별", 132, 24, function()
        local qMod = ns.ModuleManager:GetModule("Quest")
        if qMod and qMod.definition and qMod.definition.HandleSlash then
            qMod.definition:HandleSlash("mode")
            SettingsPanel:Refresh()
        end
    end)
    if questModeBtn then
        questModeBtn:SetPoint("LEFT", cleanBarsBtn, "RIGHT", 6, 0)
        self.questModeBtn = questModeBtn
    end

    local refreshBtn = ns.UI.CreateButton(f, "지표 새로고침", 104, 24, function()
        SettingsPanel:Refresh()
    end)
    if refreshBtn then
        refreshBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -18, 14)
    end

    f:Hide()
    self.frame = f
    return f
end

function SettingsPanel:Refresh()
    local f = self:EnsureFrame()
    if not f then
        return
    end
    if self.perfLabel then
        self.perfLabel:SetText(self:QueryPerformanceText())
    end
    if self.questModeBtn and self.questModeBtn._fsLabel then
        local qMode = ns.ProfileManager:Get("quest", "groupMode")
        self.questModeBtn._fsLabel:SetText("퀘스트: " .. ((qMode == "level") and "레벨별" or "지역별"))
    end
    for _, row in ipairs(self.rows) do
        local rec = ns.ModuleManager:GetModule(row.moduleName)
        if rec then
            if row.checkbox then
                row.checkbox:SetChecked(rec.state == "ENABLED")
            end
            if row.badgeLabel then
                row.badgeLabel:SetText(ns.UI.FormatStateBadge(rec.state, rec.yieldedBy))
            end
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
end

function SettingsPanel:Show()
    local f = self:EnsureFrame()
    if not f then
        return
    end
    f:Show()
    self:Refresh()
end

function SettingsPanel:Hide()
    if self.frame then
        self.frame:Hide()
    end
end

function SettingsPanel:Toggle()
    local f = self:EnsureFrame()
    if not f then
        return
    end
    if f.IsShown and f:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end

function SettingsPanel:RegisterBlizzardSettingsCategory()
    if _G.Settings and _G.Settings.RegisterCanvasLayoutCategory and _G.Settings.RegisterAddOnCategory and _G.CreateFrame then
        local canvas = _G.CreateFrame("Frame", nil, _G.UIParent)
        canvas.name = "ForeverSuite"
        local openBtn = ns.UI.CreateButton(canvas, "ForeverSuite 통합 제어판 열기 (/fs)", 240, 30, function()
            SettingsPanel:Show()
        end)
        if openBtn then
            openBtn:SetPoint("TOPLEFT", canvas, "TOPLEFT", 20, -20)
        end
        local category = _G.Settings.RegisterCanvasLayoutCategory(canvas, "ForeverSuite")
        _G.Settings.RegisterAddOnCategory(category)
    end
end

local function PrintStatusSummary()
    ns.Print("버전 v" .. ns.VERSION .. " | 스키마 v" .. tostring(ns.ProfileManager.SCHEMA_VERSION) .. (ns.ProfileManager.readOnly and " (READ-ONLY)" or ""))
    for _, rec in ipairs(ns.ModuleManager:ListModules()) do
        ns.Print(" - " .. rec.name .. ": " .. ns.UI.FormatStateBadge(rec.state, rec.yieldedBy))
    end
end

function ns.HandleSlashCommand(rawMsg)
    local msg = string_match(tostring(rawMsg or ""), "^%s*(.-)%s*$") or ""
    local cmd, rest = string_match(msg, "^(%S+)%s*(.*)$")
    cmd = cmd and string_lower(cmd) or ""

    if cmd == "" or cmd == "ui" or cmd == "config" then
        SettingsPanel:Toggle()
    elseif cmd == "status" then
        PrintStatusSummary()
    elseif cmd == "perf" then
        ns.Print(SettingsPanel:QueryPerformanceText())
    elseif cmd == "probe" then
        local rep = ns.RunClientProbe()
        ns.Print(string_format("API 프로브 저장 완료: Build=%s, TOC=%d", rep.build, rep.tocVersion))
    elseif cmd == "enable" and rest ~= "" then
        ns.ProfileManager:SetModuleEnabled(rest, true, "account")
        local ok = ns.ModuleManager:EnableModule(rest, true)
        ns.Print("모듈 활성화 요청 [" .. rest .. "] → " .. (ok and "ENABLED" or "YIELDED/FAILED"))
    elseif cmd == "disable" and rest ~= "" then
        ns.ProfileManager:SetModuleEnabled(rest, false, "account")
        ns.ModuleManager:DisableModule(rest)
        ns.Print("모듈 비활성화 완료 [" .. rest .. "]")
    elseif cmd == "gold" then
        local econ = ns.ModuleManager:GetModule("Economy")
        if econ and econ.definition and econ.definition.PrintLedgerSummary then
            econ.definition:PrintLedgerSummary()
        else
            ns.Warn("Economy 모듈이 비활성화 상태입니다.")
        end
    elseif cmd == "yield" or cmd == "gather" then
        local prof = ns.ModuleManager:GetModule("Profession")
        if prof and prof.definition and prof.definition.PrintSessionYield then
            prof.definition:PrintSessionYield()
        else
            ns.Warn("Profession 모듈이 비활성화 상태입니다.")
        end
    elseif cmd == "bars" or cmd == "cleanbars" or cmd == "actionbars" then
        local util = ns.ModuleManager:GetModule("Utility")
        if util and util.definition and util.definition.CleanActionBarsNow then
            util.definition:CleanActionBarsNow()
        else
            ns.Warn("Utility 모듈이 비활성화 상태입니다.")
        end
    elseif cmd == "quest" or cmd == "quests" or cmd == "q" then
        local qMod = ns.ModuleManager:GetModule("Quest")
        if qMod and qMod.definition and qMod.definition.HandleSlash then
            qMod.definition:HandleSlash(rest)
        else
            ns.Warn("Quest 모듈이 비활성화 상태입니다.")
        end
    else
        ns.Print("명령어: /fs [ui | status | perf | probe | quest | gold | gather | bars | enable <모듈> | disable <모듈>]")
    end
end

-- TOC Addon Compartment global entrypoints (WoW Forever 11701 native minimap compartment)
function _G.ForeverSuite_OnAddonCompartmentClick(_, buttonName)
    if buttonName == "RightButton" then
        PrintStatusSummary()
    else
        SettingsPanel:Toggle()
    end
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
    if _G.GameTooltip then
        _G.GameTooltip:Hide()
    end
end

-- Core System Bootstrap Registrations
ns.EventBus:RegisterEvent("__CORE__", "ADDON_LOADED", function(_, addonName)
    if addonName == ns.ADDON_NAME then
        ns.ProfileManager:Init()
    else
        ns.ModuleManager:OnExternalAddonLoaded(addonName)
    end
end)

ns.EventBus:RegisterEvent("__CORE__", "PLAYER_LOGIN", function()
    if not ns.ProfileManager.accountDB then
        ns.ProfileManager:Init()
    end
    if not _G.SLASH_FOREVERSUITE1 then
        _G.SLASH_FOREVERSUITE1 = "/fs"
        _G.SLASH_FOREVERSUITE2 = "/forever"
        if type(_G.SlashCmdList) == "table" then
            _G.SlashCmdList["FOREVERSUITE"] = ns.HandleSlashCommand
        end
    end
    ns.ModuleManager:BootstrapAll()
    SettingsPanel:RegisterBlizzardSettingsCategory()
end)

ns.EventBus:RegisterEvent("__CORE__", "PLAYER_REGEN_ENABLED", function()
    ns.CombatQueue:Flush()
end)
