-- Module: Blizzard/WorldMapAdapter.lua
-- Responsibility: Hooks WorldMapFrame OnHide (read-only HookScript) to flush deferred NavPort requests immediately when map closes.
-- Layer: Blizzard
local _, ns = ...
ns.Blizzard = ns.Blizzard or {}

local pcall = pcall

local WorldMapAdapter = {
    hooked = false,
}
ns.Blizzard.WorldMapAdapter = WorldMapAdapter

function WorldMapAdapter:Init()
    if self.hooked then
        return true
    end
    local wmf = _G.WorldMapFrame
    if type(wmf) == "table" and type(wmf.HookScript) == "function" then
        local ok = pcall(wmf.HookScript, wmf, "OnHide", function()
            if ns.Api and ns.Api.NavPort then
                ns.Api.NavPort.FlushIfSafe()
            end
        end)
        if ok then
            self.hooked = true
            return true
        end
    end
    return false
end
