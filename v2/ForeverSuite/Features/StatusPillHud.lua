-- Module: Features/StatusPillHud.lua
-- Responsibility: L0 compact Status Pill Bar (live bag slots · durability% · session gold · canonical realm; zero fabricated zeros).
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local Draw = ns.UI.Draw

local StatusPillHud = {
    card = nil,
    label = nil,
    segments = nil,
    baselineMoney = nil,
}
ns.Features.StatusPillHud = StatusPillHud

function StatusPillHud:Init()
    if self.card then
        return self.card
    end
    local card = W.HudFloating(nil, 336, 22, "ForeverSuiteV2StatusPill", T.ELEVATION.L0_HUD)
    if Draw and type(Draw.CreateRoundedBorder) == "function" then
        Draw.CreateRoundedBorder(card, 11, T.BORDER.HUD_GLASS, { sublevel = -5 })
    end
    if Draw and type(Draw.CreateRoundedFill) == "function" then
        Draw.CreateRoundedFill(card, 11, T.SURFACE.HUD_GLASS, { sublevel = -4 })
    end
    card:EnableMouse(true)
    card:SetScript("OnMouseUp", function(selfFrame, mouseBtn)
        if selfFrame._fsJustDragged then
            selfFrame._fsJustDragged = false
            return
        end
        if ns.UI.HudLayout and ns.UI.HudLayout.unlocked then return end
        if mouseBtn == "RightButton" then
            ns.UI.CommandHub:JumpTo("utilities", { subTab = "alts" })
        else
            ns.UI.CommandHub:JumpTo("ledger")
        end
    end)
    if type(card.SetScript) == "function" then
        card:SetScript("OnEnter", function(selfFrame)
            if _G.GameTooltip and type(_G.GameTooltip.SetOwner) == "function" then
                _G.GameTooltip:SetOwner(selfFrame, "ANCHOR_BOTTOM")
                _G.GameTooltip:SetText("★ 상태 필 바", T.TEXT.GOLD[1], T.TEXT.GOLD[2], T.TEXT.GOLD[3])
                _G.GameTooltip:AddLine("좌클릭: 골드 원장 · 우클릭: 부캐 장부", 0.90, 0.90, 0.92, true)
                _G.GameTooltip:AddLine("Shift + 좌클릭 드래그: 잠금 없이 바로 이동", 0.56, 0.94, 0.66, true)
                _G.GameTooltip:Show()
            end
        end)
        card:SetScript("OnLeave", function()
            if _G.GameTooltip and type(_G.GameTooltip.Hide) == "function" then
                _G.GameTooltip:Hide()
            end
        end)
    end

    -- Live visible 3-Segment Compact Capsule Readout (Bags | Durability | Gold · Realm)
    local seg1 = W.Label(card, "", "small", T.TEXT.PRIMARY, { justifyH = "LEFT", wordWrap = false, outline = "OUTLINE" })
    seg1:SetPoint("LEFT", card, "LEFT", 12, 0)
    seg1:SetWidth(94)

    local div1 = card:CreateTexture(nil, "ARTWORK")
    div1:SetSize(T.PixelSize(card, 1), 12)
    div1:SetPoint("LEFT", seg1, "RIGHT", 4, 0)
    div1:SetColorTexture(T.BORDER.HAIRLINE[1], T.BORDER.HAIRLINE[2], T.BORDER.HAIRLINE[3], 0.55)

    local seg2 = W.Label(card, "", "small", T.TEXT.PRIMARY, { justifyH = "CENTER", wordWrap = false, outline = "OUTLINE" })
    seg2:SetPoint("LEFT", div1, "RIGHT", 4, 0)
    seg2:SetWidth(76)

    local div2 = card:CreateTexture(nil, "ARTWORK")
    div2:SetSize(T.PixelSize(card, 1), 12)
    div2:SetPoint("LEFT", seg2, "RIGHT", 4, 0)
    div2:SetColorTexture(T.BORDER.HAIRLINE[1], T.BORDER.HAIRLINE[2], T.BORDER.HAIRLINE[3], 0.55)

    local seg3 = W.Label(card, "", "small", T.TEXT.GOLD, { justifyH = "RIGHT", wordWrap = false, outline = "OUTLINE" })
    seg3:SetPoint("LEFT", div2, "RIGHT", 4, 0)
    seg3:SetPoint("RIGHT", card, "RIGHT", -12, 0)

    -- Hidden full-string mirror for backwards API/test compatibility (never overlaps live 3-segment readout)
    local lbl = W.Label(card, "", "mono", T.TEXT.PRIMARY, { outline = "OUTLINE" })
    lbl:SetPoint("CENTER", card, "CENTER", 0, 0)
    lbl:Hide()
    self.card = card
    self.label = lbl
    self.segments = { seg1, seg2, seg3 }
    self.dividers = { div1, div2 }

    ns.UI.HudLayout:Register("statusPill", card, {
        point = "TOPRIGHT",
        relPoint = "TOPRIGHT",
        x = -24,
        y = -244,
    }, "상태 필 바")
    if type(ns.UI.HudLayout.EnableDirectDrag) == "function" then
        ns.UI.HudLayout:EnableDirectDrag("statusPill", card, { requireShift = true })
    end

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
    if self.segments then
        self.segments[1]:SetText(bagTxt)
        self.segments[2]:SetText(durTxt)
        self.segments[3]:SetText(moneyTxt .. " · " .. realm)
    end
    if self.card then
        if self.card._fsRoundedFill then
            if lowDur then
                self.card._fsRoundedFill:SetColor({ 0.34, 0.07, 0.07, 0.85 })
                W.SetBorderColor(self.card, T.SEMANTIC.DANGER)
            else
                self.card._fsRoundedFill:SetColor(T.SURFACE.HUD_GLASS)
                W.SetBorderColor(self.card, T.BORDER.HUD_GLASS)
            end
        end
        self.label:SetTextColor(T.TEXT.PRIMARY[1], T.TEXT.PRIMARY[2], T.TEXT.PRIMARY[3], 1)
    end
end
