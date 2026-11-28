-- Module: Blizzard/CharacterDockAdapter.lua
-- Responsibility: Zero-Taint read-only CharacterFrame OnShow/OnHide HookScript adapter and edge-anchor calculator.
-- Layer: Blizzard (Rank 3: NEVER calls SetScript, NEVER writes fields onto Blizzard frames, NEVER references Bridges).
local _, ns = ...
ns.Blizzard = ns.Blizzard or {}

local type = type
local pcall = pcall

local CharacterDockAdapter = {
    hooked = false,
    onShowCb = nil,
    onHideCb = nil,
}
ns.Blizzard.CharacterDockAdapter = CharacterDockAdapter

function CharacterDockAdapter:Init(onShow, onHide)
    self.onShowCb = onShow
    self.onHideCb = onHide
    if self.hooked then
        return true
    end
    local cf = _G.CharacterFrame
    if type(cf) ~= "table" or type(cf.HookScript) ~= "function" then
        return false
    end
    local ok1 = pcall(cf.HookScript, cf, "OnShow", function()
        if type(CharacterDockAdapter.onShowCb) == "function" then
            pcall(CharacterDockAdapter.onShowCb)
        end
    end)
    local ok2 = pcall(cf.HookScript, cf, "OnHide", function()
        if type(CharacterDockAdapter.onHideCb) == "function" then
            pcall(CharacterDockAdapter.onHideCb)
        end
    end)
    self.hooked = (ok1 and ok2) and true or false
    return self.hooked
end

function CharacterDockAdapter.IsShown()
    local cf = _G.CharacterFrame
    if type(cf) ~= "table" or type(cf.IsShown) ~= "function" then
        return false
    end
    local ok, shown = pcall(cf.IsShown, cf)
    return ok and shown == true
end

-- Computes safe UIParent-relative dock position beside CharacterFrame (flips to left if right overflows viewport).
function CharacterDockAdapter.ComputeDockPosition(panelWidth)
    local cf = _G.CharacterFrame
    local ui = _G.UIParent
    local pw = (type(panelWidth) == "number" and panelWidth > 0) and panelWidth or 240
    if type(cf) ~= "table" or type(cf.GetRight) ~= "function" or type(cf.GetTop) ~= "function" then
        return "TOPRIGHT", -24, -120
    end
    local okR, right = pcall(cf.GetRight, cf)
    local okL, left = pcall(cf.GetLeft, cf)
    local okT, top = pcall(cf.GetTop, cf)
    if not (okR and okT and type(right) == "number" and type(top) == "number") then
        return "TOPRIGHT", -24, -120
    end
    local charScale = (type(cf.GetEffectiveScale) == "function" and select(2, pcall(cf.GetEffectiveScale, cf))) or 1.0
    local uiScale = (type(ui) == "table" and type(ui.GetEffectiveScale) == "function" and select(2, pcall(ui.GetEffectiveScale, ui))) or 1.0
    if type(charScale) ~= "number" or charScale <= 0 then charScale = 1.0 end
    if type(uiScale) ~= "number" or uiScale <= 0 then uiScale = 1.0 end
    local ratio = charScale / uiScale
    local uiW = (type(ui) == "table" and type(ui.GetWidth) == "function" and select(2, pcall(ui.GetWidth, ui))) or 1920
    if type(uiW) ~= "number" or uiW <= 0 then uiW = 1920 end

    local rightX = (right * ratio) + 4
    local topY = top * ratio
    if (rightX + pw) <= uiW then
        return "BOTTOMLEFT", rightX, topY
    end
    local leftX = (okL and type(left) == "number") and ((left * ratio) - pw - 4) or 16
    if leftX < 8 then leftX = 8 end
    return "BOTTOMLEFT", leftX, topY
end
