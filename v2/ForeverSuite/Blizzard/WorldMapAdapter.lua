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

-- Returns { left, bottom, width, height, scale, clip, strata, level } in UIParent coordinate space (read-only), or nil.
-- Correctly converts ScrollContainer.Child coordinates by (canvasEffectiveScale / uiParentEffectiveScale)
-- and attaches the visible ScrollContainer viewport rectangle (`clip`) so zoomed-in pins & overlays never leak off-map!
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
    local U = ns.Api.SafeAPI.UNAVAILABLE
    local rawLeft = ns.Api.SafeAPI.SafeRead(canvas.GetLeft, canvas)
    local rawBottom = ns.Api.SafeAPI.SafeRead(canvas.GetBottom, canvas)
    local rawWidth = ns.Api.SafeAPI.SafeRead(canvas.GetWidth, canvas)
    local rawHeight = ns.Api.SafeAPI.SafeRead(canvas.GetHeight, canvas)
    local canvasScale = (type(canvas.GetEffectiveScale) == "function")
        and ns.Api.SafeAPI.SafeRead(canvas.GetEffectiveScale, canvas) or 1
    if rawLeft == U or rawBottom == U or rawWidth == U or rawHeight == U or canvasScale == U then
        return nil
    end
    if type(rawLeft) ~= "number" or type(rawBottom) ~= "number"
        or type(rawWidth) ~= "number" or rawWidth <= 0
        or type(rawHeight) ~= "number" or rawHeight <= 0
        or type(canvasScale) ~= "number" or canvasScale <= 0
    then
        return nil
    end

    local uiScale = 1
    if type(_G.UIParent) == "table" and type(_G.UIParent.GetEffectiveScale) == "function" then
        local s = ns.Api.SafeAPI.SafeRead(_G.UIParent.GetEffectiveScale, _G.UIParent)
        if s ~= U and type(s) == "number" and s > 0 then
            uiScale = s
        end
    end

    local ratio = canvasScale / uiScale
    local left = rawLeft * ratio
    local bottom = rawBottom * ratio
    local width = rawWidth * ratio
    local height = rawHeight * ratio

    local clip = nil
    if type(scroll.GetLeft) == "function" and type(scroll.GetBottom) == "function"
        and type(scroll.GetWidth) == "function" and type(scroll.GetHeight) == "function"
    then
        local sLeft = ns.Api.SafeAPI.SafeRead(scroll.GetLeft, scroll)
        local sBottom = ns.Api.SafeAPI.SafeRead(scroll.GetBottom, scroll)
        local sWidth = ns.Api.SafeAPI.SafeRead(scroll.GetWidth, scroll)
        local sHeight = ns.Api.SafeAPI.SafeRead(scroll.GetHeight, scroll)
        local sScale = (type(scroll.GetEffectiveScale) == "function")
            and ns.Api.SafeAPI.SafeRead(scroll.GetEffectiveScale, scroll) or canvasScale
        if sLeft ~= U and sBottom ~= U and sWidth ~= U and sHeight ~= U and sScale ~= U
            and type(sLeft) == "number" and type(sBottom) == "number"
            and type(sWidth) == "number" and sWidth > 0
            and type(sHeight) == "number" and sHeight > 0
            and type(sScale) == "number" and sScale > 0
        then
            local sRatio = sScale / uiScale
            clip = {
                left = sLeft * sRatio,
                bottom = sBottom * sRatio,
                right = (sLeft + sWidth) * sRatio,
                top = (sBottom + sHeight) * sRatio,
            }
        end
    end

    local strata = nil
    if type(wmf.GetFrameStrata) == "function" then
        local st = ns.Api.SafeAPI.SafeRead(wmf.GetFrameStrata, wmf)
        if st ~= U and type(st) == "string" and st ~= "" then
            strata = st
        end
    end
    local level = nil
    if type(wmf.GetFrameLevel) == "function" then
        local lv = ns.Api.SafeAPI.SafeRead(wmf.GetFrameLevel, wmf)
        if lv ~= U and type(lv) == "number" then
            level = lv
        end
    end

    return {
        left = left,
        bottom = bottom,
        width = width,
        height = height,
        scale = uiScale,
        canvasScale = canvasScale,
        clip = clip,
        strata = strata,
        level = level,
    }
end

-- Preferred zoomed/panned cursor reader via WorldMapFrame.ScrollContainer:GetNormalizedCursorPosition()
function WorldMapAdapter:GetNormalizedCursorPosition()
    local wmf = _G.WorldMapFrame
    if type(wmf) == "table" and type(wmf.ScrollContainer) == "table"
        and type(wmf.ScrollContainer.GetNormalizedCursorPosition) == "function"
    then
        local okN, rx, ry = pcall(wmf.ScrollContainer.GetNormalizedCursorPosition, wmf.ScrollContainer)
        if okN and type(rx) == "number" and type(ry) == "number"
            and (not ns.Api.SafeAPI.IsSecret(rx)) and (not ns.Api.SafeAPI.IsSecret(ry))
            and rx == rx and ry == ry and rx >= 0 and rx <= 1 and ry >= 0 and ry <= 1
        then
            return rx, ry
        end
    end
    return nil, nil
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
