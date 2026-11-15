local ADDON_NAME, ns = ...

ns = ns or {}
_G.ForeverSuite_GJBridge = ns

local type = type
local pairs = pairs
local ipairs = ipairs
local select = select
local tonumber = tonumber
local tostring = tostring
local pcall = pcall
local error = error
local setmetatable = setmetatable
local string_find = string.find
local string_lower = string.lower
local string_match = string.match
local string_sub = string.sub

ns.ADDON_NAME = ADDON_NAME or "ForeverSuite_GJBridge"
ns.VERSION = "0.3.1"
ns.UPSTREAM_PIN = "5.236"
ns.PERSONAL_ICON_ID = 134063
ns.PERSONAL_PREFIX = "|cffffd36a[포에버]:|r "
ns.CLEAN_QUEST_ALARM_SOUND = "dingdong"

local GJ_PREFIX_TAG = "[갓존슨]"
local FS_PREFIX_TAG = "[포에버]"
local MAX_SUPPORTED_FS_SCHEMA = 2

-- Private closure state so zero _fsgj* keys ever touch GJCompanion, frames, or GJ SavedVariables
local function NewWeakKeyTable()
    if type(setmetatable) == "function" then
        return setmetatable({}, { __mode = "k" })
    end
    return {}
end

local wrappedTargets = NewWeakKeyTable()
local ephemeralTradeSeeded = NewWeakKeyTable()
local ephemeralStarterSeeded = NewWeakKeyTable()
local pendingTradePromote = false
local pendingStarterPromote = false

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
    questAutoAccept = "OWNED_BY_FS",
    questAutoTurnIn = "OWNED_BY_FS",
    fishing = "OWNED_BY_FS",
    way = "OWNED_BY_FS",
}

local OWNERSHIP_KEYS_GJ = {
    "repair",
    "sell",
    "questAutoAccept",
    "questAutoTurnIn",
    "fishing",
}

local OWNERSHIP_KEYS_ALL = {
    "repair",
    "sell",
    "questAutoAccept",
    "questAutoTurnIn",
    "fishing",
    "way",
}

local function PrintBridge(msg)
    local text = "|cffd4af37[FS-GJBridge]|r " .. tostring(msg or "")
    if _G.DEFAULT_CHAT_FRAME and _G.DEFAULT_CHAT_FRAME.AddMessage then
        _G.DEFAULT_CHAT_FRAME:AddMessage(text)
    end
end
ns.Print = PrintBridge

local function PackCallResults(ok, ...)
    return ok, select("#", ...), { ... }
end

local function UnpackResults(list, count, idx)
    idx = idx or 1
    if idx > count then
        return
    end
    return list[idx], UnpackResults(list, count, idx + 1)
end

local function IsForeverSuiteReadOnly()
    local FS = _G.ForeverSuite
    if type(FS) == "table" and type(FS.ProfileManager) == "table" and FS.ProfileManager.readOnly then
        return true
    end
    local fsdb = _G.ForeverSuiteDB
    if fsdb ~= nil and type(fsdb) ~= "table" then
        return true
    end
    if type(fsdb) == "table" then
        local ver = tonumber(fsdb.schemaVersion)
        if ver ~= nil and ver > MAX_SUPPORTED_FS_SCHEMA then
            return true
        end
    end
    return false
end

local function ReadBridgeSeedFlags()
    local fsdb = _G.ForeverSuiteDB
    if type(fsdb) == "table" and type(fsdb.gjBridge) == "table" then
        return fsdb.gjBridge.tradeNotifySeeded == true, fsdb.gjBridge.starterLootSeeded == true
    end
    return false, false
end

local function GetBridgeStore(allowStandaloneCreate)
    if IsForeverSuiteReadOnly() then
        return nil
    end
    local fsdb = _G.ForeverSuiteDB
    if type(fsdb) ~= "table" then
        if not allowStandaloneCreate or fsdb ~= nil then
            return nil
        end
        _G.ForeverSuiteDB = {
            schemaVersion = MAX_SUPPORTED_FS_SCHEMA,
            account = {},
            gjBridge = {},
        }
        fsdb = _G.ForeverSuiteDB
    else
        local ver = tonumber(fsdb.schemaVersion)
        if ver == nil and fsdb.account == nil and not allowStandaloneCreate then
            return nil
        end
    end
    if type(fsdb.gjBridge) ~= "table" then
        fsdb.gjBridge = {}
    end
    local store = fsdb.gjBridge
    if pendingTradePromote and not store.tradeNotifySeeded then
        store.tradeNotifySeeded = true
        pendingTradePromote = false
    end
    if pendingStarterPromote and not store.starterLootSeeded then
        store.starterLootSeeded = true
        pendingStarterPromote = false
    end
    return store
end

local function ReconcileTradeConfigTable(d, store)
    if type(d) ~= "table" or IsForeverSuiteReadOnly() then
        return
    end
    local savedTradeSeeded = ReadBridgeSeedFlags()
    if d._fsgjUserInitialized ~= nil then
        if store then
            store.tradeNotifySeeded = true
        else
            ephemeralTradeSeeded[d] = true
            pendingTradePromote = true
        end
        d._fsgjUserInitialized = nil
        return
    end
    if savedTradeSeeded or (store and store.tradeNotifySeeded) then
        return
    end
    if store then
        store.tradeNotifySeeded = true
        d.notify = false
    elseif not ephemeralTradeSeeded[d] then
        ephemeralTradeSeeded[d] = true
        pendingTradePromote = true
        d.notify = false
    end
end

local function ReconcileStarterLootDefault(C, store)
    if type(C) ~= "table" or type(C.ExtraSettings) ~= "function" or IsForeverSuiteReadOnly() then
        return
    end
    local _, savedStarterSeeded = ReadBridgeSeedFlags()
    if savedStarterSeeded or (store and store.starterLootSeeded) then
        return
    end
    local okQa, qa = pcall(C.ExtraSettings, "questAnnounce")
    if not okQa or type(qa) ~= "table" then
        return
    end
    if store then
        store.starterLootSeeded = true
        qa.starterLoot = false
    elseif not ephemeralStarterSeeded[qa] then
        ephemeralStarterSeeded[qa] = true
        pendingStarterPromote = true
        qa.starterLoot = false
    end
end

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

local function ReadGJExtraBoolField(C, sectionKey, fieldKey, siblingKey)
    if type(C.ExtraSettings) ~= "function" then
        return nil
    end
    local d = C.ExtraSettings(sectionKey)
    if type(d) ~= "table" then
        return nil
    end
    local val = d[fieldKey]
    if val ~= nil and type(val) ~= "boolean" then
        return nil
    end
    local sib = d[siblingKey]
    if sib ~= nil and type(sib) ~= "boolean" then
        return nil
    end
    if val == nil and sib == nil then
        return nil
    end
    return val == true
end

function ns.SyncOwnership()
    local C = _G.GJCompanion
    local FS = _G.ForeverSuite
    if type(FS) ~= "table" or type(FS.SetFeatureYield) ~= "function" then
        return false
    end
    -- Clean up any legacy pre-0.3.1 single questAuto key if ever set
    FS.SetFeatureYield("questAuto", false, nil)

    if type(C) ~= "table" then
        for _, key in ipairs(OWNERSHIP_KEYS_GJ) do
            FS.SetFeatureYield(key, false, nil)
            ns.ownership[key] = "OWNED_BY_FS"
        end
        ns.ownership.way = FS.IsFeatureYielded("way") and ("YIELDED_TO_" .. tostring(FS.GetFeatureYieldOwner("way"))) or "OWNED_BY_FS"
        return true
    end

    local yieldRepair, reasonRepair = EvaluateGJBooleanSetting(function()
        return ReadGJExtraBoolField(C, "merchantAutomation", "repair", "sell")
    end)
    FS.SetFeatureYield("repair", yieldRepair, reasonRepair)
    ns.ownership.repair = yieldRepair and ("YIELDED (" .. tostring(reasonRepair) .. ")") or "OWNED_BY_FS"

    local yieldSell, reasonSell = EvaluateGJBooleanSetting(function()
        return ReadGJExtraBoolField(C, "merchantAutomation", "sell", "repair")
    end)
    FS.SetFeatureYield("sell", yieldSell, reasonSell)
    ns.ownership.sell = yieldSell and ("YIELDED (" .. tostring(reasonSell) .. ")") or "OWNED_BY_FS"

    local yieldQuestAccept, reasonQuestAccept = EvaluateGJBooleanSetting(function()
        return ReadGJExtraBoolField(C, "automation", "accept", "complete")
    end)
    FS.SetFeatureYield("questAutoAccept", yieldQuestAccept, reasonQuestAccept)
    ns.ownership.questAutoAccept = yieldQuestAccept and ("YIELDED (" .. tostring(reasonQuestAccept) .. ")") or "OWNED_BY_FS"

    local yieldQuestTurnIn, reasonQuestTurnIn = EvaluateGJBooleanSetting(function()
        return ReadGJExtraBoolField(C, "automation", "complete", "accept")
    end)
    FS.SetFeatureYield("questAutoTurnIn", yieldQuestTurnIn, reasonQuestTurnIn)
    ns.ownership.questAutoTurnIn = yieldQuestTurnIn and ("YIELDED (" .. tostring(reasonQuestTurnIn) .. ")") or "OWNED_BY_FS"

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

    if not wrappedTargets[launcher] and type(launcher.HookScript) == "function" then
        wrappedTargets[launcher] = true
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
    local okReg, count, regions = PackCallResults(pcall(crest.GetRegions, crest))
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
    if not wrappedTargets[C.BuildHome404] then
        local origBuildHome404 = C.BuildHome404
        local wrappedBuildHome = function(parent, ...)
            local ok, count, results = PackCallResults(pcall(origBuildHome404, parent, ...))
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
            return UnpackResults(results, count, 1)
        end
        wrappedTargets[wrappedBuildHome] = true
        C.BuildHome404 = wrappedBuildHome
    end
    ns.targets.homeScreen = "APPLIED"
end

local function WrapAuthorPresetIfPresent(C)
    if type(C.ApplyAuthorPreset) ~= "function" or wrappedTargets[C.ApplyAuthorPreset] then
        return
    end
    local origApplyAuthorPreset = C.ApplyAuthorPreset
    local wrappedPreset = function(...)
        local store = GetBridgeStore(false)
        local prevNotify = false
        if type(C.TradeManager404Config) == "function" then
            local okTm, tm = pcall(C.TradeManager404Config)
            if okTm and type(tm) == "table" and type(tm.notify) == "boolean" then
                prevNotify = tm.notify
            end
        end
        local prevStarterLoot = false
        if type(C.ExtraSettings) == "function" then
            local _, savedStarterSeeded = ReadBridgeSeedFlags()
            local starterWasSeeded = savedStarterSeeded or (store and store.starterLootSeeded) or pendingStarterPromote or IsForeverSuiteReadOnly()
            if starterWasSeeded then
                local okQa, qa = pcall(C.ExtraSettings, "questAnnounce")
                if okQa and type(qa) == "table" and type(qa.starterLoot) == "boolean" then
                    prevStarterLoot = qa.starterLoot
                end
            end
        end

        local ok, count, results = PackCallResults(pcall(origApplyAuthorPreset, ...))
        if not ok then
            error(results[1], 0)
        end

        if results[1] == true then
            local readOnly = IsForeverSuiteReadOnly()
            local postStore = GetBridgeStore(false)
            if type(C.TradeManager404Config) == "function" then
                local okTm, tm = pcall(C.TradeManager404Config)
                if okTm and type(tm) == "table" then
                    if not readOnly then
                        tm._fsgjUserInitialized = nil
                    end
                    tm.notify = prevNotify
                    if postStore then
                        postStore.tradeNotifySeeded = true
                    elseif not readOnly then
                        ephemeralTradeSeeded[tm] = true
                        pendingTradePromote = true
                    end
                end
            end
            if type(C.ExtraSettings) == "function" then
                local okQa, qa = pcall(C.ExtraSettings, "questAnnounce")
                if okQa and type(qa) == "table" then
                    qa.starterLoot = prevStarterLoot
                    if postStore then
                        postStore.starterLootSeeded = true
                    elseif not readOnly then
                        ephemeralStarterSeeded[qa] = true
                        pendingStarterPromote = true
                    end
                end
            end
            if type(C.CommitSettings) == "function" then
                pcall(C.CommitSettings)
            end
            if type(C.RefreshQuestAnnounce) == "function" then
                pcall(C.RefreshQuestAnnounce)
            end
            ns.SyncOwnership()
        end

        return UnpackResults(results, count, 1)
    end
    wrappedTargets[wrappedPreset] = true
    C.ApplyAuthorPreset = wrappedPreset
end

local function ApplyBrandingOverrides(C)
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
        if not wrappedTargets[C.TradeManager404Config] then
            local origTradeCfg = C.TradeManager404Config
            local wrappedTradeCfg = function(...)
                local ok, d = pcall(origTradeCfg, ...)
                if ok and type(d) == "table" then
                    ReconcileTradeConfigTable(d, GetBridgeStore(false))
                    return d
                end
                return { record = true, notify = false, limit = 50 }
            end
            wrappedTargets[wrappedTradeCfg] = true
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
        if not wrappedTargets[C.PlayNotificationSound] then
            local origPlayNotificationSound = C.PlayNotificationSound
            local wrappedPlaySound = function(key, ...)
                if key == "oishii_high" or key == "oishii_deep" then
                    key = ns.CLEAN_QUEST_ALARM_SOUND
                end
                return origPlayNotificationSound(key, ...)
            end
            wrappedTargets[wrappedPlaySound] = true
            C.PlayNotificationSound = wrappedPlaySound
        end
        questSoundApplied = true
    end
    if type(C.QuestAnnounce) == "table" and type(C.QuestAnnounce.Format) == "function" then
        local qaMod = C.QuestAnnounce
        if not wrappedTargets[qaMod.Format] then
            local origFormat = qaMod.Format
            local wrappedFormat = function(...)
                local okFmt, countFmt, fmtResults = PackCallResults(pcall(origFormat, ...))
                if not okFmt then
                    error(fmtResults[1], 0)
                end
                local rendered = fmtResults[1]
                if type(rendered) == "string" and string_sub(rendered, 1, #GJ_PREFIX_TAG) == GJ_PREFIX_TAG then
                    fmtResults[1] = FS_PREFIX_TAG .. string_sub(rendered, #GJ_PREFIX_TAG + 1)
                end
                return UnpackResults(fmtResults, countFmt, 1)
            end
            wrappedTargets[wrappedFormat] = true
            qaMod.Format = wrappedFormat
        end
        questSoundApplied = true
    end
    ns.targets.questSound = questSoundApplied and "APPLIED" or "MISSING"

    -- 6. ApplyAuthorPreset pre/post snapshot wrapper
    WrapAuthorPresetIfPresent(C)

    ns.SanitizeLiveGJSettings(false)

    -- 7. launcherIcon deferred frame skinning
    ns.targets.launcherIcon = "PENDING"
    ns.TrySkinLauncher()
    ns.ApplyLifecycleHooks(C)
end

function ns.ApplyLifecycleHooks(C)
    C = C or _G.GJCompanion
    if type(C) ~= "table" then
        return false
    end
    if _G.hooksecurefunc and not wrappedTargets[C] then
        wrappedTargets[C] = true
        if type(C.RestoreLauncher) == "function" then
            pcall(_G.hooksecurefunc, C, "RestoreLauncher", function()
                ns.TrySkinLauncher()
            end)
        end
        if type(C.CommitSettings) == "function" then
            pcall(_G.hooksecurefunc, C, "CommitSettings", function()
                ns.SyncOwnership()
            end)
        end
        if type(C.RefreshFishingHelper) == "function" then
            pcall(_G.hooksecurefunc, C, "RefreshFishingHelper", function()
                ns.SyncOwnership()
            end)
        end
    end
    return true
end

function ns.SanitizeLiveGJSettings(allowStandaloneStoreCreate)
    local C = _G.GJCompanion
    if type(C) ~= "table" then
        return false
    end
    local store = GetBridgeStore(allowStandaloneStoreCreate == true)
    if type(C.TradeManager404Config) == "function" then
        pcall(C.TradeManager404Config)
    end
    ReconcileStarterLootDefault(C, store)

    local ct = nil
    if type(C.DB) == "function" then
        local okDb, rawDb = pcall(C.DB)
        if okDb and type(rawDb) == "table" and type(rawDb.cursorTrail) == "table" then
            ct = rawDb.cursorTrail
        end
    elseif type(C.ExtraSettings) == "function" then
        local okCt, tbl = pcall(C.ExtraSettings, "cursorTrail")
        if okCt and type(tbl) == "table" then
            ct = tbl
        end
    end
    if type(ct) == "table" and ct._fsgjCursorLightningSanitized then
        ct.enabled = true
        ct.style = "chainTrial"
        ct._fsgjCursorLightningSanitized = nil
        if type(C.RefreshCursorTrail) == "function" then
            pcall(C.RefreshCursorTrail)
        end
    end
    return true
end

function ns.PrintStatus()
    PrintBridge("상태: " .. tostring(ns.status) .. " (Upstream Pin: v" .. tostring(ns.UPSTREAM_PIN) .. " · Bridge v" .. tostring(ns.VERSION) .. ")")
    for _, key in ipairs({ "sayPrefix", "youtubeLink", "homeScreen", "launcherIcon", "tradeWhisper", "questSound" }) do
        PrintBridge("  오버라이드 [" .. key .. "] = " .. tostring(ns.targets[key]))
    end
    for _, key in ipairs(OWNERSHIP_KEYS_ALL) do
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
        evFrame:SetScript("OnEvent", function(_, event, isInitialLogin, isReloadingUi)
            if event == "PLAYER_LOGIN" then
                if evFrame.UnregisterEvent then
                    evFrame:UnregisterEvent("PLAYER_LOGIN")
                end
                ns.SanitizeLiveGJSettings(true)
                ns.SyncOwnership()
            elseif event ~= "PLAYER_ENTERING_WORLD" or isInitialLogin ~= false or isReloadingUi ~= false then
                ns.SanitizeLiveGJSettings(false)
                ns.SyncOwnership()
            end
            ns.TrySkinLauncher()
            if event == "PLAYER_ENTERING_WORLD" and ns.targets.launcherIcon == "PENDING" then
                if type(_G.GodJohnsonGoldBorderLauncher) ~= "table" then
                    ns.targets.launcherIcon = "MISSING"
                end
            end
        end)
    end
end
