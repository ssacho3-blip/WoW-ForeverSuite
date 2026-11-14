# ForeverSuite — 통합 애드온 아키텍처 & 품질 계약서 (`FS-V030-FULL-UPGRADE`)

## 1. 시스템 계층 구조 (Modular Fault-Isolated Architecture, 18 Lua Modules)

```text
ForeverSuite v0.3.0 (TOC Interface: 11701, 16001, 120105 | Product: wowf 1.60.1.70938)
├── Core Layer (P0)
│   ├── Init.lua              : 단일 네임스페이스(ns), TOC/GetBuildInfo 메타 파싱, Secret 가드(IsSecret), CombatQueue, /fs probe
│   ├── MoneyLedgerQueue.lua  : 상점·수리·퀘스트 골드 변동 사유 FIFO 큐 (Init.lua에서 순수 도메인 분리)
│   ├── EventBus.lua          : 단일 WoW Frame 기반 중앙 이벤트 디스패처, 사전 캐시 xpcall 클로저, 버킷 쓰로틀(0.2s/0.5s)
│   ├── ProfileManager.lua    : 계층형 설정(캐릭터 > 직업 > 계정 > 기본값), 미래 스키마 Read-Only 가드(CanWrite), 보호 아이템 ID 집합
│   └── ModuleManager.lua     : 상태 머신(REGISTERED → INITIALIZED → ENABLED ⇄ DISABLED / YIELDED / FAULTED) 및 ctx 리소스 회수
├── UI Layer (P0 ~ P2, 전 파일 < 700줄 불변식 강제)
│   ├── Framework.lua         : 다크 슬레이트·골드 위젯 팩토리(체크박스 _fsLabel, 버튼, Pill 버튼, 배지 — UIDropDownMenu 0건)
│   ├── QuestTrackerModel.lua : 순수 ViewModel — ZONE(현재 지역 최상단) · LEVEL(난이도 티어) 그룹화, 목표 파싱, 아이템 메타 보존
│   ├── QuestLogCollector.lua : C_QuestLog + GetQuestLogSpecialItemInfo 실시간 스냅샷 수집기 (순수 ViewModel과 I/O 분리)
│   ├── DefaultTrackerSync.lua: 내장 ObjectiveTrackerFrame / QuestWatchFrame 비전투 가시성 동기화
│   ├── QuestTracker.lua      : 온스크린 퀘스트 추적창 View, Ctrl/Alt/Shift 클릭, [잠금], UIParent 직계 Secure 아이템 버튼 풀(1..6)
│   └── SettingsPanel.lua     : 멱등 UISpecialFrames(ESC), 3탭 제어판(모듈 세부설정 서랍 · GJ 브리지 · 골드 원장), 슬래시 라우터
└── Functional Modules (P1 ~ P2)
    ├── Utility.lua           : [P1] 자동 수리(길드→개인 폴백), 회색템 배치 판매(12개 한도·잔여 안내·/fs sell·/fs protect), 고속 전리품
    ├── Inventory.lua         : [P1] Baganator/Bagnon 공존 + 여유 슬롯 HUD(/fs move 드래그·골드 원장 호버 툴팁), 묶음 상점가(xN)·보호 배지
    ├── Map.lua               : [P1] 월드맵 열림 시 전용 0.15s 플레이어 + 커서 좌표 Ticker, /way <x> <y> → C_Map.SetUserWaypoint
    ├── Quest.lua             : [P1] Questie 공존 + 안전 자동 수락·완료(복수 보상 정지, Shift 우회), /fs quest 슬래시 라우팅
    ├── Profession.lua        : [P1] 비전투 Secure 더블우클릭 낚시(2중 해제), 효과음 부스트, classID==7 채집물/일반 전리품 분리 집계
    ├── Economy.lua           : [P2] Auctionator 시세 브리지 + PLAYER_MONEY 세션 골드 원장 + 가방 HUD 호버 실시간 갱신 콜백
    └── Combat.lua            : [P2] 9개 클래식 전 직업 버프 패밀리·무기 마법부여 체크 + issecretvalue 안전 저체력 알림(/fs move 연동)
```

---

## 2. 모듈 생명주기 상태 머신 및 리소스 소유권 격리

```text
REGISTERED ──(OnInitialize)──▶ INITIALIZED ──(외부 대체 애드온 미감지)──▶ ENABLED ⇄ DISABLED
                 │                  │                                       │
                 │(초기화 에러)      │(외부 공존 애드온 감지)                 │(60초 내 에러 3회)
                 ▼                  ▼                                       ▼
              FAULTED            YIELDED (0 훅 등록)                     FAULTED (모든 리소스 자동 회수)
```

- **리소스 소유권 원칙 (`ctx` 샌드박스)**: 각 모듈은 `CreateFrame`, `RegisterEvent`, `C_Timer.NewTicker`를 직접 호출하지 않고 `ModuleManager`가 주입하는 컨텍스트(`ctx:RegisterEvent`, `ctx:RegisterBucketEvent`, `ctx:NewTicker`, `ctx:CreateFrame`, `ctx:AddCleanup`)를 경유합니다.
- **모듈 계약 헤더 불변식**: 모든 `Core/*.lua`, `UI/*.lua`, `Modules/*.lua` 최상단에는 `Responsibility`, `Dependencies`, `Public API`, `Combat/Secret Safety` 4개 항목이 명시되며 자동화 테스트로 강제됩니다.
- **서킷 브레이커 (`FAULTED`)**: 특정 모듈에서 60초 이내 3회 런타임 오류가 발생하면 `ModuleManager`가 해당 모듈이 등록한 모든 이벤트·버킷·타이머·프레임을 즉시 일괄 회수하고 상태를 `FAULTED`로 격리합니다.

---

## 3. Taint · `InCombatLockdown()` · `C_Secrets` 경계 불변식

1. **`CombatQueue` 지연 실행 & 암묵적 보호 전파 차단 (`UIParent` 직계 원칙)**:
   - `SetOverrideBindingClick`, `ClearOverrideBindings`, Secure 프레임 속성/표시/앵커 변경 등 모든 보호 동작은 `ns.CombatQueue:RunOrDefer(key, fn)`를 경유해 비전투 시에만 실행합니다.
   - 퀘스트 특수 아이템 버튼(`ForeverSuiteQuestItemBtn1..6`, `SecureActionButtonTemplate`)은 `ForeverSuiteQuestTracker`나 행 버튼의 자식이 아닌 **`_G.UIParent` 직계 자식·직계 좌표 앵커**로만 생성하여 추적창 본체의 암묵적 보호 전파(`ADDON_ACTION_BLOCKED`)를 원천 차단합니다.
2. **낚시 더블 우클릭 2중 안전 해제**:
   - `WorldFrame:HookScript("OnMouseDown")` 후크만 사용(원본 핸들러 교체 금지 → Taint 제로).
   - 비전투 + 낚싯대 장착(또는 설정 허용) 시에만 일시 바인딩을 설정하고, ① 클릭/시전 직후 `0.05s` 타이머 및 ② `PLAYER_REGEN_DISABLED` 진입 시 즉시 `ClearOverrideBindings`를 호출합니다.
3. **`issecretvalue` 가드**: `1.60.1` 바이너리에 탑재된 `issecretvalue(v)`를 `ns.IsSecret(v)`로 래핑하여, 전투 중 체력/오라 값이 Secret일 경우 어떠한 산술·비교·문자열 결합도 수행하지 않고 즉시 우회하거나 `UNAVAILABLE`로 표기합니다.
4. **전투 자동화 원천 차단**: `CastSpellByName`, `CastSpellByID`, `TargetUnit`, `UseAction` 등 블리자드 금지 전투 자동화 API는 코드베이스 내 존재 자체를 AST 테스트로 차단합니다.

---

## 4. 성능 예산 및 Zero Fabricated Status

- **유휴 `OnUpdate` 0개**: 맵이 닫혀 있으면 좌표 Ticker는 즉시 `Cancel()`되어 백그라운드 CPU를 0.00ms 소모합니다.
- **이벤트 버킷 코얼레싱**: `BAG_UPDATE` 대신 `BAG_UPDATE_DELAYED`(0.2초 버킷), `UNIT_AURA`는 `"player"` 유닛 필터 + 비전투 0.5초 버킷만 사용합니다.
- **`UpdateAddOnMemoryUsage()` 호출 제한**: 프레임 스터터를 방지하기 위해 설정 패널이 화면에 열려 있고 비전투 상태일 때만 최소 5초 간격으로 갱신합니다.
- **Zero Fabricated Status**: `C_AddOnProfiler`가 비활성화되었거나 아이템 비동기 캐시가 아직 로드되지 않은 경우 가짜 `0.00 ms`나 `0 코퍼`를 만들지 않고 정직하게 `측정 불가` 또는 `—`를 표시합니다.
