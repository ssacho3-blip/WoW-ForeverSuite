-- Module: Core/EventBus.lua
-- Responsibility: Single-frame WoW event dispatcher, unit-filtered event listeners, bucket throttling, and tombstone sweeps.
-- Dependencies: Core/Init.lua (ns.SummarizeStack, ns.ErrorMsg).
-- Public API: ns.EventBus (RegisterEvent, RegisterUnitEvent, RegisterBucketEvent, UnregisterOwner, ActiveEventCount).
-- Combat/Secret Safety: Forwards opaque event args without touching secret values; re-entrant safe during combat dispatch.
local _, ns = ...

local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local xpcall = xpcall

local EventBus = {
    frame = nil,
    unitFrames = {},
    listeners = {},
    buckets = {},
    ownerRecords = {},
    onErrorCallback = nil,
    dispatchDepth = 0,
    dirtyEvents = {},
    dirtyUnitKeys = {},
}
ns.EventBus = EventBus

local dEvent, dA1, dA2, dA3, dA4, dA5

local function MakeEntry(ownerId, callback, errorHandler)
    local entry = {
        ownerId = ownerId,
        callback = callback,
        active = true,
    }
    entry.runner = function()
        callback(dEvent, dA1, dA2, dA3, dA4, dA5)
    end
    entry.errHandler = function(err)
        local summary = ns.SummarizeStack(err)
        if errorHandler then
            errorHandler(ownerId, summary)
        elseif EventBus.onErrorCallback then
            EventBus.onErrorCallback(ownerId, summary)
        else
            ns.ErrorMsg("이벤트 오류(" .. tostring(ownerId) .. "): " .. tostring(err))
        end
    end
    return entry
end

function EventBus:EnsureFrame()
    if self.frame then
        return self.frame
    end
    if not _G.CreateFrame then
        return nil
    end
    local f = _G.CreateFrame("Frame", "ForeverSuiteEventBusFrame")
    f:SetScript("OnEvent", function(_, event, a1, a2, a3, a4, a5)
        EventBus:Dispatch(event, a1, a2, a3, a4, a5)
    end)
    self.frame = f
    return f
end

function EventBus:SetErrorObserver(fn)
    self.onErrorCallback = fn
end

function EventBus:RecordOwnerItem(ownerId, kind, refA, refB)
    local list = self.ownerRecords[ownerId]
    if not list then
        list = {}
        self.ownerRecords[ownerId] = list
    end
    list[#list + 1] = { kind = kind, refA = refA, refB = refB }
end

function EventBus:RegisterEvent(ownerId, event, callback, errorHandler)
    if type(event) ~= "string" or type(callback) ~= "function" then
        return nil
    end
    local f = self:EnsureFrame()
    local list = self.listeners[event]
    if not list then
        list = {}
        self.listeners[event] = list
        if f and f.RegisterEvent then
            f:RegisterEvent(event)
        end
    end
    local entry = MakeEntry(ownerId, callback, errorHandler)
    list[#list + 1] = entry
    self:RecordOwnerItem(ownerId, "event", event, entry)
    return entry
end

function EventBus:RegisterUnitEvent(ownerId, event, unit, callback, errorHandler)
    if type(event) ~= "string" or type(unit) ~= "string" or type(callback) ~= "function" then
        return nil
    end
    local key = event .. ":" .. unit
    local uf = self.unitFrames[key]
    if not uf and _G.CreateFrame then
        uf = {
            frame = _G.CreateFrame("Frame"),
            entries = {},
            event = event,
        }
        if uf.frame.RegisterUnitEvent then
            uf.frame:RegisterUnitEvent(event, unit)
        elseif uf.frame.RegisterEvent then
            uf.frame:RegisterEvent(event)
        end
        uf.frame:SetScript("OnEvent", function(_, ev, a1, a2, a3, a4, a5)
            EventBus:DispatchEntries(uf.entries, ev, a1, a2, a3, a4, a5)
        end)
        self.unitFrames[key] = uf
    end
    if not uf then
        return self:RegisterEvent(ownerId, event, callback, errorHandler)
    end
    local entry = MakeEntry(ownerId, callback, errorHandler)
    uf.entries[#uf.entries + 1] = entry
    self:RecordOwnerItem(ownerId, "unit_event", key, entry)
    return entry
end

function EventBus:RegisterBucketEvent(ownerId, event, intervalSec, callback, errorHandler, unitFilter)
    local delay = tonumber(intervalSec) or 0.2
    if delay < 0.05 then
        delay = 0.05
    end
    local bucket = {
        ownerId = ownerId,
        event = event,
        delay = delay,
        pending = false,
        count = 0,
        lastArg1 = nil,
        active = true,
    }
    bucket.flushRunner = function()
        bucket.pending = false
        if not bucket.active then
            return
        end
        local c = bucket.count
        local a1 = bucket.lastArg1
        bucket.count = 0
        bucket.lastArg1 = nil
        dEvent, dA1, dA2, dA3, dA4, dA5 = event, a1, c, nil, nil, nil
        callback(dEvent, dA1, dA2)
    end
    bucket.errHandler = function(err)
        local summary = ns.SummarizeStack(err)
        if errorHandler then
            errorHandler(ownerId, summary)
        elseif EventBus.onErrorCallback then
            EventBus.onErrorCallback(ownerId, summary)
        end
    end
    bucket.onFlushTimer = function()
        if not bucket.active then
            bucket.pending = false
            return
        end
        local pe, p1, p2, p3, p4, p5 = dEvent, dA1, dA2, dA3, dA4, dA5
        xpcall(bucket.flushRunner, bucket.errHandler)
        dEvent, dA1, dA2, dA3, dA4, dA5 = pe, p1, p2, p3, p4, p5
    end

    local onRawEvent = function(_, a1)
        if not bucket.active then
            return
        end
        bucket.count = bucket.count + 1
        bucket.lastArg1 = a1
        if not bucket.pending then
            bucket.pending = true
            if C_Timer and C_Timer.After then
                C_Timer.After(bucket.delay, bucket.onFlushTimer)
            else
                bucket.onFlushTimer()
            end
        end
    end

    if unitFilter then
        self:RegisterUnitEvent(ownerId, event, unitFilter, onRawEvent, errorHandler)
    else
        self:RegisterEvent(ownerId, event, onRawEvent, errorHandler)
    end
    self:RecordOwnerItem(ownerId, "bucket", bucket, nil)
    return bucket
end

function EventBus:DispatchEntries(entries, event, a1, a2, a3, a4, a5)
    if not entries or #entries == 0 then
        return
    end
    local count = #entries
    local pe, p1, p2, p3, p4, p5 = dEvent, dA1, dA2, dA3, dA4, dA5
    self.dispatchDepth = self.dispatchDepth + 1
    for i = 1, count do
        local entry = entries[i]
        if entry and entry.active then
            dEvent, dA1, dA2, dA3, dA4, dA5 = event, a1, a2, a3, a4, a5
            xpcall(entry.runner, entry.errHandler)
        end
    end
    dEvent, dA1, dA2, dA3, dA4, dA5 = pe, p1, p2, p3, p4, p5
    self.dispatchDepth = self.dispatchDepth - 1
    if self.dispatchDepth <= 0 then
        self.dispatchDepth = 0
        self:SweepDirty()
    end
end

function EventBus:Dispatch(event, a1, a2, a3, a4, a5)
    local entries = self.listeners[event]
    if not entries then
        return
    end
    self:DispatchEntries(entries, event, a1, a2, a3, a4, a5)
end

local function CompactActiveEntries(list)
    if not list then
        return 0
    end
    local writeIdx = 1
    for readIdx = 1, #list do
        local item = list[readIdx]
        if item and item.active then
            list[writeIdx] = item
            writeIdx = writeIdx + 1
        end
    end
    for i = writeIdx, #list do
        list[i] = nil
    end
    return writeIdx - 1
end

function EventBus:CompactEventNow(event)
    local list = self.listeners[event]
    if not list then
        return
    end
    local remaining = CompactActiveEntries(list)
    if remaining == 0 then
        self.listeners[event] = nil
        if self.frame and self.frame.UnregisterEvent then
            self.frame:UnregisterEvent(event)
        end
    end
end

function EventBus:CompactUnitKeyNow(key)
    local uf = self.unitFrames[key]
    if not uf then
        return
    end
    local remaining = CompactActiveEntries(uf.entries)
    if remaining == 0 then
        if uf.frame and uf.frame.UnregisterAllEvents then
            uf.frame:UnregisterAllEvents()
        elseif uf.frame and uf.frame.UnregisterEvent then
            uf.frame:UnregisterEvent(uf.event)
        end
        self.unitFrames[key] = nil
    end
end

function EventBus:SweepDirty()
    for event in pairs(self.dirtyEvents) do
        self.dirtyEvents[event] = nil
        self:CompactEventNow(event)
    end
    for key in pairs(self.dirtyUnitKeys) do
        self.dirtyUnitKeys[key] = nil
        self:CompactUnitKeyNow(key)
    end
end

function EventBus:UnregisterOwner(ownerId)
    local records = self.ownerRecords[ownerId]
    if not records then
        return 0
    end
    local removed = 0
    local inDispatch = (self.dispatchDepth > 0)
    for _, rec in ipairs(records) do
        if rec.kind == "event" then
            local event = rec.refA
            local entry = rec.refB
            if entry and entry.active then
                entry.active = false
                removed = removed + 1
            end
            if inDispatch then
                self.dirtyEvents[event] = true
            else
                self:CompactEventNow(event)
            end
        elseif rec.kind == "unit_event" then
            local key = rec.refA
            local entry = rec.refB
            if entry and entry.active then
                entry.active = false
                removed = removed + 1
            end
            if inDispatch then
                self.dirtyUnitKeys[key] = true
            else
                self:CompactUnitKeyNow(key)
            end
        elseif rec.kind == "bucket" then
            local bucket = rec.refA
            if bucket then
                bucket.active = false
                bucket.pending = false
            end
        end
    end
    self.ownerRecords[ownerId] = nil
    return removed
end

function EventBus:ActiveEventCount()
    local total = 0
    for _, list in pairs(self.listeners) do
        for i = 1, #list do
            if list[i] and list[i].active then
                total = total + 1
            end
        end
    end
    for _, uf in pairs(self.unitFrames) do
        for i = 1, #uf.entries do
            if uf.entries[i] and uf.entries[i].active then
                total = total + 1
            end
        end
    end
    return total
end
