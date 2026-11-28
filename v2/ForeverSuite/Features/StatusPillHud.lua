-- Module: Features/StatusPillHud.lua
-- Responsibility: L0 compact Status Pill Bar (live bag slots · durability% · session gold · canonical realm; zero fabricated zeros).
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens

local StatusPillHud = {
    card = nil,
    label = nil,
    baselineMoney = nil,
}
ns.Features.StatusPillHud = StatusPillHud

function StatusPillHud:Init()
    if self.card then
        return self.card
    end
    local card = W.HudFloating(nil, 336, 24, "ForeverSuiteV2StatusPill", T.ELEVATION.L0_HUD)
    card:SetRibbon({ 0.038, 0.034, 0.046 }, 0.62, 0, 0)
    card:EnableMouse(true)
    card:SetScript("OnMouseUp", function(_, mouseBtn)
        if ns.UI.HudLayout and ns.UI.HudLayout.unlocked then return end
        if mouseBtn == "RightButton" then
            ns.UI.CommandHub:JumpTo("utilities", { subTab = "alts" })
        else
            ns.UI.CommandHub:JumpTo("ledger")
        end
    end)
    local lbl = W.Label(card, "", "mono", T.TEXT.PRIMARY, { outline = "OUTLINE" })
    lbl:SetPoint("CENTER", card, "CENTER", 0, 0)
    self.card = card
    self.label = lbl

    ns.UI.HudLayout:Register("statusPill", card, {
        point = "TOPRIGHT",
        relPoint = "TOPRIGHT",
        x = -24,
        y = -240,
    }, "상태 필 바")

    self:ApplyVisibility()
    self:RefreshLive()
    return card
end

function StatusPillHud:ApplyVisibility()
    if not self.card then
        return
    end
    if ns.UI.HudLayout and ns.UI.HudLayout:IsUnlocked() then
        self.card:Show()
        return
    end
    local visible = ns.Api.ProfileStore:Get("ui", "showStatusPill")
    if visible == false then
        self.card:Hide()
    else
        self.card:Show()
    end
end

function StatusPillHud:RefreshLive()
    local free = ns.Api.SafeAPI.GetBagFreeSlots()
    local curMoney = ns.Api.SafeAPI.GetPlayerMoney()
    local delta = nil
    if type(curMoney) == "number" then
        if self.baselineMoney == nil then
            self.baselineMoney = curMoney
        end
        delta = curMoney - self.baselineMoney
    end
    local durSlots = ns.Api.GameAdapters and ns.Api.GameAdapters.GetDurabilitySlots()
    local durPct = ns.Domain.MerchantModel and ns.Domain.MerchantModel.ComputeDurabilityPct(durSlots) or nil
    self:Refresh(free, delta, durPct)
end

function StatusPillHud:Refresh(freeSlots, sessionDeltaCopper, durPct)
    if not self.label then
        self:Init()
    end
    local bagTxt = (type(freeSlots) == "number") and ("가방 " .. tostring(freeSlots) .. "칸") or "가방 집계 없음"
    local lowDur = (type(durPct) == "number" and durPct < 30)
    local durTxt = (type(durPct) == "number")
        and (lowDur and ("|cfff87171내구 " .. tostring(durPct) .. "%|r") or ("내구 " .. tostring(durPct) .. "%"))
        or "내구 -"
    local moneyTxt = (type(sessionDeltaCopper) == "number") and ns.Domain.LedgerModel.FormatCopper(sessionDeltaCopper) or "골드 집계 없음"
    local realm = ns.Api.SafeAPI.GetCanonicalRealm()
    self.label:SetText(bagTxt .. " · " .. durTxt .. " · " .. moneyTxt .. " · " .. realm)
    if self.card then
        if type(self.card.SetRibbon) == "function" then
            if lowDur then
                self.card:SetRibbon({ 0.34, 0.07, 0.07 }, 0.72, 0, 0)
            else
                self.card:SetRibbon({ 0.038, 0.034, 0.046 }, 0.62, 0, 0)
            end
        end
        self.label:SetTextColor(T.TEXT.PRIMARY[1], T.TEXT.PRIMARY[2], T.TEXT.PRIMARY[3], 1)
    end
end
