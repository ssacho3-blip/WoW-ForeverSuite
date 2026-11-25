-- Module: Features/Bootstrap.lua
-- Responsibility: Wires v2 declarative schemas, L2 Command Hub (4 pages), Phase 2A modules, lifecycle events, and /fs2 + /way2 commands.
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local pairs = pairs
local string_match = string.match
local string_lower = string.lower

local MAX_TAINT_KEYS = 200

-- Every declared setting MUST have an active runtime consumer.
local DEFAULT_SCHEMAS = {
    {
        section = "quest",
        key = "defaultTrackerMode",
        type = "enum",
        default = "coexist",
        label = "Blizzard 기본 퀘스트 추적기 모드",
        desc = "coexist(무접촉 기본) / dim(알파만) / hide(비전투 숨김, v1 공존 시 자동 양보)",
        combatSafe = false,
        options = {
            { value = "coexist", label = "공존(기본)", width = 86 },
            { value = "dim", label = "흐리게", width = 76 },
            { value = "hide", label = "숨김", width = 72 },
        },
    },
    {
        section = "ui",
        key = "showStatusPill",
        type = "boolean",
        default = true,
        label = "상단 상태 필 바 표시 (가방·내구·골드·렐름)",
        desc = "L0 상시 HUD 상태 요약 바 표시/숨김",
        combatSafe = true,
    },
    {
        section = "quest",
        key = "autoAccept",
        type = "boolean",
        default = true,
        label = "퀘스트 자동 수락 (Shift 우회, v1 공존 시 양보)",
        desc = "NPC 대화 시 퀘스트 자동 수락",
        combatSafe = true,
    },
    {
        section = "quest",
        key = "autoTurnIn",
        type = "boolean",
        default = true,
        label = "퀘스트 자동 완료 (다중 보상 시 자동 정지)",
        desc = "보상 선택지가 1개 이하일 때만 자동 완료",
        combatSafe = true,
    },
    {
        section = "quest",
        key = "autoSuperTrack",
        type = "boolean",
        default = true,
        label = "새 퀘스트 수락 시 자동 추적 (NavPort 지연 안전)",
        desc = "전투·월드맵 중에는 지연 후 적용",
        combatSafe = true,
    },
    {
        section = "merchant",
        key = "autoRepair",
        type = "boolean",
        default = true,
        label = "상점 방문 시 자동 수리",
        desc = "Shift를 누른 채 대화하면 일시 우회",
        combatSafe = true,
    },
    {
        section = "merchant",
        key = "useGuildRepair",
        type = "boolean",
        default = true,
        label = "길드 은행 수리 우선 사용",
        desc = "불가 시 개인 골드로 안전 폴백",
        combatSafe = true,
    },
    {
        section = "merchant",
        key = "autoSellJunk",
        type = "boolean",
        default = true,
        label = "회색 잡템 자동 판매 (12개 바이백 상한)",
        desc = "/fs2 protect 보호 목록 제외",
        combatSafe = true,
    },
    {
        section = "combat",
        key = "buffReminder",
        type = "boolean",
        default = true,
        label = "비전투 9직업 자가 버프/무기 마부 누락 경고",
        desc = "전투 중에는 자동 숨김",
        combatSafe = true,
    },
    {
        section = "combat",
        key = "lowHealthAlert",
        type = "boolean",
        default = true,
        label = "저체력(≤30%) 생존 경고 (Secret-safe)",
        desc = "C_Secrets 반환 시 오경보 차단",
        combatSafe = true,
    },
    {
        section = "profession",
        key = "showFishingCard",
        type = "boolean",
        default = true,
        label = "낚싯대 장착 시 대상어 L1 카드 자동 표시",
        desc = "ForeverSuite_Data LoD 낚시 팩 연동",
        combatSafe = true,
    },
    {
        section = "combat",
        key = "showEncounterTimer",
        type = "boolean",
        default = true,
        label = "전투·보스·인던 타이머 & 풀링 카운트다운 HUD",
        desc = "/fs2 pull 10 및 /fs2 timer 지원",
        combatSafe = true,
    },
    {
        section = "qol",
        key = "fastLoot",
        type = "boolean",
        default = true,
        label = "고속 자동 루팅 (autoLoot CVar XOR Shift)",
        desc = "v1 공존 시 자동 양보",
        combatSafe = true,
    },
    {
        section = "qol",
        key = "autoReleaseBG",
        type = "boolean",
        default = true,
        label = "전장(BG) 전용 자동 영혼 해제 (자가 부활 시 중단)",
        desc = "영혼석/윤회 감지 시 절대 해제하지 않음",
        combatSafe = true,
    },
    {
        section = "qol",
        key = "autoAcceptRes",
        type = "boolean",
        default = true,
        label = "비전투 부활 자동 수락 (전투 부활 제외)",
        desc = "Shift 우회 가능, 전투 중에는 수락하지 않음",
        combatSafe = true,
    },
    {
        section = "qol",
        key = "autoAcceptFriends",
        type = "boolean",
        default = true,
        label = "친구·길드원 파티 초대 자동 수락",
        desc = "모르는 유저 초대는 수락하지 않음",
        combatSafe = true,
    },
    {
        section = "qol",
        key = "maxCameraZoom",
        type = "boolean",
        default = false,
        label = "최대 카메라 시야 거리 확장 (비전투 CVar)",
        desc = "cameraDistanceMaxZoomFactor = 2.6 적용",
        combatSafe = false,
    },
}

local Bootstrap = {
    initialized = false,
}
ns.Features.Bootstrap = Bootstrap

local function ApplyTrackerModeSafely(requestedMode)
    if ns.Api.SafeAPI.IsV1Loaded() then
        ns.Blizzard.ObjectiveTrackerAdapter:ApplyMode("coexist")
        return
    end
    ns.Blizzard.ObjectiveTrackerAdapter:ApplyMode(requestedMode or "coexist")
end

local function RecordTaintEvent(kind, addonName, funcName)
    if not ns.Api.ProfileStore:CanWrite() then
        return
    end
    local diag = ns.Api.ProfileStore.db.v2.diagnostics
    local a = ns.Api.SafeAPI.IsSecret(addonName) and "SECRET" or tostring(addonName or "UNKNOWN")
    local f = ns.Api.SafeAPI.IsSecret(funcName) and "SECRET" or tostring(funcName or "UNKNOWN")
    local k = kind .. ":" .. a .. ":" .. f
    diag.taintTotal = (diag.taintTotal or 0) + 1
    if diag.taintCounts[k] ~= nil then
        diag.taintCounts[k] = diag.taintCounts[k] + 1
    else
        local keyCount = 0
        for _ in pairs(diag.taintCounts) do
            keyCount = keyCount + 1
        end
        if keyCount < MAX_TAINT_KEYS then
            diag.taintCounts[k] = 1
        end
    end
end

function Bootstrap:Init()
    if self.initialized then
        return
    end

    ns.Api.ProfileStore:RegisterSchema(DEFAULT_SCHEMAS)
    ns.Api.ProfileStore:Init()

    -- Register L2 Command Hub workspace pages
    ns.UI.CommandHub:RegisterPage(ns.Features.DiagnosticsPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.SettingsPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.LedgerPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.CodexPage)

    ns.Blizzard.WorldMapAdapter:Init()

    local mode = ns.Api.ProfileStore:Get("quest", "defaultTrackerMode") or "coexist"
    ApplyTrackerModeSafely(mode)

    ns.Api.EventBus:Subscribe("setting:changed", function(sec, key, val)
        if sec == "quest" and key == "defaultTrackerMode" then
            ApplyTrackerModeSafely(val)
        elseif sec == "ui" and key == "showStatusPill" then
            ns.Features.StatusPillHud:ApplyVisibility()
        elseif sec == "combat" and key == "showEncounterTimer" then
            ns.Features.EncounterTimerHud:Refresh()
        elseif sec == "combat" then
            ns.Features.CombatAssistHud:Refresh()
        elseif sec == "profession" and key == "showFishingCard" then
            ns.Features.FishingCardHud:Refresh()
        elseif sec == "qol" and key == "maxCameraZoom" then
            ns.Features.QoLModule:ApplyCameraZoomIfEnabled()
        end
    end)

    -- Initialize L0/L1 HUDs
    ns.Features.QuestTrackerView:Init()
    ns.Features.QuestTrackerView:RefreshLive()
    ns.Features.StatusPillHud:Init()
    ns.Features.NavigationHud:Init()
    ns.Features.CombatAssistHud:Init()
    ns.Features.CombatAssistHud:Refresh()
    ns.Features.EncounterTimerHud:Init()
    ns.Features.EncounterTimerHud:OnZoneOrInstanceChanged()
    ns.Features.FishingCardHud:Init()
    ns.Features.FishingCardHud:Refresh()
    ns.Features.LedgerPage:SyncFromPlayerMoney()
    ns.Features.QoLModule:ResetSessionXP()
    ns.Features.QoLModule:ApplyCameraZoomIfEnabled()

    -- Lifecycle & Feature event wiring
    ns.Api.EventBus:OnEvent("v2:addonLoaded", "ADDON_LOADED", function()
        ns.Blizzard.WorldMapAdapter:Init()
    end)
    ns.Api.EventBus:OnEvent("v2:enterWorld", "PLAYER_ENTERING_WORLD", function()
        ns.Features.EncounterTimerHud:OnZoneOrInstanceChanged()
        ns.Features.QoLModule:SyncSessionXP()
    end)
    ns.Api.EventBus:OnEvent("v2:questLog", "QUEST_LOG_UPDATE", function()
        ns.Features.QuestTrackerView:RefreshLive()
    end)
    ns.Api.EventBus:OnEvent("v2:superTrack", "SUPER_TRACKING_CHANGED", function()
        ns.Features.QuestTrackerView:RefreshLive()
    end)
    ns.Api.EventBus:OnEvent("v2:bags", "BAG_UPDATE_DELAYED", function()
        ns.Features.StatusPillHud:RefreshLive()
    end)
    ns.Api.EventBus:OnEvent("v2:durability", "UPDATE_INVENTORY_DURABILITY", function()
        ns.Features.StatusPillHud:RefreshLive()
        ns.Features.MerchantModule:ResolvePendingGuildRepair("event")
    end)
    ns.Api.EventBus:OnEvent("v2:money", "PLAYER_MONEY", function()
        ns.Features.StatusPillHud:RefreshLive()
        ns.Features.LedgerPage:SyncFromPlayerMoney()
    end)
    ns.Api.EventBus:OnEvent("v2:merchantShow", "MERCHANT_SHOW", function()
        ns.Features.MerchantModule:OnMerchantShow()
    end)
    ns.Api.EventBus:OnEvent("v2:merchantClose", "MERCHANT_CLOSED", function()
        ns.Features.MerchantModule:OnMerchantClosed()
    end)
    ns.Api.EventBus:OnEvent("v2:qDetail", "QUEST_DETAIL", function()
        ns.Features.QuestAutomation:OnQuestDetail()
    end)
    ns.Api.EventBus:OnEvent("v2:qProgress", "QUEST_PROGRESS", function()
        ns.Features.QuestAutomation:OnQuestProgress()
    end)
    ns.Api.EventBus:OnEvent("v2:qComplete", "QUEST_COMPLETE", function()
        ns.Features.QuestAutomation:OnQuestComplete()
    end)
    ns.Api.EventBus:OnEvent("v2:qAccepted", "QUEST_ACCEPTED", function(_, a1, a2)
        local qid = (type(a2) == "number") and a2 or a1
        ns.Features.QuestAutomation:OnQuestAccepted(qid)
    end)
    ns.Api.EventBus:OnEvent("v2:lootReady", "LOOT_READY", function()
        ns.Features.QoLModule:OnLootReady()
    end)
    ns.Api.EventBus:OnEvent("v2:playerDead", "PLAYER_DEAD", function()
        ns.Features.EncounterTimerHud:OnPlayerDead()
        ns.Features.QoLModule:OnPlayerDead()
    end)
    ns.Api.EventBus:OnEvent("v2:resRequest", "RESURRECT_REQUEST", function(_, casterName)
        ns.Features.QoLModule:OnResurrectRequest(casterName)
    end)
    ns.Api.EventBus:OnEvent("v2:partyInvite", "PARTY_INVITE_REQUEST", function(_, inviterName)
        ns.Features.QoLModule:OnPartyInviteRequest(inviterName)
    end)
    ns.Api.EventBus:OnEvent("v2:xpUpdate", "PLAYER_XP_UPDATE", function()
        ns.Features.QoLModule:SyncSessionXP()
    end)
    ns.Api.EventBus:OnEvent("v2:levelUp", "PLAYER_LEVEL_UP", function()
        ns.Features.QoLModule:SyncSessionXP()
    end)
    ns.Api.EventBus:OnEvent("v2:encStart", "ENCOUNTER_START", function(_, _, encounterName)
        ns.Features.EncounterTimerHud:OnEncounterStart(encounterName)
    end)
    ns.Api.EventBus:OnEvent("v2:encEnd", "ENCOUNTER_END", function(_, _, encounterName, _, _, success)
        ns.Features.EncounterTimerHud:OnEncounterEnd(encounterName, success)
    end)
    ns.Api.EventBus:OnEvent("v2:aura", "UNIT_AURA", function(_, unit)
        if unit == "player" then ns.Features.CombatAssistHud:Refresh() end
    end)
    ns.Api.EventBus:OnEvent("v2:hp", "UNIT_HEALTH", function(_, unit)
        if unit == "player" then ns.Features.CombatAssistHud:Refresh() end
    end)
    ns.Api.EventBus:OnEvent("v2:enchant", "WEAPON_ENCHANT_CHANGED", function()
        ns.Features.CombatAssistHud:Refresh()
    end)
    ns.Api.EventBus:OnEvent("v2:equip", "UNIT_INVENTORY_CHANGED", function(_, unit)
        if unit == "player" then ns.Features.FishingCardHud:Refresh() end
    end)
    ns.Api.EventBus:OnEvent("v2:zone", "ZONE_CHANGED_NEW_AREA", function()
        ns.Features.FishingCardHud:Refresh()
        ns.Features.NavigationHud:Refresh()
        ns.Features.EncounterTimerHud:OnZoneOrInstanceChanged()
    end)
    ns.Api.EventBus:OnEvent("v2:combatStart", "PLAYER_REGEN_DISABLED", function()
        ns.Features.CombatAssistHud:Refresh(true)
        ns.Features.EncounterTimerHud:OnCombatStart()
    end)
    ns.Api.EventBus:OnEvent("v2:combatEnd", "PLAYER_REGEN_ENABLED", function()
        ns.Secure.CombatQueue:Flush()
        ns.Api.NavPort.FlushIfSafe()
        ns.Features.QuestTrackerView:ReRenderLast()
        ns.Features.CombatAssistHud:Refresh(false)
        ns.Features.EncounterTimerHud:OnCombatEnd()
        ns.Features.QoLModule:ApplyCameraZoomIfEnabled()
    end)

    ns.Api.EventBus:OnEvent("v2:taintBlocked", "ADDON_ACTION_BLOCKED", function(_, addonName, funcName)
        RecordTaintEvent("BLOCKED", addonName, funcName)
    end)
    ns.Api.EventBus:OnEvent("v2:taintForbidden", "ADDON_ACTION_FORBIDDEN", function(_, addonName, funcName)
        RecordTaintEvent("FORBIDDEN", addonName, funcName)
    end)

    if type(_G.SlashCmdList) == "table" then
        _G.SLASH_FOREVERSUITEV21 = "/fs2"
        _G.SlashCmdList["FOREVERSUITEV2"] = function(raw)
            local trimmed = string_match(tostring(raw or ""), "^%s*(.-)%s*$") or ""
            local cmd, rest = string_match(trimmed, "^(%S+)%s*(.*)$")
            cmd = cmd and string_lower(cmd) or ""
            if cmd == "move" then
                local unlocked = ns.UI.HudLayout:ToggleUnlock()
                ns.Api.SafeAPI.Print(unlocked and "HUD 이동 모드 활성화 (/fs2 move)" or "HUD 위치 잠금")
            elseif cmd == "codex" or cmd == "ledger" or cmd == "settings" then
                local win = ns.UI.CommandHub:EnsureWindow()
                win:Show()
                ns.UI.CommandHub:SelectPage(cmd)
            elseif cmd == "protect" then
                ns.Features.MerchantModule:ToggleProtectItem(rest)
            elseif cmd == "cheap" then
                ns.Features.MerchantModule:PrintCheapestItems()
            elseif cmd == "layer" then
                local layer = ns.Api.GameAdapters.GetZoneLayerID("target")
                ns.Api.SafeAPI.Print(layer and ("현재 대상 위상(ZoneUID): #" .. tostring(layer)) or "대상을 선택하면 위상(ZoneUID)을 확인할 수 있습니다.")
            elseif cmd == "xp" then
                ns.Features.QoLModule:HandleXPCommand(rest)
            elseif cmd == "pull" then
                ns.Features.EncounterTimerHud:HandlePullCommand(rest)
            elseif cmd == "timer" then
                ns.Features.EncounterTimerHud:PrintStatus()
            else
                ns.UI.CommandHub:Toggle()
            end
        end

        _G.SLASH_FOREVERSUITEWAYV21 = "/way2"
        _G.SlashCmdList["FOREVERSUITEWAYV2"] = function(raw)
            ns.Features.NavigationHud:HandleWaySlash(raw)
        end
    end

    self.initialized = true
end

_G.ForeverSuiteV2 = ns

ns.Api.EventBus:OnEvent("v2:boot", "PLAYER_LOGIN", function()
    Bootstrap:Init()
end)
