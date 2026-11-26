-- Module: Domain/GlobalSearchModel.lua
-- Responsibility: Pure Lua 5.1 global search engine matching feature synonyms, setting schemas, and already-loaded codex packs.
-- Layer: Domain (ZERO WoW globals, ZERO side effects, NEVER forces LoD pack loading).
local _, ns = ...
ns.Domain = ns.Domain or {}

local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local string_lower = string.lower
local string_find = string.find
local string_match = string.match

local GlobalSearchModel = {}
ns.Domain.GlobalSearchModel = GlobalSearchModel

local FEATURE_DIRECTORY = {
    { id = "home",        title = "홈 대시보드",            sub = "캐릭터 요약 · 현재 지역 · 빠른 실행",   pageId = "home",        keywords = "홈 대시보드 요약 시작 home" },
    { id = "dungeons",    title = "던전 도감",              sub = "인던 보스 드랍 · 퀘스트 · iLvl 비교",   pageId = "dungeons",    keywords = "던전 인던 보스 드랍 루팅 dungeon" },
    { id = "bis",         title = "BiS 추천 장비 비교",     sub = "직업·특성·단계별 2-Pane 착용 비교",     pageId = "bis",         keywords = "bis 비스 장비 졸업 템 비교" },
    { id = "professions", title = "전문기술 · 도안 가이드", sub = "13개 전문기술 육성 루트 · 도안 검색",   pageId = "professions", keywords = "전문기술 숙련 도안 제작 대장 연금 기공 마부 채광 약초 재봉 가세 요리 낚시 응치" },
    { id = "questguide",  title = "퀘스트 · 레벨업 가이드", sub = "구간별 루트 · 직업 퀘 · 특수 도서",     pageId = "questguide",  keywords = "퀘스트 레벨업 루트 공략 도서 직업퀘 quest" },
    { id = "codex",       title = "통합 도감 (LoD)",        sub = "낚시 · 펫 · 보상 · 아틀라스 NPC",       pageId = "codex",       keywords = "도감 낚시 펫 탈것 보상 아틀라스 codex" },
    { id = "partyfinder", title = "파티 찾기 모니터",       sub = "실시간 채팅 모집 · 안전 귓말 지원",     pageId = "partyfinder", keywords = "파티 공대 모집 구인 귓말 lfg party" },
    { id = "gdkp",        title = "골드팟 경매 · 분배기",   sub = "인원·분배율·실시간 경매·정산 공지",     pageId = "utilities",   subTab = "gdkp",      keywords = "골드팟 경매 분배 팟장 gdkp pot" },
    { id = "bookmarks",   title = "즐겨찾기 /way 북마크",   sub = "현재 위치 원클릭 저장 · 길안내",        pageId = "utilities",   subTab = "bookmarks", keywords = "북마크 즐겨찾기 좌표 웨이포인트 위치 저장 fav way" },
    { id = "protect",     title = "상점 판매 보호 목록",    sub = "잡템 자동 판매 제외 아이템 관리",       pageId = "utilities",   subTab = "protect",   keywords = "보호 판매 잡템 상점 protect" },
    { id = "alts",        title = "부캐릭터 자산 현황",     sub = "렐름 내 캐릭터 골드·레벨 통합",         pageId = "utilities",   subTab = "alts",      keywords = "부캐 알트 자산 캐릭터 alt" },
    { id = "trade",       title = "거래 내역 · 파밍 GPH",   sub = "최근 거래 로그 · 시간당 골드 측정",     pageId = "utilities",   subTab = "trade",     keywords = "거래 트레이드 파밍 시급 gph farm" },
    { id = "stats",       title = "확장 캐릭터 스탯",       sub = "전투력·치명타·주문력·방어도·이속",      pageId = "utilities",   subTab = "stats",     keywords = "스탯 전투력 치명타 주문력 이속 stat" },
    { id = "chat_url",    title = "채팅 키워드 · URL 복사", sub = "키워드 알림 등록 · 링크 복사 팝업",     pageId = "utilities",   subTab = "chat",      keywords = "채팅 키워드 알림 링크 url kw" },
    { id = "ledger",      title = "골드 원장",              sub = "일일 수입·지출 집계 및 내역",           pageId = "ledger",      keywords = "원장 골드 가계부 수입 지출 ledger gold" },
    { id = "fonts",       title = "폰트 · 외관 설정",       sub = "한글 폰트 프리셋 · 외곽선 즉시 적용",   pageId = "fonts",       keywords = "폰트 글꼴 외곽선 외관 font" },
    { id = "diagnostics", title = "진단 · HUD 관리",        sub = "Zero-Taint 상태 · LoD 팩 · HUD 초기화", pageId = "diagnostics", keywords = "진단 hud 위치 초기화 taint 버전" },
    { id = "settings",    title = "통합 설정 · 프리셋",     sub = "추천 프리셋 · 전체 기능 토글",          pageId = "settings",    keywords = "설정 옵션 프리셋 백업 복원 프로필 settings" },
}

local function Trim(s)
    return string_match(tostring(s or ""), "^%s*(.-)%s*$") or ""
end

local function ContainsCI(hay, needle)
    if type(hay) ~= "string" or hay == "" then return false end
    return string_find(string_lower(hay), needle, 1, true) ~= nil
end

function GlobalSearchModel.Search(query, schemas, loadedPacks, limits)
    local q = string_lower(Trim(query))
    if q == "" then
        return { features = {}, settings = {}, codex = {}, total = 0 }
    end

    limits = type(limits) == "table" and limits or {}
    local maxFeat = limits.features or 4
    local maxSet = limits.settings or 4
    local maxCodex = limits.codex or 4

    local features = {}
    for _, f in ipairs(FEATURE_DIRECTORY) do
        if ContainsCI(f.title, q) or ContainsCI(f.sub, q) or ContainsCI(f.keywords, q) then
            features[#features + 1] = {
                kind = "feature",
                id = f.id,
                title = f.title,
                sub = f.sub,
                pageId = f.pageId,
                subTab = f.subTab,
            }
            if #features >= maxFeat then break end
        end
    end

    local settings = {}
    for _, sc in ipairs(schemas or {}) do
        if type(sc) == "table" and (ContainsCI(sc.label, q) or ContainsCI(sc.desc, q) or ContainsCI(sc.key, q)) then
            settings[#settings + 1] = {
                kind = "setting",
                section = sc.section,
                key = sc.key,
                settingType = sc.type,
                title = sc.label or sc.key,
                sub = sc.desc or "",
                combatSafe = sc.combatSafe ~= false,
                pageId = "settings",
            }
            if #settings >= maxSet then break end
        end
    end

    local codex = {}
    if type(loadedPacks) == "table" then
        local sortedPackIds = {}
        for packId in pairs(loadedPacks) do
            sortedPackIds[#sortedPackIds + 1] = tostring(packId)
        end
        table.sort(sortedPackIds)
        for _, packId in ipairs(sortedPackIds) do
            local pack = loadedPacks[packId]
            if type(pack) == "table" and type(pack.entries) == "table"
                and not (pack._schema == 2 and pack._complete == false)
            then
                for _, e in ipairs(pack.entries) do
                    if type(e) == "table" then
                        local title = tostring(e.title or e.name or "")
                        local zone = tostring(e.zone or e.source or e.boss or "")
                        if ContainsCI(title, q) or ContainsCI(zone, q) then
                            local targetPage = "codex"
                            if packId == "dungeons" or packId == "dungeon_bosses" then
                                targetPage = "dungeons"
                            elseif packId == "bis" then
                                targetPage = "bis"
                            elseif packId == "professions" then
                                targetPage = "professions"
                            elseif packId == "quest_guides" or packId == "special_guides" then
                                targetPage = "questguide"
                            end
                            codex[#codex + 1] = {
                                kind = "codex",
                                packId = packId,
                                packTitle = pack.title or packId,
                                title = title,
                                sub = (zone ~= "" and (zone .. " · ") or "") .. tostring(pack.title or packId),
                                pageId = targetPage,
                                query = title,
                                itemID = e.itemID,
                            }
                            if #codex >= maxCodex then break end
                        end
                    end
                end
            end
            if #codex >= maxCodex then break end
        end
    end

    return {
        features = features,
        settings = settings,
        codex = codex,
        total = #features + #settings + #codex,
    }
end
