-- Module: Features/CorpseGuideModule.lua
-- Responsibility: KPI-11 Corpse Guide Auto-Waypoint (automatically points NavigationHud to player's corpse on death
--                 via verified C_DeathInfo.GetCorpseMapPosition and clears cleanly on resurrection).
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local CorpseGuideModule = {
    deathMapID = nil,
    active = false,
}
ns.Features.CorpseGuideModule = CorpseGuideModule

function CorpseGuideModule:OnPlayerDead()
    local pos = ns.Api.GameAdapters.GetPlayerPosition()
    self.deathMapID = pos and pos.mapID or self.deathMapID
    self:Refresh()
end

function CorpseGuideModule:Refresh()
    if ns.Api.ProfileStore:Get("qol", "corpseGuide") == false then
        if self.active then
            self:Clear()
        end
        return false, "DISABLED"
    end
    if not ns.Api.GameAdapters.IsPlayerDeadOrGhost() then
        if self.active then
            self:Clear()
        end
        return false, "ALIVE"
    end
    local corpse = ns.Api.GameAdapters.GetCorpsePosition(self.deathMapID)
    if not corpse then
        return false, "NO_CORPSE_POS"
    end
    self.active = true
    if ns.Features.NavigationHud then
        ns.Features.NavigationHud:SetTarget(corpse.mapID, corpse.x, corpse.y, "내 시체 위치")
    end
    return true, "GUIDING"
end

function CorpseGuideModule:Clear()
    self.active = false
    self.deathMapID = nil
    if ns.Features.NavigationHud and ns.Features.NavigationHud.target
        and ns.Features.NavigationHud.target.label == "내 시체 위치"
    then
        ns.Features.NavigationHud:Clear()
    end
end

function CorpseGuideModule:OnPlayerRevived()
    self:Clear()
end
