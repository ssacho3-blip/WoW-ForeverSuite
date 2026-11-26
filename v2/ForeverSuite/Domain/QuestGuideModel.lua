-- Module: Domain/QuestGuideModel.lua
-- Responsibility: Pure KPI-6 Leveling Zone Planner & Class Quest Walkthrough/Chain filter (zero fabricated level/class).
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

local CLASS_MASK = {
    WARRIOR = 1,
    PALADIN = 2,
    HUNTER = 4,
    ROGUE = 8,
    PRIEST = 16,
    SHAMAN = 64,
    MAGE = 128,
    WARLOCK = 256,
    DRUID = 1024,
}

local LEVELING_ZONES = {
    { minL = 1, maxL = 12, faction = "Alliance", zone = "엘윈 숲 / 던 모로 / 텔드랏실", mapID = 1429, x = 0.48, y = 0.42, tip = "초반 직업 퀘스트·전문기술 입문" },
    { minL = 1, maxL = 12, faction = "Horde", zone = "듀로타 / 멀고어 / 티리스팔 숲", mapID = 1411, x = 0.52, y = 0.43, tip = "초반 직업 퀘스트·전문기술 입문" },
    { minL = 10, maxL = 20, faction = "Alliance", zone = "서부 몰락지대 / 모단 호수 / 어둠의 해안", mapID = 1436, x = 0.56, y = 0.47, tip = "죽음의 폐광(16~22) 선행 퀘스트 수집" },
    { minL = 10, maxL = 22, faction = "Horde", zone = "불모의 땅 / 은빛소나무 숲", mapID = 1413, x = 0.52, y = 0.30, tip = "성난불길 협곡(13~18) · 통곡의 동굴(17~24)" },
    { minL = 20, maxL = 30, faction = "Both", zone = "그늘숲 / 돌발톱 산맥 / 붉은마루 / 힐스브래드", mapID = 1431, x = 0.74, y = 0.46, tip = "그림자송곳니 성채 · 검은심연 나락 · 가시덩굴 우리" },
    { minL = 30, maxL = 40, faction = "Both", zone = "가시덤불 골짜기 / 잊혀진 땅 / 아라시 고원", mapID = 1434, x = 0.35, y = 0.11, tip = "붉은십자군 수도원 · 달라란 시 · 가라앉은 도시(35~40)" },
    { minL = 40, maxL = 50, faction = "Both", zone = "타나리스 / 페랄라스 / 동부 내륙지 / 강물터", mapID = 1446, x = 0.52, y = 0.28, tip = "줄파락(44~54) · 크롤도크 보루(40~45) · 마라우돈" },
    { minL = 50, maxL = 60, faction = "Both", zone = "운고로 분화구 / 서부·동부 역병지대 / 여명의 설원", mapID = 1449, x = 0.45, y = 0.08, tip = "검은바위 나락 · 스칼로맨스 · 스트라솔름 · 구체자의 정원(58~60)" },
}

local QuestGuideModel = {
    CLASS_MASK = CLASS_MASK,
    LEVELING_ZONES = LEVELING_ZONES,
}
ns.Domain.QuestGuideModel = QuestGuideModel

local function BitHas(mask, bitVal)
    if type(mask) ~= "number" or mask <= 0 or type(bitVal) ~= "number" or bitVal <= 0 then
        return true
    end
    return (math_floor(mask / bitVal) % 2) == 1
end

function QuestGuideModel.RecommendLevelingZones(playerLevel, faction)
    local lvl = (type(playerLevel) == "number" and playerLevel == playerLevel and playerLevel >= 1) and math_floor(playerLevel) or nil
    local out = {}
    for _, z in ipairs(LEVELING_ZONES) do
        local fOk = (not faction) or z.faction == "Both" or z.faction == faction
        if fOk then
            local inRange = (lvl ~= nil) and (lvl >= z.minL - 2 and lvl <= z.maxL + 2) or false
            table_insert(out, {
                zone = z.zone,
                range = "Lv." .. tostring(z.minL) .. "-" .. tostring(z.maxL),
                tip = z.tip,
                mapID = z.mapID,
                x = z.x,
                y = z.y,
                recommended = inRange,
                minL = z.minL,
            })
        end
    end
    table_sort(out, function(a, b)
        if a.recommended ~= b.recommended then
            return a.recommended
        end
        return a.minL < b.minL
    end)
    return out
end

function QuestGuideModel.FilterClassQuests(entries, opts)
    opts = type(opts) == "table" and opts or {}
    local engClass = opts.playerClass
    local myClassOnly = opts.myClassOnly == true
    local withWalkthroughOnly = opts.withWalkthroughOnly == true
    local q = string_lower(tostring(opts.query or ""))
    local bit = engClass and CLASS_MASK[engClass] or nil

    local out = {}
    if type(entries) ~= "table" then return out end
    for _, item in ipairs(entries) do
        if type(item) == "table" and type(item.title) == "string" then
            local clsOk = (not myClassOnly) or (bit ~= nil and BitHas(item.classMask, bit))
            local walkOk = (not withWalkthroughOnly) or (type(item.walkthrough) == "string" and item.walkthrough ~= "")
            if clsOk and walkOk then
                if q == "" then
                    table_insert(out, item)
                else
                    local hay = string_lower(item.title .. " " .. tostring(item.altName or "") .. " " .. tostring(item.walkthrough or ""))
                    if string_find(hay, q, 1, true) then
                        table_insert(out, item)
                    end
                end
            end
        end
    end
    table_sort(out, function(a, b)
        local al = (type(a.minLevel) == "number") and a.minLevel or 0
        local bl = (type(b.minLevel) == "number") and b.minLevel or 0
        if al ~= bl then return al < bl end
        return (a.questID or 0) < (b.questID or 0)
    end)
    return out
end
