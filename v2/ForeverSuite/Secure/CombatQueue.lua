-- Module: Secure/CombatQueue.lua
-- Responsibility: v6 Last-write-wins keyed combat lockdown deferral queue with per-item InCombat re-check,
--                 tail preservation on mid-flush combat re-entry, re-entry guard, xpcall isolation, and retry cap.
-- Layer: Secure
local _, ns = ...
ns.Secure = ns.Secure or {}

local pairs = pairs
local ipairs = ipairs
local type = type
local tostring = tostring
local xpcall = xpcall
local table_insert = table.insert

local MAX_FLUSH_PASSES = 3
local MAX_RETRIES = 2

local function CaptureError(err)
    local msg = tostring(err)
    if type(_G.debugstack) == "function" then
        local ok, st = pcall(_G.debugstack, 2, 4, 0)
        if ok and type(st) == "string" and st ~= "" then
            return msg .. "\n" .. st
        end
    end
    return msg
end

local CombatQueue = {
    pending = {},
    order = {},
    inOrder = {},
    attempts = {},
    flushing = false,
    activeKey = nil,
    lastError = nil,
    stats = {
        executed = 0,
        deferred = 0,
        failed = 0,
        requeued = 0,
    },
}
ns.Secure.CombatQueue = CombatQueue

function CombatQueue:_enqueue(key, fn)
    if not self.inOrder[key] then
        self.inOrder[key] = true
        table_insert(self.order, key)
    end
    self.pending[key] = fn
    self.stats.deferred = self.stats.deferred + 1
end

function CombatQueue:_exec(key, fn)
    local prevActive = self.activeKey
    self.activeKey = key
    local ok, err = xpcall(fn, CaptureError)
    self.activeKey = prevActive
    if ok then
        self.attempts[key] = nil
        self.stats.executed = self.stats.executed + 1
        return true, nil
    end
    local count = (self.attempts[key] or 0) + 1
    self.attempts[key] = count
    self.lastError = tostring(err)
    -- Never overwrite or drop a distinct newer replacement queued for the same key during fn execution
    if self.pending[key] ~= nil then
        if self.pending[key] == fn then
            if count > MAX_RETRIES then
                self.pending[key] = nil
                self.inOrder[key] = nil
                self.attempts[key] = nil
                self.stats.failed = self.stats.failed + 1
            end
        else
            -- Distinct newer callback scheduled by fn: keep it queued with fresh retry budget
            self.attempts[key] = nil
            self.stats.failed = self.stats.failed + 1
        end
    elseif count <= MAX_RETRIES then
        self:_enqueue(key, fn)
        self.stats.requeued = self.stats.requeued + 1
    else
        self.attempts[key] = nil
        self.stats.failed = self.stats.failed + 1
    end
    return false, self.lastError
end

function CombatQueue:RunOrDefer(key, fn)
    if type(fn) ~= "function" then
        return false, "INVALID_FN"
    end
    if key == nil then
        return false, "INVALID_KEY"
    end
    -- Reset retry budget only for fresh external replacements, never self-reregistration inside failing activeKey
    if not (self.flushing and self.activeKey == key) then
        self.attempts[key] = nil
    end
    if ns.Api.SafeAPI.InCombat() or self.flushing then
        self:_enqueue(key, fn)
        return false, "DEFERRED"
    end
    -- Note: order array may retain a stale key until next Flush rebuild skips nil pending[key]
    self.pending[key] = nil
    self.inOrder[key] = nil
    return self:_exec(key, fn)
end

-- v6 specification compatibility alias
CombatQueue.Run = CombatQueue.RunOrDefer

function CombatQueue:Flush()
    if self.flushing or ns.Api.SafeAPI.InCombat() then
        return 0, 0
    end
    self.flushing = true
    local ran = 0
    local failed = 0

    local okLoop, loopErr = xpcall(function()
        local pass = 0
        repeat
            pass = pass + 1
            local batchOrder = self.order
            self.order = {}
            local i = 1
            while i <= #batchOrder and not ns.Api.SafeAPI.InCombat() do
                local k = batchOrder[i]
                local fn = self.pending[k]
                self.pending[k] = nil
                self.inOrder[k] = nil
                if type(fn) == "function" then
                    local ok = self:_exec(k, fn)
                    if ok then
                        ran = ran + 1
                    else
                        failed = failed + 1
                    end
                end
                i = i + 1
            end

            -- Preserve unexecuted tail AHEAD of newly deferred keys without duplicates
            local tail = {}
            local seen = {}
            for j = i, #batchOrder do
                local k = batchOrder[j]
                if self.pending[k] ~= nil and not seen[k] then
                    seen[k] = true
                    tail[#tail + 1] = k
                end
            end
            for _, k in ipairs(self.order) do
                if self.pending[k] ~= nil and not seen[k] then
                    seen[k] = true
                    tail[#tail + 1] = k
                end
            end
            self.order = tail
            self.inOrder = seen
        until ns.Api.SafeAPI.InCombat() or #self.order == 0 or pass >= MAX_FLUSH_PASSES
    end, CaptureError)

    self.flushing = false
    if not okLoop then
        -- Reconcile any orphaned pending keys back into self.order so nothing is ever lost
        local recoveredOrder = {}
        local recoveredSeen = {}
        for _, k in ipairs(self.order) do
            if self.pending[k] ~= nil and not recoveredSeen[k] then
                recoveredSeen[k] = true
                recoveredOrder[#recoveredOrder + 1] = k
            end
        end
        for k in pairs(self.pending) do
            if not recoveredSeen[k] then
                recoveredSeen[k] = true
                recoveredOrder[#recoveredOrder + 1] = k
            end
        end
        self.order = recoveredOrder
        self.inOrder = recoveredSeen
        self.lastError = tostring(loopErr)
        self.stats.failed = self.stats.failed + 1
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

function CombatQueue:GetStats()
    return {
        executed = self.stats.executed,
        deferred = self.stats.deferred,
        failed = self.stats.failed,
        requeued = self.stats.requeued,
        pending = self:PendingCount(),
        lastError = self.lastError,
    }
end
