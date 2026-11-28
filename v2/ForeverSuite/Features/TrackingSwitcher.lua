-- Module: Features/TrackingSwitcher.lua
-- Responsibility: Lightweight OOC Classic/Forever Herb/Ore/Treasure tracking cycler (/fs track),
--                 missing gathering tracker alert, and opt-in OOC Herb<->Ore auto-cycle ticker (0.00ms when idle).
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local string_lower = string.lower
local tostring = tostring

local ALERT_COOLDOWN_SEC = 300.0
local AUTO_CYCLE_INTERVAL_SEC = 4.0

local TrackingSwitcher = {
    lastIndex = 0,
    lastAlertAt = 0,
    autoTicker = nil,
}
ns.Features.TrackingSwitcher = TrackingSwitcher

function TrackingSwitcher:StopAutoCycle()
    if self.autoTicker then
        ns.Api.GameAdapters.CancelTicker(self.autoTicker)
        self.autoTicker = nil
    end
end

function TrackingSwitcher:CycleNext(silent)
    if ns.Api.SafeAPI.InCombat() then
        if not silent then
            ns.Api.SafeAPI.Print("전투 중에는 채집 추적을 전환할 수 없습니다.")
        end
        return false, "IN_COMBAT"
    end
    local list = ns.Api.GameAdapters.GetGatheringTrackers and ns.Api.GameAdapters.GetGatheringTrackers() or {}
    if #list == 0 then
        if not silent then
            ns.Api.SafeAPI.Print("활성 가능한 채집 추적(약초/광맥/보물)이 없습니다.")
        end
        return false, "NONE"
    end
    local activeIdx = 0
    for i = 1, #list do
        if list[i].active then
            activeIdx = i
            break
        end
    end
    local nextIdx = (activeIdx % #list) + 1
    local pick = list[nextIdx]
    local ok = ns.Api.GameAdapters.SetTrackingSafe and ns.Api.GameAdapters.SetTrackingSafe(pick.index, true) or false
    if ok then
        self.lastIndex = nextIdx
        if ns.Api.ProfileStore and ns.Api.ProfileStore:CanWrite() then
            ns.Api.ProfileStore:SetState("lastTrackingName", pick.name)
        end
        if not silent then
            ns.Api.SafeAPI.Print("채집 추적 전환: " .. tostring(pick.name))
        end
        return true, pick.name
    end
    if not silent then
        ns.Api.SafeAPI.Print("채집 추적 전환에 실패했습니다 (" .. tostring(pick.name) .. ").")
    end
    return false, "FAILED"
end

function TrackingSwitcher:CheckMissingTrackingAlert(force)
    if ns.Api.SafeAPI.InCombat() then
        return false, "IN_COMBAT"
    end
    if (not force) and ns.Api.ProfileStore and ns.Api.ProfileStore:Get("profession", "gatheringTrackAlert") == false then
        return false, "DISABLED"
    end
    if ns.Api.GameAdapters.IsPlayerDeadOrGhost and ns.Api.GameAdapters.IsPlayerDeadOrGhost() then
        return false, "DEAD"
    end
    local list = ns.Api.GameAdapters.GetGatheringTrackers and ns.Api.GameAdapters.GetGatheringTrackers() or {}
    if #list == 0 then
        return false, "NO_GATHER_TRACKER"
    end
    for i = 1, #list do
        if list[i].active then
            return false, "ACTIVE"
        end
    end
    local now = ns.Api.GameAdapters.GetMonotonicTime and ns.Api.GameAdapters.GetMonotonicTime() or 0
    if (not force) and self.lastAlertAt > 0 and (now - self.lastAlertAt) < ALERT_COOLDOWN_SEC then
        return false, "THROTTLED"
    end
    self.lastAlertAt = now
    local names = {}
    for i = 1, #list do
        names[#names + 1] = tostring(list[i].name)
    end
    ns.Api.SafeAPI.Print("[채집 추적 꺼짐] " .. table.concat(names, " / ") .. " 추적이 비활성화되어 있습니다 (/fs track)")
    return true, "ALERTED"
end

function TrackingSwitcher:SyncAutoCycle()
    local enabled = ns.Api.ProfileStore and ns.Api.ProfileStore:Get("profession", "autoCycleTracking") == true
    if (not enabled) or ns.Api.SafeAPI.InCombat() then
        self:StopAutoCycle()
        return false, enabled and "IN_COMBAT" or "DISABLED"
    end
    local list = ns.Api.GameAdapters.GetGatheringTrackers and ns.Api.GameAdapters.GetGatheringTrackers() or {}
    if #list < 2 then
        self:StopAutoCycle()
        return false, "NEED_TWO_TRACKERS"
    end
    if not self.autoTicker then
        self.autoTicker = ns.Api.GameAdapters.StartTicker(AUTO_CYCLE_INTERVAL_SEC, function()
            if ns.Api.SafeAPI.InCombat() then
                TrackingSwitcher:StopAutoCycle()
                return
            end
            if not (ns.Api.ProfileStore and ns.Api.ProfileStore:Get("profession", "autoCycleTracking") == true) then
                TrackingSwitcher:StopAutoCycle()
                return
            end
            if ns.Api.GameAdapters.IsPlayerDeadOrGhost and ns.Api.GameAdapters.IsPlayerDeadOrGhost() then
                return
            end
            TrackingSwitcher:CycleNext(true)
        end)
    end
    return true, "RUNNING"
end

function TrackingSwitcher:HandleCommand(raw)
    local arg = string_lower(tostring(raw or "")):match("^%s*(%S*)") or ""
    if arg == "auto" then
        local cur = ns.Api.ProfileStore and ns.Api.ProfileStore:Get("profession", "autoCycleTracking") == true
        local nextVal = not cur
        if ns.Api.ProfileStore and ns.Api.ProfileStore:CanWrite() then
            ns.Api.ProfileStore:Set("profession", "autoCycleTracking", nextVal)
        end
        local running, reason = self:SyncAutoCycle()
        if nextVal and running then
            ns.Api.SafeAPI.Print("채집 추적 비전투 자동 교대 ON (4초 간격 · 전투 진입 시 자동 중지)")
        elseif nextVal then
            ns.Api.SafeAPI.Print("채집 추적 자동 교대 ON 설정됨 (현재 대기: " .. tostring(reason) .. ")")
        else
            ns.Api.SafeAPI.Print("채집 추적 자동 교대 OFF")
        end
        return true, nextVal
    elseif arg == "check" then
        return self:CheckMissingTrackingAlert(true)
    end
    return self:CycleNext(false)
end
