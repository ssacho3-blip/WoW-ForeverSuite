-- Module: Domain/BiSBrowserModel.lua
-- Responsibility: Pure BiS gear browser filter & live 1:1 equipped-item iLvl comparison model (zero fabrication).
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local ipairs = ipairs
local tostring = tostring
local math_floor = math.floor
local string_lower = string.lower
local string_find = string.find
local table_insert = table.insert
local table_sort = table.sort

local BiSBrowserModel = {
    SLOT_FILTERS = {
        { value = "all", label = "전체", width = 46 },
        { value = "머리", label = "머리", width = 46 },
        { value = "목", label = "목", width = 38 },
        { value = "어깨", label = "어깨", width = 46 },
        { value = "등", label = "등", width = 38 },
        { value = "가슴", label = "가슴", width = 46 },
        { value = "손목", label = "손목", width = 46 },
        { value = "손", label = "손", width = 38 },
        { value = "허리", label = "허리", width = 46 },
        { value = "다리", label = "다리", width = 46 },
        { value = "발", label = "발", width = 38 },
        { value = "손가락", label = "반지", width = 46 },
        { value = "장신구", label = "장신구", width = 54 },
        { value = "무기", label = "무기", width = 46 },
    },
}
ns.Domain.BiSBrowserModel = BiSBrowserModel

local function MatchesSlotFilter(itemSlot, filterVal)
    if not filterVal or filterVal == "all" then
        return true
    end
    local s = tostring(itemSlot or "")
    if filterVal == "무기" then
        return s == "주장비" or s == "한손" or s == "양손" or s == "보조장비" or s == "방패" or s == "원거리" or s == "마법봉"
    end
    if filterVal == "등" then
        return s == "등" or s == "망토"
    end
    return s == filterVal
end

-- Computes exact iLvl delta against currently equipped item in that slot (nil if either side unknown — zero fabrication).
function BiSBrowserModel.CompareWithEquipped(itemIlvl, equippedIlvl)
    if type(itemIlvl) ~= "number" or itemIlvl <= 0 then
        return nil, "—", "MUTED"
    end
    if type(equippedIlvl) ~= "number" or equippedIlvl <= 0 then
        return nil, "iLvl " .. tostring(math_floor(itemIlvl)), "SECONDARY"
    end
    local delta = math_floor(itemIlvl) - math_floor(equippedIlvl)
    if delta > 0 then
        return delta, "+" .. tostring(delta) .. " 업글", "SUCCESS"
    elseif delta == 0 then
        return 0, "동급", "GOLD"
    else
        return delta, tostring(delta) .. " 하위", "DANGER"
    end
end

local SLOT_TO_INV = {
    ["머리"] = 1, ["목"] = 2, ["어깨"] = 3, ["가슴"] = 5, ["허리"] = 6,
    ["다리"] = 7, ["발"] = 8, ["손목"] = 9, ["손"] = 10, ["손가락"] = 11,
    ["장신구"] = 13, ["등"] = 15, ["망토"] = 15, ["주장비"] = 16, ["한손"] = 16,
    ["한손 장비"] = 16, ["양손"] = 16, ["양손 장비"] = 16, ["보조장비"] = 17,
    ["방패"] = 17, ["원거리"] = 18, ["원거리 장비"] = 18, ["마법봉"] = 18,
    ["투척"] = 18, ["성물"] = 18, ["성서"] = 18,
}

local ARMOR_TYPES = { ["천"] = true, ["가죽"] = true, ["사슬"] = true, ["판금"] = true, ["방패"] = true }
local CLASS_ARMOR_ALLOW = {
    WARRIOR = { ["천"] = true, ["가죽"] = true, ["사슬"] = true, ["판금"] = true, ["방패"] = true },
    PALADIN = { ["천"] = true, ["가죽"] = true, ["사슬"] = true, ["판금"] = true, ["방패"] = true },
    HUNTER  = { ["천"] = true, ["가죽"] = true, ["사슬"] = true },
    SHAMAN  = { ["천"] = true, ["가죽"] = true, ["사슬"] = true, ["방패"] = true },
    ROGUE   = { ["천"] = true, ["가죽"] = true },
    DRUID   = { ["천"] = true, ["가죽"] = true },
    PRIEST  = { ["천"] = true },
    MAGE    = { ["천"] = true },
    WARLOCK = { ["천"] = true },
}

function BiSBrowserModel.ResolveEquipSlot(item)
    if type(item) ~= "table" then return nil end
    local s = (type(item.equipSlot) == "number" and item.equipSlot > 0) and item.equipSlot
        or ((type(item.invSlot) == "number" and item.invSlot > 0) and item.invSlot or nil)
    if not s and type(item.slot) == "string" and item.slot ~= "" then
        s = SLOT_TO_INV[item.slot]
    end
    if s == 12 then s = 11 elseif s == 14 then s = 13 end
    return s
end

function BiSBrowserModel.CanClassUseItem(playerClass, itemType)
    if type(playerClass) ~= "string" or playerClass == "" then return true end
    if type(itemType) ~= "string" or itemType == "" then return true end
    if not ARMOR_TYPES[itemType] then return true end
    local allow = CLASS_ARMOR_ALLOW[playerClass]
    if not allow then return true end
    return allow[itemType] == true
end

local tonumber = tonumber
local string_gmatch = string.gmatch

local CLASS_SPECS = {
    WARRIOR = { { id = "arms", label = "무기", role = "melee" }, { id = "fury", label = "분노", role = "melee" }, { id = "protection", label = "방어", role = "tank" } },
    PALADIN = { { id = "holy", label = "신성", role = "healer" }, { id = "protection", label = "보호", role = "tank" }, { id = "retribution", label = "징벌", role = "melee" } },
    HUNTER  = { { id = "beastmastery", label = "야수", role = "ranged" }, { id = "marksmanship", label = "사격", role = "ranged" }, { id = "survival", label = "생존", role = "ranged" } },
    ROGUE   = { { id = "assassination", label = "암살", role = "melee" }, { id = "combat", label = "전투", role = "melee" }, { id = "subtlety", label = "잠행", role = "melee" } },
    PRIEST  = { { id = "discipline", label = "수양", role = "healer" }, { id = "holy", label = "신성", role = "healer" }, { id = "shadow", label = "암흑", role = "caster" } },
    SHAMAN  = { { id = "elemental", label = "정기", role = "caster" }, { id = "enhancement", label = "고양", role = "melee" }, { id = "restoration", label = "복원", role = "healer" } },
    MAGE    = { { id = "arcane", label = "비전", role = "caster" }, { id = "fire", label = "화염", role = "caster" }, { id = "frost", label = "냉기", role = "caster" } },
    WARLOCK = { { id = "affliction", label = "고통", role = "caster" }, { id = "demonology", label = "악마", role = "caster" }, { id = "destruction", label = "파괴", role = "caster" } },
    DRUID   = { { id = "balance", label = "조화", role = "caster" }, { id = "feral", label = "야성", role = "melee" }, { id = "restoration", label = "회복", role = "healer" } },
}
BiSBrowserModel.CLASS_SPECS = CLASS_SPECS

local ROLE_STAT_WEIGHTS = {
    melee  = { ["힘"] = 2.0, ["민첩"] = 1.7, ["체력"] = 0.6, ["전투력"] = 1.0, ["치명타"] = 16, ["적중"] = 18, ["가속"] = 10 },
    ranged = { ["민첩"] = 2.2, ["지능"] = 0.7, ["체력"] = 0.5, ["전투력"] = 1.0, ["치명타"] = 16, ["적중"] = 18, ["원거리"] = 1.0 },
    tank   = { ["체력"] = 2.2, ["힘"] = 1.2, ["민첩"] = 1.1, ["방어"] = 2.4, ["방어도"] = 0.08, ["회피"] = 14, ["무기 막기"] = 14, ["방패"] = 10, ["적중"] = 12 },
    caster = { ["지능"] = 1.5, ["정신력"] = 0.6, ["체력"] = 0.5, ["주문력"] = 2.4, ["주문 피해"] = 2.4, ["주문 극대화"] = 16, ["치명타"] = 14, ["적중"] = 18, ["마나"] = 1.4 },
    healer = { ["지능"] = 1.6, ["정신력"] = 1.5, ["체력"] = 0.5, ["치유"] = 2.5, ["주문력"] = 1.4, ["마나"] = 2.2, ["극대화"] = 10 },
}

function BiSBrowserModel.GetSpecsForClass(playerClass)
    return CLASS_SPECS[playerClass] or CLASS_SPECS.WARRIOR
end

function BiSBrowserModel.ScoreItemForSpec(item, role)
    if type(item) ~= "table" then return 0, "C" end
    local w = ROLE_STAT_WEIGHTS[role] or ROLE_STAT_WEIGHTS.melee
    local note = tostring(item.note or "")
    local score = (type(item.itemLevel) == "number" and item.itemLevel > 0) and (item.itemLevel * 0.6) or 0
    if note ~= "" then
        for statName, weight in pairs(w) do
            local pos = string_find(note, statName, 1, true)
            if pos then
                local tail = string.sub(note, pos, pos + 24)
                local num = tonumber(string.match(tail, "(%d+)"))
                if num and num > 0 then
                    score = score + (num * weight)
                end
            end
        end
    end
    score = math_floor(score + 0.5)
    local grade = "C"
    if score >= 95 then grade = "S"
    elseif score >= 65 then grade = "A"
    elseif score >= 40 then grade = "B"
    end
    return score, grade
end

function BiSBrowserModel.FindEvidence(evidenceRows, playerClass, specId)
    if type(evidenceRows) ~= "table" then return nil end
    for _, ev in ipairs(evidenceRows) do
        if type(ev) == "table" and ev.class == playerClass and (not specId or ev.spec == specId) then
            return ev
        end
    end
    return nil
end

function BiSBrowserModel.FilterAndCompare(items, opts)
    opts = type(opts) == "table" and opts or {}
    local slotFilter = opts.slotFilter or "all"
    local upgradeOnly = opts.upgradeOnly == true
    local classOnly = opts.classOnly == true
    local playerClass = opts.playerClass
    local specRole = opts.specRole
    local q = string_lower(tostring(opts.query or ""))
    local equippedMap = type(opts.equippedBySlot) == "table" and opts.equippedBySlot or {}

    local out = {}
    for _, it in ipairs(items or {}) do
        if type(it) == "table" and type(it.title) == "string" then
            local classOk = (not classOnly) or BiSBrowserModel.CanClassUseItem(playerClass, it.itemType)
            if classOk and MatchesSlotFilter(it.slot, slotFilter) then
                local hay = string_lower(
                    it.title .. " " .. tostring(it.altName or "") .. " "
                    .. tostring(it.slot or "") .. " " .. tostring(it.note or "") .. " "
                    .. tostring(it.acq or "")
                )
                if q == "" or string_find(hay, q, 1, true) then
                    local slotNum = BiSBrowserModel.ResolveEquipSlot(it)
                    local eqIlvl = (type(slotNum) == "number" and slotNum > 0) and equippedMap[slotNum] or nil
                    local delta, badge, tone = BiSBrowserModel.CompareWithEquipped(it.itemLevel, eqIlvl)
                    local specScore, specGrade = BiSBrowserModel.ScoreItemForSpec(it, specRole)
                    if (not upgradeOnly) or (type(delta) == "number" and delta > 0) then
                        table_insert(out, {
                            item = it,
                            equippedIlvl = eqIlvl,
                            delta = delta,
                            badge = badge,
                            tone = tone,
                            specScore = specScore,
                            specGrade = specGrade,
                        })
                    end
                end
            end
        end
    end

    table_sort(out, function(a, b)
        local ad = (type(a.delta) == "number") and a.delta or -9999
        local bd = (type(b.delta) == "number") and b.delta or -9999
        if ad ~= bd then
            return ad > bd
        end
        if specRole and a.specScore ~= b.specScore then
            return (a.specScore or 0) > (b.specScore or 0)
        end
        local ai = (type(a.item.itemLevel) == "number") and a.item.itemLevel or 0
        local bi = (type(b.item.itemLevel) == "number") and b.item.itemLevel or 0
        if ai ~= bi then
            return ai > bi
        end
        return tostring(a.item.title) < tostring(b.item.title)
    end)

    return out
end
