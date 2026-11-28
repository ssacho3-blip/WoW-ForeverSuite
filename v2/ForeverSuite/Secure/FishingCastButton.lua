-- Module: Secure/FishingCastButton.lua
-- Responsibility: F2 Zero-Taint SecureActionButtonTemplate + SecureHandlerStateTemplate for safe OOC double-right-click Fishing cast.
--                 Parent is strictly _G.UIParent. Uses Blizzard's restricted [combat] state driver (`self:ClearBindings()`)
--                 plus transient double-click arming (0.35s) so BUTTON2 is NEVER stuck during combat lockdown.
-- Layer: Secure
local _, ns = ...
ns.Secure = ns.Secure or {}

local FishingCastButton = {
    button = nil,
    dockCastBtn = nil,
    dockLureBtn = nil,
    dockVisible = false,
    dockAnchor = nil,
    lastLure = nil,
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

local function StyleDockSecureButton(btn, labelText, accentGold)
    if not btn then return end
    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(btn)
    if accentGold then
        bg:SetColorTexture(0.24, 0.19, 0.07, 0.92)
    else
        bg:SetColorTexture(0.11, 0.13, 0.18, 0.90)
    end
    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(btn)
    hl:SetColorTexture(0.84, 0.69, 0.28, 0.24)
    local topLine = btn:CreateTexture(nil, "BORDER")
    topLine:SetHeight(1)
    topLine:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
    topLine:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 0, 0)
    topLine:SetColorTexture(0.84, 0.69, 0.28, accentGold and 0.85 or 0.45)
    local botLine = btn:CreateTexture(nil, "BORDER")
    botLine:SetHeight(1)
    botLine:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
    botLine:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
    botLine:SetColorTexture(0.84, 0.69, 0.28, accentGold and 0.65 or 0.35)
    local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("CENTER", btn, "CENTER", 0, 0)
    lbl:SetText(labelText or "")
    if accentGold then
        lbl:SetTextColor(0.98, 0.86, 0.44, 1)
    else
        lbl:SetTextColor(0.88, 0.91, 0.96, 1)
    end
    btn._fsBg = bg
    btn._fsLabel = lbl
end

local function ResolveFishingSpellName()
    if ns.Api and ns.Api.GameAdapters then
        if type(ns.Api.GameAdapters.GetFishingSpellNameSafe) == "function" then
            return ns.Api.GameAdapters.GetFishingSpellNameSafe()
        end
        if type(ns.Api.GameAdapters.GetSpellName) == "function" then
            local n = ns.Api.GameAdapters.GetSpellName(7620)
            if type(n) == "string" and n ~= "" then return n end
        end
    end
    return "낚시"
end

function FishingCastButton:EnsureDockButtons()
    if self.dockCastBtn and self.dockLureBtn then
        return self.dockCastBtn, self.dockLureBtn
    end
    if type(_G.CreateFrame) ~= "function" then
        return nil, nil
    end
    local spellName = ResolveFishingSpellName()

    if not self.dockCastBtn then
        local cbtn = CreateFrame("Button", "ForeverSuiteFishingDockCastBtn", _G.UIParent, "SecureActionButtonTemplate,SecureHandlerStateTemplate")
        if cbtn then
            cbtn:SetSize(134, 24)
            if type(cbtn.RegisterForClicks) == "function" then
                pcall(cbtn.RegisterForClicks, cbtn, "LeftButtonUp", "RightButtonUp")
            end
            if type(cbtn.SetAttribute) == "function" then
                -- CRITICAL for WoW 1.60.1 (ActionButtonUseKeyDown=1 default): force release-click so clicks NEVER silently drop!
                pcall(cbtn.SetAttribute, cbtn, "useOnKeyDown", false)
                pcall(cbtn.SetAttribute, cbtn, "type", "spell")
                pcall(cbtn.SetAttribute, cbtn, "spell", spellName)
                pcall(cbtn.SetAttribute, cbtn, "type1", "spell")
                pcall(cbtn.SetAttribute, cbtn, "spell1", spellName)
                pcall(cbtn.SetAttribute, cbtn, "type2", "macro")
                pcall(cbtn.SetAttribute, cbtn, "macrotext2", "")
                pcall(cbtn.SetAttribute, cbtn, "fsVisible", false)
                pcall(cbtn.SetAttribute, cbtn, "_onstate-combat", "if newstate == 1 then self:Hide() elseif self:GetAttribute('fsVisible') then self:Show() end")
            end
            if type(_G.RegisterStateDriver) == "function" then
                pcall(_G.RegisterStateDriver, cbtn, "combat", "[combat] 1; 0")
            end
            StyleDockSecureButton(cbtn, "★ 낚시 시전", true)
            if type(cbtn.SetScript) == "function" then
                pcall(cbtn.SetScript, cbtn, "OnEnter", function(selfBtn)
                    if _G.GameTooltip and type(_G.GameTooltip.SetOwner) == "function" then
                        _G.GameTooltip:SetOwner(selfBtn, "ANCHOR_TOP")
                        _G.GameTooltip:SetText("★ 원클릭 낚시 시전", 0.98, 0.86, 0.44)
                        _G.GameTooltip:AddLine("좌클릭: 즉시 낚시 시전", 0.92, 0.94, 0.96, true)
                        _G.GameTooltip:AddLine("우클릭: 가방 최고 미끼 자동 적용", 0.56, 0.94, 0.66, true)
                        _G.GameTooltip:AddLine("팁: 물 위 빈 곳 더블 우클릭으로도 자동 시전!", 0.72, 0.84, 0.98, true)
                        _G.GameTooltip:Show()
                    end
                end)
                pcall(cbtn.SetScript, cbtn, "OnLeave", function()
                    if _G.GameTooltip and type(_G.GameTooltip.Hide) == "function" then _G.GameTooltip:Hide() end
                end)
            end
            if type(cbtn.Hide) == "function" then cbtn:Hide() end
        end
        self.dockCastBtn = cbtn
    end

    if not self.dockLureBtn then
        local lbtn = CreateFrame("Button", "ForeverSuiteFishingDockLureBtn", _G.UIParent, "SecureActionButtonTemplate,SecureHandlerStateTemplate")
        if lbtn then
            lbtn:SetSize(134, 24)
            if type(lbtn.RegisterForClicks) == "function" then
                pcall(lbtn.RegisterForClicks, lbtn, "LeftButtonUp", "RightButtonUp")
            end
            if type(lbtn.SetAttribute) == "function" then
                pcall(lbtn.SetAttribute, lbtn, "useOnKeyDown", false)
                pcall(lbtn.SetAttribute, lbtn, "type", "macro")
                pcall(lbtn.SetAttribute, lbtn, "macrotext", "")
                pcall(lbtn.SetAttribute, lbtn, "fsVisible", false)
                pcall(lbtn.SetAttribute, lbtn, "_onstate-combat", "if newstate == 1 then self:Hide() elseif self:GetAttribute('fsVisible') then self:Show() end")
            end
            if type(_G.RegisterStateDriver) == "function" then
                pcall(_G.RegisterStateDriver, lbtn, "combat", "[combat] 1; 0")
            end
            StyleDockSecureButton(lbtn, "미끼 없음", false)
            if type(lbtn.Hide) == "function" then lbtn:Hide() end
        end
        self.dockLureBtn = lbtn
    end

    return self.dockCastBtn, self.dockLureBtn
end

function FishingCastButton:SyncDock(anchorFrame, visible, lureInfo)
    self.dockAnchor = anchorFrame or self.dockAnchor
    self.dockVisible = visible == true
    self.lastLure = lureInfo
    if ns.Api and ns.Api.SafeAPI and ns.Api.SafeAPI.InCombat() then
        if ns.Secure and ns.Secure.CombatQueue and type(ns.Secure.CombatQueue.RunOrDefer) == "function" then
            ns.Secure.CombatQueue:RunOrDefer("fishing:syncDock", function()
                FishingCastButton:SyncDock(FishingCastButton.dockAnchor, FishingCastButton.dockVisible, FishingCastButton.lastLure)
            end)
        end
        return false, "DEFERRED_COMBAT"
    end
    local cbtn, lbtn = self:EnsureDockButtons()
    if not (cbtn and lbtn) then
        return false, "UNSUPPORTED"
    end
    if (not self.dockVisible) or (not self.dockAnchor) then
        if type(cbtn.SetAttribute) == "function" then pcall(cbtn.SetAttribute, cbtn, "fsVisible", false) end
        if type(lbtn.SetAttribute) == "function" then pcall(lbtn.SetAttribute, lbtn, "fsVisible", false) end
        if type(cbtn.Hide) == "function" then cbtn:Hide() end
        if type(lbtn.Hide) == "function" then lbtn:Hide() end
        return true, "HIDDEN"
    end

    local spellName = ResolveFishingSpellName()
    local strata = (type(self.dockAnchor.GetFrameStrata) == "function" and self.dockAnchor:GetFrameStrata()) or "MEDIUM"
    local lvl = ((type(self.dockAnchor.GetFrameLevel) == "function" and self.dockAnchor:GetFrameLevel()) or 10) + 5
    local lureMacro = (type(lureInfo) == "table" and type(lureInfo.itemID) == "number")
        and ("/use item:" .. tostring(lureInfo.itemID) .. "\n/use 16") or ""

    cbtn:ClearAllPoints()
    cbtn:SetPoint("BOTTOMLEFT", self.dockAnchor, "BOTTOMLEFT", 8, 8)
    if type(cbtn.SetFrameStrata) == "function" then cbtn:SetFrameStrata(strata) end
    if type(cbtn.SetFrameLevel) == "function" then cbtn:SetFrameLevel(lvl) end
    if type(cbtn.SetAttribute) == "function" then
        pcall(cbtn.SetAttribute, cbtn, "useOnKeyDown", false)
        pcall(cbtn.SetAttribute, cbtn, "type", "spell")
        pcall(cbtn.SetAttribute, cbtn, "spell", spellName)
        pcall(cbtn.SetAttribute, cbtn, "type1", "spell")
        pcall(cbtn.SetAttribute, cbtn, "spell1", spellName)
        pcall(cbtn.SetAttribute, cbtn, "type2", "macro")
        pcall(cbtn.SetAttribute, cbtn, "macrotext2", lureMacro)
        pcall(cbtn.SetAttribute, cbtn, "fsVisible", true)
    end
    cbtn:Show()

    lbtn:ClearAllPoints()
    lbtn:SetPoint("BOTTOMRIGHT", self.dockAnchor, "BOTTOMRIGHT", -8, 8)
    if type(lbtn.SetFrameStrata) == "function" then lbtn:SetFrameStrata(strata) end
    if type(lbtn.SetFrameLevel) == "function" then lbtn:SetFrameLevel(lvl) end
    if type(lbtn.SetAttribute) == "function" then
        pcall(lbtn.SetAttribute, lbtn, "useOnKeyDown", false)
        pcall(lbtn.SetAttribute, lbtn, "fsVisible", true)
    end
    if lureMacro ~= "" then
        if type(lbtn.SetAttribute) == "function" then
            pcall(lbtn.SetAttribute, lbtn, "type", "macro")
            pcall(lbtn.SetAttribute, lbtn, "macrotext", lureMacro)
        end
        if lbtn._fsLabel then
            lbtn._fsLabel:SetText("미끼 +" .. tostring(lureInfo.bonus or 0) .. " (" .. tostring(lureInfo.count or 1) .. ")")
            lbtn._fsLabel:SetTextColor(0.56, 0.94, 0.66, 1)
        end
    else
        if type(lbtn.SetAttribute) == "function" then
            pcall(lbtn.SetAttribute, lbtn, "type", "macro")
            pcall(lbtn.SetAttribute, lbtn, "macrotext", "")
        end
        if lbtn._fsLabel then
            lbtn._fsLabel:SetText("미끼 없음")
            lbtn._fsLabel:SetTextColor(0.60, 0.63, 0.68, 1)
        end
    end
    lbtn:Show()
    return true, "SHOWN"
end

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
    if downAt <= 0 or (now - downAt) > 0.35 then
        return false, "HELD_OR_SLOW"
    end
    if type(dx0) == "number" and type(dy0) == "number"
        and ns.Api and ns.Api.GameAdapters and type(ns.Api.GameAdapters.GetCursorScreenPosition) == "function"
    then
        local ux, uy = ns.Api.GameAdapters.GetCursorScreenPosition()
        if type(ux) == "number" and type(uy) == "number" then
            if math.abs(ux - dx0) > 8 or math.abs(uy - dy0) > 8 then
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
        local spellName = ResolveFishingSpellName()
        if type(btn.RegisterForClicks) == "function" then
            -- Register AnyUp only + useOnKeyDown=false so PostClick NEVER disarms on key-down before release casts!
            pcall(btn.RegisterForClicks, btn, "AnyUp")
        end
        if type(btn.SetAttribute) == "function" then
            pcall(btn.SetAttribute, btn, "useOnKeyDown", false)
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
    self.armedUntil = now + 0.48
    self.clearTimerGen = self.clearTimerGen + 1
    local gen = self.clearTimerGen
    if ns.Api and ns.Api.GameAdapters and type(ns.Api.GameAdapters.RunAfter) == "function" then
        ns.Api.GameAdapters.RunAfter(0.50, function()
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
