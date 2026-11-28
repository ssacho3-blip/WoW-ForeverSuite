-- Module: UI/PixelUtil.lua
-- Responsibility: Physical 1px HiDPI border & scale math (768/physH/effectiveScale), pixel-grid snap control,
--                 and 3-device display tier typography tokens (FHD / Retina / 4K).
-- Layer: UI (Rank 4).
local _, ns = ...
ns.UI = ns.UI or {}

local type = type
local pcall = pcall
local math_floor = math.floor
local math_max = math.max

local PixelUtil = {
    TYPO_TIERS = {
        FHD    = { body = 12, small = 10, outline = "" },
        RETINA = { body = 13, small = 11, outline = "" },
        UHD_4K = { body = 14, small = 12, outline = "OUTLINE" },
    },
}
ns.UI.PixelUtil = PixelUtil

function PixelUtil.GetPhysicalHeight()
    if type(_G.GetPhysicalScreenSize) == "function" then
        local ok, _, h = pcall(_G.GetPhysicalScreenSize)
        if ok and type(h) == "number" and h > 0 then
            return h
        end
    end
    return 1080
end

function PixelUtil.OnePixel(frame)
    local physH = PixelUtil.GetPhysicalHeight()
    local scale = 1.0
    if frame and type(frame.GetEffectiveScale) == "function" then
        local ok, s = pcall(frame.GetEffectiveScale, frame)
        if ok and type(s) == "number" and s > 0 then
            scale = s
        end
    end
    return (768.0 / physH) / scale
end

function PixelUtil.Snap(frame, logicalPx)
    local px = logicalPx or 1
    local unit = PixelUtil.OnePixel(frame)
    if unit <= 0 then
        return px
    end
    if px == 0 then
        return 0
    end
    local sign = (px < 0) and -1 or 1
    local mag = math_max(unit, math_floor((math.abs(px) / unit) + 0.5) * unit)
    return sign * mag
end

function PixelUtil.DisablePixelSnap(region)
    if type(region) ~= "table" then
        return false
    end
    if type(region.SetSnapToPixelGrid) == "function" then
        pcall(region.SetSnapToPixelGrid, region, false)
    end
    if type(region.SetTexelSnappingBias) == "function" then
        pcall(region.SetTexelSnappingBias, region, 0)
    end
    return true
end

function PixelUtil.GetDisplayTier(physHOverride)
    local h = (type(physHOverride) == "number" and physHOverride > 0) and physHOverride or PixelUtil.GetPhysicalHeight()
    if h >= 2000 then
        return "UHD_4K", PixelUtil.TYPO_TIERS.UHD_4K
    elseif h >= 1440 then
        return "RETINA", PixelUtil.TYPO_TIERS.RETINA
    end
    return "FHD", PixelUtil.TYPO_TIERS.FHD
end
