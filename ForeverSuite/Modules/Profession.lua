-- Module: Modules/Profession.lua
-- Responsibility: Combat-safe double-right-click fishing (dual release), crash-safe sound boost, and classID gather vs general loot yield tracker.
-- Dependencies: Core/Init.lua, Core/ProfileManager.lua, Core/ModuleManager.lua.
-- Public API: Profession (IsFishingPoleEquipped, ClearFishingBindingSafe, ReconcilePendingLoot, PrintSessionYield).
-- Combat/Secret Safety: Defers SetOverrideBindingClick/ClearOverrideBindings via CombatQueue; preserves uncached item counts without data loss.
local _, ns = ...

local type = type
local pairs = pairs
local tonumber = tonumber
local string_find = string.find
local string_format = string.format
local string_lower = string.lower
local string_match = string.match

local MAINHAND_SLOT = 16
local FISHING_BASE_SPELL_ID = 7620
local TRADE_GOODS_CLASS_ID = 7

local Profession = {
    title = "전문기술 · 채집 · 낚시 편의 (Profession)",
    priority = "P1",
    description = "비전투 안전 더블우클릭 낚시(2중 해제), 크래시 복구 사운드 부스트, 채집물 별도 집계",
    yieldTo = { "FishingBuddy" },
    active = false,
    secureBtn = nil,
    worldHooked = false,
    overrideActive = false,
    soundBoostActive = false,
    lastRightClickAt = 0,
    sessionStartAt = 0,
    sessionTotalItems = 0,
    sessionGatherItems = 0,
    sessionGeneralItems = 0,
    sessionPendingItems = 0,
    sessionByItemID = {},
    pendingUncachedByItemID = {},
    clearBindingFn = nil,
}

local function ResolveFishingSpellName()
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(FISHING_BASE_SPELL_ID)
        if type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
            return info.name
        end
    end
    return "낚시"
end

function Profession:IsFishingPoleEquipped()
    if not _G.GetInventoryItemID then
        return false
    end
    local itemID = _G.GetInventoryItemID("player", MAINHAND_SLOT)
    if not itemID then
        return false
    end
    if C_Item and C_Item.GetItemInfo then
        local _, _, _, _, _, _, itemSubType, _, _, _, _, classID, subClassID = C_Item.GetItemInfo(itemID)
        if classID == 2 and subClassID == 20 then
            return true
        end
        if type(itemSubType) == "string" then
            local low = string_lower(itemSubType)
            if string_find(low, "fishing", 1, true) or string_find(itemSubType, "낚싯대", 1, true) then
                return true
            end
        end
    end
    return false
end

function Profession:ClearFishingBindingSafe()
    if not self.overrideActive then
        return
    end
    if not self.secureBtn then
        self.overrideActive = false
        return
    end
    if ns.InCombat() then
        ns.CombatQueue:RunOrDefer("Profession:ClearFishingOverride", function()
            if Profession.overrideActive and Profession.secureBtn and _G.ClearOverrideBindings and not ns.InCombat() then
                _G.ClearOverrideBindings(Profession.secureBtn)
                Profession.overrideActive = false
            end
        end)
        return
    end
    if _G.ClearOverrideBindings then
        _G.ClearOverrideBindings(self.secureBtn)
    end
    self.overrideActive = false
end

function Profession:EnsureSecureFishingButton()
    if self.secureBtn or not _G.CreateFrame then
        return
    end
    ns.CombatQueue:RunOrDefer("Profession:InitFishingButton", function()
        if Profession.secureBtn then
            return
        end
        local btn = _G.ForeverSuiteFishingButton
        if type(btn) ~= "table" then
            btn = _G.CreateFrame("Button", "ForeverSuiteFishingButton", _G.UIParent, "SecureActionButtonTemplate")
        end
        if btn then
            if btn.Hide then
                btn:Hide()
            end
            if btn.RegisterForClicks then
                btn:RegisterForClicks("AnyUp", "AnyDown")
            end
            if btn.SetAttribute then
                btn:SetAttribute("type", "spell")
                btn:SetAttribute("spell", ResolveFishingSpellName())
            end
            if btn.SetScript then
                btn:SetScript("PostClick", function()
                    Profession:ClearFishingBindingSafe()
                end)
            end
            Profession.secureBtn = btn
        end
    end)
end

function Profession:OnWorldMouseDown(mouseButton)
    if not self.active or mouseButton ~= "RightButton" then
        return
    end
    if ns.IsFeatureYielded("fishing") or not ns.ProfileManager:Get("profession", "doubleClickFishing") then
        return
    end
    if ns.InCombat() or not self.secureBtn or not self:IsFishingPoleEquipped() then
        return
    end

    local now = ns.GetNow()
    local delta = now - self.lastRightClickAt
    if delta >= 0.05 and delta <= 0.40 then
        self.lastRightClickAt = 0
        if _G.SetOverrideBindingClick and not ns.InCombat() then
            _G.SetOverrideBindingClick(self.secureBtn, true, "BUTTON2", "ForeverSuiteFishingButton")
            self.overrideActive = true
            if C_Timer and C_Timer.After then
                C_Timer.After(0.05, self.clearBindingFn)
            end
        end
    else
        self.lastRightClickAt = now
    end
end

function Profession:SyncFishingSoundBoost()
    if ns.InCombat() then
        return
    end
    local wantBoost = self.active
        and (not ns.IsFeatureYielded("fishing"))
        and ns.ProfileManager:Get("profession", "fishingSoundBoost")
        and self:IsFishingPoleEquipped()

    if wantBoost and not self.soundBoostActive then
        ns.ProfileManager:ApplyTemporaryCVar("Sound_SFXVolume", "1.0")
        ns.ProfileManager:ApplyTemporaryCVar("Sound_MusicVolume", "0.2")
        self.soundBoostActive = true
    elseif (not wantBoost) and self.soundBoostActive then
        ns.ProfileManager:RestoreTemporaryCVar("Sound_SFXVolume")
        ns.ProfileManager:RestoreTemporaryCVar("Sound_MusicVolume")
        self.soundBoostActive = false
    end
end

function Profession:OnCombatEntering()
    self:ClearFishingBindingSafe()
end

function Profession:OnEquipmentChanged(_, slotID)
    if slotID == nil or slotID == MAINHAND_SLOT then
        self:SyncFishingSoundBoost()
        if not self:IsFishingPoleEquipped() and self.overrideActive then
            self:ClearFishingBindingSafe()
        end
    end
end

local function ClassifyItemLootBucket(itemID)
    if not (C_Item and C_Item.GetItemInfo) then
        return nil
    end
    local itemName, _, _, _, _, itemType, itemSubType, _, _, _, _, classID = C_Item.GetItemInfo(itemID)
    if itemName == nil or ns.IsSecret(itemName) then
        return nil
    end
    if ns.IsSecret(classID) then
        return "general"
    end
    if type(classID) == "number" then
        return (classID == TRADE_GOODS_CLASS_ID) and "gather" or "general"
    end
    if type(itemType) == "string" and not ns.IsSecret(itemType) then
        if string_find(itemType, "직업용품", 1, true) or string_find(string_lower(itemType), "trade goods", 1, true) then
            return "gather"
        end
    end
    if type(itemSubType) == "string" and not ns.IsSecret(itemSubType) then
        if string_find(itemSubType, "물고기", 1, true) or string_find(string_lower(itemSubType), "fish", 1, true) then
            return "gather"
        end
    end
    return "general"
end

function Profession:ReconcilePendingLoot()
    for pid, pendingQty in pairs(self.pendingUncachedByItemID) do
        local bucket = ClassifyItemLootBucket(pid)
        if bucket == "gather" then
            self.sessionGatherItems = self.sessionGatherItems + pendingQty
            self.sessionPendingItems = self.sessionPendingItems - pendingQty
            self.pendingUncachedByItemID[pid] = nil
        elseif bucket == "general" then
            self.sessionGeneralItems = self.sessionGeneralItems + pendingQty
            self.sessionPendingItems = self.sessionPendingItems - pendingQty
            self.pendingUncachedByItemID[pid] = nil
        end
    end
end

function Profession:OnItemInfoReceived()
    if self.sessionPendingItems > 0 then
        self:ReconcilePendingLoot()
    end
end

function Profession:OnLootChatMsg(_, msg)
    if not ns.ProfileManager:Get("profession", "trackGatherYield") then
        return
    end
    if type(msg) ~= "string" or ns.IsSecret(msg) then
        return
    end
    -- Ignore party/raid members' loot lines
    if string_find(msg, "님이 아이템을 획득", 1, true) or string_find(msg, " receives loot:", 1, true) then
        return
    end
    local itemIDStr = string_match(msg, "|Hitem:(%d+)")
    local itemID = tonumber(itemIDStr)
    if not itemID then
        return
    end
    local qtyStr = string_match(msg, "|h|rx(%d+)") or string_match(msg, "|hx(%d+)") or string_match(msg, "x(%d+)%.?$")
    local qty = tonumber(qtyStr) or 1
    self.sessionByItemID[itemID] = (self.sessionByItemID[itemID] or 0) + qty
    self.sessionTotalItems = self.sessionTotalItems + qty

    local bucket = ClassifyItemLootBucket(itemID)
    if bucket == "gather" then
        self.sessionGatherItems = self.sessionGatherItems + qty
    elseif bucket == "general" then
        self.sessionGeneralItems = self.sessionGeneralItems + qty
    else
        self.pendingUncachedByItemID[itemID] = (self.pendingUncachedByItemID[itemID] or 0) + qty
        self.sessionPendingItems = self.sessionPendingItems + qty
    end
    self:ReconcilePendingLoot()
end

function Profession:CheckGatheringTracking()
    if not ns.ProfileManager:Get("profession", "remindMissingTracking") or ns.InCombat() then
        return
    end
    if _G.IsResting and _G.IsResting() then
        return
    end
    if not (C_Minimap and C_Minimap.GetNumTrackingTypes and C_Minimap.GetTrackingInfo) then
        return
    end
    local count = C_Minimap.GetNumTrackingTypes() or 0
    local hasGatherSkill = false
    local anyGatherActive = false

    for idx = 1, count do
        local info = C_Minimap.GetTrackingInfo(idx)
        local name, active, category
        if type(info) == "table" then
            name = info.name
            active = info.active
            category = info.type
        else
            name = info
        end
        if not ns.IsSecret(name)
            and not ns.IsSecret(active)
            and not ns.IsSecret(category)
            and type(name) == "string"
            and (category == "spell" or string_find(name, "찾기", 1, true) or string_find(string_lower(name), "find ", 1, true))
        then
            hasGatherSkill = true
            if active then
                anyGatherActive = true
                break
            end
        end
    end

    if hasGatherSkill and not anyGatherActive then
        ns.Print("채집 추적(광물/약초/물고기 찾기)이 꺼져 있습니다. 미니맵 추적을 확인하세요.")
    end
end

function Profession:PrintSessionYield()
    self:ReconcilePendingLoot()
    local elapsedSec = ns.GetNow() - self.sessionStartAt
    local perHourText = "—"
    if elapsedSec >= 30 and self.sessionGatherItems > 0 then
        local rate = (self.sessionGatherItems / elapsedSec) * 3600
        perHourText = string_format("%.1f개/시간", rate)
    end
    local distinct = 0
    for _ in pairs(self.sessionByItemID) do
        distinct = distinct + 1
    end
    ns.Print(string_format(
        "세션 집계 — 총 %d개 (%d종) | 채집물: %d개 | 일반 전리품: %d개 | 미캐시 대기: %d개 | 채집 속도: %s",
        self.sessionTotalItems,
        distinct,
        self.sessionGatherItems,
        self.sessionGeneralItems,
        self.sessionPendingItems,
        perHourText
    ))
end

function Profession:OnInitialize()
    self.sessionStartAt = ns.GetNow()
    self.sessionTotalItems = 0
    self.sessionGatherItems = 0
    self.sessionGeneralItems = 0
    self.sessionPendingItems = 0
    self.lastRightClickAt = 0
    ns.WipeTable(self.sessionByItemID)
    ns.WipeTable(self.pendingUncachedByItemID)
    self.clearBindingFn = function()
        Profession:ClearFishingBindingSafe()
    end
end

function Profession:OnEnable(ctx)
    self.active = true
    self.lastRightClickAt = 0
    if self.sessionStartAt <= 0 then
        self.sessionStartAt = ns.GetNow()
    end
    self:EnsureSecureFishingButton()

    if not self.worldHooked and _G.WorldFrame and _G.WorldFrame.HookScript then
        self.worldHooked = true
        _G.WorldFrame:HookScript("OnMouseDown", function(_, mouseButton)
            Profession:OnWorldMouseDown(mouseButton)
        end)
    end

    ctx:RegisterEvent("PLAYER_REGEN_DISABLED", Profession.OnCombatEntering)
    ctx:RegisterEvent("PLAYER_REGEN_ENABLED", Profession.SyncFishingSoundBoost)
    ctx:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", Profession.OnEquipmentChanged)
    ctx:RegisterEvent("CHAT_MSG_LOOT", Profession.OnLootChatMsg)
    ctx:RegisterEvent("GET_ITEM_INFO_RECEIVED", Profession.OnItemInfoReceived)
    ctx:RegisterEvent("ZONE_CHANGED_NEW_AREA", Profession.CheckGatheringTracking)

    ctx:AddCleanup(function()
        Profession:ClearFishingBindingSafe()
        if Profession.soundBoostActive then
            ns.ProfileManager:RestoreTemporaryCVar("Sound_SFXVolume")
            ns.ProfileManager:RestoreTemporaryCVar("Sound_MusicVolume")
            Profession.soundBoostActive = false
        end
    end)

    self:SyncFishingSoundBoost()
end

function Profession:OnDisable()
    self.active = false
    self:ClearFishingBindingSafe()
    if self.soundBoostActive then
        ns.ProfileManager:RestoreTemporaryCVar("Sound_SFXVolume")
        ns.ProfileManager:RestoreTemporaryCVar("Sound_MusicVolume")
        self.soundBoostActive = false
    end
end

ns.ModuleManager:Register("Profession", Profession)
