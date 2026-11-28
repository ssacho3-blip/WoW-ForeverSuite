-- Module: UI/Director.lua
-- Responsibility: Non-secure 5-State (+EDIT_OVERRIDE) Director orchestration engine with single 60Hz _tweenFrame
--                 (0.00ms idle when converged), 1.2s post-combat hold, 350ms dialogue debounce, and /fs setup live preview.
-- Layer: UI (Rank 4: operates strictly on non-secure UIParent HUD SetAlpha — never touches Secure frames).
local _, ns = ...
ns.UI = ns.UI or {}

local pairs = pairs
local type = type
local pcall = pcall
local math_abs = math.abs

local POST_COMBAT_HOLD_SEC = 1.2
local DIALOGUE_EXIT_DEBOUNCE_SEC = 0.35
local EPSILON = 0.01

local Director = {
    state = "EXPLORATION",
    channels = {},       -- [channelId] = non-secure frame
    targets = {},        -- [channelId] = targetAlpha
    tweenFrame = nil,
    tweenSpeed = 5.0,
    pendingHoldToken = 0,
    schedulerFn = nil,   -- injected RunAfter(delay, fn)
    signalProvider = nil,-- injected function() -> signals table
    previewActive = false,
    previewToken = 0,
    previewSavedState = nil,
}
ns.UI.Director = Director

function Director:SetScheduler(fn)
    self.schedulerFn = (type(fn) == "function") and fn or nil
end

function Director:SetSignalProvider(fn)
    self.signalProvider = (type(fn) == "function") and fn or nil
end

function Director:SyncFromProvider(forceImmediate)
    if type(self.signalProvider) == "function" then
        local ok, sig = pcall(self.signalProvider)
        if ok and type(sig) == "table" then
            return self:ApplySignals(sig, forceImmediate)
        end
    end
    return self.state, "NO_PROVIDER"
end

function Director:RegisterChannel(channelId, frame)
    if type(channelId) ~= "string" or channelId == "" or type(frame) ~= "table" then
        return false
    end
    self.channels[channelId] = frame
    local mat = ns.Domain.DirectorModel.GetAlphaMatrix(self.state)
    local target = mat[channelId]
    if type(target) == "number" and type(frame.SetAlpha) == "function" then
        pcall(frame.SetAlpha, frame, target)
    end
    return true
end

local function EnsureTweenFrame()
    if Director.tweenFrame then
        return Director.tweenFrame
    end
    if type(_G.CreateFrame) ~= "function" then
        return nil
    end
    Director.tweenFrame = _G.CreateFrame("Frame", "ForeverSuiteDirectorTweenFrame", _G.UIParent)
    return Director.tweenFrame
end

local function StopTween()
    if Director.tweenFrame and type(Director.tweenFrame.SetScript) == "function" then
        pcall(Director.tweenFrame.SetScript, Director.tweenFrame, "OnUpdate", nil)
    end
end

function Director:StepTween(elapsed)
    local dt = (type(elapsed) == "number" and elapsed > 0) and elapsed or 0.016
    local anyMoving = false
    for channelId, target in pairs(self.targets) do
        local frame = self.channels[channelId]
        if type(frame) == "table" and type(frame.SetAlpha) == "function" then
            local cur = target
            if type(frame.GetAlpha) == "function" then
                local ok, a = pcall(frame.GetAlpha, frame)
                if ok and type(a) == "number" then
                    cur = a
                end
            end
            local diff = target - cur
            if math_abs(diff) <= EPSILON then
                pcall(frame.SetAlpha, frame, target)
            else
                local step = diff * (dt * self.tweenSpeed)
                if math_abs(step) >= math_abs(diff) then
                    pcall(frame.SetAlpha, frame, target)
                else
                    pcall(frame.SetAlpha, frame, cur + step)
                    anyMoving = true
                end
            end
        end
    end
    if not anyMoving then
        StopTween()
    end
    return anyMoving
end

function Director:_applyStateImmediate(nextState, instant)
    local prev = self.state
    self.state = nextState
    local matrix = ns.Domain.DirectorModel.GetAlphaMatrix(nextState)
    local dur = instant and 0 or ns.Domain.DirectorModel.GetTransitionDuration(prev, nextState)
    local combatFadeOff = (nextState == "COMBAT")
        and ns.Api and ns.Api.ProfileStore
        and ns.Api.ProfileStore:Get("quest", "combatFade") == false
    self.targets = {}
    for ch, alpha in pairs(matrix) do
        if ch == "questTracker" and combatFadeOff then
            self.targets[ch] = 1.00
        else
            self.targets[ch] = alpha
        end
    end

    if dur <= 0 then
        StopTween()
        for ch, target in pairs(self.targets) do
            local frame = self.channels[ch]
            if type(frame) == "table" and type(frame.SetAlpha) == "function" then
                pcall(frame.SetAlpha, frame, target)
            end
        end
        return nextState
    end

    self.tweenSpeed = 1.0 / dur
    local tf = EnsureTweenFrame()
    if tf and type(tf.SetScript) == "function" then
        pcall(tf.SetScript, tf, "OnUpdate", function(_, elapsed)
            Director:StepTween(elapsed)
        end)
    else
        -- Headless environment without OnUpdate: apply directly
        for ch, target in pairs(self.targets) do
            local frame = self.channels[ch]
            if type(frame) == "table" and type(frame.SetAlpha) == "function" then
                pcall(frame.SetAlpha, frame, target)
            end
        end
    end
    return nextState
end

function Director:ApplySignals(signals, forceImmediate)
    local desired = ns.Domain.DirectorModel.ResolveState(signals)
    -- Real COMBAT or explicit forceImmediate ALWAYS preempts and cancels setup preview!
    if self.previewActive then
        if forceImmediate or desired == "COMBAT" or desired == "EDIT_OVERRIDE" or desired == "DEAD" then
            self.previewActive = false
            self.previewToken = self.previewToken + 1
            self.previewSavedState = nil
        else
            return self.state, "PREVIEW_ACTIVE"
        end
    end
    if desired == self.state then
        -- Cancel any pending delayed exit if signals reverted to current state (e.g. combat re-entered during 1.2s hold!)
        self.pendingHoldToken = self.pendingHoldToken + 1
        return self.state, "UNCHANGED"
    end

    -- Immediate high-priority transitions (COMBAT, EDIT_OVERRIDE, DEAD, or explicit immediate)
    if forceImmediate or desired == "COMBAT" or desired == "EDIT_OVERRIDE" or desired == "DEAD" then
        self.pendingHoldToken = self.pendingHoldToken + 1
        self:_applyStateImmediate(desired, desired == "COMBAT" or desired == "EDIT_OVERRIDE" or forceImmediate)
        return self.state, "IMMEDIATE"
    end

    -- Post-combat 1.2s visual hold (prevents Feign Death / Vanish strobing)
    local holdSec = 0
    if self.state == "COMBAT" then
        holdSec = POST_COMBAT_HOLD_SEC
    elseif self.state == "DIALOGUE" and desired == "EXPLORATION" then
        holdSec = DIALOGUE_EXIT_DEBOUNCE_SEC
    end

    if holdSec > 0 and type(self.schedulerFn) == "function" then
        self.pendingHoldToken = self.pendingHoldToken + 1
        local token = self.pendingHoldToken
        local ok, scheduled = pcall(self.schedulerFn, holdSec, function()
            if Director.pendingHoldToken == token then
                Director:_applyStateImmediate(desired, false)
            end
        end)
        if ok and scheduled ~= false then
            return self.state, "HELD"
        end
    end

    self:_applyStateImmediate(desired, false)
    return self.state, "TRANSITIONED"
end

-- 4.5-second live showcase for /fs setup Step 3 (EXPLORATION -> FISHING -> COMBAT -> live re-sync)
function Director:RunSetupPreview(onComplete)
    if ns.Api and ns.Api.SafeAPI and ns.Api.SafeAPI.InCombat() then
        return false, "IN_COMBAT"
    end
    if not self.previewActive then
        self.previewSavedState = self.state
    end
    local savedState = self.previewSavedState or "EXPLORATION"
    self.previewToken = self.previewToken + 1
    local myToken = self.previewToken
    self.previewActive = true
    self:_applyStateImmediate("EXPLORATION", true)

    local function FinishPreview()
        if Director.previewToken ~= myToken then return end
        Director.previewActive = false
        Director.previewSavedState = nil
        if type(Director.signalProvider) == "function" then
            Director:SyncFromProvider(false)
        else
            Director:_applyStateImmediate(savedState, false)
        end
        if type(onComplete) == "function" then pcall(onComplete) end
    end

    if type(self.schedulerFn) ~= "function" then
        FinishPreview()
        return true
    end
    local ok1, s1 = pcall(self.schedulerFn, 1.5, function()
        if Director.previewActive and Director.previewToken == myToken then
            Director:_applyStateImmediate("FISHING", false)
        end
    end)
    local ok2, s2 = pcall(self.schedulerFn, 3.0, function()
        if Director.previewActive and Director.previewToken == myToken then
            Director:_applyStateImmediate("COMBAT", true)
        end
    end)
    local ok3, s3 = pcall(self.schedulerFn, 4.5, FinishPreview)
    if not (ok1 and s1 ~= false and ok2 and s2 ~= false and ok3 and s3 ~= false) then
        FinishPreview()
    end
    return true
end
