-- Module: Features/CombatAssistHud.lua
-- Responsibility: L0 9-class out-of-combat buff reminder strip and C_Secrets-safe low-health survival badge (ghost-safe, explicit combat override).
-- Layer: Features (uses UI/Widgets + Domain/CombatAlertModel + Api/GameAdapters).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens

local CombatAssistHud = {
    strip = nil,
    label = nil,
    lastMissing = {},
    isLowHealth = false,
}
ns.Features.CombatAssistHud = CombatAssistHud

function CombatAssistHud:Init()
    if self.strip then
        return self.strip
    end
    local card = W.Card(nil, 248, 26, "ForeverSuiteV2CombatAssist", T.ELEVATION.L0_HUD)
    local lbl = W.Label(card, "", "small", T.SEMANTIC.WARN)
    lbl:SetPoint("CENTER", card, "CENTER", 0, 0)
    self.strip = card
    self.label = lbl

    ns.UI.HudLayout:Register("combatAssist", card, {
        point = "CENTER",
        relPoint = "CENTER",
        x = 0,
        y = -156,
    }, "전투·버프 보조 바")

    card:Hide()
    return card
end

function CombatAssistHud:Refresh(inCombatOverride)
    self:Init()
    local inCombat
    if inCombatOverride ~= nil then
        inCombat = (inCombatOverride == true)
    else
        inCombat = ns.Api.SafeAPI.InCombat()
    end
    local isDeadOrGhost = ns.Api.GameAdapters.IsPlayerDeadOrGhost()

    if ns.Api.ProfileStore:Get("combat", "lowHealthAlert") ~= false then
        local hp, hpMax = ns.Api.GameAdapters.GetPlayerHealth()
        local eval = ns.Domain.CombatAlertModel.EvaluateLowHealth(hp, hpMax, 0.30, isDeadOrGhost)
        self.isLowHealth = (eval ~= nil and eval.isLow == true)
        if self.isLowHealth then
            self.label:SetText("[위험] 생명력 " .. tostring(eval.pct) .. "%")
            self.label:SetTextColor(T.SEMANTIC.DANGER[1], T.SEMANTIC.DANGER[2], T.SEMANTIC.DANGER[3], 1)
            W.SetBorderColor(self.strip, T.SEMANTIC.DANGER)
            self.strip:Show()
            return "LOW_HP"
        end
    else
        self.isLowHealth = false
    end

    if (not inCombat) and (not isDeadOrGhost) and ns.Api.ProfileStore:Get("combat", "buffReminder") ~= false then
        local engClass = ns.Api.GameAdapters.GetPlayerClass()
        local allSpells = ns.Domain.CombatAlertModel.CollectAllSpellIDsForClass(engClass)
        local cls, known, active, mhEnchant, auraReadable = ns.Api.GameAdapters.GetPlayerClassAndBuffs(allSpells)
        if not auraReadable then
            self.lastMissing = {}
            self.strip:Hide()
            return "AURA_UNAVAILABLE"
        end
        local missing = ns.Domain.CombatAlertModel.EvaluateMissingBuffs(cls, known, active, mhEnchant, inCombat, isDeadOrGhost)
        self.lastMissing = missing
        if #missing > 0 then
            self.label:SetText("버프 누락: " .. table.concat(missing, " · "))
            self.label:SetTextColor(T.SEMANTIC.WARN[1], T.SEMANTIC.WARN[2], T.SEMANTIC.WARN[3], 1)
            W.SetBorderColor(self.strip, T.SEMANTIC.WARN)
            self.strip:Show()
            return "MISSING_BUFF"
        end
    else
        self.lastMissing = {}
    end

    self.strip:Hide()
    return "CLEAR"
end
