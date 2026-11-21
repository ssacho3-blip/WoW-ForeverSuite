-- Module: Modules/Combat.lua
-- Responsibility: 9-class out-of-combat spell-family/weapon-enchant buff reminder and C_Secrets-safe low-health alert HUD.
-- Dependencies: Core/Init.lua, Core/ProfileManager.lua, Core/ModuleManager.lua, UI/Framework.lua.
-- Public API: Combat (CLASS_BUFF_FAMILIES, EvaluatePlayerHealth, CheckOutOfCombatBuffs, ApplyAlertAnchor, SyncAlertLockState, SyncNameplatePreset, SyncTempEnchantIconCVar, HandleNameplateSlash).
-- Combat/Secret Safety: Zero combat automation; strict ns.IsSecret guards on health/auras/enchants; defers nameplate/temp-enchant CVar writes via CombatQueue.
local _, ns = ...

local type = type
local pcall = pcall
local ipairs = ipairs
local tonumber = tonumber
local math_floor = math.floor
local string_format = string.format
local string_lower = string.lower
local string_match = string.match

local CLASS_BUFF_FAMILIES = {
    MAGE = {
        spells = {
            1459, 1460, 1461, 10156, 10157, 27126, -- Arcane Intellect (R1-R6)
            23028, 27127, -- Arcane Brilliance (R1-R2)
        },
        nameSeeds = { 1459, 23028 },
        label = "신비한 지능",
    },
    PRIEST = {
        spells = {
            1243, 1244, 1245, 2791, 10937, 10938, 25389, -- Power Word: Fortitude (R1-R7)
            21562, 21564, 25392, -- Prayer of Fortitude (R1-R3)
        },
        nameSeeds = { 1243, 21562 },
        label = "신의 권능: 인내",
    },
    WARRIOR = {
        spells = {
            6673, 5242, 6192, 11549, 11550, 11551, 25289, 2048, -- Battle Shout (R1-R8)
            469, -- Commanding Shout
        },
        nameSeeds = { 6673, 469 },
        label = "전투의 외침",
    },
    DRUID = {
        spells = {
            1126, 5232, 6756, 5234, 8907, 9884, 9885, 26990, -- Mark of the Wild (R1-R8)
            21849, 21850, 26991, -- Gift of the Wild (R1-R3)
        },
        nameSeeds = { 1126, 21849 },
        label = "야생의 징표",
    },
    PALADIN = {
        spells = {
            19740, 19834, 19835, 19836, 19837, 19838, 25291, 27140, -- Blessing of Might (R1-R8)
            25782, 25916, 27141, -- Greater Blessing of Might (R1-R3)
            19742, 19850, 19852, 19853, 19854, 25290, 27142, -- Blessing of Wisdom (R1-R7)
            25894, 25918, 27143, -- Greater Blessing of Wisdom (R1-R3)
            20217, 25898, -- Blessing of Kings / Greater
            19977, 19978, 19979, 27144, 25890, 27145, -- Blessing of Light / Greater
            20911, 20912, 20913, 20914, 27168, 25899, 27169, -- Blessing of Sanctuary / Greater
            1038, 25895, -- Blessing of Salvation / Greater
            465, 10290, 643, 10291, 1032, 10292, 10293, 27149, -- Devotion Aura (R1-R8)
            7294, 10298, 10299, 10300, 10301, 27150, -- Retribution Aura (R1-R6)
            19746, -- Concentration Aura
            19876, 19895, 19896, 27151, -- Shadow Resistance Aura
            19888, 19897, 19898, 27152, -- Frost Resistance Aura
            19891, 19899, 19900, 27153, -- Fire Resistance Aura
            20218, 32223, -- Sanctity Aura / Crusader Aura
        },
        nameSeeds = {
            19740, 25782, 19742, 25894, 20217, 25898, 19977, 25890,
            20911, 25899, 1038, 25895, 465, 7294, 19746, 19876, 19888, 19891, 20218, 32223,
        },
        label = "성기사 축복/오라",
    },
    SHAMAN = {
        spells = {
            324, 325, 905, 945, 8134, 10431, 10432, 25469, 25472, -- Lightning Shield (R1-R9)
            24398, 33736, -- Water Shield
            974, 32593, 32594, -- Earth Shield
            8017, 8018, 8019, 10399, 16314, 16315, 16316, -- Rockbiter Weapon
            8024, 8027, 8030, 16339, 16341, 16342, -- Flametongue Weapon
            8033, 8038, 10456, 16355, 16356, -- Frostbrand Weapon
            8232, 8235, 10486, 16362, -- Windfury Weapon
        },
        nameSeeds = { 324, 24398, 974, 8017, 8024, 8033, 8232 },
        checkWeaponEnchant = true,
        label = "주술사 보호막/무기 강화",
    },
    WARLOCK = {
        spells = {
            687, 696, -- Demon Skin (R1-R2)
            706, 1086, 11733, 11734, 11735, 27260, -- Demon Armor (R1-R6)
            28176, 28189, -- Fel Armor
        },
        nameSeeds = { 687, 706, 28176 },
        label = "악마의 갑옷",
    },
    HUNTER = {
        spells = {
            13165, 14318, 14319, 14320, 14321, 14322, 25296, 27044, -- Aspect of the Hawk (R1-R8)
            13163, 5118, 13161, 13159, -- Monkey / Cheetah / Beast / Pack
            20043, 20190, 27045, -- Aspect of the Wild (R1-R3)
            34074, -- Aspect of the Viper
        },
        nameSeeds = { 13165, 13163, 5118, 13161, 13159, 20043, 34074 },
        label = "사냥꾼의 상",
    },
    ROGUE = {
        spells = { 2842, 8679, 2823, 3408, 5761, 13219 },
        nameSeeds = { 2842, 8679, 2823, 3408, 5761, 13219 },
        checkWeaponEnchant = true,
        label = "도적 독 (무기 도포)",
    },
}

local Combat = {
    title = "전투 정보 및 생존 보조 (Combat)",
    priority = "P2",
    description = "9직업 비전투 버프·무기강화 체크, Secret 안전 저체력 배너, 이름표 CVar 최적화",
    yieldTo = {},
    CLASS_BUFF_FAMILIES = CLASS_BUFF_FAMILIES,
    alertFrame = nil,
    alertLabel = nil,
    lastHealthStatus = "NORMAL",
    lastShownPct = nil,
    lastBuffMissing = false,
    nameplatesApplied = false,
    nameplateOwner = nil,
    tempEnchantIconApplied = false,
}

local TEMP_ENCHANT_ICON_CVAR = "displayTemporaryEnchantIcon"

local EXTERNAL_NAMEPLATE_ADDONS = {
    "Platynator",
    "Plater",
    "Kui_Nameplates",
    "TidyPlates_ThreatPlates",
}

-- Keep user V/Shift-V toggles (nameplateShowEnemies/nameplateShowAll) untouched across reloads;
-- preset focuses strictly on readability, stacking, range, and target highlight scaling.
local NAMEPLATE_CVAR_PRESET = {
    { "nameplateShowEnemyMinions", "1" },
    { "nameplateMotion", "1" },
    { "nameplateMaxDistance", "41" },
    { "nameplateSelectedScale", "1.2" },
}

local LEGACY_NAMEPLATE_CVARS = {
    "nameplateShowEnemies",
    "nameplateShowAll",
}

local function IsCombatModuleActive()
    if not ns.ModuleManager or type(ns.ModuleManager.GetModule) ~= "function" then
        return false
    end
    local rec = ns.ModuleManager:GetModule("Combat")
    local enabledState = (ns.ModuleManager.STATES and ns.ModuleManager.STATES.ENABLED) or "ENABLED"
    return rec ~= nil and rec.state == enabledState
end

local function DetectExternalNameplateAddon()
    for _, addonName in ipairs(EXTERNAL_NAMEPLATE_ADDONS) do
        if ns.IsExternalAddonLoaded(addonName) then
            return addonName
        end
    end
    return nil
end

function Combat:ApplyNameplatePreset()
    local extOwner = DetectExternalNameplateAddon()
    if extOwner then
        self.nameplateOwner = extOwner
        if self.nameplatesApplied then
            self:RestoreNameplatePreset(true)
        end
        return false, extOwner
    end
    self.nameplateOwner = nil
    local executedNow = ns.CombatQueue:RunOrDefer("combat:nameplatePreset", function()
        if DetectExternalNameplateAddon()
            or not IsCombatModuleActive()
            or not ns.ProfileManager:CanWrite()
            or not ns.ProfileManager:Get("combat", "enhanceNameplates") then
            return
        end
        local appliedAny = false
        for _, kv in ipairs(NAMEPLATE_CVAR_PRESET) do
            if ns.ProfileManager:ApplyTemporaryCVar(kv[1], kv[2]) then
                appliedAny = true
            end
        end
        self.nameplatesApplied = appliedAny
    end)
    if executedNow then
        return self.nameplatesApplied == true, nil
    end
    return false, nil
end

function Combat:RestoreNameplatePreset(preserveExternalChanges)
    ns.CombatQueue:RunOrDefer("combat:nameplatePreset", function()
        local keepExternal = preserveExternalChanges == true or (DetectExternalNameplateAddon() ~= nil)
        local pending = (ns.ProfileManager and ns.ProfileManager:CanWrite()
            and ns.ProfileManager.accountDB
            and type(ns.ProfileManager.accountDB.pendingCVarRestores) == "table")
            and ns.ProfileManager.accountDB.pendingCVarRestores
            or nil
        for _, kv in ipairs(NAMEPLATE_CVAR_PRESET) do
            if keepExternal then
                -- External nameplate addon is in control; drop our restore snapshot without touching its CVars
                if pending then
                    pending[kv[1]] = nil
                end
            else
                ns.ProfileManager:RestoreTemporaryCVar(kv[1])
            end
        end
        if keepExternal and pending then
            for _, legacyCvar in ipairs(LEGACY_NAMEPLATE_CVARS) do
                pending[legacyCvar] = nil
            end
        end
        self.nameplatesApplied = false
    end)
    return true
end

function Combat:SyncNameplatePreset()
    local extOwner = DetectExternalNameplateAddon()
    if extOwner then
        self.nameplateOwner = extOwner
        self:RestoreNameplatePreset(true)
        return false, extOwner
    end
    self.nameplateOwner = nil
    if ns.ProfileManager:Get("combat", "enhanceNameplates") then
        return self:ApplyNameplatePreset()
    end
    return self:RestoreNameplatePreset()
end

function Combat:ApplyTempEnchantIconCVar()
    local executedNow = ns.CombatQueue:RunOrDefer("combat:tempEnchantIcon", function()
        if not IsCombatModuleActive()
            or not ns.ProfileManager:CanWrite()
            or not ns.ProfileManager:Get("combat", "showTempEnchantIcon") then
            return
        end
        self.tempEnchantIconApplied = ns.ProfileManager:ApplyTemporaryCVar(TEMP_ENCHANT_ICON_CVAR, "1") and true or false
    end)
    if executedNow then
        return self.tempEnchantIconApplied == true
    end
    return false
end

function Combat:RestoreTempEnchantIconCVar()
    local ok = false
    ns.CombatQueue:RunOrDefer("combat:tempEnchantIcon", function()
        if not ns.ProfileManager:CanWrite() then
            return
        end
        local pending = ns.ProfileManager.accountDB and ns.ProfileManager.accountDB.pendingCVarRestores
        local hadPending = type(pending) == "table" and pending[TEMP_ENCHANT_ICON_CVAR] ~= nil
        local restored = ns.ProfileManager:RestoreTemporaryCVar(TEMP_ENCHANT_ICON_CVAR)
        if restored or not hadPending then
            self.tempEnchantIconApplied = false
            ok = true
        end
    end)
    return ok
end

function Combat:SyncTempEnchantIconCVar()
    if ns.ProfileManager:Get("combat", "showTempEnchantIcon") then
        return self:ApplyTempEnchantIconCVar()
    end
    return self:RestoreTempEnchantIconCVar()
end

function Combat:HandleNameplateSlash(rawArg)
    local clean = ns.IsSecret(rawArg) and "" or tostring(rawArg or "")
    local sub = string_lower(string_match(clean, "^%s*(%S*)") or "")
    if sub == "on" or sub == "off" then
        if not IsCombatModuleActive() then
            ns.Warn("Combat 모듈이 비활성화(또는 양보) 상태에서는 이름표 설정을 변경할 수 없습니다.")
            return false
        end
        if not ns.ProfileManager:CanWrite() then
            ns.Warn("읽기 전용 프로필(미래 스키마)에서는 이름표 설정을 변경할 수 없습니다.")
            return false
        end
        local wantOn = (sub == "on")
        ns.ProfileManager:Set("combat", "enhanceNameplates", wantOn, "account")
        local ok, extOwner = self:SyncNameplatePreset()
        if extOwner then
            ns.Print("외부 이름표 애드온(" .. tostring(extOwner) .. ") 감지로 프리셋 적용을 양보했습니다.")
        elseif ns.InCombat() then
            ns.Print("이름표 가독성·겹침방지 최적화: " .. (wantOn and "전투 종료 후 적용 예약" or "전투 종료 후 복원 예약"))
        elseif wantOn and ok then
            ns.Print("이름표 가독성·겹침방지 최적화: 활성 (CVar 적용)")
        elseif wantOn then
            ns.Warn("이름표 가독성·겹침방지 최적화: CVar 적용 실패 (지원되지 않는 CVar)")
        else
            ns.Print("이름표 가독성·겹침방지 최적화: 비활성 (기존 CVar 복원)")
        end
        return true
    end
    local extOwner = DetectExternalNameplateAddon()
    local enabled = ns.ProfileManager:Get("combat", "enhanceNameplates") and true or false
    local stateText = extOwner and ("외부 양보(" .. extOwner .. ")") or (enabled and "활성" or "비활성")
    ns.Print(string_format(
        "이름표 최적화 상태: %s | 겹침방지(motion)=%s, 거리=%s, 선택배율=%s (/fs nameplate on|off)",
        stateText,
        tostring(ns.SafeGetCVar("nameplateMotion") or "—"),
        tostring(ns.SafeGetCVar("nameplateMaxDistance") or "—"),
        tostring(ns.SafeGetCVar("nameplateSelectedScale") or "—")
    ))
    return true
end

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

local function AddSpellNameToSet(nameSet, spellID)
    if not (C_Spell and C_Spell.GetSpellInfo) or type(spellID) ~= "number" then
        return
    end
    local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
    if ok and type(info) == "table" and not ns.IsSecret(info.name) and type(info.name) == "string" and info.name ~= "" then
        nameSet[info.name] = true
    end
end

local function GetClassBuffMatchers(self, playerClass, spec, firstKnownSpellID)
    if type(self._buffMatcherCache) ~= "table" then
        self._buffMatcherCache = {}
    end
    local entry = self._buffMatcherCache[playerClass]
    if not entry then
        local idSet = {}
        local nameSet = {}
        for _, sid in ipairs(spec.spells) do
            idSet[sid] = true
        end
        local seeds = type(spec.nameSeeds) == "table" and spec.nameSeeds or spec.spells
        for _, sid in ipairs(seeds) do
            AddSpellNameToSet(nameSet, sid)
        end
        entry = { idSet = idSet, nameSet = nameSet }
        self._buffMatcherCache[playerClass] = entry
    end
    AddSpellNameToSet(entry.nameSet, firstKnownSpellID)
    return entry.idSet, entry.nameSet
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

    local playerClass = ns.ProfileManager.playerClass
    local spec = CLASS_BUFF_FAMILIES[playerClass]
    if not spec or type(spec.spells) ~= "table" then
        return nil
    end

    local firstKnownSpellID = nil
    for _, sid in ipairs(spec.spells) do
        local known = true
        if C_Spell and C_Spell.IsSpellKnown then
            local okK, kVal = pcall(C_Spell.IsSpellKnown, sid)
            if not okK or ns.IsSecret(kVal) then
                return nil
            end
            known = kVal and true or false
        end
        if known then
            firstKnownSpellID = sid
            break
        end
    end
    if not firstKnownSpellID then
        return nil
    end

    local hasAuraByID = (C_UnitAuras and type(C_UnitAuras.GetPlayerAuraBySpellID) == "function") and true or false
    local hasAuraByIndex = (C_UnitAuras and type(C_UnitAuras.GetAuraDataByIndex) == "function") and true or false
    local hasEnchantAPI = (spec.checkWeaponEnchant and type(_G.GetWeaponEnchantInfo) == "function") and true or false
    if not hasAuraByID and not hasAuraByIndex and not hasEnchantAPI then
        return nil
    end

    local satisfied = false
    if hasEnchantAPI then
        local okW, mhEnchant, _, _, _, ohEnchant = pcall(_G.GetWeaponEnchantInfo)
        if okW then
            if ns.IsSecret(mhEnchant) or ns.IsSecret(ohEnchant) then
                return nil
            end
            if mhEnchant == true or mhEnchant == 1 or ohEnchant == true or ohEnchant == 1 then
                satisfied = true
            end
        end
    end

    if (not satisfied) and hasAuraByID then
        for _, sid in ipairs(spec.spells) do
            local okA, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, sid)
            if okA then
                if ns.IsSecret(aura) then
                    return nil
                end
                if aura ~= nil then
                    satisfied = true
                    break
                end
            end
        end
    end

    if (not satisfied) and hasAuraByIndex then
        local idSet, nameSet = GetClassBuffMatchers(self, playerClass, spec, firstKnownSpellID)
        local sawSecretAura = false
        for i = 1, 64 do
            local okI, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
            if not okI then
                break
            end
            if ns.IsSecret(aura) then
                return nil
            end
            if aura == nil then
                break
            end
            if type(aura) == "table" then
                local aSid = aura.spellId
                local aName = aura.name
                local sidSecret = ns.IsSecret(aSid)
                local nameSecret = ns.IsSecret(aName)
                if (not sidSecret) and type(aSid) == "number" and idSet[aSid] then
                    satisfied = true
                    break
                elseif (not nameSecret) and type(aName) == "string" and aName ~= "" and nameSet[aName] then
                    satisfied = true
                    break
                elseif sidSecret or nameSecret then
                    sawSecretAura = true
                end
            end
        end
        if (not satisfied) and sawSecretAura then
            return nil
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
    ctx:RegisterBucketEvent("WEAPON_ENCHANT_CHANGED", 0.30, Combat.CheckOutOfCombatBuffs)
    ctx:RegisterEvent("PLAYER_REGEN_ENABLED", Combat.CheckOutOfCombatBuffs)
    ctx:RegisterEvent("ADDON_LOADED", Combat.OnAddonLoaded)

    self:EvaluatePlayerHealth()
    self:CheckOutOfCombatBuffs()
    self:SyncNameplatePreset()
    self:SyncTempEnchantIconCVar()
end

function Combat:OnAddonLoaded(_, loadedAddonName)
    if type(loadedAddonName) ~= "string" then
        return
    end
    for _, extName in ipairs(EXTERNAL_NAMEPLATE_ADDONS) do
        if extName == loadedAddonName then
            self:SyncNameplatePreset()
            break
        end
    end
end

function Combat:OnDisable()
    self:RestoreNameplatePreset()
    self:RestoreTempEnchantIconCVar()
    self.alertFrame = nil
    self.alertLabel = nil
    self.lastShownPct = nil
    self.lastHealthStatus = "NORMAL"
    self.lastBuffMissing = false
    self._buffMatcherCache = nil
    self.nameplateOwner = nil
end

ns.ModuleManager:Register("Combat", Combat)
