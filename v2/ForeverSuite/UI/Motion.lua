-- Module: UI/Motion.lua
-- Responsibility: ForeverSuite v6.1.0 Dual Motion Engine (WhatTheWhisper Anim.lua pattern):
--                 1) C++ AnimationGroup for 150ms fade-in (0ms instant hide, zero combat mutation)
--                 2) Single hidden Lua OnUpdate Tween Driver (outCubic) that auto-hides at count == 0 (0.00ms idle)
--                 3) Hard InCombatLockdown() 0ms snap + Reduced Motion accessibility toggle
-- Layer: UI (L2; depends only on UI/Tokens & SafeAPI/InCombatLockdown).
local _, ns = ...
ns.UI = ns.UI or {}

local type = type
local pairs = pairs
local pcall = pcall

local Motion = {
    _reducedMotion = false,
    _driver = nil,
    _active = {},
    _fading = setmetatable({}, { __mode = "k" }),
    _count = 0,
    _nextId = 0,
}
ns.UI.Motion = Motion

function Motion.OutCubic(t)
    if type(t) ~= "number" or t <= 0 then return 0 end
    if t >= 1 then return 1 end
    local inv = 1 - t
    return 1 - (inv * inv * inv)
end

function Motion.InCombat()
    if ns.Api and ns.Api.SafeAPI and type(ns.Api.SafeAPI.InCombat) == "function" then
        return ns.Api.SafeAPI.InCombat() == true
    end
    if type(_G.InCombatLockdown) == "function" then
        return _G.InCombatLockdown() == true
    end
    return false
end

function Motion.SetReducedMotion(flag)
    Motion._reducedMotion = (flag == true)
    if Motion._reducedMotion then
        Motion.SnapAllForCombat()
    end
    return Motion._reducedMotion
end

function Motion.IsReducedMotion()
    return Motion._reducedMotion == true
end

function Motion.GetDriver()
    if not Motion._driver then
        local drv = CreateFrame("Frame", nil, _G.UIParent)
        drv:Hide()
        drv:SetScript("OnUpdate", function(_, elapsed)
            Motion.Step(elapsed)
        end)
        Motion._driver = drv
    end
    return Motion._driver
end

local function SyncDriverVisibility()
    local drv = Motion._driver
    if not drv then return end
    if Motion._count <= 0 then
        Motion._count = 0
        drv:Hide()
    else
        drv:Show()
    end
end

function Motion.FadeIn(frame, durationSec)
    if not frame then return false end
    local dur = (type(durationSec) == "number" and durationSec > 0) and durationSec or 0.15
    if Motion._reducedMotion or Motion.InCombat() or type(frame.CreateAnimationGroup) ~= "function" then
        frame:SetAlpha(1)
        frame:Show()
        return true
    end
    if not frame._fsFadeGroup then
        local ag = frame:CreateAnimationGroup()
        local anim = ag:CreateAnimation("Alpha")
        anim:SetFromAlpha(0)
        anim:SetToAlpha(1)
        anim:SetSmoothing("OUT")
        ag:SetScript("OnFinished", function()
            Motion._fading[frame] = nil
            frame:SetAlpha(1)
        end)
        frame._fsFadeGroup = ag
        frame._fsFadeAnim = anim
    end
    frame._fsFadeAnim:SetDuration(dur)
    frame:SetAlpha(0)
    frame:Show()
    frame._fsFadeGroup:Stop()
    Motion._fading[frame] = true
    frame._fsFadeGroup:Play()
    return true
end

function Motion.InstantHide(frame)
    if not frame then return false end
    Motion._fading[frame] = nil
    if frame._fsFadeGroup and type(frame._fsFadeGroup.Stop) == "function" then
        pcall(frame._fsFadeGroup.Stop, frame._fsFadeGroup)
    end
    Motion.CancelForTarget(frame)
    frame:SetAlpha(1)
    frame:Hide()
    return true
end

function Motion.Tween(target, propKey, fromVal, toVal, durationSec, applyFn, onDone)
    if type(applyFn) ~= "function" then return nil end
    local dur = (type(durationSec) == "number" and durationSec > 0) and durationSec or 0.15
    if Motion._reducedMotion or Motion.InCombat() then
        pcall(applyFn, toVal, 1.0)
        if type(onDone) == "function" then pcall(onDone) end
        return nil
    end

    -- Replace existing tween on the same (target, propKey) so overlapping hovers never fight
    for id, rec in pairs(Motion._active) do
        if rec.target == target and rec.propKey == propKey then
            Motion._active[id] = nil
            Motion._count = Motion._count - 1
        end
    end

    Motion._nextId = Motion._nextId + 1
    local id = Motion._nextId
    Motion._active[id] = {
        id = id,
        target = target,
        propKey = propKey,
        fromVal = fromVal,
        toVal = toVal,
        duration = dur,
        elapsed = 0,
        applyFn = applyFn,
        onDone = onDone,
    }
    Motion._count = Motion._count + 1
    Motion.GetDriver():Show()
    return id
end

function Motion.Cancel(id)
    if id ~= nil and Motion._active[id] then
        Motion._active[id] = nil
        Motion._count = Motion._count - 1
        SyncDriverVisibility()
        return true
    end
    return false
end

function Motion.CancelForTarget(target)
    if target == nil then return 0 end
    local removed = 0
    for id, rec in pairs(Motion._active) do
        if rec.target == target then
            Motion._active[id] = nil
            Motion._count = Motion._count - 1
            removed = removed + 1
        end
    end
    SyncDriverVisibility()
    return removed
end

function Motion.SnapAllForCombat()
    -- Snap any in-flight C++ AnimationGroup fade-ins immediately to full alpha (0ms)
    for frame in pairs(Motion._fading) do
        Motion._fading[frame] = nil
        if frame._fsFadeGroup and type(frame._fsFadeGroup.Stop) == "function" then
            pcall(frame._fsFadeGroup.Stop, frame._fsFadeGroup)
        end
        if type(frame.SetAlpha) == "function" then
            pcall(frame.SetAlpha, frame, 1)
        end
    end
    local finished = {}
    for id, rec in pairs(Motion._active) do
        finished[#finished + 1] = rec
        Motion._active[id] = nil
    end
    Motion._count = 0
    SyncDriverVisibility()
    for i = 1, #finished do
        local rec = finished[i]
        pcall(rec.applyFn, rec.toVal, 1.0)
        if type(rec.onDone) == "function" then pcall(rec.onDone) end
    end
    return #finished
end

function Motion.Step(elapsed)
    if Motion._count <= 0 then
        SyncDriverVisibility()
        return false
    end
    if Motion.InCombat() or Motion._reducedMotion then
        Motion.SnapAllForCombat()
        return false
    end
    local dt = (type(elapsed) == "number" and elapsed > 0) and elapsed or 0.016
    local doneList = {}
    for id, rec in pairs(Motion._active) do
        local isHidden = false
        if rec.target then
            if type(rec.target.IsVisible) == "function" then
                isHidden = (rec.target:IsVisible() ~= true)
            elseif type(rec.target.IsShown) == "function" then
                isHidden = (rec.target:IsShown() ~= true)
            end
        end
        if isHidden then
            Motion._active[id] = nil
            Motion._count = Motion._count - 1
            doneList[#doneList + 1] = rec
        else
            rec.elapsed = rec.elapsed + dt
            local p = rec.elapsed / rec.duration
            if p >= 1 then
                Motion._active[id] = nil
                Motion._count = Motion._count - 1
                doneList[#doneList + 1] = rec
            else
                local e = Motion.OutCubic(p)
                local val = rec.fromVal + (rec.toVal - rec.fromVal) * e
                pcall(rec.applyFn, val, e)
            end
        end
    end
    for i = 1, #doneList do
        local rec = doneList[i]
        pcall(rec.applyFn, rec.toVal, 1.0)
        if type(rec.onDone) == "function" then pcall(rec.onDone) end
    end
    SyncDriverVisibility()
    return Motion._count > 0
end
