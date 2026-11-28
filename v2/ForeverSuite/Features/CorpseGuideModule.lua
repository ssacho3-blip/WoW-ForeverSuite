-- Module: Features/CorpseGuideModule.lua
-- Responsibility: Corpse Guide Auto-Waypoint with Feign Death (5384) exclusion, manual /way preDeathTarget backup &
--                 restoration on resurrection, and verified C_DeathInfo.GetCorpseMapPosition lookup.
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local CorpseGuideModule = {
    deathMapID = nil,
    active = false,
    preDeathTarget = nil,
}
ns.Features.CorpseGuideModule = CorpseGuideModule

local function IsActuallyDeadOrGhost()
    if ns.Api.GameAdapters.IsPlayerFeignDeath and ns.Api.GameAdapters.IsPlayerFeignDeath() then
        return false
    end
    return ns.Api.GameAdapters.IsPlayerDeadOrGhost() == true
end

function CorpseGuideModule:OnPlayerDead()
    if not IsActuallyDeadOrGhost() then
        return false, "FEIGN_DEATH"
    end
    local pos = ns.Api.GameAdapters.GetPlayerPosition()
    self.deathMapID = pos and pos.mapID or self.deathMapID
    -- Backup active waypoint (manual OR quest metadata) before pointing to corpse
    if (not self.active) and ns.Features.NavigationHud and type(ns.Features.NavigationHud.target) == "table"
        and ns.Features.NavigationHud.target.label ~= "내 시체 위치"
    then
        local t = ns.Features.NavigationHud.target
        self.preDeathTarget = {
            mapID = t.mapID,
            x = t.x,
            y = t.y,
            label = t.label,
            source = t.source,
            questID = t.questID,
            isComplete = t.isComplete,
            waypointText = t.waypointText,
        }
    end
    return self:Refresh()
end

function CorpseGuideModule:Refresh()
    if ns.Api.ProfileStore:Get("qol", "corpseGuide") == false then
        if self.active then
            self:Clear()
        end
        return false, "DISABLED"
    end
    if not IsActuallyDeadOrGhost() then
        if self.active then
            self:Clear()
        else
            self.preDeathTarget = nil
            self.deathMapID = nil
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
    local wasActive = self.active
    self.active = false
    self.deathMapID = nil
    local saved = self.preDeathTarget
    self.preDeathTarget = nil
    local nav = ns.Features.NavigationHud
    if not nav then return end
    local cur = nav.target
    -- Restore if corpse target is still active OR was already auto-cleared on corpse arrival (cur == nil).
    -- Do NOT clobber if the user explicitly set a brand-new non-corpse target while dead.
    local canRestore = (cur == nil) or (cur.label == "내 시체 위치")
    if wasActive and canRestore and saved and saved.mapID and saved.x and saved.y then
        if saved.source == "quest" and type(saved.questID) == "number" and type(nav.TrackQuest) == "function" then
            local ok = nav:TrackQuest(saved.questID, saved.label, { explicit = false })
            if not ok then
                nav:SetTarget(saved.mapID, saved.x, saved.y, saved.label, {
                    source = saved.source,
                    questID = saved.questID,
                    isComplete = saved.isComplete,
                    waypointText = saved.waypointText,
                })
            end
        else
            nav:SetTarget(saved.mapID, saved.x, saved.y, saved.label, {
                source = saved.source,
                questID = saved.questID,
                isComplete = saved.isComplete,
                waypointText = saved.waypointText,
            })
        end
    elseif cur and cur.label == "내 시체 위치" then
        nav:Clear()
    end
end

function CorpseGuideModule:OnPlayerRevived()
    self:Clear()
end
