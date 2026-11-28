-- Module: Features/TrackingSwitcher.lua
-- Responsibility: Lightweight OOC Classic/Forever Herb/Ore/Treasure tracking cycler (/fs track) using verified
--                 GameAdapters gathering tracker queries (zero combat actions, zero taint).
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local TrackingSwitcher = {
    lastIndex = 0,
}
ns.Features.TrackingSwitcher = TrackingSwitcher

function TrackingSwitcher:CycleNext()
    if ns.Api.SafeAPI.InCombat() then
        ns.Api.SafeAPI.Print("전투 중에는 채집 추적을 전환할 수 없습니다.")
        return false, "IN_COMBAT"
    end
    local list = ns.Api.GameAdapters.GetGatheringTrackers and ns.Api.GameAdapters.GetGatheringTrackers() or {}
    if #list == 0 then
        ns.Api.SafeAPI.Print("활성 가능한 채집 추적(약초/광맥/보물)이 없습니다.")
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
        ns.Api.ProfileStore:SetState("lastTrackingName", pick.name)
        ns.Api.SafeAPI.Print("채집 추적 전환: " .. tostring(pick.name))
        return true, pick.name
    end
    ns.Api.SafeAPI.Print("채집 추적 전환에 실패했습니다 (" .. tostring(pick.name) .. ").")
    return false, "FAILED"
end
