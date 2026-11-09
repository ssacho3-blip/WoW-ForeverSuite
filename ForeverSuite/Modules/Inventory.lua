local _, ns = ...

local type = type
local select = select
local tonumber = tonumber
local string_format = string.format

local NUM_TOTAL_BAGS = 4

local Inventory = {
    title = "가방 및 아이템 정보 (Inventory)",
    priority = "P1",
    description = "Baganator/Bagnon 공존, 여유 슬롯 HUD, 툴팁 상점가·아이템 레벨 표시",
    yieldTo = { "Baganator", "Bagnon" },
    hudFrame = nil,
    hudText = nil,
    tooltipHookInstalled = false,
    active = false,
    lastFreeSlots = 0,
    lastTotalSlots = 0,
}

function Inventory:ScanBagCapacity()
    if not (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerNumFreeSlots) then
        return 0, 0
    end
    local freeTotal = 0
    local slotTotal = 0
    for bag = 0, NUM_TOTAL_BAGS do
        local numSlots = C_Container.GetContainerNumSlots(bag) or 0
        local freeSlots = C_Container.GetContainerNumFreeSlots(bag) or 0
        slotTotal = slotTotal + numSlots
        freeTotal = freeTotal + freeSlots
    end
    self.lastFreeSlots = freeTotal
    self.lastTotalSlots = slotTotal
    return freeTotal, slotTotal
end

function Inventory:UpdateHUD()
    local freeSlots, totalSlots = self:ScanBagCapacity()
    if not self.hudText then
        return
    end
    if not ns.ProfileManager:Get("inventory", "showFreeSlotsHUD") then
        if self.hudFrame then
            self.hudFrame:Hide()
        end
        return
    end
    if self.hudFrame and self.hudFrame.Show and not ns.InCombat() then
        self.hudFrame:Show()
    end
    if totalSlots <= 0 then
        self.hudText:SetText("가방: —")
        return
    end
    local color = "|cff4ade80"
    if freeSlots <= 3 then
        color = "|cfff87171"
    elseif freeSlots <= 8 then
        color = "|cfffacc15"
    end
    self.hudText:SetText(string_format("가방 여유: %s%d|r / %d", color, freeSlots, totalSlots))
end

function Inventory:EnrichItemTooltip(tooltip, itemID, itemLink)
    if not self.active or not tooltip or not tooltip.AddDoubleLine then
        return
    end
    if tooltip.IsForbidden and tooltip:IsForbidden() then
        return
    end
    if not itemID or ns.IsSecret(itemID) then
        return
    end

    local showPrice = ns.ProfileManager:Get("inventory", "showTooltipVendorPrice")
    local showIlvl = ns.ProfileManager:Get("inventory", "showTooltipItemLevel")
    if not showPrice and not showIlvl then
        return
    end

    if showIlvl and C_Item and C_Item.GetDetailedItemLevelInfo then
        local queryTarget = (type(itemLink) == "string" and not ns.IsSecret(itemLink) and itemLink ~= "") and itemLink or itemID
        local ilvl = C_Item.GetDetailedItemLevelInfo(queryTarget)
        if type(ilvl) == "number" and not ns.IsSecret(ilvl) and ilvl > 0 then
            tooltip:AddDoubleLine("|cff94a3b8아이템 레벨|r", string_format("|cffe2e8f0%d|r", ilvl))
        else
            tooltip:AddDoubleLine("|cff94a3b8아이템 레벨|r", "|cff64748b—|r")
        end
    end

    if showPrice and C_Item and C_Item.GetItemInfo then
        local sellPrice = select(11, C_Item.GetItemInfo(itemID))
        if ns.IsSecret(sellPrice) or sellPrice == nil then
            tooltip:AddDoubleLine("|cff94a3b8상점 판매가|r", "|cff64748b—|r")
        elseif type(sellPrice) == "number" and sellPrice > 0 then
            tooltip:AddDoubleLine("|cff94a3b8상점 판매가(개당)|r", ns.FormatMoney(sellPrice))
        end
    end
end

function Inventory:EnsureTooltipHook()
    if self.tooltipHookInstalled then
        return
    end
    if _G.TooltipDataProcessor and _G.TooltipDataProcessor.AddTooltipPostCall and _G.Enum and _G.Enum.TooltipDataType and _G.Enum.TooltipDataType.Item then
        _G.TooltipDataProcessor.AddTooltipPostCall(_G.Enum.TooltipDataType.Item, function(tooltip, data)
            if not Inventory.active then
                return
            end
            if type(data) == "table" and not ns.IsSecret(data.id) and data.id then
                local link = (not ns.IsSecret(data.hyperlink) and type(data.hyperlink) == "string") and data.hyperlink or nil
                Inventory:EnrichItemTooltip(tooltip, tonumber(data.id), link)
            end
        end)
        self.tooltipHookInstalled = true
    end
end

function Inventory:OnBagBucket()
    self:UpdateHUD()
end

function Inventory:OnEnable(ctx)
    self.active = true
    local hud = ctx:CreateFrame("Frame", "ForeverSuiteBagHUD", _G.UIParent)
    if hud then
        if not hud._fsInitialized then
            hud._fsInitialized = true
            hud:SetSize(148, 22)
            hud:SetPoint("BOTTOMRIGHT", _G.UIParent, "BOTTOMRIGHT", -16, 46)
            local txt = ns.UI.CreateLabel(hud, "가방: —", "GameFontHighlightSmall", ns.UI.COLORS.TEXT)
            if txt then
                txt:SetPoint("RIGHT", hud, "RIGHT", -4, 0)
                hud._fsText = txt
            end
        end
        self.hudText = hud._fsText
        self.hudFrame = hud
    end

    self:EnsureTooltipHook()
    -- Strictly use BAG_UPDATE_DELAYED with 0.2s bucket (never raw BAG_UPDATE, Contract §3.2)
    ctx:RegisterBucketEvent("BAG_UPDATE_DELAYED", 0.20, Inventory.OnBagBucket)
    self:UpdateHUD()
end

function Inventory:OnDisable()
    self.active = false
    self.hudFrame = nil
    self.hudText = nil
end

ns.ModuleManager:Register("Inventory", Inventory)
