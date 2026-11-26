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
    canvasClickHooked = false,
    onShowCallbacks = {},
    onHideCallbacks = {},
    onCanvasClickCallbacks = {},
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

-- E6: Zero-Taint read-only WorldMap canvas modifier-click callback (Alt+RightClick or Ctrl+LeftClick -> /way)
function WorldMapAdapter:RegisterCanvasClickCallback(fn)
    if type(fn) == "function" then
        table_insert(self.onCanvasClickCallbacks, fn)
    end
end

-- E6: Read already-explored FileDataIDs for mapID so Fog-of-War overlay only reveals unexplored areas
function WorldMapAdapter.GetExploredFileSet(mapID)
    local explored = {}
    if type(mapID) ~= "number" or mapID <= 0 then return explored end
    if C_MapExplorationInfo and type(C_MapExplorationInfo.GetExploredMapTextures) == "function" then
        local list = ns.Api.SafeAPI.SafeRead(C_MapExplorationInfo.GetExploredMapTextures, mapID)
        if list ~= ns.Api.SafeAPI.UNAVAILABLE and type(list) == "table" then
            for _, info in ipairs(list) do
                if type(info) == "table" and type(info.fileDataIDs) == "table" then
                    for _, fid in ipairs(info.fileDataIDs) do
                        if type(fid) == "number" then explored[fid] = true end
                    end
                end
            end
        end
    end
    return explored
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
        if not self.canvasClickHooked then
            local targetFrame = (type(wmf.ScrollContainer) == "table" and type(wmf.ScrollContainer.HookScript) == "function")
                and wmf.ScrollContainer or wmf
            if type(targetFrame.HookScript) == "function" then
                -- E6: Use Alt+LeftClick exclusively (avoids RightClick zoom-out AND Blizzard's native Ctrl+LeftClick waypoint double-pin)
                local okClick = pcall(targetFrame.HookScript, targetFrame, "OnMouseUp", function(_, mouseBtn)
                    local isAltLeft = (mouseBtn == "LeftButton") and ns.Api.GameAdapters.IsAltDown() and (not ns.Api.GameAdapters.IsControlDown())
                    if not isAltLeft then return end
                    local mapID = WorldMapAdapter:GetViewingMapID()
                    if not mapID then return end
                    local nx, ny = nil, nil
                    if type(wmf.ScrollContainer) == "table" and type(wmf.ScrollContainer.GetNormalizedCursorPosition) == "function" then
                        local okN, rx, ry = pcall(wmf.ScrollContainer.GetNormalizedCursorPosition, wmf.ScrollContainer)
                        if okN and type(rx) == "number" and type(ry) == "number" and rx >= 0 and rx <= 1 and ry >= 0 and ry <= 1 then
                            nx, ny = rx, ry
                        end
                    end
                    if not (nx and ny) then
                        local cx, cy = ns.Api.GameAdapters.GetCursorScreenPosition()
                        local metrics = WorldMapAdapter:GetCanvasMetrics()
                        if cx and cy and metrics then
                            nx, ny = ns.Domain.WorldMapModel.ComputeCursorCoords(cx, cy, metrics.scale, metrics.left, metrics.bottom, metrics.width, metrics.height)
                        end
                    end
                    if nx and ny then
                        for _, cb in ipairs(WorldMapAdapter.onCanvasClickCallbacks) do
                            pcall(cb, mapID, nx, ny)
                        end
                    end
                end)
                self.canvasClickHooked = okClick and true or false
            end
        end
        if okHide then
            self.hooked = true
            return true
        end
    end
    return false
end
