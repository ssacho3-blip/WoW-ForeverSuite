-- Module: Bridges/BridgeHost.lua
-- Responsibility: Unified lifecycle host for external specialist bridges (Coexistence, late ADDON_LOADED,
--                 BRIDGE_WARMING promotion, O(1) EventBus unsubscription, xpcall FAULTED quarantine).
-- Layer: Bridges (Rank 3: depends ONLY on Domain, Api, Secure; zero Blizzard/UI/Features references).
local _, ns = ...
ns.Bridges = ns.Bridges or {}

local type = type
local pairs = pairs
local ipairs = ipairs
local pcall = pcall
local xpcall = xpcall
local select = select
local unpack = unpack or table.unpack
local tostring = tostring

local MAX_WARM_RECHECKS = 5

local BridgeHost = {
    registry = {},
    order = {},
    policies = {},
    resolved = {},
    subscriptions = {},
    warmAttempts = {},
    faults = {},
    lastContext = {},
    lastOverrides = {},
    recheckScheduled = false,
    schedulerFn = nil,
}
ns.Bridges.BridgeHost = BridgeHost

function BridgeHost:SetScheduler(fn)
    self.schedulerFn = (type(fn) == "function") and fn or nil
    self.recheckScheduled = false
end

function BridgeHost:_hasWarming()
    for _, rec in pairs(self.resolved) do
        if rec.state == "BRIDGE_WARMING" then
            return true
        end
    end
    return false
end

function BridgeHost:ScheduleWarmingRecheck()
    if self.recheckScheduled or (not self:_hasWarming()) or type(self.schedulerFn) ~= "function" then
        return false
    end
    self.recheckScheduled = true
    local ok, scheduled = pcall(self.schedulerFn, 2.0, function()
        BridgeHost.recheckScheduled = false
        local _, deferredProtected = BridgeHost:RecheckWarming()
        -- Do not spin a 2s timer while protected bridges are already deferred in CombatQueue
        if BridgeHost:_hasWarming() and deferredProtected == 0 then
            BridgeHost:ScheduleWarmingRecheck()
        end
    end)
    if (not ok) or scheduled == false then
        self.recheckScheduled = false
        return false
    end
    return true
end

local function CaptureStack(err)
    local msg = tostring(err)
    if type(_G.debugstack) == "function" then
        local ok, st = pcall(_G.debugstack, 2, 4, 0)
        if ok and type(st) == "string" and st ~= "" then
            return msg .. "\n" .. st
        end
    end
    return msg
end

function BridgeHost:Register(spec)
    if type(spec) ~= "table" or type(spec.id) ~= "string" or spec.id == "" then
        return false, "INVALID_SPEC"
    end
    if not self.registry[spec.id] then
        self.order[#self.order + 1] = spec.id
    end
    self.registry[spec.id] = spec
    self.policies[spec.id] = {
        id = spec.id,
        target = spec.target,
        mode = spec.mode or "bridge",
        classOnly = spec.classOnly,
        yields = spec.yields or {},
    }
    return true, nil
end

function BridgeHost:_mergedPolicies()
    local merged = {}
    for id, pol in pairs(ns.Domain.Coexistence.DEFAULT_POLICIES) do
        merged[id] = pol
    end
    for id, pol in pairs(self.policies) do
        merged[id] = pol
    end
    return merged
end

function BridgeHost:UnsubscribeAll(id)
    local subs = self.subscriptions[id]
    self.subscriptions[id] = nil
    if type(subs) ~= "table" then
        return 0
    end
    local removed = 0
    for i = 1, #subs do
        local sub = subs[i]
        if ns.Api.EventBus and type(ns.Api.EventBus.OffEvent) == "function" then
            ns.Api.EventBus:OffEvent(sub.ownerKey, sub.eventName)
        end
        removed = removed + 1
    end
    return removed
end

function BridgeHost:_fault(id, err)
    local pol = self:_mergedPolicies()[id]
    local prev = self.resolved[id] and self.resolved[id].state or "SELF"
    local nextSt = ns.Domain.Coexistence.Transition(prev, "BRIDGE_FAIL", pol)
    self.resolved[id] = {
        state = nextSt,
        reason = "RUNTIME_FAULT",
        target = pol and pol.target or id,
    }
    self.faults[id] = tostring(err)
    self:UnsubscribeAll(id)
    local spec = self.registry[id]
    if spec and type(spec.teardown) == "function" then
        pcall(spec.teardown)
    end
end

function BridgeHost:Subscribe(id, eventName, handler)
    if type(id) ~= "string" or type(eventName) ~= "string" or type(handler) ~= "function" then
        return false
    end
    local st = self:GetState(id)
    if st == "FAULTED" or st == "YIELDED" then
        return false
    end
    self.subscriptions[id] = self.subscriptions[id] or {}
    local idx = #self.subscriptions[id] + 1
    local ownerKey = "bridge:" .. id .. ":" .. eventName .. ":" .. tostring(idx)
    self.subscriptions[id][idx] = { ownerKey = ownerKey, eventName = eventName }
    ns.Api.EventBus:OnEvent(ownerKey, eventName, function(ev, ...)
        local cur = BridgeHost:GetState(id)
        if cur == "FAULTED" or cur == "YIELDED" then
            return
        end
        local argc = select("#", ...)
        local args = { ... }
        local ok, err = xpcall(function()
            handler(ev, unpack(args, 1, argc))
        end, CaptureStack)
        if not ok then
            BridgeHost:_fault(id, err)
        end
    end)
    return true
end

function BridgeHost:_runInit(id)
    local spec = self.registry[id]
    if not spec or type(spec.init) ~= "function" then
        return
    end
    local rec = self.resolved[id]
    if not rec or rec.state ~= "BRIDGE_WARMING" then
        return
    end
    local pol = self:_mergedPolicies()[id]
    local function doInit()
        local ok, res = xpcall(spec.init, CaptureStack)
        if not ok then
            self:_fault(id, res)
            return
        end
        if res == "WARMING" then
            local nextSt, rsn = ns.Domain.Coexistence.Transition(rec.state, "BRIDGE_WAIT", pol)
            self.resolved[id] = { state = nextSt, reason = rsn, target = pol.target }
        elseif res == true or res == "OK" then
            local nextSt, rsn = ns.Domain.Coexistence.Transition(rec.state, "BRIDGE_OK", pol)
            self.resolved[id] = { state = nextSt, reason = rsn, target = pol.target }
        elseif res == false or res == "FAIL" then
            self:_fault(id, "INIT_RETURNED_FAIL")
        end
    end
    if spec.protected == true and ns.Secure and ns.Secure.CombatQueue then
        ns.Secure.CombatQueue:RunOrDefer("bridge:init:" .. id, doInit)
    else
        doInit()
    end
end

function BridgeHost:ResolveAll(overrides, context)
    self.lastOverrides = (type(overrides) == "table") and overrides or self.lastOverrides
    self.lastContext = (type(context) == "table") and context or self.lastContext

    local policies = self:_mergedPolicies()
    local targetSet = {}
    local targetList = {}
    for _, pol in pairs(policies) do
        if type(pol.target) == "string" and pol.target ~= "" and not targetSet[pol.target] then
            targetSet[pol.target] = true
            targetList[#targetList + 1] = pol.target
        end
    end

    local probes = ns.Api.AddonProbe.ProbeAll(targetList)
    local prevStates = {}
    for id, rec in pairs(self.resolved) do
        prevStates[id] = rec.state
    end

    local nextMap, status = ns.Domain.Coexistence.ResolveAll(
        probes, self.lastOverrides, self.lastContext, prevStates, policies
    )
    if not nextMap then
        return nil, status
    end

    for id, rec in pairs(nextMap) do
        local oldState = prevStates[id]
        self.resolved[id] = rec
        if rec.state == "YIELDED" or rec.state == "FAULTED" then
            self:UnsubscribeAll(id)
            if oldState ~= rec.state then
                local spec = self.registry[id]
                if spec and type(spec.teardown) == "function" then
                    pcall(spec.teardown)
                end
            end
        elseif rec.state == "BRIDGE_WARMING" then
            self:_runInit(id)
        end
    end
    if self:_hasWarming() then
        self:ScheduleWarmingRecheck()
    end
    return self.resolved, "OK"
end

function BridgeHost:OnAddonLoaded(addonName)
    if type(addonName) ~= "string" or addonName == "" then
        return false
    end
    local policies = self:_mergedPolicies()
    local matched = false
    for id, pol in pairs(policies) do
        if pol.target == addonName then
            matched = true
            local cur = self.resolved[id] and self.resolved[id].state or "SELF"
            if cur ~= "FAULTED" then
                local classMismatch = type(pol.classOnly) == "string"
                    and pol.classOnly ~= ""
                    and self.lastContext.playerClass ~= pol.classOnly
                if not classMismatch and self.lastOverrides[id] ~= "self" then
                    local nextSt, rsn = ns.Domain.Coexistence.Transition(cur, "PRESENT", pol)
                    self.resolved[id] = { state = nextSt, reason = rsn, target = pol.target }
                    if nextSt == "YIELDED" then
                        self:UnsubscribeAll(id)
                    elseif nextSt == "BRIDGE_WARMING" then
                        self:_runInit(id)
                    end
                end
            end
        end
    end
    if matched and self:_hasWarming() then
        self:ScheduleWarmingRecheck()
    end
    return matched
end

function BridgeHost:RecheckWarming()
    local promoted = 0
    local deferredProtected = 0
    local policies = self:_mergedPolicies()
    local ids = {}
    for id, rec in pairs(self.resolved) do
        if rec.state == "BRIDGE_WARMING" then
            ids[#ids + 1] = id
        end
    end
    for i = 1, #ids do
        local id = ids[i]
        local spec = self.registry[id]
        local checkFn = spec and (spec.onWarmCheck or spec.init) or nil
        if type(checkFn) == "function" then
            local function runWarm()
                local cur = self.resolved[id]
                if not cur or cur.state ~= "BRIDGE_WARMING" then
                    return
                end
                local ok, res = xpcall(checkFn, CaptureStack)
                if not ok then
                    self:_fault(id, res)
                elseif res == true or res == "OK" then
                    self.warmAttempts[id] = nil
                    local nextSt, rsn = ns.Domain.Coexistence.Transition("BRIDGE_WARMING", "BRIDGE_OK", policies[id])
                    self.resolved[id] = { state = nextSt, reason = rsn, target = policies[id] and policies[id].target or id }
                    promoted = promoted + 1
                elseif res == false or res == "FAIL" then
                    self.warmAttempts[id] = nil
                    self:_fault(id, "WARM_CHECK_FAILED")
                else
                    local tries = (self.warmAttempts[id] or 0) + 1
                    self.warmAttempts[id] = tries
                    if tries >= MAX_WARM_RECHECKS then
                        self.warmAttempts[id] = nil
                        self:_fault(id, "WARM_TIMEOUT")
                    end
                end
            end
            if spec.protected == true and ns.Secure and ns.Secure.CombatQueue then
                local ran, reason = ns.Secure.CombatQueue:RunOrDefer("bridge:warm:" .. id, function()
                    runWarm()
                    if BridgeHost:_hasWarming() then
                        BridgeHost:ScheduleWarmingRecheck()
                    end
                end)
                if (not ran) and reason == "DEFERRED" then
                    deferredProtected = deferredProtected + 1
                end
            else
                runWarm()
            end
        end
    end
    return promoted, deferredProtected
end

function BridgeHost:Reset(id)
    local policies = self:_mergedPolicies()
    if type(id) == "string" and id ~= "" then
        self:UnsubscribeAll(id)
        self.faults[id] = nil
        self.warmAttempts[id] = nil
        local pol = policies[id]
        self.resolved[id] = { state = "SELF", reason = "RESET", target = pol and pol.target or id }
        return self:ResolveAll(self.lastOverrides, self.lastContext)
    end
    for k in pairs(self.resolved) do
        self:UnsubscribeAll(k)
        self.faults[k] = nil
        self.warmAttempts[k] = nil
        local pol = policies[k]
        self.resolved[k] = { state = "SELF", reason = "RESET", target = pol and pol.target or k }
    end
    return self:ResolveAll(self.lastOverrides, self.lastContext)
end

function BridgeHost:GetState(id)
    local rec = self.resolved[id]
    return rec and rec.state or "SELF"
end

function BridgeHost:IsFeatureYielded(featureId)
    return ns.Domain.Coexistence.ShouldYieldFeature(self.resolved, featureId, self:_mergedPolicies())
end

function BridgeHost:GetSummary()
    local list = {}
    local policies = self:_mergedPolicies()
    for id, pol in pairs(policies) do
        local rec = self.resolved[id] or { state = "SELF", reason = "UNRESOLVED", target = pol.target }
        list[#list + 1] = {
            id = id,
            target = pol.target,
            state = rec.state,
            reason = rec.reason,
            fault = self.faults[id],
        }
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end
