-- Module: Blizzard/WorldMapAdapter.lua
-- Responsibility: Zero-Taint read-only WorldMapFrame HookScript bridge (OnShow/OnHide callbacks, NavPort flush, canvas rect & mapID reader).
-- Layer: Blizzard (NEVER calls SetScript, AddDataProvider, AcquirePin, or writes fields on WorldMapFrame).
local _, ns = ...
ns.Blizzard = ns.Blizzard or {}

local pcall = pcall
local type = type
local ipairs = ipairs
local table_insert = table.insert

local WorldMapAdapter = {
    hooked = false,
    onShowCallbacks = {},
    onHideCallbacks = {},
}
ns.Blizzard.WorldMapAdapter = WorldMapAdapter

function WorldMapAdapter:RegisterCallbacks(onShow, onHide)
    if type(onShow) == "function" then
        table_insert(self.onShowCallbacks, onShow)
    end
    if type(onHide) == "function" then
        table_insert(self.onHideCallbacks, onHide)
    end
end

function WorldMapAdapter:GetViewingMapID()
    local wmf = _G.WorldMapFrame
    if type(wmf) == "table" and type(wmf.GetMapID) == "function" then
        local id = ns.Api.SafeAPI.SafeRead(wmf.GetMapID, wmf)
        if id ~= ns.Api.SafeAPI.UNAVAILABLE and type(id) == "number" and id > 0 then
            return id
        end
    end
    return nil
end

-- Returns { left, bottom, width, height, scale } of WorldMapFrame canvas (read-only), or nil.
function WorldMapAdapter:GetCanvasMetrics()
    local wmf = _G.WorldMapFrame
    if type(wmf) ~= "table" then
        return nil
    end
    local scroll = (type(wmf.ScrollContainer) == "table") and wmf.ScrollContainer or wmf
    local canvas = (type(scroll.Child) == "table") and scroll.Child or scroll
    if type(canvas.GetLeft) ~= "function" or type(canvas.GetBottom) ~= "function"
        or type(canvas.GetWidth) ~= "function" or type(canvas.GetHeight) ~= "function"
    then
        return nil
    end
    local left = ns.Api.SafeAPI.SafeRead(canvas.GetLeft, canvas)
    local bottom = ns.Api.SafeAPI.SafeRead(canvas.GetBottom, canvas)
    local width = ns.Api.SafeAPI.SafeRead(canvas.GetWidth, canvas)
    local height = ns.Api.SafeAPI.SafeRead(canvas.GetHeight, canvas)
    local scale = (type(canvas.GetEffectiveScale) == "function")
        and ns.Api.SafeAPI.SafeRead(canvas.GetEffectiveScale, canvas) or 1
    local U = ns.Api.SafeAPI.UNAVAILABLE
    if left == U or bottom == U or width == U or height == U or scale == U then
        return nil
    end
    if type(left) ~= "number" or type(bottom) ~= "number" or type(width) ~= "number" or type(height) ~= "number" or type(scale) ~= "number" then
        return nil
    end
    return {
        left = left,
        bottom = bottom,
        width = width,
        height = height,
        scale = scale,
    }
end

function WorldMapAdapter:Init()
    if self.hooked then
        return true
    end
    local wmf = _G.WorldMapFrame
    if type(wmf) == "table" and type(wmf.HookScript) == "function" then
        local okHide = pcall(wmf.HookScript, wmf, "OnHide", function()
            for _, fn in ipairs(WorldMapAdapter.onHideCallbacks) do
                pcall(fn)
            end
            if ns.Api and ns.Api.NavPort then
                pcall(ns.Api.NavPort.FlushIfSafe)
            end
        end)
        pcall(wmf.HookScript, wmf, "OnShow", function()
            for _, fn in ipairs(WorldMapAdapter.onShowCallbacks) do
                pcall(fn)
            end
        end)
        if okHide then
            self.hooked = true
            return true
        end
    end
    return false
end
