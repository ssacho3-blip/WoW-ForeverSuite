-- Module: Domain/MinimapModel.lua
-- Responsibility: Pure Lua 5.1 polar coordinate math for the draggable Obsidian & Gold Minimap medallion button.
-- Layer: Domain (ZERO _G / WoW API access; verified by fsx check).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local math_cos = math.cos
local math_sin = math.sin
local math_atan2 = math.atan2
local math_rad = math.rad
local math_deg = math.deg
local math_floor = math.floor

local DEFAULT_ANGLE = 220
local DEFAULT_RADIUS = 80

local MinimapModel = {
    DEFAULT_ANGLE = DEFAULT_ANGLE,
    DEFAULT_RADIUS = DEFAULT_RADIUS,
}
ns.Domain.MinimapModel = MinimapModel

local function IsFiniteNumber(v)
    return type(v) == "number" and (v == v) and (v ~= 1 / 0) and (v ~= -1 / 0)
end

function MinimapModel.NormalizeAngle(deg)
    if not IsFiniteNumber(deg) then
        return DEFAULT_ANGLE
    end
    local a = deg % 360
    if a < 0 then
        a = a + 360
    end
    return math_floor(a * 10 + 0.5) / 10
end

function MinimapModel.AngleToOffset(deg, radius)
    local a = MinimapModel.NormalizeAngle(deg)
    local r = (IsFiniteNumber(radius) and radius > 0) and radius or DEFAULT_RADIUS
    local rad = math_rad(a)
    local dx = math_floor(math_cos(rad) * r + 0.5)
    local dy = math_floor(math_sin(rad) * r + 0.5)
    return dx, dy
end

function MinimapModel.CursorToAngle(cursorX, cursorY, centerX, centerY)
    if not (IsFiniteNumber(cursorX) and IsFiniteNumber(cursorY) and IsFiniteNumber(centerX) and IsFiniteNumber(centerY)) then
        return nil
    end
    local dx = cursorX - centerX
    local dy = cursorY - centerY
    if dx == 0 and dy == 0 then
        return nil
    end
    return MinimapModel.NormalizeAngle(math_deg(math_atan2(dy, dx)))
end
