-- Module: Features/MinimapButton.lua
-- Responsibility: Draggable Obsidian & Burnished Gold Minimap medallion (toggle /fs2 Hub, /fs2 move, /fs2 ledger + live status tooltip).
-- Layer: Features (uses UI/Widgets + Domain/MinimapModel + Blizzard/TooltipAdapter).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local tostring = tostring

local MinimapButton = {
    button = nil,
}
ns.Features.MinimapButton = MinimapButton

function MinimapButton:Init()
    if self.button then
        self:ApplyVisibility()
        return self.button
    end
    local savedAngle = ns.Api.ProfileStore:GetState("minimapAngle")
    local btn = W.MinimapButton(
        "ForeverSuiteV2MinimapButton",
        savedAngle,
        function(_, mouseBtn)
            if mouseBtn == "RightButton" then
                if ns.Api.GameAdapters.IsShiftDown() then
                    local win = ns.UI.CommandHub:EnsureWindow()
                    win:Show()
                    ns.UI.CommandHub:SelectPage("ledger")
                else
                    local unlocked = ns.UI.HudLayout:ToggleUnlock()
                    ns.Api.SafeAPI.Print(unlocked and "HUD 이동 모드 활성화 (/fs move)" or "HUD 위치 잠금")
                end
            else
                ns.UI.CommandHub:Toggle()
            end
        end,
        function(selfBtn)
            local gt = _G.GameTooltip
            if type(gt) == "table" and type(gt.SetOwner) == "function" then
                local ok = pcall(gt.SetOwner, gt, selfBtn, "ANCHOR_LEFT")
                if ok then
                    ns.Blizzard.TooltipAdapter.AddLine(gt, "✦ ForeverSuite", ns.Api.SafeAPI.GetCanonicalRealm(), T.TEXT.GOLD)
                    local free = ns.Api.SafeAPI.GetBagFreeSlots()
                    local freeTxt = (type(free) == "number") and (tostring(free) .. "칸") or "집계 없음"
                    ns.Blizzard.TooltipAdapter.AddLine(gt, "빈 가방 슬롯", freeTxt, T.TEXT.PRIMARY)
                    ns.Blizzard.TooltipAdapter.AddLine(gt, "좌클릭", "/fs 통합 허브 열기", T.TEXT.SECONDARY)
                    ns.Blizzard.TooltipAdapter.AddLine(gt, "우클릭 / Shift+우클릭", "HUD 이동 / 골드 원장", T.TEXT.SECONDARY)
                    if type(gt.Show) == "function" then
                        pcall(gt.Show, gt)
                    end
                end
            end
        end,
        function(newAngle)
            ns.Api.ProfileStore:SetState("minimapAngle", newAngle)
        end
    )
    self.button = btn
    self:ApplyVisibility()
    return btn
end

function MinimapButton:ApplyVisibility()
    if not self.button then
        return
    end
    if ns.Api.ProfileStore:Get("ui", "showMinimapButton") == false then
        self.button:Hide()
    else
        self.button:Show()
    end
end
