-- Module: Api/EventBus.lua
-- Responsibility: Centralized WoW event dispatcher and internal pub/sub message bus with O(1) owner unsubscription.
-- Layer: Api
local _, ns = ...
ns.Api = ns.Api or {}

local pairs = pairs
local ipairs = ipairs
local pcall = pcall
local xpcall = xpcall
local type = type
local tostring = tostring
local select = select
local unpack = unpack or table.unpack
local table_insert = table.insert

local EventBus = {
    wowHandlers = {},
    registeredEvents = {},
    topics = {},
    frame = nil,
}
ns.Api.EventBus = EventBus

local function FormatErr(err)
    local msg = tostring(err)
    if type(_G.debugstack) == "function" then
        local ok, st = pcall(_G.debugstack, 2, 4, 0)
        if ok and type(st) == "string" and st ~= "" then
            return msg .. "\n" .. st
        end
    end
    return msg
end

local function SafeInvoke(fn, ...)
    local argc = select("#", ...)
    local args = { ... }
    local ok, err = xpcall(function()
        fn(unpack(args, 1, argc))
    end, FormatErr)
    if not ok then
        local getter = _G.geterrorhandler
        if type(getter) == "function" then
            local okGet, handler = pcall(getter)
            if okGet and type(handler) == "function" then
                pcall(handler, err)
            end
        end
    end
    return ok, err
end

local function EnsureFrame()
    if EventBus.frame then
        return EventBus.frame
    end
    if type(_G.CreateFrame) ~= "function" then
        return nil
    end
    local f = _G.CreateFrame("Frame")
    f:SetScript("OnEvent", function(_, event, ...)
        local map = EventBus.wowHandlers[event]
        if not map then
            return
        end
        -- Snapshot (ownerKey, fn) pairs so unsubscription AND same-key replacement mid-dispatch are both isolated
        local snap = {}
        for k, fn in pairs(map) do
            snap[#snap + 1] = { k = k, fn = fn }
        end
        for i = 1, #snap do
            local entry = snap[i]
            if map[entry.k] == entry.fn and type(entry.fn) == "function" then
                SafeInvoke(entry.fn, event, ...)
            end
        end
    end)
    EventBus.frame = f
    return f
end

function EventBus:OnEvent(ownerKey, eventName, handler)
    if ownerKey == nil or type(eventName) ~= "string" or eventName == "" or type(handler) ~= "function" then
        return false
    end
    local f = EnsureFrame()
    self.wowHandlers[eventName] = self.wowHandlers[eventName] or {}
    self.wowHandlers[eventName][ownerKey] = handler
    if (not self.registeredEvents[eventName]) and f and f.RegisterEvent then
        local ok = pcall(f.RegisterEvent, f, eventName)
        if ok then
            self.registeredEvents[eventName] = true
        end
    end
    return true
end

function EventBus:OffEvent(ownerKey, eventName)
    if ownerKey == nil or type(eventName) ~= "string" or eventName == "" then
        return false
    end
    local map = self.wowHandlers[eventName]
    if not map then
        return false
    end
    if map[ownerKey] == nil then
        return false
    end
    map[ownerKey] = nil
    if next(map) == nil then
        self.wowHandlers[eventName] = nil
        self.registeredEvents[eventName] = nil
        if self.frame and self.frame.UnregisterEvent then
            pcall(self.frame.UnregisterEvent, self.frame, eventName)
        end
    end
    return true
end

function EventBus:Subscribe(topic, handler)
    self.topics[topic] = self.topics[topic] or {}
    table_insert(self.topics[topic], handler)
end

function EventBus:Publish(topic, ...)
    local list = self.topics[topic]
    if not list then
        return
    end
    for _, fn in ipairs(list) do
        SafeInvoke(fn, ...)
    end
end
