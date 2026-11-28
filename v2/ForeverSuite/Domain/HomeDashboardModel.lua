-- Module: Domain/HomeDashboardModel.lua
-- Responsibility: Pure Lua 5.1 ViewModel for ForeverSuite v6.1 Home Dashboard (auto-detected character profile,
--                 Horde/Alliance faction-aware growth & dungeon guide, quick-launch tiles).
-- Layer: Domain (ZERO WoW globals, ZERO C_* calls, ZERO fabricated numbers).
local _, ns = ...
ns.Domain = ns.Domain or {}

local tostring = tostring
local type = type
local math_floor = math.floor

local HomeDashboardModel = {}
ns.Domain.HomeDashboardModel = HomeDashboardModel

local CLASS_LABELS_KR = {
    WARRIOR = "전사",
    PALADIN = "성기사",
    HUNTER  = "사냥꾼",
    ROGUE   = "도적",
    PRIEST  = "사제",
    SHAMAN  = "주술사",
    MAGE    = "마법사",
    WARLOCK = "흑마법사",
    DRUID   = "드루이드",
}

local FACTION_LABELS_KR = {
    Horde    = "호드",
    Alliance = "얼라이언스",
}

local LEVEL_RECOMMENDATIONS_HORDE = {
    { maxLv = 19, zone = "불모의 땅 · 은빛소나무 숲", dungeon = "성난불길 협곡 · 통곡의 동굴", tip = "크로스로드·오그리마 초반 동선과 성난불길/통곡 퀘스트를 함께 묶으세요." },
    { maxLv = 29, zone = "돌발톱 산맥 · 힐스브래드 구릉지", dungeon = "그림자송곳니 성채 · 검은심연 나락 · 가시덩굴 우리", tip = "호드 직업 퀘스트(토템/변신/소환수/무기)와 핵심 던전 퀘스트를 우선 챙기세요." },
    { maxLv = 39, zone = "가시덤불 골짜기 · 아라시 고원 · 잊혀진 땅", dungeon = "붉은십자군 수도원 · 가시덩굴 구릉 · 달라란 시 · 가라앉은 도시", tip = "수도원 4지구 반복과 달라란 시·가라앉은 도시 포에버 신규 보상을 확인하세요." },
    { maxLv = 49, zone = "타나리스 · 페랄라스 · 동부 내륙지 · 강물터", dungeon = "줄파락 · 크롤도크 보루 · 마라우돈 · 가라앉은 사원", tip = "40레벨 탈것 골드 관리와 마라우돈·크롤도크 보루(40~45) 사전 퀘스트를 확인하세요." },
    { maxLv = 59, zone = "운고로 분화구 · 서부·동부 역병지대 · 여명의 설원", dungeon = "검은바위 나락 · 스트라솔름 · 스칼로맨스 · 구체자의 정원", tip = "60레벨 Pre-BiS 파밍과 오닉시아(호드 렉사르)·화산심장부 입장 퀘스트를 시작하세요." },
    { maxLv = 99, zone = "검은바위 산 · 동부 역병지대 · 실리더스", dungeon = "화산심장부 · 오닉시아의 둥지 · 검은날개 둥지 · 구체자의 정원", tip = "BiS 장비 2-Pane 비교로 업그레이드 슬롯을 점검하고, 골드팟 장부로 분배를 기록하세요." },
}

local LEVEL_RECOMMENDATIONS_ALLIANCE = {
    { maxLv = 19, zone = "서부 몰락지대 · 모단 호수 · 어둠의 해안", dungeon = "죽음의 폐광 · 스톰윈드 지하감옥", tip = "서부 몰락지대 데피아즈단 연계와 죽음의 폐광 선행 퀘스트를 함께 묶으세요." },
    { maxLv = 29, zone = "그늘숲 · 붉은마루 산맥 · 저습지", dungeon = "스톰윈드 지하감옥 · 검은심연 나락 · 놈리건", tip = "얼라이언스 직업 퀘스트와 핵심 무기 보상을 우선 확보하면 사냥 속도가 크게 오릅니다." },
    { maxLv = 39, zone = "가시덤불 골짜기 · 아라시 고원 · 잊혀진 땅", dungeon = "놈리건 · 붉은십자군 수도원 · 달라란 시 · 가라앉은 도시", tip = "달라란 시·가라앉은 도시(35~40)와 붉은십자군 수도원 파템 파밍 구간입니다." },
    { maxLv = 49, zone = "타나리스 · 페랄라스 · 동부 내륙지 · 강물터", dungeon = "줄파락 · 울다만 · 크롤도크 보루 · 마라우돈", tip = "40레벨 탈것 골드 관리와 마라우돈·크롤도크 보루(40~45) 사전 퀘스트를 확인하세요." },
    { maxLv = 59, zone = "운고로 분화구 · 서부·동부 역병지대 · 여명의 설원", dungeon = "검은바위 나락 · 스트라솔름 · 스칼로맨스 · 구체자의 정원", tip = "60레벨 Pre-BiS 파밍과 오닉시아(얼라 윈저 원수)·화산심장부 입장 퀘스트를 시작하세요." },
    { maxLv = 99, zone = "검은바위 산 · 동부 역병지대 · 실리더스", dungeon = "화산심장부 · 오닉시아의 둥지 · 검은날개 둥지 · 구체자의 정원", tip = "BiS 장비 2-Pane 비교로 업그레이드 슬롯을 점검하고, 골드팟 장부로 분배를 기록하세요." },
}

local LEVEL_RECOMMENDATIONS = {
    { maxLv = 19, zone = "초반 시작·2차 육성 지역", dungeon = "성난불길 협곡 · 죽음의 폐광", tip = "초반 퀘스트 라인과 던전 퀘스트를 함께 묶어 동선을 단축하세요." },
    { maxLv = 29, zone = "20~30 중반 육성 지역", dungeon = "그림자송곳니 성채 · 스톰윈드 지하감옥 · 통곡의 동굴", tip = "직업 퀘스트와 핵심 무기 보상을 우선 확보하면 사냥 속도가 크게 오릅니다." },
    { maxLv = 39, zone = "가시덤불 · 아라시 · 잊혀진 땅", dungeon = "붉은십자군 수도원 · 놈리건 · 달라란 시 · 가라앉은 도시", tip = "수도원 4개 지구 반복으로 경험치와 파템 장비를 동시에 확보할 수 있습니다." },
    { maxLv = 49, zone = "타나리스 · 페랄라스 · 강물터", dungeon = "줄파락 · 울다만 · 크롤도크 보루 · 마라우돈", tip = "40레벨 탈것 골드 관리와 마라우돈 사전 퀘스트 연계를 확인하세요." },
    { maxLv = 59, zone = "운고로 · 역병지대 · 여명의 설원", dungeon = "검은바위 나락 · 스트라솔름 · 스칼로맨스 · 첨탑", tip = "60레벨 Pre-BiS 장비 파밍과 레이드 입장 퀘스트(오닉시아·화산심장부)를 시작할 구간입니다." },
    { maxLv = 99, zone = "검은바위 산 · 동부 역병지대", dungeon = "화산심장부 · 오닉시아의 둥지 · 검은날개 둥지", tip = "BiS 장비 2-Pane 비교로 업그레이드 슬롯을 점검하고, 골드팟 장부로 분배를 기록하세요." },
}

local CUSTOM_ICON_DIR = "Interface\\AddOns\\ForeverSuite_Media_Assets\\Icons\\"

local QUICK_TILES = {
    { id = "dungeons",    title = "던전 도감",     sub = "보스 드랍 · 진영 퀘스트",     icon = "Interface\\Icons\\INV_Misc_Map_01" },
    { id = "bis",         title = "BiS 장비 비교", sub = "착용 장비 vs 추천 슬롯 비교", icon = "Interface\\Icons\\INV_Helmet_03" },
    { id = "partyfinder", title = "파티 찾기",     sub = "실시간 모집 · 안전 귓말",     iconKey = "partyFinder", icon = CUSTOM_ICON_DIR .. "FS-Icon-PartyFinder.tga" },
    { id = "professions", title = "전문기술",      sub = "숙련도 루트 · 도안 검색",     icon = "Interface\\Icons\\Trade_BlackSmithing" },
    { id = "questguide",  title = "퀘스트 가이드", sub = "호드/얼라 분리 · 직업/육성",  icon = "Interface\\Icons\\INV_Misc_Book_09" },
    { id = "utilities",   title = "유틸 · 골드팟", sub = "경매·북마크·보호목록·부캐",  iconKey = "coinPot",     icon = CUSTOM_ICON_DIR .. "FS-Icon-CoinPot.tga" },
    { id = "ledger",      title = "골드 원장",     sub = "세션 수입·지출 · 100건 내역", iconKey = "coinGold",    icon = CUSTOM_ICON_DIR .. "FS-Icon-CoinGold.tga" },
    { id = "codex",       title = "통합 도감",     sub = "낚시·보상·펫·NPC 원스톱",     iconKey = "codex",       icon = CUSTOM_ICON_DIR .. "FS-Icon-Codex.tga" },
}

function HomeDashboardModel.GetQuickTiles()
    return QUICK_TILES
end

function HomeDashboardModel.RecommendForLevel(level, faction)
    if type(level) ~= "number" or level < 1 then
        return {
            zone = "접속 캐릭터 자동 감지 대기 중",
            dungeon = "던전 도감에서 내 레벨 맞춤 인던 확인",
            tip = "캐릭터 레벨과 진영이 집계되면 맞춤 육성 지역·던전·직업 퀘스트를 자동으로 안내합니다.",
        }
    end
    local tbl = LEVEL_RECOMMENDATIONS
    if faction == "Horde" then
        tbl = LEVEL_RECOMMENDATIONS_HORDE
    elseif faction == "Alliance" then
        tbl = LEVEL_RECOMMENDATIONS_ALLIANCE
    end
    local lv = math_floor(level)
    for i = 1, #tbl do
        local r = tbl[i]
        if lv <= r.maxLv then
            return r
        end
    end
    return tbl[#tbl]
end

function HomeDashboardModel.BuildOverview(ctx)
    ctx = type(ctx) == "table" and ctx or {}
    local name = (type(ctx.name) == "string" and ctx.name ~= "") and ctx.name or "모험가"
    local classEng = (type(ctx.classEng) == "string" and ctx.classEng ~= "") and ctx.classEng or nil
    local classKr = (classEng and CLASS_LABELS_KR[classEng]) or (type(ctx.classLoc) == "string" and ctx.classLoc) or "직업 미집계"
    local faction = (ctx.faction == "Horde" or ctx.faction == "Alliance") and ctx.faction or nil
    local factionKr = faction and FACTION_LABELS_KR[faction] or nil
    local raceLoc = (type(ctx.raceLoc) == "string" and ctx.raceLoc ~= "") and ctx.raceLoc or nil
    local levelText = (type(ctx.level) == "number" and ctx.level >= 1) and ("Lv." .. tostring(math_floor(ctx.level))) or "Lv.-"
    local zoneText = (type(ctx.zone) == "string" and ctx.zone ~= "") and ctx.zone or "지역 집계 없음"
    local realmText = (type(ctx.realm) == "string" and ctx.realm ~= "") and ctx.realm or "렐름 미집계"

    local bagVal = (type(ctx.freeSlots) == "number") and (tostring(math_floor(ctx.freeSlots)) .. "칸 여유") or "집계 없음"
    local bagTone = "GOLD"
    if type(ctx.freeSlots) == "number" then
        if ctx.freeSlots <= 4 then bagTone = "DANGER"
        elseif ctx.freeSlots <= 10 then bagTone = "WARN"
        else bagTone = "SUCCESS" end
    end

    local durVal = (type(ctx.durPct) == "number") and (tostring(math_floor(ctx.durPct)) .. "%") or "집계 없음"
    local durTone = "SUCCESS"
    if type(ctx.durPct) == "number" then
        if ctx.durPct < 30 then durTone = "DANGER"
        elseif ctx.durPct < 60 then durTone = "WARN"
        else durTone = "SUCCESS" end
    else
        durTone = "MUTED"
    end

    local goldVal = (type(ctx.goldText) == "string" and ctx.goldText ~= "") and ctx.goldText or "집계 없음"
    local questVal = (type(ctx.questCount) == "number") and (tostring(math_floor(ctx.questCount)) .. "개 진행") or "집계 없음"
    local talentSub = (type(ctx.unspentTalents) == "number" and ctx.unspentTalents > 0)
        and ("미사용 특성 +" .. tostring(math_floor(ctx.unspentTalents)) .. "p!")
        or (factionKr and (factionKr .. " 퀘스트 가이드 바로가기") or "퀘스트 가이드 바로가기")

    local rec = HomeDashboardModel.RecommendForLevel(ctx.level, faction)
    local lodCount = (type(ctx.loadedPacksCount) == "number") and math_floor(ctx.loadedPacksCount) or 0
    local lodText = (lodCount > 0)
        and ("LoD 도감 " .. tostring(lodCount) .. "팩 로드됨")
        or "LoD 도감 온디맨드 대기"

    local extraParts = { zoneText, realmText }
    if type(ctx.xpPct) == "number" then
        local xpStr = "XP " .. tostring(math_floor(ctx.xpPct)) .. "%"
        if type(ctx.restedPct) == "number" and ctx.restedPct > 0 then
            xpStr = xpStr .. "(휴식 " .. tostring(math_floor(ctx.restedPct)) .. "%)"
        end
        extraParts[#extraParts + 1] = xpStr
    end
    if type(ctx.avgIlvl) == "number" and ctx.avgIlvl > 0 then
        extraParts[#extraParts + 1] = "평균 iLvl " .. tostring(math_floor(ctx.avgIlvl))
    end
    extraParts[#extraParts + 1] = lodText

    local identityParts = { name, levelText }
    if factionKr then
        identityParts[#identityParts + 1] = "[" .. factionKr .. "]"
    end
    if raceLoc then
        identityParts[#identityParts + 1] = raceLoc .. " " .. classKr
    else
        identityParts[#identityParts + 1] = classKr
    end

    local dungeonLine = rec.dungeon
    if rec.zone and rec.zone ~= "" then
        dungeonLine = (factionKr and ("[" .. factionKr .. "] ") or "") .. rec.zone .. "\n· 추천 인던: " .. rec.dungeon
    end

    return {
        heroTitle = table.concat(identityParts, " · "),
        heroSub = table.concat(extraParts, "  |  "),
        classEng = classEng,
        faction = faction,
        factionKr = factionKr,
        recommendedZone = rec.zone,
        recommendedDungeon = dungeonLine,
        recommendedTip = rec.tip,
        cards = {
            {
                id = "bags",
                caption = "가방 여유 공간",
                value = bagVal,
                sub = "상점 잡템 자동 판매 지원",
                tone = bagTone,
                icon = "Interface\\Icons\\INV_Misc_Bag_08",
                targetPage = "settings",
            },
            {
                id = "durability",
                caption = "장비 평균 내구도",
                value = durVal,
                sub = (durTone == "DANGER") and "수리 필요! 상점 방문 권장" or "상점 방문 시 자동 수리",
                tone = durTone,
                icon = "Interface\\Icons\\Trade_BlackSmithing",
                targetPage = "settings",
            },
            {
                id = "gold",
                caption = "보유 골드 · 원장",
                value = goldVal,
                sub = "클릭하여 수입·지출 원장 열기",
                tone = "GOLD",
                iconKey = "coinGold",
                icon = CUSTOM_ICON_DIR .. "FS-Icon-CoinGold.tga",
                targetPage = "ledger",
            },
            {
                id = "quests",
                caption = "활성 퀘스트 · 특성",
                value = questVal,
                sub = talentSub,
                tone = (type(ctx.unspentTalents) == "number" and ctx.unspentTalents > 0) and "WARN" or "INFO",
                icon = "Interface\\Icons\\INV_Misc_Book_09",
                targetPage = "questguide",
            },
        },
    }
end
