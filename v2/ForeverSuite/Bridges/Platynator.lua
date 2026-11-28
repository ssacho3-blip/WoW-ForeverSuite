-- Module: Bridges/Platynator.lua
-- Responsibility: Official Platynator.API preset bridge + LibSharedMedia-3.0 font registration helper
--                 + ForeverTotems (SHAMAN safe zone & yield) + RareScanner coexistence registration.
-- Layer: Bridges (Rank 3: OOC user-click only for ImportString; never touches nameplate frames or CVars).
local _, ns = ...
ns.Bridges = ns.Bridges or {}

local type = type
local pcall = pcall

local PlatynatorBridge = {
    registered = false,
    lsmRegistered = false,
    lsmCount = 0,
    TOTEM_SAFE_ZONE = { yMin = 140, yMax = 210 },
}
ns.Bridges.Platynator = PlatynatorBridge

function PlatynatorBridge:RegisterSharedFonts(fontEntries)
    if self.lsmRegistered then
        return true, self.lsmCount
    end
    if type(fontEntries) ~= "table" then
        return false, 0
    end
    local libStub = ns.Api.AddonProbe.GetGlobal("LibStub")
    if type(libStub) ~= "function" and type(libStub) ~= "table" then
        return false, 0
    end
    local ok, lsm = pcall(libStub, "LibSharedMedia-3.0", true)
    if not ok or type(lsm) ~= "table" or type(lsm.Register) ~= "function" then
        return false, 0
    end
    local count = 0
    for i = 1, #fontEntries do
        local f = fontEntries[i]
        if type(f) == "table" and type(f.name) == "string" and type(f.path) == "string" then
            local okReg = pcall(lsm.Register, lsm, "font", f.name, f.path, 255)
            if okReg then
                count = count + 1
            end
        end
    end
    if count > 0 then
        self.lsmRegistered = true
        self.lsmCount = count
    end
    return count > 0, count
end

function PlatynatorBridge:Init()
    local pl = ns.Api.AddonProbe.GetGlobal("Platynator")
    if type(pl) ~= "table" or type(pl.API) ~= "table" then
        return "WARMING"
    end
    self.registered = true
    return "OK"
end

function PlatynatorBridge:ImportPreset(presetString)
    if ns.Api.SafeAPI.InCombat() then
        return false, "IN_COMBAT"
    end
    if type(presetString) ~= "string" or presetString == "" then
        return false, "INVALID_PRESET"
    end
    local pl = ns.Api.AddonProbe.GetGlobal("Platynator")
    local api = (type(pl) == "table") and pl.API or nil
    if type(api) ~= "table" or type(api.ImportString) ~= "function" then
        return false, "API_UNAVAILABLE"
    end
    local ok, err = pcall(api.ImportString, presetString)
    return ok and true or false, err
end

function PlatynatorBridge:GetTotemSafeZone()
    if ns.Bridges.BridgeHost:GetState("forever_totems") == "YIELDED" then
        return self.TOTEM_SAFE_ZONE
    end
    return nil
end

ns.Bridges.BridgeHost:Register({
    id = "platynator",
    target = "Platynator",
    mode = "bridge",
    protected = false,
    yields = { "nameplates" },
    init = function()
        return PlatynatorBridge:Init()
    end,
    teardown = function()
        PlatynatorBridge.registered = false
    end,
})

-- Yield-only specialist registrations (ForeverTotems for SHAMAN + RareScanner)
ns.Bridges.BridgeHost:Register({
    id = "forever_totems",
    target = "ForeverTotems",
    mode = "yield",
    classOnly = "SHAMAN",
    yields = { "shaman_assist" },
})

ns.Bridges.BridgeHost:Register({
    id = "rare_scanner",
    target = "RareScanner",
    mode = "yield",
    yields = { "rare_alerts" },
})
