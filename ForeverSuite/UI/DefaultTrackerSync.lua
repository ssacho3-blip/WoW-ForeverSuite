-- Module: UI/DefaultTrackerSync.lua
-- Responsibility: Non-tainting hide/restore synchronization for Blizzard ObjectiveTrackerFrame/QuestWatchFrame with EditMode respect.
-- Dependencies: Core/Init.lua (ns.IsSecret, ns.CombatQueue), Core/ProfileManager.lua (ns.ProfileManager).
-- Public API: ns.QuestTracker:SyncDefaultTrackerVisibility.
-- Combat/Secret Safety: Uses HookScript only (never replaces native scripts); defers Show/Hide via CombatQueue during lockdown.
local _, ns = ...

local type = type
local tostring = tostring
local pcall = pcall
local setmetatable = setmetatable

local QuestTracker = ns.QuestTracker or {}
ns.QuestTracker = QuestTracker

local hookedDefaultFrames = setmetatable and setmetatable({}, { __mode = "k" }) or {}
local hookedEditModeFrames = setmetatable and setmetatable({}, { __mode = "k" }) or {}
local hiddenByUs = setmetatable and setmetatable({}, { __mode = "k" }) or {}

local function IsEditModeActive()
    local em = _G.EditModeManagerFrame
    if not ns.IsSecret(em) and type(em) == "table" and not ns.IsSecret(em.editModeActive) and em.editModeActive == true then
        return true
    end
    return false
end

local function EnsureEditModeExitHook()
    local em = _G.EditModeManagerFrame
    if not ns.IsSecret(em) and type(em) == "table" and not hookedEditModeFrames[em] and em.HookScript then
        hookedEditModeFrames[em] = true
        pcall(em.HookScript, em, "OnHide", function()
            QuestTracker:SyncDefaultTrackerVisibility()
        end)
    end
end

function QuestTracker:SyncDefaultTrackerVisibility()
    EnsureEditModeExitHook()
    local shouldHide = self.active
        and ns.ProfileManager:Get("quest", "trackerEnabled")
        and ns.ProfileManager:Get("quest", "hideDefaultTracker")
        and true
        or false

    local targets = { _G.ObjectiveTrackerFrame, _G.QuestWatchFrame }
    for i = 1, #targets do
        local targetFrame = targets[i]
        if not ns.IsSecret(targetFrame) and type(targetFrame) == "table" then
            if shouldHide and not hookedDefaultFrames[targetFrame] and targetFrame.HookScript then
                hookedDefaultFrames[targetFrame] = true
                pcall(targetFrame.HookScript, targetFrame, "OnShow", function(shownFrame)
                    if not QuestTracker.active then
                        return
                    end
                    if not ns.ProfileManager:Get("quest", "trackerEnabled") or not ns.ProfileManager:Get("quest", "hideDefaultTracker") then
                        return
                    end
                    if IsEditModeActive() then
                        return
                    end
                    ns.CombatQueue:RunOrDefer("quest:hideDefault:" .. tostring(i), function()
                        if QuestTracker.active
                            and ns.ProfileManager:Get("quest", "trackerEnabled")
                            and ns.ProfileManager:Get("quest", "hideDefaultTracker")
                            and not IsEditModeActive()
                            and shownFrame.Hide
                        then
                            hiddenByUs[shownFrame] = true
                            shownFrame:Hide()
                        end
                    end)
                end)
            end

            if shouldHide then
                local currentlyShown = (not targetFrame.IsShown) or (targetFrame:IsShown() and true or false)
                if currentlyShown and not IsEditModeActive() then
                    ns.CombatQueue:RunOrDefer("quest:syncDefault:" .. tostring(i), function()
                        if QuestTracker.active
                            and ns.ProfileManager:Get("quest", "trackerEnabled")
                            and ns.ProfileManager:Get("quest", "hideDefaultTracker")
                            and not IsEditModeActive()
                            and targetFrame.Hide
                        then
                            hiddenByUs[targetFrame] = true
                            targetFrame:Hide()
                        end
                    end)
                end
            elseif hiddenByUs[targetFrame] then
                if not IsEditModeActive() then
                    ns.CombatQueue:RunOrDefer("quest:syncDefault:" .. tostring(i), function()
                        if not IsEditModeActive() then
                            hiddenByUs[targetFrame] = nil
                            if targetFrame.Show then
                                targetFrame:Show()
                            end
                        end
                    end)
                end
            end
        end
    end
end
