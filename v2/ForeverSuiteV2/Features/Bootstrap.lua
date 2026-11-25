-- Module: Features/Bootstrap.lua
-- Responsibility: Wires v2 live declarative schemas, L2 Command Hub, WorldMap/Combat/Bag/Quest events, and /fs2 commands.
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local pairs = pairs
local string_match = string.match
local string_lower = string.lower

local MAX_TAINT_KEYS = 200

-- Every declared setting MUST have a live consumer (Zero Fabricated/No-Op Settings invariant).
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
        label = "상단 상태 필 바 표시 (가방·골드·렐름)",
        desc = "L0 상시 HUD 상태 요약 바 표시/숨김",
        combatSafe = true,
    },
}

local Bootstrap = {
    initialized = false,
}
ns.Features.Bootstrap = Bootstrap

local function ApplyTrackerModeSafely(requestedMode)
    -- Yield ObjectiveTracker control to live v1 ForeverSuite when both are loaded!
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

    ns.UI.CommandHub:RegisterPage(ns.Features.DiagnosticsPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.SettingsPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.CodexPage)

    ns.Blizzard.WorldMapAdapter:Init()

    local mode = ns.Api.ProfileStore:Get("quest", "defaultTrackerMode") or "coexist"
    ApplyTrackerModeSafely(mode)

    ns.Api.EventBus:Subscribe("setting:changed", function(sec, key, val)
        if sec == "quest" and key == "defaultTrackerMode" then
            ApplyTrackerModeSafely(val)
        elseif sec == "ui" and key == "showStatusPill" then
            ns.Features.StatusPillHud:ApplyVisibility()
        end
    end)

    ns.Features.QuestTrackerView:Init()
    ns.Features.QuestTrackerView:RefreshLive()
    ns.Features.StatusPillHud:Init()

    -- Re-check WorldMapAdapter on late ADDON_LOADED
    ns.Api.EventBus:OnEvent("v2:addonLoaded", "ADDON_LOADED", function()
        ns.Blizzard.WorldMapAdapter:Init()
    end)

    -- Live data feeds for QuestTracker & StatusPill
    ns.Api.EventBus:OnEvent("v2:questLog", "QUEST_LOG_UPDATE", function()
        ns.Features.QuestTrackerView:RefreshLive()
    end)
    ns.Api.EventBus:OnEvent("v2:superTrack", "SUPER_TRACKING_CHANGED", function()
        ns.Features.QuestTrackerView:RefreshLive()
    end)
    ns.Api.EventBus:OnEvent("v2:bags", "BAG_UPDATE_DELAYED", function()
        ns.Features.StatusPillHud:RefreshLive()
    end)
    ns.Api.EventBus:OnEvent("v2:money", "PLAYER_MONEY", function()
        ns.Features.StatusPillHud:RefreshLive()
    end)

    -- Combat exit drains protected queue, flushes NavPort, and re-renders tracker labels to match flushed dock!
    ns.Api.EventBus:OnEvent("v2:combat", "PLAYER_REGEN_ENABLED", function()
        ns.Secure.CombatQueue:Flush()
        ns.Api.NavPort.FlushIfSafe()
        ns.Features.QuestTrackerView:ReRenderLast()
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
            local cmd = string_lower(string_match(tostring(raw or ""), "^%s*(%S*)") or "")
            if cmd == "move" then
                local unlocked = ns.UI.HudLayout:ToggleUnlock()
                ns.Api.SafeAPI.Print(unlocked and "HUD 이동 모드 활성화 (/fs2 move)" or "HUD 위치 잠금")
            elseif cmd == "codex" then
                local win = ns.UI.CommandHub:EnsureWindow()
                win:Show()
                ns.UI.CommandHub:SelectPage("codex")
            else
                ns.UI.CommandHub:Toggle()
            end
        end
    end

    self.initialized = true
end

_G.ForeverSuiteV2 = ns

ns.Api.EventBus:OnEvent("v2:boot", "PLAYER_LOGIN", function()
    Bootstrap:Init()
end)
