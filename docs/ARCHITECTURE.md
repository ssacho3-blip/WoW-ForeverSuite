# ForeverSuite v6.0 — 통합 아키텍처 & 품질 계약서

## 1. 7-Layer 엄격 격리 구조 (111 Lua Modules · `fsx check` AST 강제)

```text
ForeverSuite v6.0.0 (TOC Interface: 16001, 120105 | Client: wowf 1.60.1.71037)
├── ForeverSuite/ (103 Lua)
│   ├── Rank 0 · Domain/   (34 순수 Lua 모델 — _G / CreateFrame / WoW API 0건)
│   │   ├── Coexistence.lua          : 5상태 × 8이벤트(40셀) 외부 전문 애드온 공존 정책
│   │   ├── DirectorModel.lua        : 6상태(EDIT_OVERRIDE > COMBAT > DEAD > FISHING > DIALOGUE > EXPLORATION) & 알파 매트릭스
│   │   ├── DataResolver.lua         : STATIC → LIVE → EMBEDDED(≤60KB) 3-계층 조회 & 매니페스트 호환성
│   │   ├── ProfileMigrationModel.lua: schemaVersion=6 Expand-Migrate, 기기 키 격리, _backup_v5 복원, 미래 스키마 Read-Only
│   │   ├── AltCooldownModel.lua     : 부캐 전문기술 다일 쿨다운(연금 48h · 소금 72h · 달빛 96h)
│   │   └── CharacterGuideModel.lua  : 업그레이드 Top3(2H·반지/장신구 슬롯 정규화) · 향후 5레벨 스킬 비용/부족 골드
│   ├── Rank 1 · Api/      (7 어댑터 — SafeAPI, AddonProbe, DataHub, Adapters/Duration, GameAdapters, EventBus, ProfileStore)
│   ├── Rank 2 · Secure/   (3 전투 격리 — CombatQueue, QuestItemDock, FishingCastButton · UIParent 직계 전용)
│   ├── Rank 3 · Blizzard/ (4 읽기 전용 HookScript 어댑터 — ObjectiveTracker, WorldMap, Tooltip, CharacterDock · Bridges 참조 금지)
│   ├── Rank 3 · Bridges/  (7 외부 전문 앱 공식 API 브리지 — BridgeHost, Baganator, Syndicator, Auctionator, DialogueUI, Spoken, Platynator · Blizzard/Features 참조 금지)
│   ├── Rank 4 · UI/       (8 렌더링 코어 — PixelUtil, Tokens, NineSlice, Widgets, CompositeWidgets, HudLayout, Director, CommandHub)
│   └── Rank 5 · Features/ (40 기능/HUD/페이지 + Bootstrap 오케스트레이터)
├── ForeverSuite_Data/ (7 Lua · LoadOnDemand: 1 · manifest.lua · 0-Pack 생존)
└── ForeverSuite_Media/ (1 Lua · Burnished Gold 9-Slice · 12-Layer 3D 화살표 · Assets 자동 해석)
```

> **정적 & 런타임 품질 게이트 (`tools/fsx`)**:
> - `cargo test`: 16개 Rust 단위 테스트 (AST 레이어 격리, `D1` 레거시 SV 쓰기 차단, `A0` 배선·데이터 진정성, `@secret` 데이터플로, 3-폴더 패키징, 외부 백업·원자적 롤백)
> - `fsx check`: TOC↔디스크 정합성, 1.60.1 API 화이트리스트, 7-Layer 역참조 차단, `Blizzard/ SetScript` 금지, `Secure/` `UIParent` 강제, `@secret` 데이터플로 차단
> - `fsx test v2`: 임베디드 Lua 5.1 VM (`mlua`) 25개 통합 테스트 스위트 (Secret Proxy 퍼징 포함)

---

## 2. 핵심 불변식 (Invariants)

1. **Zero-Taint & `Blizzard ⊥ Bridges` 격리**:
   - `Blizzard/` 계층은 `HookScript`만 허용하며 Blizzard 프레임에 필드를 쓰거나 `SetScript`를 호출할 수 없습니다.
   - `Blizzard/`와 `Bridges/`는 상호 참조가 금지되어 외부 애드온 오류가 Blizzard 후크로 전파되지 않습니다.
   - 모든 `SecureActionButtonTemplate`은 `Secure/` 계층에서만 `UIParent` 직계 자식으로 생성합니다.
2. **`C_Secrets` 불투명 바인딩 (`I1`/`I2` & AC-6)**:
   - 전투 중 오라/쿨다운 지속시간은 `Api/Adapters/Duration.lua`의 `C_DurationUtil.CreateDurationTextBinding` 및 `C_UnitAuras.GetAuraApplicationDisplayCount`로 불투명 전달합니다.
   - `fsx check`의 `check_secret_dataflow`가 `@secret` 변수의 산술·비교·문자열 결합·`tostring`/`format`·단독 진리 분기(직접 호출 및 `pcall`, 정규화 `not IsSecret` 우회 포함)를 CI 단계에서 차단합니다.
3. **SavedVariables 무손실 확장 (`D1`)**:
   - 활성 SavedVariables는 `ForeverSuiteV2DB` / `ForeverSuiteV2CharDB` (`schemaVersion = 6`)이며, 레거시 `ForeverSuiteDB` / `ForeverSuiteCharDB` 쓰기(`=` / `rawset` / 별칭 경유)는 `fsx check`에서 차단합니다.
   - `schemaVersion > 6` 감지 시 자동 `FUTURE_SCHEMA_READONLY` 모드로 진입해 상위 버전 데이터를 보호합니다.
4. **유휴 `0.00ms` 성능 & Zero Fabricated Status**:
   - `Director`의 60Hz `_tweenFrame`, `CharacterDockPanel`의 0.15s 티커, `WorldMapOverlay` 좌표 티커는 비활성·수렴 즉시 정지합니다.
   - API·데이터팩·소지 골드 조회 실패 시 가짜 수치(`0골드`, `0ms`) 대신 명시적 미확인 상태를 표시합니다.
5. **원자적 배포 & 외부 백업 격리**:
   - `fsx install`은 백업을 WoW `AddOns/` 외부(`~/.foreversuite/backups`)에 SHA-256 `manifest.json`과 함께 저장(`--keep 2` 회전)하며, `fsx rollback`으로 1명령 원복합니다.
   - 릴리스 아카이브(`fsx package --max-mb 18`)는 `ForeverSuite_Dev/`·`Private/` 유입을 차단하고 CRC32·SHA-256을 전수 검증합니다.
