-- Module: Bridges/Baganator.lua
-- Responsibility: Official Baganator.API bridge - O(1) 4-corner badge widget, /fs protect junk plugin,
--                 BiS/+iLvl upgrade plugin, compact <=52x20px bottom_left "정리" region, and OOC preset ImportString.
-- Layer: Bridges (Rank 3: display-only; never moves/sells items; OOC registration only).
local _, ns = ...
ns.Bridges = ns.Bridges or {}

local type = type
local pcall = pcall

local BaganatorBridge = {
    registered = false,
    badgeProvider = nil,   -- function(itemID) -> { text = string, color = {r,g,b} } | nil (O(1) hash lookup only)
    upgradeProvider = nil, -- function(itemID, itemLink) -> boolean | nil
    cheapAction = nil,     -- function() -> void (invoked when user clicks bottom_left "정리" pill)
}
ns.Bridges.Baganator = BaganatorBridge

function BaganatorBridge:SetProviders(providers)
    if type(providers) ~= "table" then
        return
    end
    if type(providers.badge) == "function" then
        self.badgeProvider = providers.badge
    end
    if type(providers.upgrade) == "function" then
        self.upgradeProvider = providers.upgrade
    end
    if type(providers.cheapAction) == "function" then
        self.cheapAction = providers.cheapAction
    end
end

function BaganatorBridge.IsProtectedItem(itemID)
    if type(itemID) ~= "number" or itemID <= 0 then
        return false
    end
    local db = ns.Api.ProfileStore and ns.Api.ProfileStore.db
    local prot = db and db.v2 and db.v2.protectedItems
    return type(prot) == "table" and prot[itemID] == true
end

function BaganatorBridge:EvaluateCornerBadge(itemDetails)
    if type(itemDetails) ~= "table" then
        return nil
    end
    local itemID = itemDetails.itemID
    if ns.Api.SafeAPI.IsSecret(itemID) or type(itemID) ~= "number" or itemID <= 0 then
        return nil
    end
    -- Priority 1: /fs protect SKY badge (#4FA6E0)
    if BaganatorBridge.IsProtectedItem(itemID) then
        return { text = "보호", r = 0.31, g = 0.65, b = 0.88 }
    end
    -- Priority 2: O(1) pre-indexed provider (material / quest-starter / BiS)
    if type(self.badgeProvider) == "function" then
        local ok, badge = pcall(self.badgeProvider, itemID)
        if ok and type(badge) == "table" and type(badge.text) == "string" and badge.text ~= "" then
            return badge
        end
    end
    return nil
end

function BaganatorBridge:EvaluateJunk(bagID, slotID, itemID, itemLink)
    if ns.Api.SafeAPI.IsSecret(itemID) or type(itemID) ~= "number" or itemID <= 0 then
        return false
    end
    -- Protected items are NEVER junk
    if BaganatorBridge.IsProtectedItem(itemID) then
        return false
    end
    return nil -- defer to default grey-junk evaluation
end

function BaganatorBridge:EvaluateUpgrade(itemDetails)
    if type(itemDetails) ~= "table" then
        return nil
    end
    local itemID = itemDetails.itemID
    if ns.Api.SafeAPI.IsSecret(itemID) or type(itemID) ~= "number" or itemID <= 0 then
        return nil
    end
    if type(self.upgradeProvider) == "function" then
        local ok, isUp = pcall(self.upgradeProvider, itemID, itemDetails.itemLink)
        if ok and type(isUp) == "boolean" then
            return isUp
        end
    end
    return nil
end

function BaganatorBridge:Init()
    local bag = ns.Api.AddonProbe.GetGlobal("Baganator")
    local api = (type(bag) == "table") and bag.API or nil
    if type(api) ~= "table" then
        return "WARMING"
    end
    if self.registered then
        return "OK"
    end

    local registeredCount = 0
    if type(api.RegisterCornerWidget) == "function" then
        local ok = pcall(api.RegisterCornerWidget, "ForeverSuite", "foreversuite_badge", function(cornerFrame, details)
            local badge = BaganatorBridge:EvaluateCornerBadge(details)
            if not badge then
                if cornerFrame and type(cornerFrame.Hide) == "function" then
                    pcall(cornerFrame.Hide, cornerFrame)
                end
                return false
            end
            if cornerFrame and type(cornerFrame.SetText) == "function" then
                pcall(cornerFrame.SetText, cornerFrame, badge.text)
                if type(cornerFrame.SetTextColor) == "function" then
                    pcall(cornerFrame.SetTextColor, cornerFrame, badge.r or 0.90, badge.g or 0.76, badge.b or 0.36)
                end
                if type(cornerFrame.Show) == "function" then
                    pcall(cornerFrame.Show, cornerFrame)
                end
            end
            return true
        end, function(itemButton)
            if itemButton and type(itemButton.CreateFontString) == "function" then
                local fs = itemButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                fs:Hide()
                return fs
            end
            return { SetText = function() end, SetTextColor = function() end, Show = function() end, Hide = function() end }
        end, { corner = "top_right", priority = 2 })
        if not ok then
            return false
        end
        registeredCount = registeredCount + 1
    end

    if type(api.RegisterJunkPlugin) == "function" then
        local ok = pcall(api.RegisterJunkPlugin, "ForeverSuite Protect", "foreversuite_protect", function(bagID, slotID, itemID, itemLink)
            return BaganatorBridge:EvaluateJunk(bagID, slotID, itemID, itemLink)
        end)
        if not ok then
            return false
        end
        registeredCount = registeredCount + 1
    end

    if type(api.RegisterUpgradePlugin) == "function" then
        local ok = pcall(api.RegisterUpgradePlugin, "ForeverSuite BiS", "foreversuite_bis", function(details)
            return BaganatorBridge:EvaluateUpgrade(details)
        end)
        if not ok then
            return false
        end
        registeredCount = registeredCount + 1
    end

    -- Official Baganator.API.RegisterRegion(label, id, viewType, position, frame) - 5 args + real frame <=52x20px
    if type(api.RegisterRegion) == "function" then
        local pillFrame = self.cheapPillFrame
        if not pillFrame then
            if type(_G.CreateFrame) == "function" then
                pillFrame = _G.CreateFrame("Button", "ForeverSuiteBaganatorCheapPill", _G.UIParent)
                if type(pillFrame.SetSize) == "function" then
                    pillFrame:SetSize(48, 20)
                end
                if type(pillFrame.SetText) == "function" then
                    pillFrame:SetText("정리")
                end
                if type(pillFrame.SetScript) == "function" then
                    pillFrame:SetScript("OnClick", function()
                        if type(BaganatorBridge.cheapAction) == "function" then
                            pcall(BaganatorBridge.cheapAction)
                        end
                    end)
                end
            else
                pillFrame = {
                    SetParent = function() end,
                    ClearAllPoints = function() end,
                    SetPoint = function() end,
                    GetWidth = function() return 48 end,
                    GetHeight = function() return 20 end,
                    label = "정리",
                }
            end
            self.cheapPillFrame = pillFrame
        end
        local ok = pcall(api.RegisterRegion, "ForeverSuite 정리", "foreversuite_cheap_pill", "backpack", "bottom_left", pillFrame)
        if not ok then
            return false
        end
        registeredCount = registeredCount + 1
    end

    if registeredCount == 0 then
        return false
    end
    self.registered = true
    return "OK"
end

function BaganatorBridge:ImportPreset(presetString)
    if ns.Api.SafeAPI.InCombat() then
        return false, "IN_COMBAT"
    end
    if type(presetString) ~= "string" or presetString == "" then
        return false, "INVALID_PRESET"
    end
    local bag = ns.Api.AddonProbe.GetGlobal("Baganator")
    local api = (type(bag) == "table") and bag.API or nil
    if type(api) ~= "table" or type(api.ImportString) ~= "function" then
        return false, "API_UNAVAILABLE"
    end
    local ok, err = pcall(api.ImportString, presetString)
    return ok and true or false, err
end

ns.Bridges.BridgeHost:Register({
    id = "baganator",
    target = "Baganator",
    mode = "bridge",
    protected = true,
    yields = {},
    init = function()
        return BaganatorBridge:Init()
    end,
    teardown = function()
        BaganatorBridge.registered = false
    end,
})
