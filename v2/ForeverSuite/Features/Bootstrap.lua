-- Module: Features/Bootstrap.lua
-- Responsibility: Wires v2 declarative schemas, L2 Command Hub (4 pages), Phase 2A modules, lifecycle events, and /fs2 + /way2 commands.
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local pairs = pairs
local string_match = string.match
local string_lower = string.lower

local MAX_TAINT_KEYS = 200

-- Every declared setting MUST have an active runtime consumer.
local DEFAULT_SCHEMAS = {
    {
        section = "quest",
        key = "defaultTrackerMode",
        type = "enum",
        default = "hide",
        label = "Blizzard 기본 퀘스트 추적기 모드",
        desc = "hide(기본 · 중복 방지) / dim(흐리게) / coexist(기본 공존)",
        combatSafe = false,
        options = {
            { value = "hide", label = "숨김(기본)", width = 82 },
            { value = "dim", label = "흐리게", width = 76 },
            { value = "coexist", label = "공존", width = 72 },
        },
    },
    {
        section = "ui",
        key = "showStatusPill",
        type = "boolean",
        default = true,
        label = "상단 상태 필 바 표시 (가방·내구·골드·렐름)",
        desc = "L0 상시 HUD 상태 요약 바 표시/숨김 (Shift+드래그 자유 이동)",
        combatSafe = true,
    },
    {
        section = "ui",
        key = "showQuickDock",
        type = "boolean",
        default = true,
        label = "빠른 도구 바 표시 (낚시·추적·싼템·파찾·풀링·채팅·이동)",
        desc = "자주 쓰는 편의 기능을 1클릭으로 실행하는 접이식 플로팅 도구 바",
        combatSafe = true,
    },
    {
        section = "ui",
        key = "showMinimapButton",
        type = "boolean",
        default = true,
        label = "미니맵 원형 버튼 표시 (드래그 이동 · 퀵액션)",
        desc = "좌클릭 허브 / 우클릭 HUD 이동 / Shift+우클릭 원장",
        combatSafe = true,
    },
    {
        section = "quest",
        key = "groupMode",
        type = "enum",
        default = "zone",
        label = "퀘스트 추적기 그룹 기준",
        desc = "지역별(현재 지역 최상단) 또는 레벨 구간별 정렬",
        combatSafe = true,
        options = {
            { value = "zone", label = "지역별", width = 72 },
            { value = "level", label = "레벨별", width = 72 },
        },
    },
    {
        section = "quest",
        key = "currentZoneOnly",
        type = "boolean",
        default = false,
        label = "퀘스트 추적기: 현재 지역 퀘스트만 표시",
        desc = "다른 지역 퀘스트를 숨겨 집중도를 높입니다",
        combatSafe = true,
    },
    {
        section = "quest",
        key = "combatFade",
        type = "boolean",
        default = true,
        label = "퀘스트 추적기: 전투 중 반투명 페이드",
        desc = "전투 시 투명도 35%로 낮춤 (보안 프레임 비간섭)",
        combatSafe = true,
    },
    {
        section = "quest",
        key = "trackerLocked",
        type = "boolean",
        default = false,
        label = "퀘스트 추적기 위치 잠금",
        desc = "오클릭 드래그 방지",
        combatSafe = true,
    },
    {
        section = "quest",
        key = "trackerMinimized",
        type = "boolean",
        default = false,
        label = "퀘스트 추적기 헤더만 접기",
        desc = "상단 헤더의 -/+ 버튼과 연동됩니다",
        combatSafe = true,
    },
    {
        section = "ui",
        key = "showWorldMapOverlay",
        type = "boolean",
        default = true,
        label = "월드맵 좌표 & 주요 NPC/던전 입구 패널 표시",
        desc = "Zero-Taint 읽기 전용 좌표 오버레이 (지도 닫으면 0% CPU)",
        combatSafe = true,
    },
    {
        section = "ui",
        key = "enhanceTooltips",
        type = "boolean",
        default = true,
        label = "아이템·주문 툴팁 iLvl / ID / 상점가 / 보호 배지 표시",
        desc = "Zero-Taint 읽기 전용 후크(Forbidden 툴팁 제외)",
        combatSafe = true,
    },
    {
        section = "quest",
        key = "autoAccept",
        type = "boolean",
        default = true,
        label = "퀘스트 자동 수락 (Shift 우회 · PvP 차단)",
        desc = "NPC 대화 시 퀘스트 자동 수락",
        combatSafe = true,
    },
    {
        section = "quest",
        key = "autoTurnIn",
        type = "boolean",
        default = true,
        label = "퀘스트 자동 완료 (다중 보상 시 자동 정지)",
        desc = "보상 선택지가 1개 이하일 때만 자동 완료",
        combatSafe = true,
    },
    {
        section = "quest",
        key = "autoSuperTrack",
        type = "boolean",
        default = true,
        label = "새 퀘스트 수락 시 자동 추적 (NavPort 지연 안전)",
        desc = "전투·월드맵 중에는 지연 후 적용",
        combatSafe = true,
    },
    {
        section = "merchant",
        key = "autoRepair",
        type = "boolean",
        default = true,
        label = "상점 방문 시 자동 수리",
        desc = "Shift를 누른 채 대화하면 일시 우회",
        combatSafe = true,
    },
    {
        section = "merchant",
        key = "useGuildRepair",
        type = "boolean",
        default = true,
        label = "길드 은행 수리 우선 사용",
        desc = "불가 시 개인 골드로 안전 폴백",
        combatSafe = true,
    },
    {
        section = "merchant",
        key = "autoSellJunk",
        type = "boolean",
        default = true,
        label = "회색 잡템 자동 판매 (12개 바이백 상한)",
        desc = "/fs protect 보호 목록 제외",
        combatSafe = true,
    },
    {
        section = "combat",
        key = "buffReminder",
        type = "boolean",
        default = true,
        label = "비전투 9직업 자가 버프/무기 마부 누락 경고",
        desc = "전투 중에는 자동 숨김",
        combatSafe = true,
    },
    {
        section = "combat",
        key = "lowHealthAlert",
        type = "boolean",
        default = true,
        label = "저체력(≤30%) 생존 경고 (Secret-safe)",
        desc = "C_Secrets 반환 시 오경보 차단",
        combatSafe = true,
    },
    {
        section = "profession",
        key = "showFishingCard",
        type = "boolean",
        default = true,
        label = "낚싯대 장착 시 대상어 L1 카드 자동 표시",
        desc = "ForeverSuite_Data LoD 낚시 팩 연동",
        combatSafe = true,
    },
    {
        section = "combat",
        key = "showEncounterTimer",
        type = "boolean",
        default = true,
        label = "전투·보스·인던 타이머 & 풀링 카운트다운 HUD",
        desc = "/fs pull 10 및 /fs timer 지원",
        combatSafe = true,
    },
    {
        section = "qol",
        key = "fastLoot",
        type = "boolean",
        default = true,
        label = "고속 자동 루팅 (autoLoot CVar XOR 수정키)",
        desc = "전리품 창 열림 시 즉시 역순 획득",
        combatSafe = true,
    },
    {
        section = "qol",
        key = "autoReleaseBG",
        type = "boolean",
        default = true,
        label = "전장(BG) 전용 자동 영혼 해제 (자가 부활 시 중단)",
        desc = "영혼석/윤회 감지 시 절대 해제하지 않음",
        combatSafe = true,
    },
    {
        section = "qol",
        key = "autoAcceptRes",
        type = "boolean",
        default = true,
        label = "비전투 부활 자동 수락 (전투 부활 제외)",
        desc = "Shift 우회 가능, 전투 중에는 수락하지 않음",
        combatSafe = true,
    },
    {
        section = "qol",
        key = "autoAcceptFriends",
        type = "boolean",
        default = true,
        label = "친구·길드원 파티 초대 자동 수락",
        desc = "모르는 유저 초대는 수락하지 않음",
        combatSafe = true,
    },
    {
        section = "combat",
        key = "showThreatMeter",
        type = "boolean",
        default = true,
        label = "전투 중 위협 수준 미터 (Threat HUD · Secret-Safe)",
        desc = "비전투 자동 숨김 및 티커 정지 (네임플레이트 비간섭)",
        combatSafe = true,
    },
    {
        section = "ui",
        key = "showWorldMapPins",
        type = "boolean",
        default = true,
        label = "월드맵 캔버스 직접 핀 표시 (미수락 퀘스트 ! · NPC · 던전)",
        desc = "Zero-Taint UIParent 오버레이 핀 레이어 (3,609개 퀘스트 시작점)",
        combatSafe = true,
    },
    {
        section = "ui",
        key = "showCursorRing",
        type = "boolean",
        default = false,
        label = "마우스 커서 FX 표시 (링 / 십자선 / 30Hz 잔상 트레일)",
        desc = "비활성 시 OnUpdate 완전 정지 (0% CPU)",
        combatSafe = true,
    },
    {
        section = "ui",
        key = "cursorStyle",
        type = "enum",
        default = "ring",
        label = "마우스 커서 FX 스타일",
        desc = "골드 링 / 십자선 / 다중 잔상 트레일",
        combatSafe = true,
        options = {
            { value = "ring", label = "골드 링", width = 76 },
            { value = "crosshair", label = "십자선", width = 72 },
            { value = "trail", label = "잔상 트레일", width = 92 },
        },
    },
    {
        section = "ui",
        key = "cursorCombatOnly",
        type = "boolean",
        default = false,
        label = "마우스 커서 FX: 전투 중에만 표시",
        desc = "평시에는 숨기고 전투 진입 시에만 커서를 강조합니다",
        combatSafe = true,
    },
    {
        section = "qol",
        key = "talentReminder",
        type = "boolean",
        default = true,
        label = "미사용 특성 포인트 알림",
        desc = "접속 및 레벨업 시 남은 특성 포인트 안내",
        combatSafe = true,
    },
    {
        section = "social",
        key = "autoGreetJoin",
        type = "boolean",
        default = false,
        label = "파티 합류 시 자동 인사 (비전투 · 쿨다운 보호)",
        desc = "공격대 및 로그인/리로드 시 자동 억제",
        combatSafe = true,
    },
    {
        section = "social",
        key = "autoGreetWelcome",
        type = "boolean",
        default = false,
        label = "새 파티원 합류 시 환영 인사 (1인 합류 한정)",
        desc = "대량 합류 및 전투 중 자동 억제",
        combatSafe = true,
    },
    {
        section = "social",
        key = "autoThankBuff",
        type = "boolean",
        default = false,
        label = "단일 버프 수신 시 /감사 자동 감정표현 (기본 OFF)",
        desc = "비전투 및 비비밀 오라 확인 시에만 동작",
        combatSafe = true,
    },
    {
        section = "social",
        key = "chatKeywordAlerts",
        type = "boolean",
        default = true,
        label = "채팅 키워드 알림 토스트 (/fs kw 단어1,단어2)",
        desc = "비밀 메시지는 절대 저장·검색하지 않음",
        combatSafe = true,
    },
    {
        section = "ui",
        key = "fontPreset",
        type = "enum",
        default = "default_kr",
        label = "통합 UI 한글 폰트 프리셋",
        desc = "ForeverSuite 전용 폰트 객체에만 안전 적용",
        combatSafe = false,
        options = {
            { value = "default_kr",  label = "기본 고딕",   width = 76 },
            { value = "bold_kr",     label = "굵은 고딕",   width = 76 },
            { value = "pagetext_kr", label = "명조체",     width = 66 },
            { value = "damage_kr",   label = "전투 숫자",   width = 76 },
            { value = "clean_en",    label = "클린 고딕",   width = 76 },
            { value = "gmarket_kr",  label = "지마켓산스",  width = 82 },
            { value = "gyeonggi_kr", label = "경기천년",    width = 76 },
            { value = "gothic_a1_kr", label = "고딕A1",     width = 68 },
        },
    },
    {
        section = "ui",
        key = "fontOutline",
        type = "enum",
        default = "none",
        label = "통합 UI 폰트 외곽선",
        desc = "그림자 기본 / 얇은 외곽선 / 굵은 외곽선",
        combatSafe = false,
        options = {
            { value = "none", label = "그림자만", width = 76 },
            { value = "outline", label = "얇게", width = 64 },
            { value = "thick", label = "굵게", width = 64 },
        },
    },
    {
        section = "qol",
        key = "maxCameraZoom",
        type = "boolean",
        default = false,
        label = "최대 카메라 시야 거리 확장 (비전투 CVar)",
        desc = "cameraDistanceMaxZoomFactor = 2.6 적용",
        combatSafe = false,
    },
    {
        section = "combat",
        key = "showComboHud",
        type = "boolean",
        default = true,
        label = "콤보 포인트 HUD 표시 (도적·야성 드루이드)",
        desc = "연계 점수 보유 시에만 표시 (0점 자동 숨김)",
        combatSafe = true,
    },
    {
        section = "combat",
        key = "showRangeHud",
        type = "boolean",
        default = true,
        label = "대상 사거리 표시 HUD (근접·중거리·원거리)",
        desc = "대상 선택 시에만 표시 (미선택 시 CPU 0%)",
        combatSafe = true,
    },
    {
        section = "combat",
        key = "showShortBuffHud",
        type = "boolean",
        default = true,
        label = "단기 버프(≤30초) 만료 경고 바 표시",
        desc = "난도질·방막·보호막 등 짧은 버프 남은 초 추적",
        combatSafe = true,
    },
    {
        section = "ui",
        key = "showScreenClock",
        type = "boolean",
        default = false,
        label = "온스크린 로컬·서버 시계 HUD 표시",
        desc = "/fs move 로 위치 자유 이동 (비활성 시 CPU 0%)",
        combatSafe = true,
    },
    {
        section = "qol",
        key = "corpseGuide",
        type = "boolean",
        default = true,
        label = "사망 시 내 시체 위치 자동 /way 화살표 안내",
        desc = "C_DeathInfo 좌표 자동 연결, 부활 시 자동 해제",
        combatSafe = true,
    },
    {
        section = "social",
        key = "questAnnounceParty",
        type = "boolean",
        default = false,
        label = "파티 채널에 퀘스트 목표·완료 자동 알림 (기본 OFF)",
        desc = "비전투 파티 한정 (공격대·로그인 시 자동 억제)",
        combatSafe = true,
    },
    {
        section = "ui",
        key = "cursorTooltip",
        type = "boolean",
        default = false,
        label = "마우스 커서 위치에 툴팁 표시 (CursorTooltip)",
        desc = "비전투 시 기본 툴팁을 커서 옆에 고정합니다",
        combatSafe = true,
    },
    {
        section = "ui",
        key = "tooltipItemSources",
        type = "boolean",
        default = true,
        label = "툴팁에 던전 드랍처 · BiS 추천 · 전문기술 재료 출처 표시",
        desc = "로드된 LoD 도감에서 아이템 출처를 자동 표시",
        combatSafe = true,
    },
    {
        section = "ui",
        key = "tooltipTranslation",
        type = "boolean",
        default = true,
        label = "아이템·툴팁 영한 번역 보조 표시",
        desc = "ForeverSuite_Data_Items 영한 번역 사전 연동",
        combatSafe = true,
    },
    {
        section = "ui",
        key = "showDungeonQuickLoot",
        type = "boolean",
        default = true,
        label = "던전 내부 빠른 드랍 팝업 버튼 표시",
        desc = "던전 입장 시 1클릭 보스 드랍 확인 버튼 표시",
        combatSafe = true,
    },
    {
        section = "ui",
        key = "showRollPreview",
        type = "boolean",
        default = true,
        label = "전리품 주사위 굴림 시 iLvl·BiS 미리보기 토스트",
        desc = "착용 장비 대비 업그레이드·BiS 여부 즉시 안내",
        combatSafe = true,
    },
    {
        section = "ui",
        key = "navArrowStyle",
        type = "enum",
        default = "roundedClassic",
        label = "내비게이션 화살표 스타일 (12-레이어 3D 사틴 / 갓존스)",
        desc = "3D클래식(기본) / 3D쐐기 / 3D나침반 / 갓존스 황금 / 문장 / 심플",
        combatSafe = true,
        options = {
            { value = "roundedClassic", label = "3D클래식", width = 66 },
            { value = "roundedWedge",   label = "3D쐐기",   width = 58 },
            { value = "roundedCompass", label = "3D나침반", width = 66 },
            { value = "gold_classic",   label = "갓존스",   width = 56 },
            { value = "crest",          label = "문장",     width = 48 },
            { value = "minimal",        label = "심플",     width = 48 },
        },
    },
    {
        section = "ui",
        key = "worldMapReveal",
        type = "boolean",
        default = false,
        label = "월드맵 미탐험 지역 안개 밝히기 오버레이 (Zero-Taint)",
        desc = "UIParent 오버레이 레이어에 미탐험 구역 표시",
        combatSafe = true,
    },
    {
        section = "ui",
        key = "worldMapHeatmap",
        type = "boolean",
        default = false,
        label = "월드맵 채집(약초·광맥) 밀도 히트맵 표시",
        desc = "ForeverSuite_Data_MapExtra 채집 밀도 오버레이",
        combatSafe = true,
    },
    {
        section = "ui",
        key = "worldMapPetHeatmap",
        type = "boolean",
        default = false,
        label = "월드맵 사냥꾼 야수 출현 밀도 히트맵 표시",
        desc = "ForeverSuite_Data_MapExtra 야수 출현 밀도 오버레이",
        combatSafe = true,
    },
    {
        section = "profession",
        key = "fishingDoubleClick",
        type = "boolean",
        default = true,
        label = "낚싯대 장착 시 비전투 더블 우클릭 자동 낚시 시전",
        desc = "물 위 빈 곳 더블 우클릭 자동 시전 (SecureActionButton · 전투 시 자동 해제)",
        combatSafe = false,
    },
    {
        section = "quest",
        key = "collectionAlerts",
        type = "boolean",
        default = true,
        label = "퀘스트 수집 완료 배너 및 알림음 표시",
        desc = "퀘스트 목표 완료 시 토스트·알림음 안내",
        combatSafe = true,
    },
    {
        section = "quest",
        key = "partyQuestSync",
        type = "boolean",
        default = true,
        label = "파티원 퀘스트 진행도 동기화 (FSQuest4 애드온 메시지)",
        desc = "비전투 파티 한정 15초 쓰로틀 동기화",
        combatSafe = true,
    },
    {
        section = "quest",
        key = "proximityAlerts",
        type = "boolean",
        default = true,
        label = "근처 퀘스트 대화·보고 목표 접근 알림",
        desc = "진행 중인 퀘스트 특수 목표 근접 시 안내",
        combatSafe = true,
    },
    {
        section = "qol",
        key = "growthAlerts",
        type = "boolean",
        default = true,
        label = "레벨업·구간별 성장 이정표 알림 (GrowthAlert)",
        desc = "10/15/20/30/40/50/60 주요 해금 콘텐츠 안내",
        combatSafe = true,
    },
    {
        section = "social",
        key = "partyWatchAlerts",
        type = "boolean",
        default = true,
        label = "파티 찾기 관심 던전·단어 팝업 알림 (/fs watch 단어)",
        desc = "허브가 닫혀 있어도 일치 모집글 즉시 알림",
        combatSafe = true,
    },
    {
        section = "social",
        key = "showChatButtons",
        type = "boolean",
        default = false,
        label = "채팅 빠른 채널 버튼 바 표시 ([일반][파티][공대][길드][파찾])",
        desc = "/fs move 로 위치 이동 가능",
        combatSafe = true,
    },
    {
        section = "combat",
        key = "showProcAlerts",
        type = "boolean",
        default = true,
        label = "전투 발동(Proc) 경보 배너 HUD (일몰·화살탄막·청명 등)",
        desc = "발동 버프 감지 시 화면 배너·알림음 표시",
        combatSafe = true,
    },
    {
        section = "combat",
        key = "showSkillCooldowns",
        type = "boolean",
        default = true,
        label = "직업 주요 쿨다운 추적 HUD (SkillCooldowns)",
        desc = "재사용 대기 중인 주요 생존기·공격기 남은 초 표시",
        combatSafe = true,
    },
    {
        section = "ui",
        key = "cursorColor",
        type = "enum",
        default = "gold",
        label = "마우스 커서 FX 색상",
        desc = "골드 / 시안 / 에메랄드 / 크림슨",
        combatSafe = true,
        options = {
            { value = "gold",    label = "골드",    width = 62 },
            { value = "cyan",    label = "시안",    width = 62 },
            { value = "emerald", label = "에메랄드", width = 76 },
            { value = "crimson", label = "크림슨",  width = 68 },
        },
    },
    {
        section = "ui",
        key = "cursorSize",
        type = "enum",
        default = "medium",
        label = "마우스 커서 FX 크기",
        desc = "소(24px) / 중(34px) / 대(46px)",
        combatSafe = true,
        options = {
            { value = "small",  label = "소형", width = 58 },
            { value = "medium", label = "중형", width = 58 },
            { value = "large",  label = "대형", width = 58 },
        },
    },
    {
        section = "ui",
        key = "cursorAlpha",
        type = "enum",
        default = "100",
        label = "마우스 커서 FX 투명도",
        desc = "50% / 75% / 100%",
        combatSafe = true,
        options = {
            { value = "50",  label = "50%",  width = 56 },
            { value = "75",  label = "75%",  width = 56 },
            { value = "100", label = "100%", width = 56 },
        },
    },
    {
        section = "ui",
        key = "alertSoundKey",
        type = "enum",
        default = "dingdong",
        label = "통합 알림음 선택 (ForeverSuite_Media_Assets)",
        desc = "띵동 / 하이톤 오이쉬 / 돈통소리 / 빅토리 / 경보 / 끄기",
        combatSafe = true,
        options = {
            { value = "dingdong",       label = "띵동",    width = 56 },
            { value = "oishii_high",    label = "오이쉬",  width = 62 },
            { value = "cash",           label = "돈통",    width = 56 },
            { value = "victory",        label = "빅토리",  width = 62 },
            { value = "quest_complete", label = "퀘완료",  width = 62 },
            { value = "none",           label = "무음",    width = 52 },
        },
    },
    {
        section = "qol",
        key = "captureLuaErrors",
        type = "boolean",
        default = false,
        label = "인앱 Lua 오류 로그 캡처 활성화 (BugSack 공존)",
        desc = "진단 페이지에서 최근 30건 오류 리포트 복사 지원",
        combatSafe = true,
    },
    {
        section = "ui",
        key = "uiTheme",
        type = "enum",
        default = "gold",
        label = "ForeverSuite 통합 UI 테마 (즉시 전환 · 리로드 불필요)",
        desc = "Forever Gold (갓존스·DialogueUI풍) / Midnight Dark (클린 다크)",
        combatSafe = true,
        options = {
            { value = "gold", label = "Forever Gold", width = 110 },
            { value = "dark", label = "Midnight Dark", width = 114 },
        },
    },
    {
        section = "ui",
        key = "textureBrightness",
        type = "number",
        default = 0.78,
        min = 0.35,
        max = 1.00,
        step = 0.05,
        label = "UI 표면 질감 밝기 (InkUV 0.35 ~ 1.00)",
        desc = "차콜·가죽 표면 밝기를 모니터 환경에 맞춰 미세 조절합니다",
        combatSafe = true,
    },
    {
        section = "ui",
        key = "goldBrightness",
        type = "number",
        default = 0.88,
        min = 0.40,
        max = 1.00,
        step = 0.05,
        label = "UI 골드 테두리·강조 밝기 (0.40 ~ 1.00)",
        desc = "금장 테두리와 강조선 밝기 (본문 골드 대비 7:1 이상 자동 보정)",
        combatSafe = true,
    },
    {
        section = "ui",
        key = "reducedMotion",
        type = "boolean",
        default = false,
        label = "모션 줄이기 (Reduced Motion · 모든 전환 0ms 즉시 적용)",
        desc = "창 페이드인과 탭 슬라이드 애니메이션을 비활성화합니다",
        combatSafe = true,
    },
    {
        section = "quest",
        key = "compactMode",
        type = "boolean",
        default = false,
        label = "퀘스트 추적기 3+1 축약 모드 (중요 3개 + 나머지 요약)",
        desc = "화면 시야 확보를 위해 상위 3개 퀘스트와 +N 요약만 표시합니다",
        combatSafe = true,
    },
}

local Bootstrap = {
    initialized = false,
}
ns.Features.Bootstrap = Bootstrap

local function ApplyTrackerModeSafely(requestedMode)
    ns.Blizzard.ObjectiveTrackerAdapter:ApplyMode(requestedMode or "hide")
end

local function RecordTaintEvent(kind, addonName, funcName)
    if not ns.Api.ProfileStore:CanWrite() then
        return
    end
    local diag = ns.Api.ProfileStore.db.v2.diagnostics
    local a = ns.Api.SafeAPI.IsSecret(addonName) and "SECRET" or tostring(addonName or "UNKNOWN")
    local f = ns.Api.SafeAPI.IsSecret(funcName) and "SECRET" or tostring(funcName or "UNKNOWN")
    local k = kind .. ":" .. a .. ":" .. f
    diag.taintTotal = (diag.taintTotal or 0) + 1
    if diag.taintCounts[k] ~= nil then
        diag.taintCounts[k] = diag.taintCounts[k] + 1
    else
        local keyCount = 0
        for _ in pairs(diag.taintCounts) do
            keyCount = keyCount + 1
        end
        if keyCount < MAX_TAINT_KEYS then
            diag.taintCounts[k] = 1
        end
    end
end

function Bootstrap:Init()
    if self.initialized then
        return
    end

    ns.Api.ProfileStore:RegisterSchema(DEFAULT_SCHEMAS)
    ns.Api.ProfileStore:Init()
    -- Phase 1 (C7): Recover any crash-interrupted CVar mutations before mounting features
    ns.Api.ProfileStore:RestoreCvarJournal(function(k, fn)
        return ns.Secure.CombatQueue:RunOrDefer(k, fn)
    end)

    -- Phase 4 (Coexistence Resolve - must precede Secure/UI/Feature mount)
    if ns.Bridges and ns.Bridges.BridgeHost then
        if ns.Bridges.Baganator then
            ns.Bridges.Baganator:SetProviders({
                badge = function(itemID)
                    if ns.Features.TooltipEnhanceModule then
                        if ns.Features.TooltipEnhanceModule.bisIndex and ns.Features.TooltipEnhanceModule.bisIndex[itemID] then
                            return { text = "BiS", r = 0.33, g = 0.83, b = 0.42 }
                        end
                        if ns.Features.TooltipEnhanceModule.profMatIndex and ns.Features.TooltipEnhanceModule.profMatIndex[itemID] then
                            return { text = "재료", r = 0.90, g = 0.76, b = 0.36 }
                        end
                    end
                    return nil
                end,
                cheapAction = function()
                    if ns.Features.MerchantModule then
                        ns.Features.MerchantModule:PrintCheapestItems()
                    end
                end,
            })
        end
        if ns.Bridges.DialogueUI then
            ns.Bridges.DialogueUI:SetProviders({
                evaluator = function(itemLink)
                    local itemID = tonumber(string_match(itemLink or "", "item:(%d+)"))
                    if itemID and ns.Features.TooltipEnhanceModule and ns.Features.TooltipEnhanceModule.bisIndex then
                        local bis = ns.Features.TooltipEnhanceModule.bisIndex[itemID]
                        if bis then
                            return true, "ForeverSuite BiS: " .. tostring(bis)
                        end
                    end
                    return false, nil
                end,
                translator = function(questID)
                    local packs = _G.ForeverSuiteData and _G.ForeverSuiteData.packs
                    local qt = packs and packs.quest_tips and packs.quest_tips.entries
                    if type(qt) == "table" then
                        for i = 1, #qt do
                            local rec = qt[i]
                            if rec and rec.questID == questID and type(rec.title) == "string" and rec.title ~= "" then
                                return { title = rec.title, description = rec.note }
                            end
                        end
                    end
                    return nil
                end,
            })
        end
        if ns.Bridges.Spoken and ns.Api.GameAdapters and type(ns.Api.GameAdapters.SetAudioDuckPredicate) == "function" then
            ns.Api.GameAdapters.SetAudioDuckPredicate(function(isSurvivalAlert)
                return ns.Bridges.Spoken:ShouldDuckAudio(isSurvivalAlert)
            end)
        end
        local bridgeOverrides = ns.Api.ProfileStore:GetState("bridgeOverrides")
        ns.Bridges.BridgeHost:SetScheduler(ns.Api.GameAdapters.RunAfter)
        ns.Bridges.BridgeHost:ResolveAll(bridgeOverrides, {
            playerClass = ns.Api.GameAdapters.GetPlayerClass(),
        })
    end

    if ns.UI and ns.UI.Tokens and type(ns.UI.Tokens.SetTheme) == "function" then
        ns.UI.Tokens.SetTheme(ns.Api.ProfileStore:Get("ui", "uiTheme") or "gold")
        if type(ns.UI.Tokens.SetBrightness) == "function" then
            ns.UI.Tokens.SetBrightness(
                ns.Api.ProfileStore:Get("ui", "textureBrightness"),
                ns.Api.ProfileStore:Get("ui", "goldBrightness")
            )
        end
    end
    if ns.UI and ns.UI.Motion and type(ns.UI.Motion.SetReducedMotion) == "function" then
        ns.UI.Motion.SetReducedMotion(ns.Api.ProfileStore:Get("ui", "reducedMotion") == true)
    end

    -- Register L2 Command Hub workspace pages (v3.0 4-Group Unified Hub; Home is default landing)
    ns.UI.CommandHub:RegisterPage(ns.Features.HomePage)
    ns.UI.CommandHub:RegisterPage(ns.Features.PartyFinderPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.QuestGuidePage)
    ns.UI.CommandHub:RegisterPage(ns.Features.DungeonBrowserPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.BiSBrowserPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.CodexPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.ProfessionPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.UtilitiesPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.LedgerPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.SettingsPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.FontsPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.DiagnosticsPage)

    ns.Blizzard.WorldMapAdapter:Init()

    local mode = ns.Api.ProfileStore:Get("quest", "defaultTrackerMode") or "hide"
    ApplyTrackerModeSafely(mode)

    ns.Api.EventBus:Subscribe("hud:layout_locked", function()
        ns.Features.CombatHudPack:RefreshAll()
        ns.Features.ThreatMeterHud:Refresh()
        ns.Features.FishingCardHud:Refresh()
        ns.Features.NavigationHud:Refresh()
        ns.Features.CombatAssistHud:Refresh()
        ns.Features.EncounterTimerHud:Refresh()
        ns.Features.StatusPillHud:ApplyVisibility()
    end)

    ns.Api.EventBus:Subscribe("hud:layout_unlocked", function()
        if ns.Secure and ns.Secure.FishingCastButton and type(ns.Secure.FishingCastButton.SyncDock) == "function" then
            ns.Secure.FishingCastButton:SyncDock(ns.Features.FishingCardHud and ns.Features.FishingCardHud.card, false, nil)
        end
    end)
    ns.Api.EventBus:Subscribe("hud:layout_locked", function()
        if ns.Features.FishingCardHud and ns.Features.FishingCardHud.visible then
            ns.Features.FishingCardHud:Refresh()
        end
    end)
    ns.Api.EventBus:Subscribe("setting:changed", function(sec, key, val)
        if sec == "quest" and key == "defaultTrackerMode" then
            ns.Api.ProfileStore:SetState("userExplicitTrackerMode", true)
            ApplyTrackerModeSafely(val)
        elseif sec == "quest" and (key == "groupMode" or key == "currentZoneOnly" or key == "trackerMinimized" or key == "trackerLocked" or key == "compactMode") then
            ns.Features.QuestTrackerView:RefreshLive()
        elseif sec == "quest" and key == "combatFade" then
            ns.Features.QuestTrackerView:UpdateCombatVisuals()
        elseif sec == "quest" and key == "proximityAlerts" then
            ns.Features.QuestExtraModule:SyncProximityTicker()
        elseif sec == "ui" and key == "uiTheme" then
            if ns.UI and ns.UI.Tokens and type(ns.UI.Tokens.SetTheme) == "function" then
                ns.UI.Tokens.SetTheme(val)
            end
        elseif sec == "ui" and (key == "textureBrightness" or key == "goldBrightness") then
            if ns.UI and ns.UI.Tokens and type(ns.UI.Tokens.SetBrightness) == "function" then
                ns.UI.Tokens.SetBrightness(
                    ns.Api.ProfileStore:Get("ui", "textureBrightness"),
                    ns.Api.ProfileStore:Get("ui", "goldBrightness")
                )
            end
        elseif sec == "ui" and key == "reducedMotion" then
            if ns.UI and ns.UI.Motion and type(ns.UI.Motion.SetReducedMotion) == "function" then
                ns.UI.Motion.SetReducedMotion(val == true)
            end
        elseif sec == "ui" and key == "showStatusPill" then
            ns.Features.StatusPillHud:ApplyVisibility()
        elseif sec == "ui" and key == "showQuickDock" then
            ns.Features.QuickDockHud:ApplyVisibility()
        elseif sec == "ui" and (key == "showWorldMapOverlay" or key == "showWorldMapPins" or key == "worldMapReveal" or key == "worldMapHeatmap" or key == "worldMapPetHeatmap") then
            ns.Features.WorldMapOverlay:ApplyVisibility()
        elseif sec == "ui" and key == "showMinimapButton" then
            ns.Features.MinimapButton:ApplyVisibility()
        elseif sec == "ui" and (key == "showCursorRing" or key == "cursorStyle" or key == "cursorCombatOnly" or key == "cursorColor" or key == "cursorSize" or key == "cursorAlpha") then
            ns.Features.CursorTrailHud:ApplyVisibility()
        elseif sec == "ui" and key == "navArrowStyle" then
            ns.Features.NavigationHud:Refresh()
        elseif sec == "ui" and key == "showScreenClock" then
            ns.Features.CombatHudPack:RefreshClock()
        elseif sec == "ui" and (key == "fontPreset" or key == "fontOutline") then
            ns.Features.FontsPage:ApplySavedFonts()
        elseif sec == "social" and key == "showChatButtons" then
            ns.Features.ChatToolsModule:RefreshChannelBar()
        elseif sec == "combat" and key == "showThreatMeter" then
            ns.Features.ThreatMeterHud:Refresh()
        elseif sec == "combat" and key == "showEncounterTimer" then
            ns.Features.EncounterTimerHud:Refresh()
        elseif sec == "combat" and (key == "showProcAlerts" or key == "showSkillCooldowns") then
            ns.Features.ProcCooldownHud:RefreshProcs()
            ns.Features.ProcCooldownHud:RefreshCooldowns()
        elseif sec == "combat" and (key == "showComboHud" or key == "showRangeHud" or key == "showShortBuffHud") then
            ns.Features.CombatHudPack:RefreshAll()
        elseif sec == "combat" then
            ns.Features.CombatAssistHud:Refresh()
        elseif sec == "profession" and (key == "showFishingCard" or key == "fishingDoubleClick") then
            ns.Features.FishingCardHud:Refresh()
        elseif sec == "qol" and key == "captureLuaErrors" then
            ns.Features.DiagnosticsPage:InstallErrorCaptureIfEnabled()
        elseif sec == "qol" and key == "corpseGuide" then
            ns.Features.CorpseGuideModule:Refresh()
        elseif sec == "qol" and key == "maxCameraZoom" then
            ns.Features.QoLModule:ApplyCameraZoomIfEnabled()
        end
    end)

    -- Initialize L0/L1 HUDs & Zero-Taint adapters
    ns.Features.QuestTrackerView:Init()
    ns.Features.QuestTrackerView:RefreshLive()
    ns.Features.WorldMapOverlay:Init()
    ns.Features.StatusPillHud:Init()
    ns.Features.NavigationHud:Init()
    ns.Features.NavigationHud:SyncSuperTrackedQuest(false)
    ns.Features.CombatAssistHud:Init()
    ns.Features.CombatAssistHud:Refresh()
    ns.Features.ThreatMeterHud:Init()
    ns.Features.CursorTrailHud:Init()
    ns.Features.CombatHudPack:Init()
    ns.Features.ProcCooldownHud:Init()
    ns.Features.EncounterTimerHud:Init()
    ns.Features.EncounterTimerHud:OnZoneOrInstanceChanged()
    ns.Features.FishingCardHud:Init()
    ns.Features.FishingCardHud:Refresh()
    ns.Features.QuickDockHud:Init()
    ns.Features.MinimapButton:Init()
    ns.Features.TooltipEnhanceModule:Init()
    ns.Features.ChatToolsModule:Init()
    ns.Features.QuestExtraModule:Init()
    ns.Features.DiagnosticsPage:InstallErrorCaptureIfEnabled()
    ns.Features.AutoGreetingModule:SyncInitialRoster()
    ns.Features.FontsPage:ApplySavedFonts()
    ns.Features.LedgerPage:SyncFromPlayerMoney()
    ns.Features.UtilitiesPage:LoadSavedGdkp()
    ns.Features.UtilitiesPage:LoadSavedBookmarks()
    ns.Features.UtilitiesPage:RecordCurrentCharacter()
    ns.Features.TradeLogModule:LoadSaved()
    ns.Features.TradeLogModule:ResetFarm()
    ns.Features.QuestAnnounceModule:OnQuestLogUpdate()
    ns.Features.DungeonBrowserPage:OnInstanceChanged()
    ns.Features.QoLModule:ResetSessionXP()
    ns.Features.QoLModule:ApplyCameraZoomIfEnabled()
    ns.Features.CharacterDockPanel:Init()

    -- Phase 3: Wire Director 5-State Morphing non-secure HUD channels, scheduler & live signal sync
    local directorInDialogue = false
    local function CollectDirectorSignals(combatOverride)
        local inCombat
        if combatOverride == nil then
            inCombat = ns.Api.SafeAPI.InCombat() and true or false
        else
            inCombat = combatOverride == true
        end
        return {
            isEditOverride  = (ns.UI.HudLayout and ns.UI.HudLayout:IsUnlocked()) and true or false,
            inCombat        = inCombat,
            isDeadOrGhost   = ns.Api.GameAdapters.IsPlayerDeadOrGhost() == true,
            isFeignDeath    = (ns.Api.GameAdapters.IsPlayerFeignDeath and ns.Api.GameAdapters.IsPlayerFeignDeath()) and true or false,
            hasFishingPole  = (
                (ns.Api.GameAdapters.IsFishingPoleEquipped and ns.Api.GameAdapters.IsFishingPoleEquipped())
                or (ns.Features.FishingCardHud and ns.Features.FishingCardHud.pinned == true)
            ) and true or false,
            isMounted       = (ns.Api.GameAdapters.IsPlayerMounted and ns.Api.GameAdapters.IsPlayerMounted()) and true or false,
            isDialogueShown = directorInDialogue == true,
        }
    end
    local function SyncDirectorState(combatOverride, forceImmediate)
        if not (ns.UI and ns.UI.Director) then return end
        ns.UI.Director:ApplySignals(CollectDirectorSignals(combatOverride), forceImmediate)
    end
    if ns.UI and ns.UI.Director then
        ns.UI.Director:SetScheduler(ns.Api.GameAdapters.RunAfter)
        ns.UI.Director:SetSignalProvider(function() return CollectDirectorSignals(nil) end)
        if ns.Features.QuestTrackerView.container then ns.UI.Director:RegisterChannel("questTracker", ns.Features.QuestTrackerView.container) end
        if ns.Features.NavigationHud.card then ns.UI.Director:RegisterChannel("navArrow", ns.Features.NavigationHud.card) end
        if ns.Features.FishingCardHud.card then ns.UI.Director:RegisterChannel("fishingCard", ns.Features.FishingCardHud.card) end
        if ns.Features.StatusPillHud.card then ns.UI.Director:RegisterChannel("statusPill", ns.Features.StatusPillHud.card) end
        if ns.Features.CombatAssistHud.strip then ns.UI.Director:RegisterChannel("combatAssist", ns.Features.CombatAssistHud.strip) end
        SyncDirectorState(nil, true)
    end

    -- Lifecycle & Feature event wiring
    ns.Api.EventBus:OnEvent("v2:addonLoaded", "ADDON_LOADED", function(_, addonName)
        if ns.Bridges and ns.Bridges.BridgeHost and type(addonName) == "string" then
            ns.Bridges.BridgeHost:OnAddonLoaded(addonName)
        end
        ns.Blizzard.WorldMapAdapter:Init()
        ApplyTrackerModeSafely(ns.Api.ProfileStore:Get("quest", "defaultTrackerMode") or "hide")
    end)
    local function RefreshHomeIfVisible()
        if ns.UI and ns.UI.CommandHub and ns.UI.CommandHub.activePageId == "home"
            and ns.UI.CommandHub.window and type(ns.UI.CommandHub.window.IsShown) == "function"
            and ns.UI.CommandHub.window:IsShown()
            and ns.Features.HomePage and type(ns.Features.HomePage.OnShow) == "function"
        then
            ns.Features.HomePage:OnShow()
        end
    end

    ns.Api.EventBus:OnEvent("v2:enterWorld", "PLAYER_ENTERING_WORLD", function()
        ApplyTrackerModeSafely(ns.Api.ProfileStore:Get("quest", "defaultTrackerMode") or "hide")
        ns.Features.EncounterTimerHud:OnZoneOrInstanceChanged()
        ns.Features.DungeonBrowserPage:OnInstanceChanged()
        ns.Features.ThreatMeterHud:Refresh()
        ns.Features.QoLModule:SyncSessionXP()
        ns.Features.AutoGreetingModule:SyncInitialRoster()
        ns.Features.CharacterAssistModule:CheckTalents(false)
        ns.Features.UtilitiesPage:RecordCurrentCharacter()
        ns.Features.NavigationHud:SyncSuperTrackedQuest(false)
        directorInDialogue = false
        SyncDirectorState(nil, true)
        RefreshHomeIfVisible()
    end)
    ns.Api.EventBus:OnEvent("v2:questWatchChanged", "QUEST_WATCH_LIST_CHANGED", function()
        ApplyTrackerModeSafely(ns.Api.ProfileStore:Get("quest", "defaultTrackerMode") or "hide")
    end)
    ns.Api.EventBus:OnEvent("v2:levelUpTracker", "PLAYER_LEVEL_UP", function()
        ns.Features.QuestTrackerView:RefreshLive()
        if ns.Features.WorldMapOverlay and type(ns.Features.WorldMapOverlay.InvalidatePinCache) == "function" then
            ns.Features.WorldMapOverlay:InvalidatePinCache()
        end
        RefreshHomeIfVisible()
    end)
    ns.Api.EventBus:OnEvent("v2:groupRoster", "GROUP_ROSTER_UPDATE", function()
        ns.Features.AutoGreetingModule:OnGroupRosterUpdate()
    end)
    ns.Api.EventBus:OnEvent("v2:charPoints", "CHARACTER_POINTS_CHANGED", function()
        ns.Features.CharacterAssistModule:CheckTalents(false)
    end)
    ns.Api.EventBus:OnEvent("v2:questLog", "QUEST_LOG_UPDATE", function()
        ns.Features.QuestTrackerView:RefreshLive()
        ns.Features.QuestAnnounceModule:OnQuestLogUpdate()
        ns.Features.QuestExtraModule:CheckCollectionAlerts()
        ns.Features.QuestExtraModule:BroadcastPartyQuestSync(false)
        ns.Features.QuestExtraModule:SyncProximityTicker()
        if ns.Features.WorldMapOverlay and type(ns.Features.WorldMapOverlay.InvalidatePinCache) == "function" then
            ns.Features.WorldMapOverlay:InvalidatePinCache()
        end
        ns.Features.NavigationHud:OnQuestLogUpdate()
    end)
    ns.Api.EventBus:OnEvent("v2:superTrack", "SUPER_TRACKING_CHANGED", function()
        ns.Features.QuestTrackerView:RefreshLive()
        ns.Features.NavigationHud:SyncSuperTrackedQuest(false)
    end)
    ns.Api.EventBus:OnEvent("v2:bags", "BAG_UPDATE_DELAYED", function()
        ns.Features.StatusPillHud:RefreshLive()
        ns.Features.ProfessionPage:RecordBagBankMaterials(false)
        ns.Features.QuestExtraModule:CheckCollectionAlerts()
        if ns.Features.FishingCardHud and ns.Features.FishingCardHud.visible then
            ns.Features.FishingCardHud:Refresh()
        end
    end)
    ns.Api.EventBus:OnEvent("v6:fishLoot", "CHAT_MSG_LOOT", function(_, msg)
        if ns.Api.SafeAPI.IsSecret(msg) then return end
        if ns.Features.FishingCardHud and ns.Features.FishingCardHud.visible then
            ns.Features.FishingCardHud:OnLootMessage(msg)
        end
    end)
    ns.Api.EventBus:OnEvent("v6:logoutCleanup", "PLAYER_LOGOUT", function()
        if ns.Features.FishingCardHud then
            if ns.Features.FishingCardHud.soundBoost then
                ns.Features.FishingCardHud:ToggleSoundBoost(false)
            end
            if ns.Features.FishingCardHud.oneKeyInteract then
                ns.Features.FishingCardHud:ToggleOneKeyInteract(false)
            end
        end
    end)
    ns.Api.EventBus:OnEvent("v4:bankOpen", "BANKFRAME_OPENED", function()
        ns.Features.ProfessionPage:RecordBagBankMaterials(true)
    end)
    ns.Api.EventBus:OnEvent("v4:lootRoll", "START_LOOT_ROLL", function(_, rollID)
        ns.Features.DungeonBrowserPage:OnStartLootRoll(rollID)
    end)
    ns.Api.EventBus:OnEvent("v4:spellCd", "SPELL_UPDATE_COOLDOWN", function()
        ns.Features.ProcCooldownHud:RefreshCooldowns()
    end)
    ns.Api.EventBus:OnEvent("v2:durability", "UPDATE_INVENTORY_DURABILITY", function()
        ns.Features.StatusPillHud:RefreshLive()
        ns.Features.MerchantModule:ResolvePendingGuildRepair("event")
    end)
    ns.Api.EventBus:OnEvent("v2:money", "PLAYER_MONEY", function()
        ns.Features.StatusPillHud:RefreshLive()
        ns.Features.LedgerPage:SyncFromPlayerMoney()
        ns.Features.UtilitiesPage:RecordCurrentCharacter()
    end)
    ns.Api.EventBus:OnEvent("v2:merchantShow", "MERCHANT_SHOW", function()
        ns.Features.MerchantModule:OnMerchantShow()
    end)
    ns.Api.EventBus:OnEvent("v2:merchantClose", "MERCHANT_CLOSED", function()
        ns.Features.MerchantModule:OnMerchantClosed()
    end)
    ns.Api.EventBus:OnEvent("v2:qDetail", "QUEST_DETAIL", function()
        ns.Features.QuestAutomation:OnQuestDetail()
        directorInDialogue = true
        SyncDirectorState(nil, false)
    end)
    ns.Api.EventBus:OnEvent("v6:gossipShow", "GOSSIP_SHOW", function()
        directorInDialogue = true
        SyncDirectorState(nil, false)
    end)
    ns.Api.EventBus:OnEvent("v6:gossipClosed", "GOSSIP_CLOSED", function()
        directorInDialogue = false
        SyncDirectorState(nil, false)
    end)
    ns.Api.EventBus:OnEvent("v6:qFinished", "QUEST_FINISHED", function()
        directorInDialogue = false
        SyncDirectorState(nil, false)
    end)
    ns.Api.EventBus:OnEvent("v6:mountChanged", "PLAYER_MOUNT_DISPLAY_CHANGED", function()
        SyncDirectorState(nil, false)
    end)
    ns.Api.EventBus:OnEvent("v2:qProgress", "QUEST_PROGRESS", function()
        ns.Features.QuestAutomation:OnQuestProgress()
        directorInDialogue = true
        SyncDirectorState(nil, false)
    end)
    ns.Api.EventBus:OnEvent("v2:qComplete", "QUEST_COMPLETE", function()
        ns.Features.QuestAutomation:OnQuestComplete()
        directorInDialogue = true
        SyncDirectorState(nil, false)
    end)
    ns.Api.EventBus:OnEvent("v6:qGreeting", "QUEST_GREETING", function()
        directorInDialogue = true
        SyncDirectorState(nil, false)
    end)
    ns.Api.EventBus:OnEvent("v2:qAccepted", "QUEST_ACCEPTED", function(_, a1, a2)
        if ns.Api.SafeAPI.IsSecret(a1) or ns.Api.SafeAPI.IsSecret(a2) then return end
        local qid = (type(a2) == "number") and a2 or a1
        if type(qid) == "number" and qid > 0 then
            ns.Features.QuestAutomation:OnQuestAccepted(qid)
        end
    end)
    ns.Api.EventBus:OnEvent("v2:lootReady", "LOOT_READY", function()
        ns.Features.QoLModule:OnLootReady()
    end)
    ns.Api.EventBus:OnEvent("v2:playerDead", "PLAYER_DEAD", function()
        ns.Features.EncounterTimerHud:OnPlayerDead()
        ns.Features.QoLModule:OnPlayerDead()
        ns.Features.CorpseGuideModule:OnPlayerDead()
        SyncDirectorState(nil, false)
    end)
    ns.Api.EventBus:OnEvent("v2:playerAlive", "PLAYER_ALIVE", function()
        ns.Features.EncounterTimerHud:OnZoneOrInstanceChanged()
        -- PLAYER_ALIVE also fires when releasing spirit to ghost: Refresh() keeps guiding while ghost and clears when alive
        ns.Features.CorpseGuideModule:Refresh()
        SyncDirectorState(nil, false)
    end)
    ns.Api.EventBus:OnEvent("v2:playerUnghost", "PLAYER_UNGHOST", function()
        ns.Features.EncounterTimerHud:OnZoneOrInstanceChanged()
        ns.Features.CorpseGuideModule:OnPlayerRevived()
        SyncDirectorState(nil, false)
    end)
    ns.Api.EventBus:OnEvent("v2:resRequest", "RESURRECT_REQUEST", function(_, casterName)
        ns.Features.QoLModule:OnResurrectRequest(casterName)
    end)
    ns.Api.EventBus:OnEvent("v2:partyInvite", "PARTY_INVITE_REQUEST", function(_, inviterName)
        ns.Features.QoLModule:OnPartyInviteRequest(inviterName)
    end)
    ns.Api.EventBus:OnEvent("v2:xpUpdate", "PLAYER_XP_UPDATE", function()
        ns.Features.QoLModule:SyncSessionXP()
    end)
    ns.Api.EventBus:OnEvent("v2:levelUp", "PLAYER_LEVEL_UP", function(_, newLevel)
        ns.Features.QoLModule:SyncSessionXP()
        ns.Features.CharacterAssistModule:CheckTalents(true)
        ns.Features.UtilitiesPage:RecordCurrentCharacter()
        ns.Features.QuestExtraModule:CheckGrowthMilestone(newLevel)
    end)
    ns.Api.EventBus:OnEvent("v2:encStart", "ENCOUNTER_START", function(_, _, encounterName)
        ns.Features.EncounterTimerHud:OnEncounterStart(encounterName)
    end)
    ns.Api.EventBus:OnEvent("v2:encEnd", "ENCOUNTER_END", function(_, _, encounterName, _, _, success)
        ns.Features.EncounterTimerHud:OnEncounterEnd(encounterName, success)
        ns.Features.DungeonBrowserPage:OnBossKilled(encounterName, success)
    end)
    ns.Api.EventBus:OnEvent("v2:aura", "UNIT_AURA", function(_, unit)
        if ns.Api.SafeAPI.IsSecret(unit) then return end
        if unit == "player" then
            ns.Features.CombatAssistHud:Refresh()
            ns.Features.CombatHudPack:RefreshShortBuffs()
            ns.Features.ProcCooldownHud:RefreshProcs()
            ns.Features.AutoGreetingModule:OnPlayerAuraChanged()
        end
    end)
    ns.Api.EventBus:OnEvent("v2:power", "UNIT_POWER_UPDATE", function(_, unit)
        if ns.Api.SafeAPI.IsSecret(unit) then return end
        if unit == "player" then ns.Features.CombatHudPack:RefreshCombo() end
    end)
    ns.Api.EventBus:OnEvent("v2:targetChanged", "PLAYER_TARGET_CHANGED", function()
        ns.Features.CombatHudPack:RefreshCombo()
        ns.Features.CombatHudPack:RefreshRange()
    end)
    ns.Api.EventBus:OnEvent("v2:tradeShow", "TRADE_SHOW", function()
        ns.Features.TradeLogModule:OnTradeShow()
    end)
    ns.Api.EventBus:OnEvent("v2:tradeMoney", "TRADE_MONEY_CHANGED", function()
        ns.Features.TradeLogModule:OnTradeUpdated()
    end)
    ns.Api.EventBus:OnEvent("v2:tradePItem", "TRADE_PLAYER_ITEM_CHANGED", function()
        ns.Features.TradeLogModule:OnTradeUpdated()
    end)
    ns.Api.EventBus:OnEvent("v2:tradeTItem", "TRADE_TARGET_ITEM_CHANGED", function()
        ns.Features.TradeLogModule:OnTradeUpdated()
    end)
    ns.Api.EventBus:OnEvent("v2:tradeAccept", "TRADE_ACCEPT_UPDATE", function(_, pAcc, tAcc)
        ns.Features.TradeLogModule:OnTradeAcceptUpdate(pAcc, tAcc)
    end)
    ns.Api.EventBus:OnEvent("v2:tradeInfo", "UI_INFO_MESSAGE", function(_, _, msg)
        ns.Features.TradeLogModule:OnInfoMessage(msg)
    end)
    ns.Api.EventBus:OnEvent("v2:tradeClosed", "TRADE_CLOSED", function()
        ns.Features.TradeLogModule:OnTradeClosed()
    end)
    ns.Api.EventBus:OnEvent("v2:hp", "UNIT_HEALTH", function(_, unit)
        if ns.Api.SafeAPI.IsSecret(unit) then return end
        if unit == "player" then ns.Features.CombatAssistHud:Refresh() end
    end)
    ns.Api.EventBus:OnEvent("v2:enchant", "WEAPON_ENCHANT_CHANGED", function()
        ns.Features.CombatAssistHud:Refresh()
    end)
    ns.Api.EventBus:OnEvent("v2:equip", "UNIT_INVENTORY_CHANGED", function(_, unit)
        if ns.Api.SafeAPI.IsSecret(unit) then return end
        if unit == "player" then
            ns.Features.FishingCardHud:Refresh()
            SyncDirectorState(nil, false)
            if ns.Features.BiSBrowserPage and ns.Features.BiSBrowserPage.host
                and type(ns.Features.BiSBrowserPage.host.IsVisible) == "function"
                and ns.Features.BiSBrowserPage.host:IsVisible()
            then
                ns.Features.BiSBrowserPage:Render(ns.Features.BiSBrowserPage.lastQuery)
            end
        end
    end)
    local itemInfoPending = false
    ns.Api.EventBus:OnEvent("v2:itemInfo", "GET_ITEM_INFO_RECEIVED", function(_, itemID, okFlag)
        if ns.Api.SafeAPI.IsSecret(itemID) or ns.Api.SafeAPI.IsSecret(okFlag) or okFlag == false then return end
        if itemInfoPending then return end
        local bisVis = ns.Features.BiSBrowserPage and ns.Features.BiSBrowserPage.host
            and type(ns.Features.BiSBrowserPage.host.IsVisible) == "function"
            and ns.Features.BiSBrowserPage.host:IsVisible()
        local dungVis = ns.Features.DungeonBrowserPage and ns.Features.DungeonBrowserPage.host
            and type(ns.Features.DungeonBrowserPage.host.IsVisible) == "function"
            and ns.Features.DungeonBrowserPage.host:IsVisible()
        if not (bisVis or dungVis) then return end
        itemInfoPending = true
        local function flush()
            itemInfoPending = false
            if ns.Features.BiSBrowserPage and ns.Features.BiSBrowserPage.host
                and type(ns.Features.BiSBrowserPage.host.IsVisible) == "function"
                and ns.Features.BiSBrowserPage.host:IsVisible()
            then
                ns.Features.BiSBrowserPage:Render(ns.Features.BiSBrowserPage.lastQuery)
            end
            if ns.Features.DungeonBrowserPage and ns.Features.DungeonBrowserPage.host
                and type(ns.Features.DungeonBrowserPage.host.IsVisible) == "function"
                and ns.Features.DungeonBrowserPage.host:IsVisible()
            then
                ns.Features.DungeonBrowserPage:RenderRight()
            end
        end
        if not ns.Api.GameAdapters.RunAfter(0.25, flush) then
            flush()
        end
    end)
    ns.Api.EventBus:OnEvent("v2:zone", "ZONE_CHANGED_NEW_AREA", function()
        ns.Features.QuestTrackerView:RefreshLive()
        ns.Features.FishingCardHud:Refresh()
        ns.Features.NavigationHud:Refresh()
        ns.Features.EncounterTimerHud:OnZoneOrInstanceChanged()
        ns.Features.QuestExtraModule:CheckProximityAlerts()
        ns.Features.QuestExtraModule:SyncProximityTicker()
        RefreshHomeIfVisible()
    end)
    ns.Api.EventBus:OnEvent("v2:combatStart", "PLAYER_REGEN_DISABLED", function()
        if ns.UI and ns.UI.Motion and type(ns.UI.Motion.SnapAllForCombat) == "function" then
            ns.UI.Motion.SnapAllForCombat()
        end
        if ns.UI.HudLayout and ns.UI.HudLayout:IsUnlocked() then
            ns.UI.HudLayout:SetUnlocked(false)
        end
        if ns.Secure and ns.Secure.FishingCastButton then
            ns.Secure.FishingCastButton:OnCombatEntered()
        end
        if ns.Features.FishingCardHud and type(ns.Features.FishingCardHud.OnCombatEntered) == "function" then
            ns.Features.FishingCardHud:OnCombatEntered()
        end
        ns.Features.QuestTrackerView:UpdateCombatVisuals(true)
        ns.Features.CombatAssistHud:Refresh(true)
        ns.Features.CombatHudPack:RefreshRange(true)
        ns.Features.ThreatMeterHud:OnCombatStart()
        ns.Features.CursorTrailHud:ApplyVisibility(true)
        ns.Features.EncounterTimerHud:OnCombatStart()
        ns.Features.QuestExtraModule:SyncProximityTicker(true)
        SyncDirectorState(true, true)
    end)
    ns.Api.EventBus:OnEvent("v2:combatEnd", "PLAYER_REGEN_ENABLED", function()
        ns.Secure.CombatQueue:Flush()
        ns.Api.NavPort.FlushIfSafe()
        ns.Features.NavigationHud:SyncSuperTrackedQuest(false)
        if ns.Features.WorldMapOverlay and type(ns.Features.WorldMapOverlay.InvalidatePinCache) == "function" then
            ns.Features.WorldMapOverlay:InvalidatePinCache()
        end
        if ns.Features.FontsPage and not ns.Features.FontsPage.lastAppliedPreset then
            ns.Features.FontsPage:ApplySavedFonts()
        end
        ns.Features.QuestTrackerView:UpdateCombatVisuals(false)
        ns.Features.QuestTrackerView:ReRenderLast()
        ns.Features.CombatAssistHud:Refresh(false)
        ns.Features.CombatHudPack:RefreshRange(false)
        ns.Features.ThreatMeterHud:OnCombatEnd()
        ns.Features.CursorTrailHud:ApplyVisibility(false)
        ns.Features.EncounterTimerHud:OnCombatEnd()
        ns.Features.QoLModule:ApplyCameraZoomIfEnabled()
        ns.Features.QuestExtraModule:SyncProximityTicker(false)
        if ns.Features.FishingCardHud and ns.Features.FishingCardHud.visible then
            ns.Features.FishingCardHud:Refresh()
        end
        SyncDirectorState(false, false)
    end)

    ns.Api.EventBus:OnEvent("v2:taintBlocked", "ADDON_ACTION_BLOCKED", function(_, addonName, funcName)
        RecordTaintEvent("BLOCKED", addonName, funcName)
    end)
    ns.Api.EventBus:OnEvent("v2:taintForbidden", "ADDON_ACTION_FORBIDDEN", function(_, addonName, funcName)
        RecordTaintEvent("FORBIDDEN", addonName, funcName)
    end)

    if type(_G.SlashCmdList) == "table" then
        local function HandleMainSlash(raw)
            local trimmed = string_match(tostring(raw or ""), "^%s*(.-)%s*$") or ""
            local cmd, rest = string_match(trimmed, "^(%S+)%s*(.*)$")
            cmd = cmd and string_lower(cmd) or ""
            if cmd == "move" then
                local unlocked, reason = ns.UI.HudLayout:ToggleUnlock()
                if reason == "IN_COMBAT" then
                    ns.Api.SafeAPI.Print("전투 중에는 HUD 이동 모드를 켤 수 없습니다.")
                else
                    SyncDirectorState(nil, true)
                    ns.Api.SafeAPI.Print(unlocked and "HUD 이동 모드 활성화 (/fs move)" or "HUD 위치 잠금")
                end
            elseif cmd == "home" or cmd == "codex" or cmd == "ledger" or cmd == "settings" or cmd == "utilities" or cmd == "fonts"
                or cmd == "dungeons" or cmd == "bis" or cmd == "professions" or cmd == "questguide" or cmd == "partyfinder"
                or cmd == "diagnostics"
            then
                local win = ns.UI.CommandHub:EnsureWindow()
                win:Show()
                ns.UI.CommandHub:SelectPage(cmd)
            elseif cmd == "train" then
                ns.Features.CharacterAssistModule:PrintTrainableSummary()
            elseif cmd == "gdkp" then
                ns.Features.UtilitiesPage:HandleGdkpCommand(rest)
            elseif cmd == "farm" then
                ns.Features.TradeLogModule:HandleFarmCommand(rest)
            elseif cmd == "fav" then
                ns.Features.UtilitiesPage:HandleFavCommand(rest)
            elseif cmd == "profile" then
                ns.Features.UtilitiesPage:HandleProfileCommand(rest)
            elseif cmd == "kw" then
                ns.Features.ChatToolsModule:SetKeywords(rest)
            elseif cmd == "watch" then
                ns.Features.PartyFinderPage:SetWatchKeywords(rest)
            elseif cmd == "quickloot" then
                ns.Features.DungeonBrowserPage:ToggleQuickLootPopup()
            elseif cmd == "channel" then
                ns.Features.ChatToolsModule:JoinChannel(rest ~= "" and rest or "파티찾기")
            elseif cmd == "greet" then
                local gKind, gText = string_match(rest or "", "^(%S+)%s+(.+)$")
                if gKind == "join" or gKind == "welcome" then
                    ns.Features.AutoGreetingModule:SetCustomMessage(gKind, gText)
                    ns.Api.SafeAPI.Print("자동 인사(" .. gKind .. ") 문구 저장됨: " .. gText)
                elseif gKind == "filter" then
                    ns.Features.AutoGreetingModule:SetExcludedBuffs(gText)
                    ns.Api.SafeAPI.Print("버프 감사 제외 목록 저장됨: " .. gText)
                else
                    ns.Api.SafeAPI.Print("사용법: /fs greet <join|welcome|filter> <문구>")
                end
            elseif cmd == "preset" then
                local pSub, pArg = string_match(rest or "", "^(%S+)%s*(.*)$")
                pSub = pSub and string_lower(pSub) or ""
                if pSub == "cvar" then
                    ns.Features.PresetManagerModule:ApplyRecommendedGameCVars()
                elseif pSub == "barsave" then
                    ns.Features.PresetManagerModule:SaveActionBarLoadout(pArg)
                elseif pSub == "barload" then
                    ns.Features.PresetManagerModule:RestoreActionBarLoadout(pArg)
                elseif pSub == "import" then
                    ns.Features.PresetManagerModule:ImportEditModeLayout(pArg, "ForeverSuite")
                elseif pSub == "sync" then
                    ns.Features.PresetManagerModule:SyncSharedSettingsToChar()
                    ns.Api.SafeAPI.Print("계정 설정을 캐릭터에 동기화했습니다.")
                elseif pSub == "load" then
                    ns.Features.PresetManagerModule:RestoreSharedSettingsFromChar()
                else
                    ns.Api.SafeAPI.Print("사용법: /fs preset <cvar|barsave|barload|import|sync|load>")
                end
            elseif cmd == "cd" then
                local cSub, cArg = string_match(rest or "", "^(%S+)%s*(.*)$")
                cSub = cSub and string_lower(cSub) or ""
                if cSub == "add" then
                    ns.Features.ProcCooldownHud:AddCustomCooldown(cArg)
                elseif cSub == "clear" then
                    ns.Features.ProcCooldownHud:ClearCustomCooldowns()
                else
                    ns.Api.SafeAPI.Print("사용법: /fs cd <add <spellID>|clear>")
                end
            elseif cmd == "party" then
                ns.Features.ChatToolsModule:PrintPartyClassRoster()
            elseif cmd == "protect" then
                ns.Features.MerchantModule:ToggleProtectItem(rest)
            elseif cmd == "cheap" then
                ns.Features.MerchantModule:PrintCheapestItems()
            elseif cmd == "layer" then
                local layer = ns.Api.GameAdapters.GetZoneLayerID("target")
                ns.Api.SafeAPI.Print(layer and ("현재 대상 위상(ZoneUID): #" .. tostring(layer)) or "대상을 선택하면 위상(ZoneUID)을 확인할 수 있습니다.")
            elseif cmd == "xp" then
                ns.Features.QoLModule:HandleXPCommand(rest)
            elseif cmd == "pull" then
                ns.Features.EncounterTimerHud:HandlePullCommand(rest)
            elseif cmd == "timer" then
                ns.Features.EncounterTimerHud:PrintStatus()
            elseif cmd == "clearway" then
                ns.Features.NavigationHud:Clear()
                ns.Api.SafeAPI.Print("웨이포인트를 해제했습니다.")
            elseif cmd == "bridges" then
                if ns.Bridges and ns.Bridges.BridgeHost then
                    local summary = ns.Bridges.BridgeHost:GetSummary()
                    local parts = {}
                    for i = 1, #summary do
                        local s = summary[i]
                        parts[#parts + 1] = s.target .. "=" .. s.state
                    end
                    ns.Api.SafeAPI.Print("외부 브리지 공존 상태: " .. table.concat(parts, " | "))
                end
            elseif cmd == "reset" then
                if ns.Bridges and ns.Bridges.BridgeHost then
                    ns.Bridges.BridgeHost:Reset(rest ~= "" and rest or nil)
                    ns.Api.SafeAPI.Print("Coexistence/Bridge 상태를 재초기화했습니다.")
                end
            elseif cmd == "setup" then
                ns.Features.SetupWizard:HandleCommand(string_lower(rest or ""))
            elseif cmd == "track" then
                ns.Features.TrackingSwitcher:CycleNext()
            elseif cmd == "fish" then
                ns.Features.FishingCardHud:HandleCommand(rest)
            elseif cmd == "dock" then
                local shown = ns.Features.QuickDockHud:Toggle()
                ns.Api.SafeAPI.Print(shown and "빠른 도구 바 표시 ON" or "빠른 도구 바 숨김 OFF")
            elseif cmd == "help" then
                ns.Api.SafeAPI.Print("허브 페이지: /fs [dungeons|bis|professions|questguide|codex|partyfinder|utilities|ledger|fonts|settings|move]")
                ns.Api.SafeAPI.Print("기능 커맨드: /fs [fish|dock|setup|track|bridges|reset|gdkp|kw|train|farm|fav|profile|protect|cheap|layer|xp|pull|timer|clearway] · /fsdb · /way <x> <y> [이름]")
            else
                ns.UI.CommandHub:Toggle()
            end
        end

        _G.SLASH_FOREVERSUITE1 = "/fs"
        _G.SLASH_FOREVERSUITE2 = "/fs2"
        _G.SlashCmdList["FOREVERSUITE"] = HandleMainSlash
        _G.SlashCmdList["FOREVERSUITEV2"] = HandleMainSlash

        local function HandleWaySlash(raw)
            ns.Features.NavigationHud:HandleWaySlash(raw)
        end
        _G.SLASH_FOREVERSUITEWAY1 = "/way"
        _G.SLASH_FOREVERSUITEWAY2 = "/way2"
        _G.SlashCmdList["FOREVERSUITEWAY"] = HandleWaySlash
        _G.SlashCmdList["FOREVERSUITEWAYV2"] = HandleWaySlash

        local function HandleDbSlash(raw)
            local trimmed = string_match(tostring(raw or ""), "^%s*(.-)%s*$") or ""
            local sub, arg = string_match(trimmed, "^(%S+)%s*(.*)$")
            sub = sub and string_lower(sub) or ""
            arg = arg and string_lower(arg) or ""
            if sub == "restore" and arg == "v5" then
                local ok, reason = ns.Api.ProfileStore:RestoreV5()
                if ok then
                    ns.Api.SafeAPI.Print("v5 백업 스냅샷으로 복원했습니다. /reload 로 반영하세요.")
                else
                    ns.Api.SafeAPI.Print("복원 가능한 v5 백업이 없습니다 (" .. tostring(reason) .. ").")
                end
            else
                local ver = ns.Api.ProfileStore.db and ns.Api.ProfileStore.db.schemaVersion or "?"
                local dev = ns.Api.ProfileStore:GetDeviceKey()
                ns.Api.SafeAPI.Print("ForeverSuite DB 스키마 v" .. tostring(ver) .. " · 기기키=" .. tostring(dev) .. " · 복원: /fsdb restore v5")
            end
        end
        _G.SLASH_FOREVERSUITEDB1 = "/fsdb"
        _G.SlashCmdList["FOREVERSUITEDB"] = HandleDbSlash
    end

    self.initialized = true
end

_G.ForeverSuite = ns
_G.ForeverSuiteV2 = ns

ns.Api.EventBus:OnEvent("v2:boot", "PLAYER_LOGIN", function()
    Bootstrap:Init()
end)
