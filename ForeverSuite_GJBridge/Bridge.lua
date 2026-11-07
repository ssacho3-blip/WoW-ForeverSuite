local ADDON_NAME, ns = ...

ns = ns or {}
_G.ForeverSuite_GJBridge = ns

local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local pcall = pcall
local string_gsub = string.gsub
local string_lower = string.lower
local string_match = string.match

ns.ADDON_NAME = ADDON_NAME or "ForeverSuite_GJBridge"
ns.VERSION = "0.2.0"
ns.UPSTREAM_PIN = "5.0.132"
ns.PERSONAL_ICON_ID = 134063
ns.PERSONAL_PREFIX = "|cffffd36a[포에버]:|r "
ns.CLEAN_QUEST_ALARM_SOUND = "dingdong"

ns.status = "UNINITIALIZED"
ns.targets = {
    sayPrefix = "MISSING",
    youtubeLink = "MISSING",
    homeScreen = "MISSING",
    launcherIcon = "MISSING",
    tradeWhisper = "MISSING",
    questSound = "MISSING",
}
ns.ownership = {
    repair = "OWNED_BY_FS",
    sell = "OWNED_BY_FS",
    questAuto = "OWNED_BY_FS",
    fishing = "OWNED_BY_FS",
    way = "OWNED_BY_FS",
}

local function PrintBridge(msg)
    local text = "|cffd4af37[FS-GJBridge]|r " .. tostring(msg or "")
    if _G.DEFAULT_CHAT_FRAME and _G.DEFAULT_CHAT_FRAME.AddMessage then
        _G.DEFAULT_CHAT_FRAME:AddMessage(text)
    end
end
ns.Print = PrintBridge

local function EvaluateGJBooleanSetting(getterFn)
    if type(getterFn) ~= "function" then
        return true, "GJ_UNREADABLE_FAILSAFE"
    end
    local ok, val = pcall(getterFn)
    if not ok or type(val) ~= "boolean" then
        return true, "GJ_UNREADABLE_FAILSAFE"
    end
    if val == true then
        return true, "GodJohnsonGoldBorder"
    end
    return false, nil
end

function ns.SyncOwnership()
    local C = _G.GJCompanion
    local FS = _G.ForeverSuite
    if type(FS) ~= "table" or type(FS.SetFeatureYield) ~= "function" then
        return false
    end

    if type(C) ~= "table" then
        for _, key in ipairs({ "repair", "sell", "questAuto", "fishing" }) do
            FS.SetFeatureYield(key, false, nil)
            ns.ownership[key] = "OWNED_BY_FS"
        end
        ns.ownership.way = FS.IsFeatureYielded("way") and ("YIELDED_TO_" .. tostring(FS.GetFeatureYieldOwner("way"))) or "OWNED_BY_FS"
        return true
    end

    local yieldRepair, reasonRepair = EvaluateGJBooleanSetting(function()
        if type(C.ExtraSettings) ~= "function" then
            return nil
        end
        local d = C.ExtraSettings("merchantAutomation")
        if type(d) ~= "table" then
            return nil
        end
        return d.repair
    end)
    FS.SetFeatureYield("repair", yieldRepair, reasonRepair)
    ns.ownership.repair = yieldRepair and ("YIELDED (" .. tostring(reasonRepair) .. ")") or "OWNED_BY_FS"

    local yieldSell, reasonSell = EvaluateGJBooleanSetting(function()
        if type(C.ExtraSettings) ~= "function" then
            return nil
        end
        local d = C.ExtraSettings("merchantAutomation")
        if type(d) ~= "table" then
            return nil
        end
        return d.sell
    end)
    FS.SetFeatureYield("sell", yieldSell, reasonSell)
    ns.ownership.sell = yieldSell and ("YIELDED (" .. tostring(reasonSell) .. ")") or "OWNED_BY_FS"

    local yieldQuest, reasonQuest = EvaluateGJBooleanSetting(function()
        if type(C.ExtraSettings) ~= "function" then
            return nil
        end
        local d = C.ExtraSettings("automation")
        if type(d) ~= "table" then
            return nil
        end
        if (d.accept ~= nil and type(d.accept) ~= "boolean") or (d.complete ~= nil and type(d.complete) ~= "boolean") then
            return nil
        end
        if d.accept == nil and d.complete == nil then
            return nil
        end
        return (d.accept == true) or (d.complete == true)
    end)
    FS.SetFeatureYield("questAuto", yieldQuest, reasonQuest)
    ns.ownership.questAuto = yieldQuest and ("YIELDED (" .. tostring(reasonQuest) .. ")") or "OWNED_BY_FS"

    local yieldFishing, reasonFishing = EvaluateGJBooleanSetting(function()
        if type(C.FishingSettings) ~= "function" then
            return nil
        end
        local s = C.FishingSettings()
        if type(s) ~= "table" then
            return nil
        end
        if (s.enabled ~= nil and type(s.enabled) ~= "boolean") or (s.doubleClick ~= nil and type(s.doubleClick) ~= "boolean") then
            return nil
        end
        if s.enabled == nil and s.doubleClick == nil then
            return nil
        end
        return (s.enabled == true) and (s.doubleClick == true)
    end)
    FS.SetFeatureYield("fishing", yieldFishing, reasonFishing)
    ns.ownership.fishing = yieldFishing and ("YIELDED (" .. tostring(reasonFishing) .. ")") or "OWNED_BY_FS"

    -- Condition #3: /way is never yielded to GJ unless an actual /way slash command existed
    if FS.IsFeatureYielded and FS.IsFeatureYielded("way") then
        ns.ownership.way = "YIELDED (" .. tostring(FS.GetFeatureYieldOwner("way")) .. ")"
    else
        ns.ownership.way = "OWNED_BY_FS"
    end

    return true
end

function ns.TrySkinLauncher()
    local C = _G.GJCompanion
    if type(C) ~= "table" then
        ns.targets.launcherIcon = "UNAVAILABLE"
        return false
    end
    local launcher = _G.GodJohnsonGoldBorderLauncher
    if type(launcher) ~= "table" then
        if ns.targets.launcherIcon ~= "APPLIED" then
            ns.targets.launcherIcon = "PENDING"
        end
        return false
    end

    local logo = launcher.logo
    if type(logo) == "table" and type(logo.SetTexture) == "function" then
        pcall(logo.SetTexture, logo, ns.PERSONAL_ICON_ID)
    end

    if not launcher._fsgjTooltipHooked and type(launcher.HookScript) == "function" then
        launcher._fsgjTooltipHooked = true
        pcall(launcher.HookScript, launcher, "OnEnter", function()
            if _G.GameTooltip and _G.GameTooltip.IsShown and _G.GameTooltip:IsShown() and _G.GameTooltip.SetText then
                pcall(function()
                    _G.GameTooltip:ClearLines()
                    _G.GameTooltip:SetText("포에버 통합 도우미 (Personal Edition)")
                    _G.GameTooltip:AddLine("클릭: 통합 도감 · 가이드 열기/닫기", 1, 0.9, 0.65)
                    _G.GameTooltip:AddLine("드래그: 아이콘 위치 이동  |  /fs : ForeverSuite 설정", 0.75, 0.82, 0.88)
                    _G.GameTooltip:Show()
                end)
            end
        end)
    end

    ns.targets.launcherIcon = "APPLIED"
    return true
end

local function ApplyBrandingOverrides(C)
    -- 1. sayPrefix override (CompanionCore.lua:74)
    if type(C.Say) == "function" then
        C.Say = function(msg)
            local text = ns.PERSONAL_PREFIX .. tostring(msg or "")
            if _G.DEFAULT_CHAT_FRAME and _G.DEFAULT_CHAT_FRAME.AddMessage then
                _G.DEFAULT_CHAT_FRAME:AddMessage(text)
            end
        end
        ns.targets.sayPrefix = "APPLIED"
    else
        ns.targets.sayPrefix = "MISSING"
    end

    -- 2. youtubeLink override (ChannelLink.lua:19-23)
    if type(C.OpenYouTube) == "function" or type(C.BuildYouTubeButton) == "function" then
        C.OpenYouTube = function()
            if C.Say then
                C.Say("포에버 개인용 통합 환경 (GJ v" .. tostring(C.version or ns.UPSTREAM_PIN) .. " + ForeverSuite v" .. tostring(ns.VERSION) .. ")")
            end
        end
        if type(C.YouTubeButton) == "table" then
            pcall(function()
                if C.YouTubeButton.Hide then
                    C.YouTubeButton:Hide()
                end
                if C.YouTubeButton.EnableMouse then
                    C.YouTubeButton:EnableMouse(false)
                end
            end)
        end
        if type(C.BuildYouTubeButton) == "function" then
            local origBuildYouTube = C.BuildYouTubeButton
            C.BuildYouTubeButton = function(parent, heading, ButtonFn)
                local ok = pcall(origBuildYouTube, parent, heading, ButtonFn)
                if ok and type(C.YouTubeButton) == "table" then
                    pcall(function()
                        if C.YouTubeButton.Hide then
                            C.YouTubeButton:Hide()
                        end
                        if C.YouTubeButton.EnableMouse then
                            C.YouTubeButton:EnableMouse(false)
                        end
                        if C.YouTubeButton.SetAlpha then
                            C.YouTubeButton:SetAlpha(0)
                        end
                    end)
                end
            end
        end
        ns.targets.youtubeLink = "APPLIED"
    else
        ns.targets.youtubeLink = "MISSING"
    end

    -- 3. homeScreen override (Home404.lua:12, late-bound via CompanionUI.lua:347)
    if type(C.BuildHome404) == "function" then
        local origBuildHome404 = C.BuildHome404
        C.BuildHome404 = function(parent)
            pcall(origBuildHome404, parent)
            local home = C.Home404
            if type(home) == "table" then
                if type(home.logo) == "table" and type(home.logo.SetScript) == "function" then
                    pcall(home.logo.SetScript, home.logo, "OnClick", function()
                        ns.PrintStatus()
                    end)
                    pcall(home.logo.SetScript, home.logo, "OnEnter", function(self)
                        if _G.GameTooltip and _G.GameTooltip.SetOwner then
                            _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                            _G.GameTooltip:SetText("포에버 통합 도우미 (Personal Edition)")
                            _G.GameTooltip:AddLine("클릭하면 브리지 및 단일 소유자 상태를 출력합니다.", 1, 0.9, 0.65)
                            _G.GameTooltip:Show()
                        end
                    end)
                end
                if type(home.notice) == "table" and type(home.notice.SetText) == "function" then
                    pcall(
                        home.notice.SetText,
                        home.notice,
                        "포에버 개인용 통합 애드온 (GodJohnson DB v" .. tostring(C.version or ns.UPSTREAM_PIN) .. " + ForeverSuite Bridge)\n"
                            .. "원본 21개 폴더 무수정 해시 고정 · 중복 기능 자동 양보(Single Owner) 활성\n"
                            .. "명령어: /fs (ForeverSuite 설정) · /fsgj status (브리지 및 양보 상태 점검)"
                    )
                end
            end
        end
        ns.targets.homeScreen = "APPLIED"
    else
        ns.targets.homeScreen = "MISSING"
    end

    -- 4. tradeWhisper & vitalAlerts template clean defaults (TradeManager404.lua:25, VitalAlerts.lua:17)
    local tradeApplied = false
    if type(C.TradeManager404Config) == "function" then
        local origTradeCfg = C.TradeManager404Config
        C.TradeManager404Config = function()
            local ok, d = pcall(origTradeCfg)
            if ok and type(d) == "table" then
                if not d._fsgjUserInitialized then
                    d._fsgjUserInitialized = true
                    d.notify = false
                end
                return d
            end
            return { record = true, notify = false, limit = 50 }
        end
        tradeApplied = true
    end
    if type(C.ExtraSchemas) == "table" and type(C.ExtraSchemas.vitalAlerts) == "table" then
        for _, row in ipairs(C.ExtraSchemas.vitalAlerts) do
            if type(row) == "table" and type(row.default) == "string" then
                row.default = string_gsub(row.default, "^%[갓존슨%]", "[알림]")
            end
        end
    end
    ns.targets.tradeWhisper = tradeApplied and "APPLIED" or "MISSING"

    -- 5. questSound override: eliminate "oishii" voice and replace with clean alarm ("dingdong")
    local questSoundApplied = false
    if type(C.ExtraSchemas) == "table" and type(C.ExtraSchemas.questAnnounce) == "table" then
        for _, row in ipairs(C.ExtraSchemas.questAnnounce) do
            if type(row) == "table" then
                if (row.key == "questSound" or row.key == "objectiveSound")
                    and (row.default == "oishii_high" or row.default == "oishii_deep")
                then
                    row.default = ns.CLEAN_QUEST_ALARM_SOUND
                elseif (row.key == "objectiveTemplate" or row.key == "questTemplate") and type(row.default) == "string" then
                    row.default = string_gsub(row.default, "^%[갓존슨%]", "[포에버]")
                end
            end
        end
        questSoundApplied = true
    end
    if type(C.NotificationSoundNames) == "table" then
        C.NotificationSoundNames.oishii_high = "띵동 (오이쉬 대체 알람)"
        C.NotificationSoundNames.oishii_deep = "띵동 (오이쉬 대체 알람)"
        questSoundApplied = true
    end
    if type(C.PlayNotificationSound) == "function" and not C._fsgjPlaySoundWrapped then
        C._fsgjPlaySoundWrapped = true
        local origPlayNotificationSound = C.PlayNotificationSound
        C.PlayNotificationSound = function(key, volume, source, importance, channel)
            if key == "oishii_high" or key == "oishii_deep" then
                key = ns.CLEAN_QUEST_ALARM_SOUND
            end
            return origPlayNotificationSound(key, volume, source, importance, channel)
        end
        questSoundApplied = true
    elseif C._fsgjPlaySoundWrapped then
        questSoundApplied = true
    end

    if type(C.ExtraSettings) == "function" and not C._fsgjExtraSettingsWrapped then
        C._fsgjExtraSettingsWrapped = true
        local origExtraSettings = C.ExtraSettings
        C.ExtraSettings = function(key, ...)
            local d = origExtraSettings(key, ...)
            if type(d) == "table" then
                if key == "questAnnounce" then
                    if d.questSound == "oishii_high" or d.questSound == "oishii_deep" then
                        d.questSound = ns.CLEAN_QUEST_ALARM_SOUND
                    end
                    if d.objectiveSound == "oishii_high" or d.objectiveSound == "oishii_deep" then
                        d.objectiveSound = ns.CLEAN_QUEST_ALARM_SOUND
                    end
                    if type(d.questTemplate) == "string" then
                        d.questTemplate = string_gsub(d.questTemplate, "^%[갓존슨%]", "[포에버]")
                    end
                    if type(d.objectiveTemplate) == "string" then
                        d.objectiveTemplate = string_gsub(d.objectiveTemplate, "^%[갓존슨%]", "[포에버]")
                    end
                elseif key == "libraryBooksAccess471" then
                    if d.acquisitionSound == "oishii_high" or d.acquisitionSound == "oishii_deep" then
                        d.acquisitionSound = ns.CLEAN_QUEST_ALARM_SOUND
                    end
                end
            end
            return d
        end
        questSoundApplied = true
    elseif C._fsgjExtraSettingsWrapped then
        questSoundApplied = true
    end

    ns.targets.questSound = questSoundApplied and "APPLIED" or "MISSING"
    ns.SanitizeLiveGJSettings()

    -- 6. launcherIcon deferred frame skinning (Condition #1)
    ns.targets.launcherIcon = "PENDING"
    ns.TrySkinLauncher()
    if _G.hooksecurefunc and not C._fsgjLifecycleHooksRegistered then
        C._fsgjLifecycleHooksRegistered = true
        if type(C.RestoreLauncher) == "function" then
            pcall(_G.hooksecurefunc, C, "RestoreLauncher", function()
                ns.TrySkinLauncher()
            end)
        end
        if type(C.BorderApply) == "function" then
            pcall(_G.hooksecurefunc, C, "BorderApply", function()
                ns.TrySkinLauncher()
            end)
        end
        if type(C.CommitSettings) == "function" then
            pcall(_G.hooksecurefunc, C, "CommitSettings", function()
                ns.SanitizeLiveGJSettings()
                ns.SyncOwnership()
            end)
        end
        if type(C.RefreshUtilities) == "function" then
            pcall(_G.hooksecurefunc, C, "RefreshUtilities", function()
                ns.SanitizeLiveGJSettings()
                ns.SyncOwnership()
            end)
        end
        if type(C.RefreshFishingHelper) == "function" then
            pcall(_G.hooksecurefunc, C, "RefreshFishingHelper", function()
                ns.SyncOwnership()
            end)
        end
    end
end

function ns.SanitizeLiveGJSettings()
    local C = _G.GJCompanion
    if type(C) ~= "table" then
        return false
    end
    if type(C.ExtraSettings) == "function" then
        pcall(C.ExtraSettings, "questAnnounce")
        pcall(C.ExtraSettings, "libraryBooksAccess471")
        local ok, ct = pcall(C.ExtraSettings, "cursorTrail")
        if ok and type(ct) == "table" and ct._fsgjCursorLightningSanitized then
            ct.enabled = true
            ct.style = "chainTrial"
            ct._fsgjCursorLightningSanitized = nil
            if type(C.RefreshCursorTrail) == "function" then
                pcall(C.RefreshCursorTrail)
            end
        end
    end
    return true
end

function ns.PrintStatus()
    PrintBridge("상태: " .. tostring(ns.status) .. " (Upstream Pin: v" .. tostring(ns.UPSTREAM_PIN) .. ")")
    for _, key in ipairs({ "sayPrefix", "youtubeLink", "homeScreen", "launcherIcon", "tradeWhisper", "questSound" }) do
        PrintBridge("  오버라이드 [" .. key .. "] = " .. tostring(ns.targets[key]))
    end
    for _, key in ipairs({ "repair", "sell", "questAuto", "fishing", "way" }) do
        PrintBridge("  기능 소유권 [" .. key .. "] = " .. tostring(ns.ownership[key]))
    end
end

function ns.Initialize()
    local C = _G.GJCompanion
    if type(C) ~= "table" then
        ns.status = "UNAVAILABLE"
        for k in pairs(ns.targets) do
            ns.targets[k] = "UNAVAILABLE"
        end
        ns.SyncOwnership()
        return false
    end

    ns.status = "ACTIVE"
    ApplyBrandingOverrides(C)
    ns.SyncOwnership()
    return true
end

_G.SLASH_FOREVERSUITEGJ1 = "/fsgj"
if type(_G.SlashCmdList) == "table" then
    _G.SlashCmdList["FOREVERSUITEGJ"] = function(msg)
        local cmd = string_match(tostring(msg or ""), "^%s*(%S*)") or ""
        cmd = string_lower(cmd)
        if cmd == "sync" then
            ns.SyncOwnership()
            ns.TrySkinLauncher()
            PrintBridge("단일 소유권 및 런처 상태 재동기화 완료.")
        end
        ns.PrintStatus()
    end
end

ns.Initialize()

if _G.CreateFrame then
    local evFrame = _G.CreateFrame("Frame")
    if evFrame and evFrame.RegisterEvent and evFrame.SetScript then
        evFrame:RegisterEvent("PLAYER_LOGIN")
        evFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
        evFrame:SetScript("OnEvent", function(_, event)
            ns.SanitizeLiveGJSettings()
            ns.TrySkinLauncher()
            ns.SyncOwnership()
            if event == "PLAYER_ENTERING_WORLD" and ns.targets.launcherIcon == "PENDING" then
                if type(_G.GodJohnsonGoldBorderLauncher) ~= "table" then
                    ns.targets.launcherIcon = "MISSING"
                end
            end
        end)
    end
end
