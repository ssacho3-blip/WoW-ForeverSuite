-- Module: Features/StatusPillHud.lua
-- Responsibility: L0 compact Status Pill Bar (live free bag slots · session gold delta · canonical realm; zero fabricated zeros).
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
    local card = W.Card(nil, 280, 26, "ForeverSuiteV2StatusPill")
    local lbl = W.Label(card, "", "mono", T.TEXT.PRIMARY)
    lbl:SetPoint("CENTER", card, "CENTER", 0, 0)
    self.card = card
    self.label = lbl

    ns.UI.HudLayout:Register("statusPill", card, {
        point = "TOPRIGHT",
        relPoint = "TOPRIGHT",
        x = -24,
        y = -180,
    }, "상태 필 바")

    self:ApplyVisibility()
    self:RefreshLive()
    return card
end

function StatusPillHud:ApplyVisibility()
    if not self.card then
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
    self:Refresh(free, delta)
end

function StatusPillHud:Refresh(freeSlots, sessionDeltaCopper)
    if not self.label then
        self:Init()
    end
    local bagTxt = (type(freeSlots) == "number") and ("가방 " .. tostring(freeSlots) .. "칸") or "가방 집계 없음"
    local moneyTxt = (type(sessionDeltaCopper) == "number") and ns.Domain.LedgerModel.FormatCopper(sessionDeltaCopper) or "골드 집계 없음"
    local realm = ns.Api.SafeAPI.GetCanonicalRealm()
    self.label:SetText(bagTxt .. "  ·  " .. moneyTxt .. "  ·  " .. realm)
end
