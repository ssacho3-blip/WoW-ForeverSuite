-- Module: Modules/Inventory.lua
-- Responsibility: Bag free-slot HUD (draggable when unlocked + live session gold tooltip) and item tooltip vendor/stack/protection enrichment.
-- Dependencies: Core/Init.lua, Core/ProfileManager.lua, Core/ModuleManager.lua, UI/Framework.lua.
-- Public API: Inventory (ScanBagCapacity, UpdateHUD, ApplyHUDAnchor, SyncHUDLockState, RefreshHoveredGoldTooltip, EnrichItemTooltip).
-- Combat/Secret Safety: Uses BAG_UPDATE_DELAYED 0.20s bucket (never raw BAG_UPDATE); guards secret item/stack/price fields.
local _, ns = ...

local type = type
local pcall = pcall
local select = select
local tonumber = tonumber
local math_floor = math.floor
local string_format = string.format

local NUM_TOTAL_BAGS = 4

local Inventory = {
    title = "가방 및 아이템 정보 (Inventory)",
    priority = "P1",
    description = "Baganator/Bagnon 공존, 여유 슬롯·골드 원장 HUD, 툴팁 상점가·묶음가·보호 표시",
    yieldTo = { "Baganator", "Bagnon" },
    hudFrame = nil,
    hudText = nil,
    hudHovered = false,
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

function Inventory:ApplyHUDAnchor()
    if not self.hudFrame or not self.hudFrame.SetPoint then
        return
    end
    local pt = ns.ProfileManager:Get("ui", "bagHudPoint") or "BOTTOMRIGHT"
    local relPt = ns.ProfileManager:Get("ui", "bagHudRelPoint") or "BOTTOMRIGHT"
    local x = tonumber(ns.ProfileManager:Get("ui", "bagHudX")) or -16
    local y = tonumber(ns.ProfileManager:Get("ui", "bagHudY")) or 46
    if self.hudFrame.ClearAllPoints then
        self.hudFrame:ClearAllPoints()
    end
    self.hudFrame:SetPoint(pt, _G.UIParent, relPt, x, y)
end

function Inventory:SyncHUDLockState()
    if not self.hudFrame then
        return
    end
    self:ApplyHUDAnchor()
    if self.hudFrame.EnableMouse then
        self.hudFrame:EnableMouse(true)
    end
    self:UpdateHUD()
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
    local prefix = ns.ProfileManager:Get("ui", "hudUnlocked") and "|cffffd23f✥ |r" or ""
    if totalSlots <= 0 then
        self.hudText:SetText(prefix .. "가방: —")
        return
    end
    local color = "|cff4ade80"
    if freeSlots <= 3 then
        color = "|cfff87171"
    elseif freeSlots <= 8 then
        color = "|cfffacc15"
    end
    self.hudText:SetText(string_format("%s가방 여유: %s%d|r / %d", prefix, color, freeSlots, totalSlots))
end

function Inventory:RenderGoldTooltip()
    local gt = _G.GameTooltip
    if not (self.hudFrame and gt and gt.SetOwner) then
        return
    end
    if gt.ClearLines then
        gt:ClearLines()
    end
    gt:SetOwner(self.hudFrame, "ANCHOR_TOPLEFT")
    gt:AddLine("ForeverSuite · 세션 골드 원장", 1.0, 0.85, 0.35)

    local econRec = ns.ModuleManager:GetModule("Economy")
    if not econRec or econRec.state ~= "ENABLED" or not econRec.definition or not ns.ProfileManager:Get("economy", "trackSessionGold") or not econRec.definition.initializedBaseline then
        gt:AddDoubleLine("|cff94a3b8세션 순증감|r", "|cff64748b—|r")
    else
        local econ = econRec.definition
        gt:AddDoubleLine("|cffcbd5e1세션 순증감|r", ns.FormatMoney(econ:GetNetDelta()))
        gt:AddDoubleLine("|cff94a3b8상점 판매|r", ns.FormatMoney(econ.ledger.vendorSell))
        gt:AddDoubleLine("|cff94a3b8장비 수리|r", ns.FormatMoney(econ.ledger.repair))
        gt:AddDoubleLine("|cff94a3b8퀘스트 보상|r", ns.FormatMoney(econ.ledger.quest))
        gt:AddDoubleLine("|cff94a3b8기타 수지|r", ns.FormatMoney(econ.ledger.other))
    end
    gt:AddLine("이동: /fs move  |  초기화: /fs move reset", 0.62, 0.68, 0.76)
    gt:Show()
end

function Inventory:RefreshHoveredGoldTooltip()
    if self.active and self.hudHovered then
        self:RenderGoldTooltip()
    end
end

local function ResolveSlotStackCount(tooltip, data)
    if type(data) == "table" then
        if not ns.IsSecret(data.stackCount) and type(data.stackCount) == "number" and data.stackCount >= 1 then
            return math_floor(data.stackCount)
        end
        if not ns.IsSecret(data.bagID) and not ns.IsSecret(data.slotIndex) and type(data.bagID) == "number" and type(data.slotIndex) == "number" then
            if C_Container and C_Container.GetContainerItemInfo then
                local info = C_Container.GetContainerItemInfo(data.bagID, data.slotIndex)
                if type(info) == "table" and not ns.IsSecret(info.stackCount) and type(info.stackCount) == "number" and info.stackCount >= 1 then
                    return math_floor(info.stackCount)
                end
            end
        end
    end
    if tooltip and type(tooltip.GetOwner) == "function" and C_Container and C_Container.GetContainerItemInfo then
        local okOwner, owner = pcall(tooltip.GetOwner, tooltip)
        if okOwner and type(owner) == "table" and not ns.IsSecret(owner) and type(owner.GetBagID) == "function" and type(owner.GetID) == "function" then
            local okB, bagID = pcall(owner.GetBagID, owner)
            local okS, slotID = pcall(owner.GetID, owner)
            if okB and okS and type(bagID) == "number" and type(slotID) == "number" and bagID >= 0 and slotID >= 1 then
                local info = C_Container.GetContainerItemInfo(bagID, slotID)
                if type(info) == "table" and not ns.IsSecret(info.stackCount) and type(info.stackCount) == "number" and info.stackCount >= 1 then
                    return math_floor(info.stackCount)
                end
            end
        end
    end
    return 1
end

local function ResetTooltipEnrichState(tip)
    if type(tip) == "table" then
        tip._fsLastEnrichSig = nil
        tip._fsLastLineCount = nil
    end
end

local function EnsureTooltipResetHooks(tooltip)
    if type(tooltip) ~= "table" or tooltip._fsResetHookInstalled then
        return
    end
    tooltip._fsResetHookInstalled = true
    if type(tooltip.HookScript) == "function" then
        pcall(tooltip.HookScript, tooltip, "OnTooltipCleared", ResetTooltipEnrichState)
        pcall(tooltip.HookScript, tooltip, "OnHide", ResetTooltipEnrichState)
    end
    if type(_G.hooksecurefunc) == "function" then
        if type(tooltip.ClearLines) == "function" then
            pcall(_G.hooksecurefunc, tooltip, "ClearLines", ResetTooltipEnrichState)
        end
        if type(tooltip.SetOwner) == "function" then
            pcall(_G.hooksecurefunc, tooltip, "SetOwner", ResetTooltipEnrichState)
        end
    end
end

function Inventory:EnrichItemTooltip(tooltip, itemID, itemLink, stackCount)
    if not self.active or not tooltip or not tooltip.AddDoubleLine then
        return
    end
    if tooltip.IsForbidden and tooltip:IsForbidden() then
        return
    end
    if not itemID or ns.IsSecret(itemID) then
        return
    end

    EnsureTooltipResetHooks(tooltip)

    local isProtected = ns.ProfileManager:IsProtectedItem(itemID)
    local showPrice = ns.ProfileManager:Get("inventory", "showTooltipVendorPrice")
    local showIlvl = ns.ProfileManager:Get("inventory", "showTooltipItemLevel")
    if not isProtected and not showPrice and not showIlvl then
        return
    end

    local cleanStack = (not ns.IsSecret(stackCount) and type(stackCount) == "number" and stackCount >= 2) and math_floor(stackCount) or 1
    local enrichSig = string_format(
        "%s:%d:%d:%d:%d",
        tostring(itemID),
        cleanStack,
        isProtected and 1 or 0,
        showPrice and 1 or 0,
        showIlvl and 1 or 0
    )

    if type(tooltip.NumLines) == "function" then
        local lineCount = tooltip:NumLines()
        if type(lineCount) == "number" and lineCount > 0 and tooltip._fsLastEnrichSig == enrichSig and tooltip._fsLastLineCount == lineCount then
            return
        end
    end

    if isProtected then
        tooltip:AddDoubleLine("|cff4ade80[판매 보호됨]|r", "|cff94a3b8자동·수동 판매 제외|r")
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
            if cleanStack >= 2 then
                tooltip:AddDoubleLine(string_format("|cff94a3b8묶음 판매가(x%d)|r", cleanStack), ns.FormatMoney(sellPrice * cleanStack))
            end
        end
    end

    if type(tooltip.NumLines) == "function" then
        tooltip._fsLastEnrichSig = enrichSig
        tooltip._fsLastLineCount = tooltip:NumLines()
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
                local stackCount = ResolveSlotStackCount(tooltip, data)
                Inventory:EnrichItemTooltip(tooltip, tonumber(data.id), link, stackCount)
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
    self.hudHovered = false
    local hud = ctx:CreateFrame("Frame", "ForeverSuiteBagHUD", _G.UIParent)
    if hud then
        if not hud._fsInitialized then
            hud._fsInitialized = true
            hud:SetSize(164, 22)
            if hud.SetClampedToScreen then
                hud:SetClampedToScreen(true)
            end
            if hud.SetMovable then
                hud:SetMovable(true)
                hud:EnableMouse(true)
                hud:RegisterForDrag("LeftButton")
                hud:SetScript("OnDragStart", function(sf)
                    if not ns.ProfileManager:Get("ui", "hudUnlocked") or ns.InCombat() then
                        return
                    end
                    if sf.StartMoving then
                        sf._fsDragging = true
                        sf:StartMoving()
                    end
                end)
                hud:SetScript("OnDragStop", function(sf)
                    local wasDragging = sf._fsDragging
                    sf._fsDragging = false
                    if sf.StopMovingOrSizing then
                        sf:StopMovingOrSizing()
                    end
                    if (not ns.ProfileManager:Get("ui", "hudUnlocked") and not wasDragging) or not ns.ProfileManager:CanWrite() then
                        return
                    end
                    if sf.GetPoint then
                        local pt, _, relPt, xOfs, yOfs = sf:GetPoint(1)
                        if type(pt) == "string" and type(relPt) == "string" and type(xOfs) == "number" and type(yOfs) == "number" then
                            ns.ProfileManager:Set("ui", "bagHudPoint", pt, "account")
                            ns.ProfileManager:Set("ui", "bagHudRelPoint", relPt, "account")
                            ns.ProfileManager:Set("ui", "bagHudX", math_floor(xOfs + 0.5), "account")
                            ns.ProfileManager:Set("ui", "bagHudY", math_floor(yOfs + 0.5), "account")
                        end
                    end
                end)
            end
            hud:SetScript("OnEnter", function()
                Inventory.hudHovered = true
                Inventory:RenderGoldTooltip()
            end)
            hud:SetScript("OnLeave", function()
                Inventory.hudHovered = false
                if _G.GameTooltip and _G.GameTooltip.Hide then
                    _G.GameTooltip:Hide()
                end
            end)
            local txt = ns.UI.CreateLabel(hud, "가방: —", "GameFontHighlightSmall", ns.UI.COLORS.TEXT)
            if txt then
                txt:SetPoint("RIGHT", hud, "RIGHT", -4, 0)
                hud._fsText = txt
            end
        end
        self.hudText = hud._fsText
        self.hudFrame = hud
        self:SyncHUDLockState()
    end

    self:EnsureTooltipHook()
    ctx:RegisterBucketEvent("BAG_UPDATE_DELAYED", 0.20, Inventory.OnBagBucket)
    self:UpdateHUD()
end

function Inventory:OnDisable()
    self.active = false
    self.hudHovered = false
    self.hudFrame = nil
    self.hudText = nil
end

ns.ModuleManager:Register("Inventory", Inventory)
