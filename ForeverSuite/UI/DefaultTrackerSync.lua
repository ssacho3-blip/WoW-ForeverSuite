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
local alphaZeroedByUs = setmetatable and setmetatable({}, { __mode = "k" }) or {}

local function IsEditModeActive()
    local em = _G.EditModeManagerFrame
    if not ns.IsSecret(em) and type(em) == "table" and not ns.IsSecret(em.editModeActive) and em.editModeActive == true then
        return true
    end
    return false
end

local function ShouldHideDefaultTracker()
    return QuestTracker.active
        and (not ns.IsFeatureYielded("questTrackerHud"))
        and ns.ProfileManager:Get("quest", "trackerEnabled")
        and ns.ProfileManager:Get("quest", "hideDefaultTracker")
        and true
        or false
end

local function TrySetAlpha(frame, alpha)
    if not frame or not frame.SetAlpha then
        return false
    end
    return pcall(frame.SetAlpha, frame, alpha) and true or false
end

local function HideDefaultFrame(frame)
    if not ShouldHideDefaultTracker() or IsEditModeActive() or not frame then
        return
    end
    if TrySetAlpha(frame, 0) then
        alphaZeroedByUs[frame] = true
    end
    if frame.Hide and pcall(frame.Hide, frame) then
        hiddenByUs[frame] = true
    end
end

local function RestoreDefaultFrame(frame)
    if not frame or ShouldHideDefaultTracker() or IsEditModeActive() then
        return
    end
    if alphaZeroedByUs[frame] and not TrySetAlpha(frame, 1) then
        return
    end
    if hiddenByUs[frame] then
        if not (frame.Show and pcall(frame.Show, frame)) then
            return
        end
        hiddenByUs[frame] = nil
    end
    alphaZeroedByUs[frame] = nil
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
    local shouldHide = ShouldHideDefaultTracker()

    local targets = { _G.ObjectiveTrackerFrame, _G.QuestWatchFrame }
    for i = 1, 2 do
        local slot = i
        local targetFrame = targets[slot]
        if not ns.IsSecret(targetFrame) and type(targetFrame) == "table" then
            if shouldHide and not hookedDefaultFrames[targetFrame] and targetFrame.HookScript then
                hookedDefaultFrames[targetFrame] = true
                pcall(targetFrame.HookScript, targetFrame, "OnShow", function(shownFrame)
                    if not ShouldHideDefaultTracker() or IsEditModeActive() then
                        return
                    end
                    -- Alpha is unprotected: hide visually mid-combat before CombatQueue can run Hide().
                    if TrySetAlpha(shownFrame, 0) then
                        alphaZeroedByUs[shownFrame] = true
                    end
                    ns.CombatQueue:RunOrDefer("quest:hideDefault:" .. tostring(slot), function()
                        HideDefaultFrame(shownFrame)
                    end)
                end)
            end

            if shouldHide then
                local currentlyShown = (not targetFrame.IsShown) or (targetFrame:IsShown() and true or false)
                if currentlyShown and not IsEditModeActive() then
                    if TrySetAlpha(targetFrame, 0) then
                        alphaZeroedByUs[targetFrame] = true
                    end
                    ns.CombatQueue:RunOrDefer("quest:syncDefault:" .. tostring(slot), function()
                        HideDefaultFrame(targetFrame)
                    end)
                end
            elseif hiddenByUs[targetFrame] or alphaZeroedByUs[targetFrame] then
                if not IsEditModeActive() then
                    ns.CombatQueue:RunOrDefer("quest:syncDefault:" .. tostring(slot), function()
                        RestoreDefaultFrame(targetFrame)
                    end)
                end
            end
        end
    end
end
