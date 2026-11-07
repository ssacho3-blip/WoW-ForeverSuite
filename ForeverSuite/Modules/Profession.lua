local _, ns = ...

local type = type
local pairs = pairs
local tonumber = tonumber
local tostring = tostring
local string_find = string.find
local string_format = string.format
local string_lower = string.lower
local string_match = string.match

local MAINHAND_SLOT = 16
local FISHING_BASE_SPELL_ID = 7620

local Profession = {
    title = "전문기술 · 채집 · 낚시 편의 (Profession)",
    priority = "P1",
    description = "비전투 안전 더블우클릭 낚시(2중 해제), 크래시 복구 사운드 부스트, 채집 수확량 추적",
    yieldTo = { "FishingBuddy" },
    active = false,
    secureBtn = nil,
    worldHooked = false,
    overrideActive = false,
    soundBoostActive = false,
    lastRightClickAt = 0,
    sessionStartAt = 0,
    sessionTotalItems = 0,
    sessionByItemID = {},
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
        -- Weapon(2) + Fishing Pole(20), or localized subtype match
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
    if ns.IsFeatureYielded("fishing") then
        return
    end
    if not ns.ProfileManager:Get("profession", "doubleClickFishing") then
        return
    end
    if ns.InCombat() or not self.secureBtn then
        return
    end
    if not self:IsFishingPoleEquipped() then
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
    -- Attempt immediate release if pre-lockdown; otherwise safely defer via CombatQueue (AC-3)
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

function Profession:OnLootChatMsg(_, msg)
    if not ns.ProfileManager:Get("profession", "trackGatherYield") then
        return
    end
    if type(msg) ~= "string" or ns.IsSecret(msg) then
        return
    end
    local itemIDStr = string_match(msg, "|Hitem:(%d+):")
    local itemID = tonumber(itemIDStr)
    if not itemID then
        return
    end
    local qtyStr = string_match(msg, "|h|rx(%d+)") or string_match(msg, "x(%d+)%.?$")
    local qty = tonumber(qtyStr) or 1
    self.sessionByItemID[itemID] = (self.sessionByItemID[itemID] or 0) + qty
    self.sessionTotalItems = self.sessionTotalItems + qty
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
            name, _, active, category = info, nil, nil, nil
        end
        if
            not ns.IsSecret(name)
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
    local elapsedSec = ns.GetNow() - self.sessionStartAt
    local perHourText = "—"
    if elapsedSec >= 30 and self.sessionTotalItems > 0 then
        local rate = (self.sessionTotalItems / elapsedSec) * 3600
        perHourText = string_format("%.1f개/시간", rate)
    end
    local distinct = 0
    for _ in pairs(self.sessionByItemID) do
        distinct = distinct + 1
    end
    ns.Print(string_format("세션 전리품/채집 집계: 총 %d개 (%d종류) | 속도: %s", self.sessionTotalItems, distinct, perHourText))
end

function Profession:OnInitialize()
    self.sessionStartAt = ns.GetNow()
    self.sessionTotalItems = 0
    self.lastRightClickAt = 0
    ns.WipeTable(self.sessionByItemID)
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
