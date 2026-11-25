-- Module: Secure/CombatQueue.lua
-- Responsibility: Last-write-wins keyed combat lockdown deferral queue with deduplicated ordering & error telemetry.
-- Layer: Secure
local _, ns = ...
ns.Secure = ns.Secure or {}

local pairs = pairs
local pcall = pcall
local tostring = tostring
local table_insert = table.insert

local CombatQueue = {
    pending = {},
    order = {},
    inOrder = {},
    lastError = nil,
}
ns.Secure.CombatQueue = CombatQueue

function CombatQueue:RunOrDefer(key, fn)
    if type(fn) ~= "function" then
        return false, "INVALID_FN"
    end
    if ns.Api.SafeAPI.InCombat() then
        if not self.inOrder[key] then
            self.inOrder[key] = true
            table_insert(self.order, key)
        end
        self.pending[key] = fn
        return false, "DEFERRED"
    end
    self.pending[key] = nil
    local ok, err = pcall(fn)
    if not ok then
        self.lastError = tostring(err)
        return false, err
    end
    return true, nil
end

function CombatQueue:Flush()
    if ns.Api.SafeAPI.InCombat() then
        return 0, 0
    end
    local ran = 0
    local failed = 0
    local keys = self.order
    local map = self.pending
    self.order = {}
    self.pending = {}
    self.inOrder = {}
    for i = 1, #keys do
        local fn = map[keys[i]]
        if type(fn) == "function" then
            local ok, err = pcall(fn)
            if ok then
                ran = ran + 1
            else
                failed = failed + 1
                self.lastError = tostring(err)
            end
        end
    end
    return ran, failed
end

function CombatQueue:PendingCount()
    local n = 0
    for _ in pairs(self.pending) do
        n = n + 1
    end
    return n
end
