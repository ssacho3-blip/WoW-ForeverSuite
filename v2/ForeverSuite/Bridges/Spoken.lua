-- Module: Bridges/Spoken.lua
-- Responsibility: Official Spoken TTS bridge - tracks voice playback state without mutating CVars,
--                 ducks non-survival ForeverSuite SFX while letting survival alerts pierce, and yields QuestAutomation.
-- Layer: Bridges (Rank 3: zero CVar mutations; AddGate scoped strictly to ForeverSuite-owned clip IDs).
local _, ns = ...
ns.Bridges = ns.Bridges or {}

local type = type
local pcall = pcall
local string_sub = string.sub

local SpokenBridge = {
    registered = false,
    playingFlag = false,
}
ns.Bridges.Spoken = SpokenBridge

local function GetSpoken()
    local sp = ns.Api.AddonProbe.GetGlobal("Spoken")
    return (type(sp) == "table") and sp or nil
end

function SpokenBridge:IsPlaying()
    local sp = GetSpoken()
    if not sp then
        return false
    end
    if type(sp.IsPlaying) == "function" then
        local ok, playing = pcall(sp.IsPlaying, sp)
        if ok then
            self.playingFlag = playing == true
            return self.playingFlag
        end
        -- Fail-Safe: unknown playback state pauses non-essential FS SFX
        return true
    end
    return self.playingFlag == true
end

-- C2 / C7 contract: skip non-survival FS SFX & fishing sound boost while Spoken is playing;
-- critical survival warnings (e.g. HP <= 30%) always bypass audio ducking.
function SpokenBridge:ShouldDuckAudio(isSurvivalAlert)
    if isSurvivalAlert == true then
        return false
    end
    if ns.Bridges.BridgeHost:GetState("spoken") ~= "BRIDGE_ONLY" then
        return false
    end
    return self:IsPlaying()
end

function SpokenBridge:Init()
    local sp = GetSpoken()
    if not sp then
        return "WARMING"
    end
    if self.registered then
        return "OK"
    end

    if type(sp.RegisterCallback) == "function" then
        pcall(sp.RegisterCallback, sp, "PlaybackStarted", function()
            SpokenBridge.playingFlag = true
        end)
        pcall(sp.RegisterCallback, sp, "PlaybackStopped", function()
            SpokenBridge.playingFlag = false
        end)
    end

    -- Official Spoken:AddGate(fn) takes a single gate function(clip) -> holdReason | nil;
    -- always return nil for external clips so Spoken narration is never blocked.
    if type(sp.AddGate) == "function" then
        pcall(sp.AddGate, sp, function(clip)
            if type(clip) == "table" and type(clip.id) == "string" and string_sub(clip.id, 1, 3) == "fs:" then
                return nil
            end
            return nil
        end)
    end

    self.registered = true
    return "OK"
end

ns.Bridges.BridgeHost:Register({
    id = "spoken",
    target = "Spoken",
    mode = "bridge",
    protected = false,
    yields = { "quest_automation" },
    init = function()
        return SpokenBridge:Init()
    end,
    teardown = function()
        SpokenBridge.registered = false
        SpokenBridge.playingFlag = false
    end,
})
