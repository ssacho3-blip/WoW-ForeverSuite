-- Module: Api/EventBus.lua
-- Responsibility: Centralized WoW event dispatcher and internal pub/sub message bus.
-- Layer: Api
local _, ns = ...
ns.Api = ns.Api or {}

local pairs = pairs
local ipairs = ipairs
local pcall = pcall
local table_insert = table.insert

local EventBus = {
    wowHandlers = {},
    topics = {},
    frame = nil,
}
ns.Api.EventBus = EventBus

local function SafeInvoke(fn, ...)
    local ok, err = pcall(fn, ...)
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
        for _, fn in pairs(map) do
            SafeInvoke(fn, event, ...)
        end
    end)
    EventBus.frame = f
    return f
end

function EventBus:OnEvent(ownerKey, eventName, handler)
    local f = EnsureFrame()
    self.wowHandlers[eventName] = self.wowHandlers[eventName] or {}
    self.wowHandlers[eventName][ownerKey] = handler
    if f and f.RegisterEvent then
        pcall(f.RegisterEvent, f, eventName)
    end
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
