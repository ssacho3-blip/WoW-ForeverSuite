local _, ns = ...

local type = type
local tonumber = tonumber
local math_floor = math.floor
local string_format = string.format

local CLASS_SELF_BUFFS = {
    MAGE = 1459,      -- 신비한 지능 (Arcane Intellect)
    PRIEST = 1243,    -- 신의 권능: 인내 (Power Word: Fortitude)
    WARRIOR = 6673,   -- 전투의 외침 (Battle Shout)
    DRUID = 1126,     -- 야생의 징표 (Mark of the Wild)
}

local Combat = {
    title = "전투 정보 및 생존 보조 (Combat)",
    priority = "P2",
    description = "내장 미터기·쿨다운 뷰어 연동, 비전투 직업 버프 누락 체크, Secret 안전 저체력 알림",
    yieldTo = {},
    alertFrame = nil,
    alertLabel = nil,
    lastHealthStatus = "NORMAL",
    lastShownPct = nil,
    lastBuffMissing = false,
}

function Combat:EvaluatePlayerHealth()
    if not ns.ProfileManager:Get("combat", "lowHealthAlert") then
        self.lastHealthStatus = "DISABLED"
        self.lastShownPct = nil
        if self.alertFrame then
            self.alertFrame:Hide()
        end
        return
    end
    if not (_G.UnitHealth and _G.UnitHealthMax) then
        return
    end

    local hp = _G.UnitHealth("player")
    local maxHp = _G.UnitHealthMax("player")

    -- Strict C_Secrets guard: zero arithmetic or comparisons on secret values (AC-4)
    if ns.IsSecret(hp) or ns.IsSecret(maxHp) then
        self.lastHealthStatus = "UNAVAILABLE"
        self.lastShownPct = nil
        if self.alertFrame then
            self.alertFrame:Hide()
        end
        return
    end

    if type(hp) ~= "number" or type(maxHp) ~= "number" or maxHp <= 0 then
        return
    end
    if _G.UnitIsDeadOrGhost and _G.UnitIsDeadOrGhost("player") then
        self.lastHealthStatus = "DEAD"
        self.lastShownPct = nil
        if self.alertFrame then
            self.alertFrame:Hide()
        end
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
        if self.alertFrame then
            self.alertFrame:Hide()
        end
    end
end

function Combat:CheckOutOfCombatBuffs()
    -- Out-of-combat strictly enforced (Contract Taint/Secret Rule #4)
    if ns.InCombat() or not ns.ProfileManager:Get("combat", "remindMissingClassBuff") then
        return
    end
    if _G.UnitIsDeadOrGhost and _G.UnitIsDeadOrGhost("player") then
        return
    end
    local spellID = CLASS_SELF_BUFFS[ns.ProfileManager.playerClass]
    if not spellID then
        return
    end
    if not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then
        return
    end
    if C_Spell and C_Spell.IsSpellKnown and not C_Spell.IsSpellKnown(spellID) then
        return
    end

    local aura = C_UnitAuras.GetPlayerAuraBySpellID(spellID)
    if ns.IsSecret(aura) then
        return
    end
    local missing = (aura == nil)
    if missing and not self.lastBuffMissing then
        local buffName = "직업 강화 효과"
        if C_Spell and C_Spell.GetSpellInfo then
            local info = C_Spell.GetSpellInfo(spellID)
            if type(info) == "table" and type(info.name) == "string" then
                buffName = info.name
            end
        end
        ns.Print("비전투 버프 누락 알림: [" .. buffName .. "] 효과가 없습니다.")
    end
    self.lastBuffMissing = missing
end

function Combat:OnEnable(ctx)
    local banner = ctx:CreateFrame("Frame", "ForeverSuiteHealthAlertFrame", _G.UIParent)
    if banner then
        if not banner._fsInitialized then
            banner._fsInitialized = true
            banner:SetSize(260, 32)
            banner:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 140)
            local lbl = ns.UI.CreateLabel(banner, "", "GameFontNormalLarge", ns.UI.COLORS.TEXT)
            if lbl then
                lbl:SetPoint("CENTER", banner, "CENTER", 0, 0)
                banner._fsAlertLabel = lbl
            end
        end
        self.alertLabel = banner._fsAlertLabel
        banner:Hide()
        self.alertFrame = banner
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
end

ns.ModuleManager:Register("Combat", Combat)
