-- Module: Blizzard/ObjectiveTrackerAdapter.lua
-- Responsibility: Zero-taint 3-mode (coexist true no-op / dim alpha / hide non-combat) adapter for ObjectiveTrackerFrame.
-- Layer: Blizzard
local _, ns = ...
ns.Blizzard = ns.Blizzard or {}

local pcall = pcall

local Adapter = {
    mode = "coexist",
    hooked = false,
    touched = false,
}
ns.Blizzard.ObjectiveTrackerAdapter = Adapter

local function GetTrackerFrame()
    return _G.ObjectiveTrackerFrame
end

local function EnsureHook(frame)
    if Adapter.hooked or not (frame and type(frame.HookScript) == "function") then
        return
    end
    Adapter.hooked = true
    pcall(frame.HookScript, frame, "OnShow", function(f)
        if Adapter.mode == "dim" and f.SetAlpha then
            pcall(f.SetAlpha, f, 0.15)
        elseif Adapter.mode == "hide" then
            if f.SetAlpha then
                pcall(f.SetAlpha, f, 0)
            end
            ns.Secure.CombatQueue:RunOrDefer("blizz:hideObjTracker", function()
                if Adapter.mode == "hide" and f.Hide then
                    pcall(f.Hide, f)
                end
            end)
        end
    end)
end

function Adapter:ApplyMode(mode)
    local nextMode = mode or "coexist"
    self.mode = nextMode
    local frame = GetTrackerFrame()
    if not frame then
        return false
    end

    -- True hands-off default: never touch Blizzard's tracker if coexist and never touched in this session!
    if nextMode == "coexist" then
        if not self.touched then
            return true
        end
        if frame.SetAlpha then
            pcall(frame.SetAlpha, frame, 1.0)
        end
        ns.Secure.CombatQueue:RunOrDefer("blizz:showObjTracker", function()
            if Adapter.mode == "coexist" and frame.Show then
                pcall(frame.Show, frame)
            end
        end)
        return true
    end

    self.touched = true
    EnsureHook(frame)

    if nextMode == "dim" then
        if frame.SetAlpha then
            pcall(frame.SetAlpha, frame, 0.15)
        end
        ns.Secure.CombatQueue:RunOrDefer("blizz:showObjTracker", function()
            if Adapter.mode == "dim" and frame.Show then
                pcall(frame.Show, frame)
            end
        end)
    elseif nextMode == "hide" then
        if frame.SetAlpha then
            pcall(frame.SetAlpha, frame, 0)
        end
        ns.Secure.CombatQueue:RunOrDefer("blizz:hideObjTracker", function()
            if Adapter.mode == "hide" and frame.Hide then
                pcall(frame.Hide, frame)
            end
        end)
    end
    return true
end
