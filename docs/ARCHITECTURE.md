# ForeverSuite — 통합 애드온 아키텍처 & 품질 계약서 (`WOWF-20261101-001`)

## 1. 시스템 계층 구조 (Modular Fault-Isolated Architecture)

```text
ForeverSuite (TOC Interface: 11701, 16001 | Product: wowf 1.60.1.70707)
├── Core Layer (P0)
│   ├── Init.lua            : 단일 네임스페이스(ns), Secret 가드(IsSecret), CombatQueue, /fs probe 진실 원천 덤퍼
│   ├── EventBus.lua        : 단일 WoW Frame 기반 중앙 이벤트 디스패처, 사전 캐시 xpcall 클로저, 버킷 쓰로틀(0.2s/0.5s)
│   ├── ProfileManager.lua  : 계층형 설정 해석(캐릭터 > 직업 > 계정 > 기본값), 멱등 마이그레이션(_backup), 미래 스키마 Read-Only, CVar 크래시 복구
│   └── ModuleManager.lua   : 상태 머신(REGISTERED → INITIALIZED → ENABLED ⇄ DISABLED / YIELDED / FAULTED) 및 ctx 리소스 소유권 회수
├── UI Framework (P0)
│   ├── Framework.lua       : 공통 다크 슬레이트·골드 테마 위젯 팩토리(체크박스, 버튼, 배지, 섹션 헤더 — 레거시 UIDropDownMenu 제로)
│   └── SettingsPanel.lua   : /fs · /forever 통합 제어판 + AddonCompartment 진입 + 실시간 CPU/메모리 모니터(Zero Fabricated Status)
└── Functional Modules (P1 ~ P2)
    ├── Utility.lua         : [P1] 자동 수리(길드→개인 폴백), 안전 회색템 판매(1회 12개 되사기 한도, 보호목록, Shift 정지), 고속 전리품, QoL CVar
    ├── Inventory.lua       : [P1] Baganator/Bagnon 공존(YIELDED) + 여유 슬롯 HUD, 원클릭 정렬, 툴팁 상점가·템렙(비동기 nil 시 '—')
    ├── Map.lua             : [P1] 월드맵 열림 시 전용 0.15s 좌표 Ticker(인스턴스 nil 시 '—'), /way <x> <y> → C_Map.SetUserWaypoint + C_SuperTrack
    ├── Quest.lua           : [P1] Questie 공존 + 안전한 자동 수락·완료(복수 보상 시 수동 정지, Shift 우회), 최근접/수락 퀘스트 SuperTrack 보조
    ├── Profession.lua      : [P1] 채광·무두질·낚시·요리 편의 — 비전투 Secure 더블우클릭 낚시(2중 해제), 크래시 안전 효과음 부스트, 시간당 채집 수확량, 채집 추적 알림
    ├── Economy.lua         : [P2] Auctionator 시세 브리지 + PLAYER_MONEY 델타 정합성 검증 세션 골드 원장(상점·수리·퀘스트·전리품·기타)
    └── Combat.lua          : [P2] 내장 C_DamageMeter · C_CooldownViewer · C_EditMode 빠른 연동 + 비전투 직업 버프 누락 체크 + issecretvalue 안전 저체력 알림
```

---

## 2. 모듈 생명주기 상태 머신 및 리소스 소유권 격리 (`AC-2`, `AC-7`)

```text
REGISTERED ──(OnInitialize)──▶ INITIALIZED ──(외부 대체 애드온 미감지)──▶ ENABLED ⇄ DISABLED
                 │                  │                                       │
                 │(초기화 에러)      │(외부 공존 애드온 감지)                 │(60초 내 에러 3회)
                 ▼                  ▼                                       ▼
              FAULTED            YIELDED (0 훅 등록)                     FAULTED (모든 리소스 자동 회수)
```

- **리소스 소유권 원칙 (`ctx` 샌드박스)**: 각 모듈은 `CreateFrame`, `RegisterEvent`, `C_Timer.NewTicker`를 직접 호출하지 않고 `ModuleManager`가 주입하는 컨텍스트(`ctx:RegisterEvent`, `ctx:RegisterBucketEvent`, `ctx:NewTicker`, `ctx:CreateFrame`, `ctx:AddCleanup`)를 경유합니다.
- **서킷 브레이커 (`FAULTED`)**: 특정 모듈에서 60초 이내 3회 런타임 오류가 발생하면 `ModuleManager`가 해당 모듈이 등록한 모든 이벤트·버킷·타이머·프레임을 즉시 일괄 회수하고 상태를 `FAULTED`로 격리합니다. 다른 모듈은 100% 정상 동작을 유지하며, `/fs` 설정창에 마지막 오류와 스택 요약이 기록됩니다.

---

## 3. Taint · `InCombatLockdown()` · `C_Secrets` 경계 불변식 (`AC-3`, `AC-4`)

1. **`CombatQueue` 지연 실행**: `SetOverrideBindingClick`, `ClearOverrideBindings`, Secure 프레임 속성/표시 변경 등 모든 보호 동작은 `InCombatLockdown()`이 `true`일 때 호출하지 않고 `ns.CombatQueue:RunOrDefer(key, fn)`에 적재해 `PLAYER_REGEN_ENABLED` 직후 실행합니다.
2. **낚시 더블 우클릭 2중 안전 해제**:
   - `WorldFrame:HookScript("OnMouseDown")` 후크만 사용(원본 핸들러 교체 금지 → Taint 제로).
   - 비전투 + 낚싯대 장착(또는 설정 허용) 시에만 일시 바인딩을 설정하고, ① 클릭/시전 직후 `0.05s` 타이머 및 ② `PLAYER_REGEN_DISABLED` 진입 시 즉시 `ClearOverrideBindings`를 호출합니다.
3. **`issecretvalue` 가드**: `1.60.1` 바이너리에 탑재된 `issecretvalue(v)`를 `ns.IsSecret(v)`로 래핑하여, 전투 중 체력/오라 값이 Secret일 경우 어떠한 산술·비교·문자열 결합도 수행하지 않고 즉시 우회하거나 `UNAVAILABLE`로 표기합니다.
4. **전투 자동화 원천 차단**: `CastSpellByName`, `CastSpellByID`, `TargetUnit`, `UseAction` 등 블리자드 금지 전투 자동화 API는 코드베이스 내 존재 자체를 AST 테스트로 차단합니다.

---

## 4. 성능 예산 및 Zero Fabricated Status (`AC-7`)

- **유휴 `OnUpdate` 0개**: 맵이 닫혀 있으면 좌표 Ticker는 즉시 `Cancel()`되어 백그라운드 CPU를 0.00ms 소모합니다.
- **이벤트 버킷 코얼레싱**: `BAG_UPDATE` 대신 `BAG_UPDATE_DELAYED`(0.2초 버킷), `UNIT_AURA`는 `"player"` 유닛 필터 + 비전투 0.5초 버킷만 사용합니다.
- **`UpdateAddOnMemoryUsage()` 호출 제한**: 프레임 스터터를 방지하기 위해 설정 패널이 화면에 열려 있고 비전투 상태일 때만 최소 5초 간격으로 갱신합니다.
- **Zero Fabricated Status**: `C_AddOnProfiler`가 비활성화되었거나 아이템 비동기 캐시가 아직 로드되지 않은 경우 가짜 `0.00 ms`나 `0 코퍼`를 만들지 않고 정직하게 `측정 불가` 또는 `—`를 표시합니다.
