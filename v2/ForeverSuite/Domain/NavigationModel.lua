-- Module: Domain/NavigationModel.lua
-- Responsibility: Pure 2D map-coordinate guidance (honest 3:2 map aspect compensation, map-unit distance, no fabricated yards/facing).
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local tonumber = tonumber
local math_sqrt = math.sqrt
local math_atan2 = math.atan2
local math_pi = math.pi
local math_floor = math.floor
local string_format = string.format

local TWO_PI = math_pi * 2
-- Standard WoW zone map aspect ratio (width : height ~= 3 : 2) for honest bearing without fabricating yard scales
local MAP_ASPECT_X = 1.5
local MAP_ASPECT_Y = 1.0
local ARRIVAL_MAP_UNITS = 0.8 -- ~0.8 map coordinate units (out of 100)

local RELATIVE_ARROWS = { "↑", "↗", "→", "↘", "↓", "↙", "←", "↖" }

local NavigationModel = {}
ns.Domain.NavigationModel = NavigationModel

function NavigationModel.ParseWayArgs(raw)
    if type(raw) ~= "string" then
        return nil
    end
    local trimmed = raw:match("^%s*(.-)%s*$") or ""
    if trimmed == "" then
        return { cmd = "status" }
    end
    local low = trimmed:lower()
    if low == "clear" or low == "reset" or low == "off" then
        return { cmd = "clear" }
    end
    local sx, sy, label = trimmed:match("^([%d%.]+)[,%s]+([%d%.]+)%s*(.*)$")
    local nx = tonumber(sx)
    local ny = tonumber(sy)
    if not nx or not ny or nx < 0 or nx > 100 or ny < 0 or ny > 100 then
        return nil
    end
    return {
        cmd = "set",
        x = nx / 100,
        y = ny / 100,
        label = (label and label ~= "") and label or string_format("%.1f, %.1f", nx, ny),
    }
end

-- Computes honest map-unit distance (0..100 scale) and aspect-compensated bearing.
-- When facingRad is nil/unavailable, returns arrow="·" (never fabricates North).
function NavigationModel.ComputeGuidance(px, py, facingRad, tx, ty)
    if type(px) ~= "number" or type(py) ~= "number" or type(tx) ~= "number" or type(ty) ~= "number" then
        return nil
    end
    local dx = (tx - px) * 100
    local dy = (py - ty) * 100 -- north is +dy
    local mapUnits = math_sqrt(dx * dx + dy * dy)

    local arrow = "·"
    local relAngle = nil
    if type(facingRad) == "number" then
        local ax = dx * MAP_ASPECT_X
        local ay = dy * MAP_ASPECT_Y
        local targetBearing = math_atan2(ax, ay)
        if targetBearing < 0 then
            targetBearing = targetBearing + TWO_PI
        end
        local playerClockwise = (TWO_PI - (facingRad % TWO_PI)) % TWO_PI
        relAngle = (targetBearing - playerClockwise) % TWO_PI
        local sector = (math_floor((relAngle / (math_pi / 4)) + 0.5) % 8) + 1
        arrow = RELATIVE_ARROWS[sector] or "↑"
    end

    return {
        mapUnits = mapUnits,
        distText = string_format("%.1f좌표", mapUnits),
        arrived = mapUnits <= ARRIVAL_MAP_UNITS,
        arrow = arrow,
        relAngle = relAngle,
    }
end
