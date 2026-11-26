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
        desc = "L0 상시 HUD 상태 요약 바 표시/숨김",
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
        desc = "상단 헤더의 −/+ 버튼과 연동됩니다",
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
        desc = "/fs2 protect 보호 목록 제외",
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
        desc = "/fs2 pull 10 및 /fs2 timer 지원",
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
            { value = "default_kr", label = "기본 고딕", width = 80 },
            { value = "bold_kr", label = "굵은 고딕", width = 80 },
            { value = "pagetext_kr", label = "명조체", width = 72 },
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

    -- Register L2 Command Hub workspace pages (full GodJohnson parity workspaces)
    ns.UI.CommandHub:RegisterPage(ns.Features.DiagnosticsPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.DungeonBrowserPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.BiSBrowserPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.ProfessionPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.QuestGuidePage)
    ns.UI.CommandHub:RegisterPage(ns.Features.CodexPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.PartyFinderPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.UtilitiesPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.LedgerPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.FontsPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.SettingsPage)

    ns.Blizzard.WorldMapAdapter:Init()

    local mode = ns.Api.ProfileStore:Get("quest", "defaultTrackerMode") or "hide"
    ApplyTrackerModeSafely(mode)

    ns.Api.EventBus:Subscribe("setting:changed", function(sec, key, val)
        if sec == "quest" and key == "defaultTrackerMode" then
            ApplyTrackerModeSafely(val)
        elseif sec == "quest" and (key == "groupMode" or key == "currentZoneOnly" or key == "trackerMinimized" or key == "trackerLocked") then
            ns.Features.QuestTrackerView:RefreshLive()
        elseif sec == "quest" and key == "combatFade" then
            ns.Features.QuestTrackerView:UpdateCombatVisuals()
        elseif sec == "ui" and key == "showStatusPill" then
            ns.Features.StatusPillHud:ApplyVisibility()
        elseif sec == "ui" and (key == "showWorldMapOverlay" or key == "showWorldMapPins") then
            ns.Features.WorldMapOverlay:ApplyVisibility()
        elseif sec == "ui" and key == "showMinimapButton" then
            ns.Features.MinimapButton:ApplyVisibility()
        elseif sec == "ui" and (key == "showCursorRing" or key == "cursorStyle" or key == "cursorCombatOnly") then
            ns.Features.CursorTrailHud:ApplyVisibility()
        elseif sec == "ui" and key == "showScreenClock" then
            ns.Features.CombatHudPack:RefreshClock()
        elseif sec == "ui" and (key == "fontPreset" or key == "fontOutline") then
            ns.Features.FontsPage:ApplySavedFonts()
        elseif sec == "combat" and key == "showThreatMeter" then
            ns.Features.ThreatMeterHud:Refresh()
        elseif sec == "combat" and key == "showEncounterTimer" then
            ns.Features.EncounterTimerHud:Refresh()
        elseif sec == "combat" and (key == "showComboHud" or key == "showRangeHud" or key == "showShortBuffHud") then
            ns.Features.CombatHudPack:RefreshAll()
        elseif sec == "combat" then
            ns.Features.CombatAssistHud:Refresh()
        elseif sec == "profession" and key == "showFishingCard" then
            ns.Features.FishingCardHud:Refresh()
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
    ns.Features.CombatAssistHud:Init()
    ns.Features.CombatAssistHud:Refresh()
    ns.Features.ThreatMeterHud:Init()
    ns.Features.CursorTrailHud:Init()
    ns.Features.CombatHudPack:Init()
    ns.Features.EncounterTimerHud:Init()
    ns.Features.EncounterTimerHud:OnZoneOrInstanceChanged()
    ns.Features.FishingCardHud:Init()
    ns.Features.FishingCardHud:Refresh()
    ns.Features.MinimapButton:Init()
    ns.Features.TooltipEnhanceModule:Init()
    ns.Features.ChatToolsModule:Init()
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

    -- Lifecycle & Feature event wiring
    ns.Api.EventBus:OnEvent("v2:addonLoaded", "ADDON_LOADED", function()
        ns.Blizzard.WorldMapAdapter:Init()
    end)
    ns.Api.EventBus:OnEvent("v2:enterWorld", "PLAYER_ENTERING_WORLD", function()
        ns.Features.EncounterTimerHud:OnZoneOrInstanceChanged()
        ns.Features.DungeonBrowserPage:OnInstanceChanged()
        ns.Features.ThreatMeterHud:Refresh()
        ns.Features.QoLModule:SyncSessionXP()
        ns.Features.AutoGreetingModule:SyncInitialRoster()
        ns.Features.CharacterAssistModule:CheckTalents(false)
        ns.Features.UtilitiesPage:RecordCurrentCharacter()
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
    end)
    ns.Api.EventBus:OnEvent("v2:superTrack", "SUPER_TRACKING_CHANGED", function()
        ns.Features.QuestTrackerView:RefreshLive()
    end)
    ns.Api.EventBus:OnEvent("v2:bags", "BAG_UPDATE_DELAYED", function()
        ns.Features.StatusPillHud:RefreshLive()
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
    end)
    ns.Api.EventBus:OnEvent("v2:qProgress", "QUEST_PROGRESS", function()
        ns.Features.QuestAutomation:OnQuestProgress()
    end)
    ns.Api.EventBus:OnEvent("v2:qComplete", "QUEST_COMPLETE", function()
        ns.Features.QuestAutomation:OnQuestComplete()
    end)
    ns.Api.EventBus:OnEvent("v2:qAccepted", "QUEST_ACCEPTED", function(_, a1, a2)
        local qid = (type(a2) == "number") and a2 or a1
        ns.Features.QuestAutomation:OnQuestAccepted(qid)
    end)
    ns.Api.EventBus:OnEvent("v2:lootReady", "LOOT_READY", function()
        ns.Features.QoLModule:OnLootReady()
    end)
    ns.Api.EventBus:OnEvent("v2:playerDead", "PLAYER_DEAD", function()
        ns.Features.EncounterTimerHud:OnPlayerDead()
        ns.Features.QoLModule:OnPlayerDead()
        ns.Features.CorpseGuideModule:OnPlayerDead()
    end)
    ns.Api.EventBus:OnEvent("v2:playerAlive", "PLAYER_ALIVE", function()
        ns.Features.EncounterTimerHud:OnZoneOrInstanceChanged()
        -- PLAYER_ALIVE also fires when releasing spirit to ghost: Refresh() keeps guiding while ghost and clears when alive
        ns.Features.CorpseGuideModule:Refresh()
    end)
    ns.Api.EventBus:OnEvent("v2:playerUnghost", "PLAYER_UNGHOST", function()
        ns.Features.EncounterTimerHud:OnZoneOrInstanceChanged()
        ns.Features.CorpseGuideModule:OnPlayerRevived()
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
    ns.Api.EventBus:OnEvent("v2:levelUp", "PLAYER_LEVEL_UP", function()
        ns.Features.QoLModule:SyncSessionXP()
        ns.Features.CharacterAssistModule:CheckTalents(true)
        ns.Features.UtilitiesPage:RecordCurrentCharacter()
    end)
    ns.Api.EventBus:OnEvent("v2:encStart", "ENCOUNTER_START", function(_, _, encounterName)
        ns.Features.EncounterTimerHud:OnEncounterStart(encounterName)
    end)
    ns.Api.EventBus:OnEvent("v2:encEnd", "ENCOUNTER_END", function(_, _, encounterName, _, _, success)
        ns.Features.EncounterTimerHud:OnEncounterEnd(encounterName, success)
        ns.Features.DungeonBrowserPage:OnBossKilled(encounterName, success)
    end)
    ns.Api.EventBus:OnEvent("v2:aura", "UNIT_AURA", function(_, unit)
        if unit == "player" then
            ns.Features.CombatAssistHud:Refresh()
            ns.Features.CombatHudPack:RefreshShortBuffs()
            ns.Features.AutoGreetingModule:OnPlayerAuraChanged()
        end
    end)
    ns.Api.EventBus:OnEvent("v2:power", "UNIT_POWER_UPDATE", function(_, unit)
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
        if unit == "player" then ns.Features.CombatAssistHud:Refresh() end
    end)
    ns.Api.EventBus:OnEvent("v2:enchant", "WEAPON_ENCHANT_CHANGED", function()
        ns.Features.CombatAssistHud:Refresh()
    end)
    ns.Api.EventBus:OnEvent("v2:equip", "UNIT_INVENTORY_CHANGED", function(_, unit)
        if unit == "player" then ns.Features.FishingCardHud:Refresh() end
    end)
    ns.Api.EventBus:OnEvent("v2:zone", "ZONE_CHANGED_NEW_AREA", function()
        ns.Features.QuestTrackerView:RefreshLive()
        ns.Features.FishingCardHud:Refresh()
        ns.Features.NavigationHud:Refresh()
        ns.Features.EncounterTimerHud:OnZoneOrInstanceChanged()
    end)
    ns.Api.EventBus:OnEvent("v2:combatStart", "PLAYER_REGEN_DISABLED", function()
        ns.Features.QuestTrackerView:UpdateCombatVisuals(true)
        ns.Features.CombatAssistHud:Refresh(true)
        ns.Features.CombatHudPack:RefreshRange(true)
        ns.Features.ThreatMeterHud:OnCombatStart()
        ns.Features.CursorTrailHud:ApplyVisibility(true)
        ns.Features.EncounterTimerHud:OnCombatStart()
    end)
    ns.Api.EventBus:OnEvent("v2:combatEnd", "PLAYER_REGEN_ENABLED", function()
        ns.Secure.CombatQueue:Flush()
        ns.Api.NavPort.FlushIfSafe()
        ns.Features.QuestTrackerView:UpdateCombatVisuals(false)
        ns.Features.QuestTrackerView:ReRenderLast()
        ns.Features.CombatAssistHud:Refresh(false)
        ns.Features.CombatHudPack:RefreshRange(false)
        ns.Features.ThreatMeterHud:OnCombatEnd()
        ns.Features.CursorTrailHud:ApplyVisibility(false)
        ns.Features.EncounterTimerHud:OnCombatEnd()
        ns.Features.QoLModule:ApplyCameraZoomIfEnabled()
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
                local unlocked = ns.UI.HudLayout:ToggleUnlock()
                ns.Api.SafeAPI.Print(unlocked and "HUD 이동 모드 활성화 (/fs move)" or "HUD 위치 잠금")
            elseif cmd == "codex" or cmd == "ledger" or cmd == "settings" or cmd == "utilities" or cmd == "fonts"
                or cmd == "dungeons" or cmd == "bis" or cmd == "professions" or cmd == "questguide" or cmd == "partyfinder"
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
            elseif cmd == "help" then
                ns.Api.SafeAPI.Print("명령어: /fs [ledger|codex|settings|move|protect <ID/링크>|cheap|layer|xp [reset]|pull <3~30|0>|timer|clearway] · /way <x> <y> [이름]")
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
    end

    self.initialized = true
end

_G.ForeverSuite = ns
_G.ForeverSuiteV2 = ns

ns.Api.EventBus:OnEvent("v2:boot", "PLAYER_LOGIN", function()
    Bootstrap:Init()
end)
