-- Module: Modules/Combat.lua
-- Responsibility: 9-class out-of-combat spell-family/weapon-enchant buff reminder and C_Secrets-safe low-health alert HUD.
-- Dependencies: Core/Init.lua, Core/ProfileManager.lua, Core/ModuleManager.lua, UI/Framework.lua.
-- Public API: Combat (CLASS_BUFF_FAMILIES, EvaluatePlayerHealth, CheckOutOfCombatBuffs, ApplyAlertAnchor, SyncAlertLockState).
-- Combat/Secret Safety: Zero combat automation; strict ns.IsSecret guards on health/auras/enchants; click-through when HUD locked.
local _, ns = ...

local type = type
local pcall = pcall
local ipairs = ipairs
local tonumber = tonumber
local math_floor = math.floor
local string_format = string.format

local CLASS_BUFF_FAMILIES = {
    MAGE = { spells = { 1459, 23028 }, label = "신비한 지능" },
    PRIEST = { spells = { 1243, 21562 }, label = "신의 권능: 인내" },
    WARRIOR = { spells = { 6673 }, label = "전투의 외침" },
    DRUID = { spells = { 1126, 21849 }, label = "야생의 징표" },
    PALADIN = { spells = { 19740, 19742, 20217, 25782, 25894, 25898, 465 }, label = "성기사 축복/오라" },
    SHAMAN = { spells = { 324, 8017, 8024, 8033, 8232 }, checkWeaponEnchant = true, label = "주술사 보호막/무기 강화" },
    WARLOCK = { spells = { 687, 706 }, label = "악마의 갑옷" },
    HUNTER = { spells = { 13165, 13163, 5118, 13161, 13159, 20043 }, label = "사냥꾼의 상" },
    ROGUE = { spells = { 2842, 8679, 2823, 3408 }, checkWeaponEnchant = true, label = "도적 독 (무기 도포)" },
}

local Combat = {
    title = "전투 정보 및 생존 보조 (Combat)",
    priority = "P2",
    description = "9직업 비전투 버프·무기강화 누락 체크, Secret 안전 저체력 알림 배너",
    yieldTo = {},
    CLASS_BUFF_FAMILIES = CLASS_BUFF_FAMILIES,
    alertFrame = nil,
    alertLabel = nil,
    lastHealthStatus = "NORMAL",
    lastShownPct = nil,
    lastBuffMissing = false,
}

local function ShowUnlockedPlaceholderOrHide(self)
    if not self.alertFrame then
        return
    end
    local unlocked = ns.ProfileManager:Get("ui", "hudUnlocked") and true or false
    if unlocked then
        if self.alertLabel then
            self.alertLabel:SetText("|cffffd23f✥ 생명력 경고 배너 위치 (드래그 이동)|r")
        end
        if not ns.InCombat() then
            self.alertFrame:Show()
        end
    else
        self.alertFrame:Hide()
    end
end

function Combat:ApplyAlertAnchor()
    if not self.alertFrame or not self.alertFrame.SetPoint then
        return
    end
    local pt = ns.ProfileManager:Get("ui", "healthAlertPoint") or "CENTER"
    local relPt = ns.ProfileManager:Get("ui", "healthAlertRelPoint") or "CENTER"
    local x = tonumber(ns.ProfileManager:Get("ui", "healthAlertX")) or 0
    local y = tonumber(ns.ProfileManager:Get("ui", "healthAlertY")) or 140
    if self.alertFrame.ClearAllPoints then
        self.alertFrame:ClearAllPoints()
    end
    self.alertFrame:SetPoint(pt, _G.UIParent, relPt, x, y)
end

function Combat:SyncAlertLockState()
    if not self.alertFrame then
        return
    end
    self:ApplyAlertAnchor()
    local unlocked = ns.ProfileManager:Get("ui", "hudUnlocked") and true or false
    if self.alertFrame.EnableMouse then
        self.alertFrame:EnableMouse(unlocked)
    end
    self:EvaluatePlayerHealth()
    if unlocked and self.lastHealthStatus ~= "LOW" then
        ShowUnlockedPlaceholderOrHide(self)
    end
end

function Combat:EvaluatePlayerHealth()
    if not ns.ProfileManager:Get("combat", "lowHealthAlert") then
        self.lastHealthStatus = "DISABLED"
        self.lastShownPct = nil
        ShowUnlockedPlaceholderOrHide(self)
        return
    end
    if not (_G.UnitHealth and _G.UnitHealthMax) then
        return
    end

    local hp = _G.UnitHealth("player")
    local maxHp = _G.UnitHealthMax("player")

    if ns.IsSecret(hp) or ns.IsSecret(maxHp) then
        self.lastHealthStatus = "UNAVAILABLE"
        self.lastShownPct = nil
        ShowUnlockedPlaceholderOrHide(self)
        return
    end

    if type(hp) ~= "number" or type(maxHp) ~= "number" or maxHp <= 0 then
        return
    end
    if _G.UnitIsDeadOrGhost and _G.UnitIsDeadOrGhost("player") then
        self.lastHealthStatus = "DEAD"
        self.lastShownPct = nil
        ShowUnlockedPlaceholderOrHide(self)
        return
    end

    local threshold = tonumber(ns.ProfileManager:Get("combat", "lowHealthThreshold")) or 0.30
    local ratio = hp / maxHp
    if ratio <= threshold then
        self.lastHealthStatus = "LOW"
        local pct = math_floor((ratio * 100) + 0.5)
        if self.alertLabel and self.alertFrame then
            if self.lastShownPct ~= pct then
                self.lastShownPct = pct
                self.alertLabel:SetText(string_format("|cfff87171⚠️ 생명력 위험 (%d%%)|r", pct))
            end
            self.alertFrame:Show()
        end
    else
        self.lastHealthStatus = "NORMAL"
        self.lastShownPct = nil
        ShowUnlockedPlaceholderOrHide(self)
    end
end

function Combat:CheckOutOfCombatBuffs()
    if ns.InCombat() or not ns.ProfileManager:Get("combat", "remindMissingClassBuff") then
        return nil
    end
    if _G.UnitIsDeadOrGhost and _G.UnitIsDeadOrGhost("player") then
        return nil
    end
    if _G.IsResting and _G.IsResting() then
        return nil
    end
    if _G.IsMounted and _G.IsMounted() then
        return nil
    end
    if _G.UnitOnTaxi and _G.UnitOnTaxi("player") then
        return nil
    end

    local spec = CLASS_BUFF_FAMILIES[ns.ProfileManager.playerClass]
    if not spec or type(spec.spells) ~= "table" then
        return nil
    end

    local firstKnownSpellID = nil
    for _, sid in ipairs(spec.spells) do
        local known = true
        if C_Spell and C_Spell.IsSpellKnown then
            known = C_Spell.IsSpellKnown(sid) and true or false
        end
        if known then
            firstKnownSpellID = sid
            break
        end
    end
    if not firstKnownSpellID then
        return nil
    end

    local hasAuraAPI = (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) and true or false
    local hasEnchantAPI = (spec.checkWeaponEnchant and type(_G.GetWeaponEnchantInfo) == "function") and true or false
    if not hasAuraAPI and not hasEnchantAPI then
        return nil
    end

    local satisfied = false
    if hasEnchantAPI then
        local okW, mhEnchant, _, _, _, ohEnchant = pcall(_G.GetWeaponEnchantInfo)
        if okW then
            if ns.IsSecret(mhEnchant) or ns.IsSecret(ohEnchant) then
                return nil
            end
            if mhEnchant == true or ohEnchant == true then
                satisfied = true
            end
        end
    end

    if (not satisfied) and hasAuraAPI then
        for _, sid in ipairs(spec.spells) do
            local aura = C_UnitAuras.GetPlayerAuraBySpellID(sid)
            if ns.IsSecret(aura) then
                return nil
            end
            if aura ~= nil then
                satisfied = true
                break
            end
        end
    end

    local missing = not satisfied
    if missing and not self.lastBuffMissing then
        local buffName = spec.label or "직업 강화 효과"
        if C_Spell and C_Spell.GetSpellInfo then
            local info = C_Spell.GetSpellInfo(firstKnownSpellID)
            if type(info) == "table" and not ns.IsSecret(info.name) and type(info.name) == "string" and info.name ~= "" then
                buffName = info.name
            end
        end
        ns.Print("비전투 버프 누락 알림: [" .. buffName .. "] 효과가 없습니다.")
    end
    self.lastBuffMissing = missing
    return satisfied
end

function Combat:OnEnable(ctx)
    self.lastBuffMissing = false
    local banner = ctx:CreateFrame("Frame", "ForeverSuiteHealthAlertFrame", _G.UIParent)
    if banner then
        if not banner._fsInitialized then
            banner._fsInitialized = true
            banner:SetSize(280, 32)
            if banner.SetClampedToScreen then
                banner:SetClampedToScreen(true)
            end
            if banner.SetMovable then
                banner:SetMovable(true)
                banner:RegisterForDrag("LeftButton")
                banner:SetScript("OnDragStart", function(sf)
                    if not ns.ProfileManager:Get("ui", "hudUnlocked") or ns.InCombat() then
                        return
                    end
                    if sf.StartMoving then
                        sf._fsDragging = true
                        sf:StartMoving()
                    end
                end)
                banner:SetScript("OnDragStop", function(sf)
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
                            ns.ProfileManager:Set("ui", "healthAlertPoint", pt, "account")
                            ns.ProfileManager:Set("ui", "healthAlertRelPoint", relPt, "account")
                            ns.ProfileManager:Set("ui", "healthAlertX", math_floor(xOfs + 0.5), "account")
                            ns.ProfileManager:Set("ui", "healthAlertY", math_floor(yOfs + 0.5), "account")
                        end
                    end
                end)
            end
            local lbl = ns.UI.CreateLabel(banner, "", "GameFontNormalLarge", ns.UI.COLORS.TEXT)
            if lbl then
                lbl:SetPoint("CENTER", banner, "CENTER", 0, 0)
                banner._fsAlertLabel = lbl
            end
        end
        self.alertLabel = banner._fsAlertLabel
        self.alertFrame = banner
        self:SyncAlertLockState()
    end

    ctx:RegisterUnitEvent("UNIT_HEALTH", "player", Combat.EvaluatePlayerHealth)
    ctx:RegisterBucketEvent("UNIT_AURA", 0.50, Combat.CheckOutOfCombatBuffs, "player")
    ctx:RegisterEvent("PLAYER_REGEN_ENABLED", Combat.CheckOutOfCombatBuffs)

    self:EvaluatePlayerHealth()
    self:CheckOutOfCombatBuffs()
end

function Combat:OnDisable()
    self.alertFrame = nil
    self.alertLabel = nil
    self.lastShownPct = nil
    self.lastHealthStatus = "NORMAL"
    self.lastBuffMissing = false
end

ns.ModuleManager:Register("Combat", Combat)
