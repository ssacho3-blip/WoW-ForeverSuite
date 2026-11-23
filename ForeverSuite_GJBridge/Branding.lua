local _, ns = ...

local type = type
local tostring = tostring
local pcall = pcall
local error = error
local string_find = string.find
local string_lower = string.lower
local string_sub = string.sub

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

    if not ns._wrappedTargets[launcher] and type(launcher.HookScript) == "function" then
        ns._wrappedTargets[launcher] = true
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

local function SkinHomeCrestLogo(crest)
    if type(crest) ~= "table" or type(crest.GetRegions) ~= "function" then
        return
    end
    local okReg, count, regions = ns._PackCallResults(pcall(crest.GetRegions, crest))
    if not okReg then
        return
    end
    for i = 1, count do
        local reg = regions[i]
        if type(reg) == "table"
            and reg ~= crest.gjLogoRing405
            and reg ~= crest.gjLogoMask405
            and type(reg.SetTexture) == "function"
        then
            local shouldReplace = false
            if type(reg.GetTexture) == "function" then
                local okTex, tex = pcall(reg.GetTexture, reg)
                if okTex and type(tex) == "string" and string_find(string_lower(tex), "channellogo", 1, true) then
                    shouldReplace = true
                end
            elseif type(reg.GetDrawLayer) == "function" then
                local okLayer, layer = pcall(reg.GetDrawLayer, reg)
                if okLayer and layer == "ARTWORK" then
                    shouldReplace = true
                end
            else
                shouldReplace = true
            end
            if shouldReplace then
                pcall(reg.SetTexture, reg, ns.PERSONAL_ICON_ID)
            end
        end
    end
end

local function ApplyHomeScreenOverrides(C)
    if type(C.BuildHome404) ~= "function" then
        ns.targets.homeScreen = "MISSING"
        return
    end
    if not ns._wrappedTargets[C.BuildHome404] then
        local origBuildHome404 = C.BuildHome404
        local wrappedBuildHome = function(parent, ...)
            local ok, count, results = ns._PackCallResults(pcall(origBuildHome404, parent, ...))
            if not ok then
                error(results[1], 0)
            end
            local home = C.Home404
            if type(home) == "table" then
                if type(home.logo) == "table" then
                    SkinHomeCrestLogo(home.logo)
                    if type(home.logo.SetScript) == "function" then
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
                end
                if type(home.setupReminder) == "table" and type(home.setupReminder.SetText) == "function" then
                    pcall(
                        home.setupReminder.SetText,
                        home.setupReminder,
                        "개인화 통합 환경 · 자동셋팅 실행 시 거래 귓말 및 시작템 파티알림 설정이 보존됩니다"
                    )
                    if type(home.setupReminder.SetTextColor) == "function" then
                        pcall(home.setupReminder.SetTextColor, home.setupReminder, 0.86, 0.82, 0.73)
                    end
                end
                if type(home.notice) == "table" and type(home.notice.SetText) == "function" then
                    pcall(
                        home.notice.SetText,
                        home.notice,
                        "포에버 개인용 통합 애드온 (GodJohnson DB v" .. tostring(C.version or ns.UPSTREAM_PIN) .. " + ForeverSuite Bridge v" .. tostring(ns.VERSION) .. ")\n"
                            .. "원본 21개 폴더 전체 파일 SHA-256 해시 고정 · 중복 기능 자동 양보(Single Owner) 활성\n"
                            .. "명령어: /fs (ForeverSuite 설정) · /fsgj status (브리지 및 양보 상태 점검)"
                    )
                end
            end
            return ns._UnpackResults(results, count, 1)
        end
        ns._wrappedTargets[wrappedBuildHome] = true
        C.BuildHome404 = wrappedBuildHome
    end
    ns.targets.homeScreen = "APPLIED"
end

local function WrapAuthorPresetIfPresent(C)
    if type(C.ApplyAuthorPreset) ~= "function" or ns._wrappedTargets[C.ApplyAuthorPreset] then
        return
    end
    local origApplyAuthorPreset = C.ApplyAuthorPreset
    local wrappedPreset = function(...)
        local store = ns._GetBridgeStore(false)
        local prevNotify = false
        if type(C.TradeManager404Config) == "function" then
            local okTm, tm = pcall(C.TradeManager404Config)
            if okTm and type(tm) == "table" and type(tm.notify) == "boolean" then
                prevNotify = tm.notify
            end
        end
        local prevStarterLoot = false
        if type(C.ExtraSettings) == "function" and ns._IsStarterSeededOrPending(store) then
            local okQa, qa = pcall(C.ExtraSettings, "questAnnounce")
            if okQa and type(qa) == "table" and type(qa.starterLoot) == "boolean" then
                prevStarterLoot = qa.starterLoot
            end
        end

        local ok, count, results = ns._PackCallResults(pcall(origApplyAuthorPreset, ...))
        if not ok then
            error(results[1], 0)
        end

        if results[1] == true then
            local readOnly = ns._IsForeverSuiteReadOnly()
            local postStore = ns._GetBridgeStore(false)
            if type(C.TradeManager404Config) == "function" then
                local okTm, tm = pcall(C.TradeManager404Config)
                if okTm and type(tm) == "table" then
                    if not readOnly then
                        tm._fsgjUserInitialized = nil
                    end
                    tm.notify = prevNotify
                    ns._RecordTradeSeeded(tm, postStore)
                end
            end
            if type(C.ExtraSettings) == "function" then
                local okQa, qa = pcall(C.ExtraSettings, "questAnnounce")
                if okQa and type(qa) == "table" then
                    qa.starterLoot = prevStarterLoot
                    ns._RecordStarterSeeded(qa, postStore)
                end
            end
            ns._ResetNavRangeLayoutSeed(postStore)
            ns._ReconcileNavRangeLayout(C, postStore, false)
            if type(ns.ReconcileExternalCoexistence) == "function" then
                ns.ReconcileExternalCoexistence(C)
            end
            if type(C.CommitSettings) == "function" then
                pcall(C.CommitSettings)
            end
            if type(C.RefreshQuestAnnounce) == "function" then
                pcall(C.RefreshQuestAnnounce)
            end
            ns.SyncOwnership()
        end

        return ns._UnpackResults(results, count, 1)
    end
    ns._wrappedTargets[wrappedPreset] = true
    C.ApplyAuthorPreset = wrappedPreset
end

local function WrapAuctionPriceTooltipIfPresent(C)
    if type(C.AddAuctionPriceTooltip) ~= "function" or ns._wrappedTargets[C.AddAuctionPriceTooltip] then
        return
    end
    local origAddAuctionPriceTooltip = C.AddAuctionPriceTooltip
    local wrappedAddAuctionPriceTooltip = function(...)
        if type(C.AuctionSettings) == "function" then
            local okS, s = pcall(C.AuctionSettings)
            if okS and type(s) == "table" then
                if s.enabled == false or s.tooltips == false then
                    return false
                end
            elseif type(ns.externalCoexistence.auction) == "string" and string_sub(ns.externalCoexistence.auction, 1, 11) == "YIELDED_TO_" then
                return false
            end
        end
        return origAddAuctionPriceTooltip(...)
    end
    ns._wrappedTargets[wrappedAddAuctionPriceTooltip] = true
    C.AddAuctionPriceTooltip = wrappedAddAuctionPriceTooltip
end

function ns._ApplyBrandingOverrides(C)
    -- 1. sayPrefix override (CompanionCore.lua:84)
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

    -- 2. youtubeLink override (ChannelLink.lua:43)
    if type(C.OpenYouTube) == "function" then
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
        ns.targets.youtubeLink = "APPLIED"
    else
        ns.targets.youtubeLink = "MISSING"
    end

    -- 3. homeScreen override (Home404.lua:12)
    ApplyHomeScreenOverrides(C)

    -- 4. tradeWhisper clean default without polluting GJDB.tradeManager404 (ProfileShare.lua:282 safe)
    if type(C.TradeManager404Config) == "function" then
        if not ns._wrappedTargets[C.TradeManager404Config] then
            local origTradeCfg = C.TradeManager404Config
            local wrappedTradeCfg = function(...)
                local ok, d = pcall(origTradeCfg, ...)
                if ok and type(d) == "table" then
                    ns._ReconcileTradeConfigTable(d, ns._GetBridgeStore(false))
                    return d
                end
                return { record = true, notify = false, limit = 50 }
            end
            ns._wrappedTargets[wrappedTradeCfg] = true
            C.TradeManager404Config = wrappedTradeCfg
        end
        ns.targets.tradeWhisper = "APPLIED"
    else
        ns.targets.tradeWhisper = "MISSING"
    end

    -- 5. questSound & QuestAnnounce.Format runtime override (zero GJ SavedVariables mutation)
    local questSoundApplied = false
    if type(C.NotificationSoundNames) == "table" then
        C.NotificationSoundNames.oishii_high = "띵동 (오이쉬 대체 알람)"
        C.NotificationSoundNames.oishii_deep = "띵동 (오이쉬 대체 알람)"
        questSoundApplied = true
    end
    if type(C.PlayNotificationSound) == "function" then
        if not ns._wrappedTargets[C.PlayNotificationSound] then
            local origPlayNotificationSound = C.PlayNotificationSound
            local wrappedPlaySound = function(key, ...)
                if key == "oishii_high" or key == "oishii_deep" then
                    key = ns.CLEAN_QUEST_ALARM_SOUND
                end
                return origPlayNotificationSound(key, ...)
            end
            ns._wrappedTargets[wrappedPlaySound] = true
            C.PlayNotificationSound = wrappedPlaySound
        end
        questSoundApplied = true
    end
    if type(C.QuestAnnounce) == "table" and type(C.QuestAnnounce.Format) == "function" then
        local qaMod = C.QuestAnnounce
        if not ns._wrappedTargets[qaMod.Format] then
            local origFormat = qaMod.Format
            local wrappedFormat = function(...)
                local okFmt, countFmt, fmtResults = ns._PackCallResults(pcall(origFormat, ...))
                if not okFmt then
                    error(fmtResults[1], 0)
                end
                local rendered = fmtResults[1]
                if type(rendered) == "string" and string_sub(rendered, 1, #ns.GJ_PREFIX_TAG) == ns.GJ_PREFIX_TAG then
                    fmtResults[1] = ns.FS_PREFIX_TAG .. string_sub(rendered, #ns.GJ_PREFIX_TAG + 1)
                end
                return ns._UnpackResults(fmtResults, countFmt, 1)
            end
            ns._wrappedTargets[wrappedFormat] = true
            qaMod.Format = wrappedFormat
        end
        questSoundApplied = true
    end
    ns.targets.questSound = questSoundApplied and "APPLIED" or "MISSING"

    -- 6. ApplyAuthorPreset pre/post snapshot wrapper & AuctionPriceTooltip guard
    WrapAuthorPresetIfPresent(C)
    WrapAuctionPriceTooltipIfPresent(C)

    ns.SanitizeLiveGJSettings(false)

    -- 7. launcherIcon deferred frame skinning
    ns.targets.launcherIcon = "PENDING"
    ns.TrySkinLauncher()
    ns.ApplyLifecycleHooks(C)
end
