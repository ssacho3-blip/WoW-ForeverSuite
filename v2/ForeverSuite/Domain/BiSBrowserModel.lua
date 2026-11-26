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

function BiSBrowserModel.FilterAndCompare(items, opts)
    opts = type(opts) == "table" and opts or {}
    local slotFilter = opts.slotFilter or "all"
    local upgradeOnly = opts.upgradeOnly == true
    local q = string_lower(tostring(opts.query or ""))
    local equippedMap = type(opts.equippedBySlot) == "table" and opts.equippedBySlot or {}

    local out = {}
    for _, it in ipairs(items or {}) do
        if type(it) == "table" and type(it.title) == "string" then
            if MatchesSlotFilter(it.slot, slotFilter) then
                local hay = string_lower(
                    it.title .. " " .. tostring(it.altName or "") .. " "
                    .. tostring(it.slot or "") .. " " .. tostring(it.note or "") .. " "
                    .. tostring(it.acq or "")
                )
                if q == "" or string_find(hay, q, 1, true) then
                    local eqIlvl = (type(it.equipSlot) == "number" and it.equipSlot > 0) and equippedMap[it.equipSlot] or nil
                    local delta, badge, tone = BiSBrowserModel.CompareWithEquipped(it.itemLevel, eqIlvl)
                    if (not upgradeOnly) or (type(delta) == "number" and delta > 0) then
                        table_insert(out, {
                            item = it,
                            equippedIlvl = eqIlvl,
                            delta = delta,
                            badge = badge,
                            tone = tone,
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
        local ai = (type(a.item.itemLevel) == "number") and a.item.itemLevel or 0
        local bi = (type(b.item.itemLevel) == "number") and b.item.itemLevel or 0
        if ai ~= bi then
            return ai > bi
        end
        return tostring(a.item.title) < tostring(b.item.title)
    end)

    return out
end
