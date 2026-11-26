-- Module: Domain/CombatAlertModel.lua
-- Responsibility: Pure 9-class out-of-combat buff reminder rules (including group buffs & known-enchant gates) and Secret-safe low-HP evaluator.
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local ipairs = ipairs

local CLASS_BUFF_SPELLS = {
    MAGE = {
        name = "신비한 지능",
        spells = { 1459, 1460, 1461, 10156, 10157, 23028 },
        secondaryName = "마법사 갑옷",
        secondarySpells = { 168, 7300, 7301, 7302, 7320, 10219, 10220, 6117, 22782, 22783 },
    },
    PRIEST = {
        name = "신의 권능: 인내",
        spells = { 1243, 1244, 1245, 2791, 10937, 10938, 21562, 21564 },
        secondaryName = "내면의 열정",
        secondarySpells = { 588, 7128, 602, 1006, 10951, 10952 },
    },
    DRUID = {
        name = "야생의 징표",
        spells = { 1126, 5232, 6756, 5234, 8907, 9884, 9885, 21849, 21850 },
        secondaryName = "가시",
        secondarySpells = { 467, 782, 1075, 8914, 9756, 9910 },
    },
    WARLOCK = { name = "악마의 갑옷", spells = { 687, 696, 706, 1086, 11733, 11734, 11735 } },
    PALADIN = {
        name = "축복",
        spells = { 19740, 19834, 19835, 19836, 19837, 19838, 25291, 19742, 19850, 19852, 19853, 19854, 25290, 20217, 25782, 25894, 25898 },
        secondaryName = "성기사 오라",
        secondarySpells = { 465, 10290, 643, 10291, 1032, 10292, 10293, 7294, 10298, 10299, 10300, 10301, 19746 },
    },
    WARRIOR = { name = "전투의 외침", spells = { 6673, 5242, 6192, 11549, 11550, 11551, 25289 } },
    HUNTER = { name = "상(Aspect)", spells = { 13165, 14318, 14319, 14320, 14321, 14322, 25296, 13163, 5118, 13159, 20043 } },
    SHAMAN = {
        name = "번개 보호막",
        spells = { 324, 325, 905, 945, 8134, 10431, 10432 },
        enchantSpells = { 8017, 8018, 8019, 10399, 8024, 8027, 8030, 16339, 16341, 16342, 8232, 8235, 10486, 16362 },
    },
    ROGUE = {
        name = "독 바르기",
        spells = {},
        enchantSpells = { 2842 },
    },
}

local CombatAlertModel = {
    CLASS_BUFF_SPELLS = CLASS_BUFF_SPELLS,
}
ns.Domain.CombatAlertModel = CombatAlertModel

function CombatAlertModel.CollectAllSpellIDsForClass(engClass)
    local cfg = CLASS_BUFF_SPELLS[engClass]
    if not cfg then
        return {}
    end
    local out = {}
    for _, sid in ipairs(cfg.spells or {}) do out[#out + 1] = sid end
    for _, sid in ipairs(cfg.secondarySpells or {}) do out[#out + 1] = sid end
    for _, sid in ipairs(cfg.enchantSpells or {}) do out[#out + 1] = sid end
    return out
end

function CombatAlertModel.EvaluateMissingBuffs(engClass, knownSet, activeAuraSet, hasMainHandEnchant, inCombat, isDeadOrGhost)
    if inCombat or isDeadOrGhost then
        return {}
    end
    local cfg = CLASS_BUFF_SPELLS[engClass]
    if not cfg then
        return {}
    end
    local missing = {}
    local knowsAny = false
    local hasActive = false
    for _, sid in ipairs(cfg.spells or {}) do
        if knownSet and knownSet[sid] then knowsAny = true end
        if activeAuraSet and activeAuraSet[sid] then hasActive = true end
    end
    if knowsAny and not hasActive then
        missing[#missing + 1] = cfg.name
    end

    if cfg.secondarySpells and cfg.secondaryName then
        local knowsSec, hasSec = false, false
        for _, sid in ipairs(cfg.secondarySpells) do
            if knownSet and knownSet[sid] then knowsSec = true end
            if activeAuraSet and activeAuraSet[sid] then hasSec = true end
        end
        if knowsSec and not hasSec then
            missing[#missing + 1] = cfg.secondaryName
        end
    end

    if cfg.enchantSpells and hasMainHandEnchant == false then
        local knowsEnchant = false
        for _, sid in ipairs(cfg.enchantSpells) do
            if knownSet and knownSet[sid] then
                knowsEnchant = true
                break
            end
        end
        if knowsEnchant then
            missing[#missing + 1] = (engClass == "SHAMAN") and "무기 마법부여" or "주무기 독"
        end
    end
    return missing
end

function CombatAlertModel.EvaluateLowHealth(hp, hpMax, threshold, isDeadOrGhost)
    if isDeadOrGhost then
        return nil
    end
    if type(hp) ~= "number" or type(hpMax) ~= "number" or hpMax <= 0 then
        return nil
    end
    local ratio = hp / hpMax
    local limit = (type(threshold) == "number" and threshold > 0 and threshold < 1) and threshold or 0.30
    return {
        ratio = ratio,
        pct = math.floor(ratio * 100 + 0.5),
        isLow = (ratio > 0 and ratio <= limit),
    }
end
