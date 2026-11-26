-- Module: Blizzard/ObjectiveTrackerAdapter.lua
-- Responsibility: Zero-taint 3-mode (coexist / dim alpha / hide non-combat) adapter for Blizzard's default quest tracker frames
--                 (ObjectiveTrackerFrame, QuestObjectiveTracker, QuestWatchFrame, WatchFrame).
-- Layer: Blizzard
local _, ns = ...
ns.Blizzard = ns.Blizzard or {}

local pcall = pcall
local type = type
local ipairs = ipairs

local Adapter = {
    mode = "coexist",
    hooked = false,
    hookedFrames = {},
    touched = false,
}
ns.Blizzard.ObjectiveTrackerAdapter = Adapter

local CANDIDATE_NAMES = {
    "ObjectiveTrackerFrame",
    "QuestObjectiveTracker",
    "QuestWatchFrame",
    "WatchFrame",
}

local function CollectTrackerFrames()
    local frames = {}
    local seen = {}
    for _, name in ipairs(CANDIDATE_NAMES) do
        local f = _G[name]
        if type(f) == "table" and not seen[f] then
            local forbidden = (type(f.IsForbidden) == "function") and select(2, pcall(f.IsForbidden, f))
            if forbidden ~= true then
                seen[f] = true
                frames[#frames + 1] = { name = name, frame = f }
            end
        end
    end
    return frames
end

local function EnsureHook(frame, frameKey)
    if Adapter.hookedFrames[frame] or not (frame and type(frame.HookScript) == "function") then
        return
    end
    Adapter.hookedFrames[frame] = true
    Adapter.hooked = true
    pcall(frame.HookScript, frame, "OnShow", function(f)
        if Adapter.mode == "dim" and f.SetAlpha then
            pcall(f.SetAlpha, f, 0.15)
        elseif Adapter.mode == "hide" then
            if f.SetAlpha then
                pcall(f.SetAlpha, f, 0)
            end
            ns.Secure.CombatQueue:RunOrDefer("blizz:hideObjTracker:" .. tostring(frameKey), function()
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
    local entries = CollectTrackerFrames()
    if #entries == 0 then
        return false
    end

    -- True hands-off default: never touch Blizzard's tracker if coexist and never touched in this session!
    if nextMode == "coexist" then
        if not self.touched then
            return true
        end
        for _, entry in ipairs(entries) do
            local frame, key = entry.frame, entry.name
            if frame.SetAlpha then
                pcall(frame.SetAlpha, frame, 1.0)
            end
            ns.Secure.CombatQueue:RunOrDefer("blizz:showObjTracker:" .. key, function()
                if Adapter.mode == "coexist" and frame.Show then
                    pcall(frame.Show, frame)
                end
            end)
        end
        return true
    end

    self.touched = true
    for _, entry in ipairs(entries) do
        local frame, key = entry.frame, entry.name
        EnsureHook(frame, key)
        if nextMode == "dim" then
            if frame.SetAlpha then
                pcall(frame.SetAlpha, frame, 0.15)
            end
            ns.Secure.CombatQueue:RunOrDefer("blizz:showObjTracker:" .. key, function()
                if Adapter.mode == "dim" and frame.Show then
                    pcall(frame.Show, frame)
                end
            end)
        elseif nextMode == "hide" then
            if frame.SetAlpha then
                pcall(frame.SetAlpha, frame, 0)
            end
            ns.Secure.CombatQueue:RunOrDefer("blizz:hideObjTracker:" .. key, function()
                if Adapter.mode == "hide" and frame.Hide then
                    pcall(frame.Hide, frame)
                end
            end)
        end
    end
    return true
end
