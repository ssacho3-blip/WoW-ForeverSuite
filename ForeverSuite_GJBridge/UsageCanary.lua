-- Module: ForeverSuite_GJBridge/UsageCanary.lua
-- Responsibility: Phase 0 read-only GodJohnson panel OnShow usage telemetry (for data-driven v2 Codex whitelist).
-- Dependencies: ForeverSuite/Core/Diagnostics.lua (ForeverSuite.Diagnostics.RecordGJPanelShow).
-- Combat/Secret Safety: Strictly read-only HookScript; never writes any field onto GJ frames or GJCompanion tables.
local _, ns = ...

local type = type
local pairs = pairs
local pcall = pcall
local string_sub = string.sub

local hookedFrames = {}

local IGNORED_FRAMES = {
    GodJohnsonGoldBorderLauncher = true,
    GodJohnsonGoldBorderMinimapButton = true,
}

local function IsTrackedGJFrameName(name)
    if type(name) ~= "string" or name == "" then
        return false
    end
    if IGNORED_FRAMES[name] then
        return false
    end
    if string_sub(name, 1, 10) == "GodJohnson" then
        return true
    end
    if string_sub(name, 1, 2) == "GJ" and string_sub(name, 1, 11) ~= "GJCompanion" then
        return true
    end
    return false
end

local function TryHookFrame(name, obj)
    if type(obj) ~= "table" or hookedFrames[obj] then
        return false
    end
    if type(obj.HookScript) ~= "function" then
        return false
    end
    local okType, objType = pcall(function()
        return type(obj.GetObjectType) == "function" and obj:GetObjectType() or "Frame"
    end)
    if not okType or (objType ~= "Frame" and objType ~= "Button" and objType ~= "ScrollFrame") then
        return false
    end
    local okHook = pcall(obj.HookScript, obj, "OnShow", function()
        local FS = _G.ForeverSuite
        if type(FS) == "table" and type(FS.Diagnostics) == "table" and type(FS.Diagnostics.RecordGJPanelShow) == "function" then
            pcall(FS.Diagnostics.RecordGJPanelShow, FS.Diagnostics, name)
        end
    end)
    if okHook then
        hookedFrames[obj] = name
        return true
    end
    return false
end

function ns.ScanAndHookGJUsageCanary()
    local hookedCount = 0
    for key, val in pairs(_G) do
        if IsTrackedGJFrameName(key) and TryHookFrame(key, val) then
            hookedCount = hookedCount + 1
        end
    end
    return hookedCount
end

if _G.CreateFrame then
    local f = _G.CreateFrame("Frame")
    if f and f.RegisterEvent and f.SetScript then
        f:RegisterEvent("PLAYER_LOGIN")
        f:RegisterEvent("PLAYER_ENTERING_WORLD")
        f:SetScript("OnEvent", function()
            ns.ScanAndHookGJUsageCanary()
        end)
    end
end
