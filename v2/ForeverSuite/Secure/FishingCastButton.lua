-- Module: Secure/FishingCastButton.lua
-- Responsibility: F2 Zero-Taint SecureActionButtonTemplate + SecureHandlerStateTemplate for safe OOC double-right-click Fishing cast.
--                 Parent is strictly _G.UIParent. Uses Blizzard's restricted [combat] state driver (`self:ClearBindings()`)
--                 plus transient double-click arming (0.35s) so BUTTON2 is NEVER stuck during combat lockdown.
-- Layer: Secure
local _, ns = ...
ns.Secure = ns.Secure or {}

local FishingCastButton = {
    button = nil,
    enabled = false,
    bound = false,
    armedUntil = 0,
    lastDownAt = 0,
    lastDownX = nil,
    lastDownY = nil,
    worldHooked = false,
    clearTimerGen = 0,
}
ns.Secure.FishingCastButton = FishingCastButton

function FishingCastButton:OnWorldMouseDown(mouseBtn)
    if mouseBtn == "RightButton" and self.enabled then
        self.lastDownAt = (ns.Api and ns.Api.GameAdapters and ns.Api.GameAdapters.GetMonotonicTime()) or 0
        if ns.Api and ns.Api.GameAdapters and type(ns.Api.GameAdapters.GetCursorScreenPosition) == "function" then
            self.lastDownX, self.lastDownY = ns.Api.GameAdapters.GetCursorScreenPosition()
        else
            self.lastDownX, self.lastDownY = nil, nil
        end
    end
end

function FishingCastButton:OnWorldMouseUp(mouseBtn)
    if mouseBtn ~= "RightButton" or not self.enabled then return false, "IGNORED" end
    local now = (ns.Api and ns.Api.GameAdapters and ns.Api.GameAdapters.GetMonotonicTime()) or 0
    local downAt, dx0, dy0 = self.lastDownAt, self.lastDownX, self.lastDownY
    self.lastDownAt, self.lastDownX, self.lastDownY = 0, nil, nil
    if downAt <= 0 or (now - downAt) > 0.22 then
        return false, "HELD_OR_SLOW"
    end
    if type(dx0) == "number" and type(dy0) == "number"
        and ns.Api and ns.Api.GameAdapters and type(ns.Api.GameAdapters.GetCursorScreenPosition) == "function"
    then
        local ux, uy = ns.Api.GameAdapters.GetCursorScreenPosition()
        if type(ux) == "number" and type(uy) == "number" then
            if math.abs(ux - dx0) > 6 or math.abs(uy - dy0) > 6 then
                return false, "DRAGGED"
            end
        end
    end
    return self:OnWorldRightClick()
end

function FishingCastButton:EnsureButton()
    if self.button then return self.button end
    if type(_G.CreateFrame) ~= "function" then return nil end
    local btn = CreateFrame("Button", "ForeverSuiteSecureFishingBtn", _G.UIParent, "SecureActionButtonTemplate,SecureHandlerStateTemplate")
    if btn then
        local spellName = (ns.Api and ns.Api.GameAdapters and ns.Api.GameAdapters.GetSpellName(7620)) or "낚시"
        if type(btn.SetAttribute) == "function" then
            pcall(btn.SetAttribute, btn, "type", "spell")
            pcall(btn.SetAttribute, btn, "spell", spellName)
            -- Restricted Blizzard combat state driver: clears override bindings atomically BEFORE combat lockdown!
            pcall(btn.SetAttribute, btn, "_onstate-combat", "if newstate == 1 then self:ClearBindings() end")
        end
        if type(_G.RegisterStateDriver) == "function" then
            pcall(_G.RegisterStateDriver, btn, "combat", "[combat] 1; 0")
        end
        if type(btn.SetScript) == "function" then
            pcall(btn.SetScript, btn, "PostClick", function()
                FishingCastButton:DisarmNow()
            end)
        end
        if type(btn.Hide) == "function" then btn:Hide() end
    end
    self.button = btn

    -- Arm ONLY on stationary quick right-click release (<=0.22s and <=6px cursor movement), so camera drags NEVER arm!
    if (not self.worldHooked) and type(_G.WorldFrame) == "table" and type(_G.WorldFrame.HookScript) == "function" then
        self.worldHooked = true
        pcall(_G.WorldFrame.HookScript, _G.WorldFrame, "OnMouseDown", function(_, mouseBtn)
            FishingCastButton:OnWorldMouseDown(mouseBtn)
        end)
        pcall(_G.WorldFrame.HookScript, _G.WorldFrame, "OnMouseUp", function(_, mouseBtn)
            FishingCastButton:OnWorldMouseUp(mouseBtn)
        end)
    end
    return btn
end

function FishingCastButton:DisarmNow()
    self.armedUntil = 0
    if not self.bound then return true, "ALREADY_CLEAR" end
    if ns.Api and ns.Api.SafeAPI and ns.Api.SafeAPI.InCombat() then
        -- Restricted state driver (`_onstate-combat -> self:ClearBindings()`) owns combat-entry clearing
        self.bound = false
        return true, "CLEARED_BY_STATE_DRIVER"
    end
    if self.button and type(_G.ClearOverrideBindings) == "function" then
        pcall(_G.ClearOverrideBindings, self.button)
    end
    self.bound = false
    return true, "CLEARED"
end

-- Called on PLAYER_REGEN_DISABLED: reflects restricted state driver clear without calling protected ClearOverrideBindings in lockdown
function FishingCastButton:OnCombatEntered()
    self.armedUntil = 0
    if self.button and type(self.button.ClearBindings) == "function" then
        pcall(self.button.ClearBindings, self.button)
    end
    self.bound = false
    return true, "CLEARED_BY_STATE_DRIVER"
end

function FishingCastButton:OnWorldRightClick()
    if not self.enabled then return false, "DISABLED" end
    if ns.Api and ns.Api.SafeAPI and ns.Api.SafeAPI.InCombat() then return false, "IN_COMBAT" end
    local btn = self:EnsureButton()
    if not btn then return false, "UNSUPPORTED" end
    local now = (ns.Api and ns.Api.GameAdapters and ns.Api.GameAdapters.GetMonotonicTime()) or 0
    if type(_G.SetOverrideBindingClick) == "function" then
        local ok = pcall(_G.SetOverrideBindingClick, btn, true, "BUTTON2", "ForeverSuiteSecureFishingBtn")
        if not ok then
            self.bound = false
            return false, "BIND_FAILED"
        end
        self.bound = true
    else
        return false, "UNSUPPORTED"
    end
    self.armedUntil = now + 0.35
    self.clearTimerGen = self.clearTimerGen + 1
    local gen = self.clearTimerGen
    if ns.Api and ns.Api.GameAdapters and type(ns.Api.GameAdapters.RunAfter) == "function" then
        ns.Api.GameAdapters.RunAfter(0.38, function()
            if FishingCastButton.clearTimerGen == gen then
                FishingCastButton:DisarmNow()
            end
        end)
    end
    return true, "ARMED"
end

function FishingCastButton:SetActive(enabled)
    local want = enabled == true
    if not want then
        self.enabled = false
        return self:DisarmNow()
    end
    if ns.Api and ns.Api.SafeAPI and ns.Api.SafeAPI.InCombat() then
        return false, "IN_COMBAT"
    end
    local btn = self:EnsureButton()
    if not btn then return false, "UNSUPPORTED" end
    self.enabled = true
    -- Never hold a persistent BUTTON2 override; arm transiently only on hardware right-click!
    return true, "READY"
end
