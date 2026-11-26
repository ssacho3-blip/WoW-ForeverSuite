-- Module: Secure/QuestItemDock.lua
-- Responsibility: Fixed-slot (1..6) UIParent-direct SecureActionButton dock for quest items (frozen during combat to keep labels & items aligned).
-- Layer: Secure
local _, ns = ...
ns.Secure = ns.Secure or {}

local tostring = tostring

local MAX_SLOTS = 6
local SLOT_SIZE = 32
local SLOT_GAP = 6

local QuestItemDock = {
    buttons = {},
    anchor = { point = "TOPRIGHT", relPoint = "TOPRIGHT", x = -348, y = -220 },
    lastSlots = {},
    activeSlotByQuest = {},
}
ns.Secure.QuestItemDock = QuestItemDock

local function PaintHairlineBorder(btn, r, g, b, a)
    local top = btn:CreateTexture(nil, "BORDER")
    top:SetHeight(1)
    top:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
    top:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 0, 0)
    top:SetColorTexture(r, g, b, a)

    local bottom = btn:CreateTexture(nil, "BORDER")
    bottom:SetHeight(1)
    bottom:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
    bottom:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
    bottom:SetColorTexture(r, g, b, a)

    local left = btn:CreateTexture(nil, "BORDER")
    left:SetWidth(1)
    left:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
    left:SetColorTexture(r, g, b, a)

    local right = btn:CreateTexture(nil, "BORDER")
    right:SetWidth(1)
    right:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 0, 0)
    right:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
    right:SetColorTexture(r, g, b, a)
end

function QuestItemDock:EnsureButtons()
    if #self.buttons == MAX_SLOTS then
        return self.buttons
    end
    for i = 1, MAX_SLOTS do
        local name = "ForeverSuiteV2QuestItemSlot" .. tostring(i)
        local btn = CreateFrame("Button", name, _G.UIParent, "SecureActionButtonTemplate")
        btn:SetSize(SLOT_SIZE, SLOT_SIZE)
        btn:SetFrameStrata("MEDIUM")
        btn:SetClampedToScreen(true)
        btn:RegisterForClicks("LeftButtonUp")
        btn:SetAttribute("useOnKeyDown", false)
        btn:SetAttribute("type", "item")

        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(btn)
        bg:SetColorTexture(0.068, 0.060, 0.074, 0.94)
        btn._bg = bg

        PaintHairlineBorder(btn, 0.855, 0.694, 0.255, 0.85)

        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 2, -2)
        icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
        if type(icon.SetTexCoord) == "function" then
            pcall(icon.SetTexCoord, icon, 0.08, 0.92, 0.08, 0.92)
        end
        btn._icon = icon

        -- Native Blizzard quest item frame or custom gold metallic ring overlay
        local ring = btn:CreateTexture(nil, "OVERLAY")
        ring:SetAllPoints(btn)
        local usedAtlas = false
        if type(ring.SetAtlas) == "function" then
            local okA = pcall(ring.SetAtlas, ring, "UI-QuestTrackerButton-QuestItem-Frame", false)
            if okA and type(ring.GetAtlas) == "function" then
                local okG, cur = pcall(ring.GetAtlas, ring)
                usedAtlas = okG and cur == "UI-QuestTrackerButton-QuestItem-Frame"
            elseif okA then
                usedAtlas = true
            end
        end
        if not usedAtlas and type(ring.SetTexture) == "function" then
            pcall(ring.SetTexture, ring, "Interface\\AddOns\\ForeverSuite_Media_Assets\\UI\\FS-IconRing.tga")
            if type(ring.SetVertexColor) == "function" then
                pcall(ring.SetVertexColor, ring, 0.855, 0.694, 0.255, 0.92)
            end
        end
        btn._ring = ring

        local fontObj = (_G.FS_Font_Small ~= nil) and "FS_Font_Small" or "GameFontNormalSmall"
        local badge = btn:CreateFontString(nil, "OVERLAY", fontObj)
        badge:SetPoint("TOPLEFT", btn, "TOPLEFT", 3, -2)
        badge:SetText(tostring(i))
        badge:SetTextColor(0.98, 0.91, 0.62, 1)
        btn._badge = badge

        -- Hover item tooltip (read-only GameTooltip, zero taint)
        btn:SetScript("OnEnter", function(self)
            if self._itemLink and _G.GameTooltip and type(_G.GameTooltip.SetOwner) == "function" then
                pcall(function()
                    _G.GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                    if type(_G.GameTooltip.SetHyperlink) == "function" then
                        _G.GameTooltip:SetHyperlink(self._itemLink)
                    end
                    _G.GameTooltip:Show()
                end)
            end
        end)
        btn:SetScript("OnLeave", function()
            if _G.GameTooltip and type(_G.GameTooltip.Hide) == "function" then
                pcall(_G.GameTooltip.Hide, _G.GameTooltip)
            end
        end)

        btn:Hide()
        self.buttons[i] = btn
    end
    return self.buttons
end

function QuestItemDock:ApplySlots(dockSlots)
    self.lastSlots = dockSlots or {}
    return ns.Secure.CombatQueue:RunOrDefer("secure:questItemDock", function()
        local buttons = QuestItemDock:EnsureButtons()
        local a = QuestItemDock.anchor
        local nextActive = {}
        for i = 1, MAX_SLOTS do
            local btn = buttons[i]
            local slotData = QuestItemDock.lastSlots[i]
            if slotData and slotData.itemLink then
                btn:ClearAllPoints()
                btn:SetPoint(a.point, _G.UIParent, a.relPoint, a.x, a.y - ((i - 1) * (SLOT_SIZE + SLOT_GAP)))
                btn:SetAttribute("type", "item")
                btn:SetAttribute("item", slotData.itemLink)
                btn._itemLink = slotData.itemLink
                if btn._icon then
                    btn._icon:SetTexture(slotData.itemIcon)
                end
                btn:Show()
                if slotData.questID then
                    nextActive[slotData.questID] = i
                end
            else
                btn:SetAttribute("item", nil)
                btn._itemLink = nil
                if btn._icon then
                    btn._icon:SetTexture(nil)
                end
                btn:Hide()
            end
        end
        QuestItemDock.activeSlotByQuest = nextActive
    end)
end

function QuestItemDock:GetActiveSlotForQuest(questID)
    return self.activeSlotByQuest[questID]
end

function QuestItemDock:SetAnchorFromRect(left, right, top, screenW, screenH)
    local sw = (type(screenW) == "number" and screenW > 0) and screenW or 1920
    local sh = (type(screenH) == "number" and screenH > 0) and screenH or 1080
    local totalDockHeight = (MAX_SLOTS * SLOT_SIZE) + ((MAX_SLOTS - 1) * SLOT_GAP)
    local minTop = totalDockHeight + 16
    local maxTop = sh - 16
    local clampedTop = top or (sh - 220)
    if clampedTop < minTop then clampedTop = minTop end
    if clampedTop > maxTop then clampedTop = maxTop end

    local centerX = ((left or 0) + (right or 0)) * 0.5
    if centerX >= (sw * 0.5) then
        local x = (left or (sw - 340)) - 12
        if x < (SLOT_SIZE + 8) then x = SLOT_SIZE + 8 end
        self.anchor = { point = "TOPRIGHT", relPoint = "BOTTOMLEFT", x = x, y = clampedTop }
    else
        local x = (right or 340) + 12
        if x > (sw - SLOT_SIZE - 8) then x = sw - SLOT_SIZE - 8 end
        self.anchor = { point = "TOPLEFT", relPoint = "BOTTOMLEFT", x = x, y = clampedTop }
    end
    self:ApplySlots(self.lastSlots)
end

function QuestItemDock:SetAnchor(anchor)
    if type(anchor) == "table" then
        self.anchor = anchor
        self:ApplySlots(self.lastSlots)
    end
end
