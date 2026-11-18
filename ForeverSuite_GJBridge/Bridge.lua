local _, ns = ...

local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local pcall = pcall
local string_lower = string.lower
local string_match = string.match

ns.UPSTREAM_PIN = "5.278"

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
        if type(FS.IsFeatureYielded) == "function" and FS.IsFeatureYielded("way") then
            local owner = (type(FS.GetFeatureYieldOwner) == "function") and FS.GetFeatureYieldOwner("way") or nil
            ns.ownership.way = "YIELDED_TO_" .. tostring(owner)
        else
            ns.ownership.way = "OWNED_BY_FS"
        end
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

    if type(FS.IsFeatureYielded) == "function" and FS.IsFeatureYielded("way") then
        local owner = (type(FS.GetFeatureYieldOwner) == "function") and FS.GetFeatureYieldOwner("way") or nil
        ns.ownership.way = "YIELDED (" .. tostring(owner) .. ")"
    else
        ns.ownership.way = "OWNED_BY_FS"
    end

    return true
end

function ns.ApplyLifecycleHooks(C)
    C = C or _G.GJCompanion
    if type(C) ~= "table" then
        return false
    end
    if _G.hooksecurefunc and not ns._wrappedTargets[C] then
        ns._wrappedTargets[C] = true
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
    local store = ns._GetBridgeStore(allowStandaloneStoreCreate == true)
    if type(C.TradeManager404Config) == "function" then
        pcall(C.TradeManager404Config)
    end
    ns._ReconcileStarterLootDefault(C, store)
    ns._ReconcileNavRangeLayout(C, store, false)

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
    ns.Print("상태: " .. tostring(ns.status) .. " (Upstream Pin: v" .. tostring(ns.UPSTREAM_PIN) .. " · Bridge v" .. tostring(ns.VERSION) .. ")")
    for _, key in ipairs({ "sayPrefix", "youtubeLink", "homeScreen", "launcherIcon", "tradeWhisper", "questSound", "navRangeLayout" }) do
        ns.Print("  오버라이드 [" .. key .. "] = " .. tostring(ns.targets[key]))
    end
    for _, key in ipairs(OWNERSHIP_KEYS_ALL) do
        ns.Print("  기능 소유권 [" .. key .. "] = " .. tostring(ns.ownership[key]))
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
    ns._ApplyBrandingOverrides(C)
    ns._ReconcileNavRangeLayout(C, ns._GetBridgeStore(false), false)
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
            ns.Print("단일 소유권 및 런처 상태 재동기화 완료.")
        elseif cmd == "layout" or cmd == "fixlayout" then
            local C = _G.GJCompanion
            local store = ns._GetBridgeStore(true)
            if ns._ReconcileNavRangeLayout(C, store, true) then
                ns.Print("네비 화살표(상단 " .. tostring(ns.NAV_ARROW_DEFAULT_Y) .. ")와 대상 거리(하단 " .. tostring(ns.RANGE_DEFAULT_Y) .. ") 위치를 분리했습니다.")
            else
                ns.Print("전투 중이거나 읽기 전용 또는 설정을 읽을 수 없어 레이아웃 분리를 적용하지 못했습니다.")
            end
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
        evFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        evFrame:SetScript("OnEvent", function(_, event, isInitialLogin, isReloadingUi)
            if event == "PLAYER_REGEN_ENABLED" then
                if ns.targets.navRangeLayout == "PENDING" then
                    ns._ReconcileNavRangeLayout(_G.GJCompanion, ns._GetBridgeStore(false), false)
                end
                return
            elseif event == "PLAYER_LOGIN" then
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
