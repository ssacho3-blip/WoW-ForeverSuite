-- Module: Features/QoLModule.lua
-- Responsibility: Safe QoL automation (Fast Loot, BG-only Release, OOC Res, Friend/Guild Invite, OOC Max Camera Zoom) + Session XP/h tracker (/fs2 xp).
-- Layer: Features (zero raw C_* / CreateFrame calls; delegates to Domain/QoLModel + Api/GameAdapters).
local _, ns = ...
ns.Features = ns.Features or {}

local tostring = tostring
local string_format = string.format
local string_lower = string.lower
local string_match = string.match

local QoLModule = {
    xpState = nil,
    savedCameraZoom = nil,
}
ns.Features.QoLModule = QoLModule

function QoLModule:EnsureXPState()
    if not self.xpState then
        local now = ns.Api.GameAdapters.GetMonotonicTime() or 0
        self.xpState = ns.Domain.QoLModel.CreateXPState(now)
    end
    return self.xpState
end

function QoLModule:ResetSessionXP()
    local now = ns.Api.GameAdapters.GetMonotonicTime() or 0
    self.xpState = ns.Domain.QoLModel.CreateXPState(now)
    local xp, maxXP, lvl, _, _, ok = ns.Api.GameAdapters.GetPlayerXPInfo()
    if ok then
        ns.Domain.QoLModel.UpdateXPState(self.xpState, xp, maxXP, lvl, now)
    end
    return true
end

function QoLModule:SyncSessionXP()
    local state = self:EnsureXPState()
    local now = ns.Api.GameAdapters.GetMonotonicTime() or 0
    local xp, maxXP, lvl, _, _, ok = ns.Api.GameAdapters.GetPlayerXPInfo()
    if not ok then
        return ns.Domain.QoLModel.UpdateXPState(state, nil, nil, nil, now)
    end
    return ns.Domain.QoLModel.UpdateXPState(state, xp, maxXP, lvl, now)
end

function QoLModule:GetSessionXPStats()
    local state = self:EnsureXPState()
    local now = ns.Api.GameAdapters.GetMonotonicTime() or 0
    local xp, maxXP, lvl, maxLvl, rested, ok = ns.Api.GameAdapters.GetPlayerXPInfo()
    if not ok then
        return nil
    end
    if not state.initialized then
        ns.Domain.QoLModel.UpdateXPState(state, xp, maxXP, lvl, now)
    end
    return ns.Domain.QoLModel.ComputeXPStats(state, xp, maxXP, lvl, maxLvl, rested, now)
end

function QoLModule:HandleXPCommand(rawArg)
    local sub = string_lower(string_match(tostring(rawArg or ""), "^%s*(%S*)") or "")
    if sub == "reset" or sub == "초기화" then
        self:ResetSessionXP()
        ns.Api.SafeAPI.Print("세션 XP 통계를 초기화했습니다.")
        return true, "RESET"
    end
    self:SyncSessionXP()
    local st = self:GetSessionXPStats()
    if not st then
        ns.Api.SafeAPI.Print("현재 경험치 정보를 읽을 수 없습니다(API/Secret 불가).")
        return false, "UNREADABLE"
    end
    local Q = ns.Domain.QoLModel
    if st.isMaxLevel then
        ns.Api.SafeAPI.Print(string_format("최고 레벨(Lv.%d) 상태입니다. (세션 경과 %s)", st.level, Q.FormatDuration(st.elapsedSec)))
        return true, "MAX_LEVEL"
    end
    local rateStr = st.xpPerHour and (Q.FormatNumberWithCommas(st.xpPerHour) .. " XP/h") or "집계 중"
    local etaStr = st.etaSec and Q.FormatDuration(st.etaSec) or "—"
    local gapTag = st.secretGap and " [일부 구간 Secret 미집계]" or ""
    ns.Api.SafeAPI.Print(string_format(
        "세션 XP: +%s (%s) | 속도: %s | Lv.%d까지 %s (%.1f%%, 예상 %s)%s",
        Q.FormatNumberWithCommas(st.sessionGained),
        Q.FormatDuration(st.elapsedSec),
        rateStr,
        st.level + 1,
        Q.FormatNumberWithCommas(st.remainingXP),
        st.pct,
        etaStr,
        gapTag
    ))
    return true, "PRINTED"
end

function QoLModule:OnLootReady()
    local enabled = ns.Api.ProfileStore:Get("qol", "fastLoot") == true
    local v1 = ns.Api.SafeAPI.IsV1Loaded()
    local cvarAuto = ns.Api.GameAdapters.GetCVarBool("autoLootDefault")
    local modDown = ns.Api.GameAdapters.IsAutoLootModifierDown()
    local shouldLoot, reason = ns.Domain.QoLModel.ShouldFastLoot(enabled, v1, cvarAuto, modDown)
    if not shouldLoot then
        return false, reason
    end
    local n = ns.Api.GameAdapters.FastLootAll()
    return n > 0, (n > 0 and "LOOTED" or "EMPTY")
end

function QoLModule:OnPlayerDead()
    local enabled = ns.Api.ProfileStore:Get("qol", "autoReleaseBG") == true
    local v1 = ns.Api.SafeAPI.IsV1Loaded()
    local shift = ns.Api.GameAdapters.IsShiftDownState()
    local inInst, instType = ns.Api.GameAdapters.GetInstanceContext()
    local hasSelfRes = ns.Api.GameAdapters.HasSelfResOption()
    local shouldRel, reason = ns.Domain.QoLModel.ShouldAutoReleaseSpirit(enabled, v1, shift, inInst, instType, hasSelfRes)
    if not shouldRel then
        return false, reason
    end
    local ok = ns.Api.GameAdapters.ReleaseSpiritSafe()
    if ok then
        ns.Api.SafeAPI.Print("전장 자동 영혼 해제를 실행했습니다.")
    end
    return ok, ok and "RELEASED" or "FAILED"
end

function QoLModule:OnResurrectRequest(casterName)
    local enabled = ns.Api.ProfileStore:Get("qol", "autoAcceptRes") == true
    local v1 = ns.Api.SafeAPI.IsV1Loaded()
    local shift = ns.Api.GameAdapters.IsShiftDownState()
    local bossActive = (ns.Features.EncounterTimerHud and ns.Features.EncounterTimerHud:IsBossActive()) == true
    local inCombat = ns.Api.GameAdapters.IsResurrectInCombat(casterName, bossActive)
    local shouldAcc, reason = ns.Domain.QoLModel.ShouldAutoAcceptRes(enabled, v1, shift, inCombat)
    if not shouldAcc then
        return false, reason
    end
    local ok, resReason = ns.Api.GameAdapters.AcceptResurrectSafe(casterName, bossActive)
    if ok then
        ns.Api.SafeAPI.Print("비전투 부활 요청을 자동 수락했습니다.")
    end
    return ok, resReason
end

function QoLModule:OnPartyInviteRequest(inviterName)
    local enabled = ns.Api.ProfileStore:Get("qol", "autoAcceptFriends") == true
    local v1 = ns.Api.SafeAPI.IsV1Loaded()
    local shift = ns.Api.GameAdapters.IsShiftDownState()
    local trusted = ns.Api.GameAdapters.IsTrustedInviter(inviterName)
    local shouldAcc, reason = ns.Domain.QoLModel.ShouldAutoAcceptInvite(enabled, v1, shift, trusted)
    if not shouldAcc then
        return false, reason
    end
    local ok = ns.Api.GameAdapters.AcceptGroupInviteSafe()
    if ok then
        ns.Api.SafeAPI.Print("친구/길드원 파티 초대를 자동 수락했습니다.")
    end
    return ok, ok and "ACCEPTED" or "FAILED"
end

function QoLModule:ApplyCameraZoomIfEnabled()
    local enabled = ns.Api.ProfileStore:Get("qol", "maxCameraZoom") == true
    local savedPrev = ns.Api.ProfileStore:GetState("cameraZoomPrev") or self.savedCameraZoom

    -- Restore BEFORE v1 yield check so disabling always restores cleanly even if v1 loads mid-session
    if not enabled then
        if savedPrev ~= nil and tostring(savedPrev) ~= "" then
            local ok, reason = ns.Api.GameAdapters.SetCVarSafe("cameraDistanceMaxZoomFactor", savedPrev)
            if ok then
                self.savedCameraZoom = nil
                ns.Api.ProfileStore:SetState("cameraZoomPrev", nil)
            end
            return ok, reason
        end
        return false, "DISABLED"
    end

    if ns.Api.SafeAPI.IsV1Loaded() then
        return false, "YIELDED_TO_V1"
    end

    if savedPrev == nil then
        local prev = ns.Api.GameAdapters.GetCVarRaw("cameraDistanceMaxZoomFactor")
        if prev ~= nil and tostring(prev) ~= "" then
            local prevStr = tostring(prev)
            self.savedCameraZoom = prevStr
            ns.Api.ProfileStore:SetState("cameraZoomPrev", prevStr)
        end
    end
    return ns.Api.GameAdapters.SetCVarSafe("cameraDistanceMaxZoomFactor", "2.6")
end
