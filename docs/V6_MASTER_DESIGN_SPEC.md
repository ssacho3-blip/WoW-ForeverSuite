# ForeverSuite v6.0 — 마스터 소프트웨어 설계 정본 (`V6_MASTER_DESIGN_SPEC` · Rev 6.1 Deepened)

> **방향 확정**: **「길 C: 단일 연출자 OS 셸 + 외부 전문 앱 편입」** (WoW Forever `1.60.1.71037` · TOC `16001` · Lua 5.1)
> **작성/심화일**: 2026-11-27 KST · **설계 위원회 (5개사 대표모델 1차 합동 + Opus 5.5 & Carbon High 실코드 대조 2차 적대적 심화 감사)**
> - **Part A (코어 아키텍처 · 4대 모듈 계약 · Strangler Fig · `full_moon` AST)**: **Anthropic `Claude Opus 5.5`** *(1차 설계 + 2차 실코드 적대적 감사)*
> - **Part B (외부 6대 공식 브리지 · Rust `fsx` · 실클라 QA)**: **OpenAI `GPT-6.2 Sol`**
> - **Part C (연출 State-Morphing · 디자인 시스템 · 5대 맥락형 UX · 실전 엣지케이스)**: **Zhipu `GLM-5.3`** + **Google `Gemini 4 Carbon High`** *(2차 실코드 UX·연출·브리지 심화 감사)*
> - **Part D (148→17MB 자산 · v5→v6 마이그레이션 · 3단 폴백 · 리스크)**: **DeepSeek `DeepSeek-V4.1-Flash`**
> - **통합 설계 · `1.60.1` API 교차검증 · 충돌 최종 조정 (`C1~C7`, `D1~D6`)**: **Google `Gemini 4 Neon High`**

---

## 0. 실코드 대조 교차 검증 · 충돌 해소 원장 (`C1~C7` & `D1~D6`)

구현 전 1차 5개사 설계안을 `WoW Forever 1.60.1` 엔진 규격 및 실제 `v2/ForeverSuite`·`tools/fsx` 코드와 대조하여 **엔진/명세 충돌 7건(`C1~C7`)**과 **실코드 치명 결함 6건(`D1~D6`)**을 사전 해소했습니다.

### 0-1. 엔진 규격 & 명세 내부 충돌 해소 (`C1 ~ C7`)

| # | 발견된 충돌 / `1.60.1` 엔진 함정 | 최종 확정 계약 (SSOT) |
| :-: | --- | --- |
| **C1** | `OnTooltipSetItem` / `GetQuestLogLeaderBoard` / 전투 중 `SpellStopCasting()` 제안 | ❌ 구형/보호 API 금지. **`TooltipDataProcessor.AddTooltipPostCall`** · **`C_QuestLog.GetQuestObjectives`** 사용. 전투 진입 시 낚시는 시전 취소 대신 **비보안 HUD 페이드 + `SecureHandler` 바인딩 자동 해제**만 수행 |
| **C2** | `Spoken:IsPlaying()` 중 `Sound_SFXVolume` CVar 반복 수정 제안 | ❌ CVar 반복 조작 금지. **`Spoken:IsPlaying() == true`일 때 ForeverSuite 자체 비생존 효과음 스킵**(단, 저체력 `≤30%` 생존 경보는 무음 게이트 우회, `"SFX"` 채널 전용) |
| **C3** | 이미지 최적화에 `PNG8` 제안 + 오디오 `"Master"` 채널 제안 | ❌ **WoW `1.60.1`은 `.png` 텍스처 미지원!** 모든 텍스처는 **POT `.tga`(RLE 압축) 또는 `.blp`**만 허용. 오디오는 **`"SFX"`** 채널 + 내장 `SoundKit ID`(0KB) 우선 |
| **C4** | `CharacterFrame` 직접 `SetPoint` + `0.1s OnUpdate` vs Zero-Taint | `UIParent` 직계 형제 프레임 + `CharacterFrame:HookScript("OnShow"/"OnHide")` + **열려 있을 때만 `0.15s` active-only Ticker**(우측 폭 초과 시 좌측 도킹, 닫힘 시 `0.00ms`) |
| **C5** | *(Rev 6.1 Opus `D1` 교정)* SavedVariables 전역 대상 오류(`ForeverSuiteDB` vs `ForeverSuiteV2DB`) | ❌ `.toc` SV 이름 변경 금지(데이터 소실)! 실제 v5 활성 SV인 **`ForeverSuiteV2DB` + `ForeverSuiteV2CharDB`**(`schemaVersion 5→6`)를 v6 활성 전역으로 고정 유지. 구형 v1 **`ForeverSuiteDB`/`ForeverSuiteCharDB`**는 정적 검사로 **쓰기 영구 금지**(읽기 전용 아카이브) |
| **C6** | `I2(GetTime 산술 금지)` 범위 vs 비전투 타이머 | `I2`(`C_DurationUtil` 단일 경로)는 **전투 오라/쿨기(`Secret` 가능 API)**에 강제. 비전투/비비밀 타이머(낚시·XP/h·풀링)는 active-only `C_Timer.NewTicker` 허용 |
| **C7** | *(Rev 6.1 Carbon 검출)* `C2`(CVar 미변조) ↔ `C-3`(낚시 `Sound_SFXVolume` 부스트) 충돌 + `Alt+F4` 오염 | ① 낚시 사운드 부스트 **기본 `OFF`** ② 변조 직전 **`ForeverSuiteV2DB.v2.state.cvarRestoreJournal`**에 원복 값 기록 → **Boot Phase 1 최선두에서 `Alt+F4`/크래시 미복구 저널 자동 원복** ③ `Spoken:IsPlaying()` 중 부스트 일시 해제 |

### 0-2. 실코드 대조 치명 결함 & 보정 원장 (`D1 ~ D6`, Opus 5.5 + Carbon High)

| # | v5 실코드에서 발견된 치명 결함 | 실패 시나리오 | v6 확정 보정 계약 |
| :-: | --- | --- | --- |
| **D1** | `ProfileStore.lua:30`이 `_G.ForeverSuiteV2DB`를 활성 SV로 사용 중 | v6가 `ForeverSuiteDB`를 쓰면 v1 아카이브 덮어쓰기 + v5 유저 데이터 고아화 | `ForeverSuiteV2DB` 고정(`schemaVersion 5→6`), `ForeverSuiteDB` 쓰기 AST 차단 |
| **D2** | `ProfileStore.lua:43` `PresetManager`가 `CharDB.syncedSharedSettings`에 별도 저장 | v6 `chars[key]` 계층과 이중 저장(Split-Brain) | `PLAYER_LOGIN` 1회만 `chars[key]`로 흡수 후 `applySyncedOnNextLogin=false`, 구 필드는 읽기 전용 shim |
| **D3** | `CombatQueue.lua:41` `Flush()`가 진입 시 1회만 `InCombat()` 확인 후 큐를 선삭제 | 플러시 도중 전투 재진입 시 남은 콜백 전투 실행(Taint) 또는 영구 유실 | **항목마다 `InCombat()` 재확인** + 미실행 `tail`을 신규 항목 앞에 재삽입 + `flushing` 재진입 가드 + `pass ≤ 3` + `maxRetry=2` + `CQ.Run = CQ.RunOrDefer` |
| **D4** | `Bootstrap.lua` `EventBus`가 `YIELDED`/`FAULTED` 모듈에도 이벤트 계속 분배 + 단일 오류 시 체인 중단 | 외부 애드온에 양보한 모듈이 계속 반응해 충돌/연쇄 오류 | 모든 기능 구독을 **`BridgeHost:Subscribe(id, ev, fn)`**로 일원화 → 상태 전이 시 O(1) 구독 일괄 해제 + 핸들러별 `xpcall` |
| **D5** | `SafeAPI.lua:98` `_G.ForeverSuite_RegisterPack`이 `schemaVer == 2`만 허용 + 샤드 불완전 활성 | v6 팩 거부 또는 일부 샤드 누락 상태에서 불완전 데이터 노출 | `schemaVer ∈ {2, 6}` 정규화 · `shardIdx` 멱등 · `received == totalShards` 충족 시에만 `ACTIVE`(이전 `PENDING`) |
| **D6** | `ProfileStore:Set`이 SV 쓰기+프레임 반영 동시 실행 + 단일 `layout` 키 + 전투 `/reload` 시 `QuestItemDock:53`·`FishingCastButton:57` Taint | 전투 중 레이아웃 변경/재접속 시 Taint, 3기기 좌표 서로 덮어쓰기 | SV 쓰기는 즉시 · 프레임 반영 및 Phase 5 Secure 생성 전량을 **`CombatQueue:RunOrDefer`**로 지연. v5 `layout`은 `devices.legacy`로 보존 후 신규 기기 첫 접속 시 **copy-on-first-sight** |

---

## Part A. 코어 아키텍처 · 4대 모듈 정밀 계약 · Strangler Fig · `full_moon` AST (`Claude Opus 5.5` + `Neon`)

### A-1. 타겟 7계층 구조 & 단방향 의존 규칙 (`Rank 0 → 5`)

| Rank | 계층 | 폴더 | 책임 | 허용 의존 | 금지 |
| :-: | --- | --- | --- | --- | --- |
| **0** | `Domain` | `Domain/` | 순수 규칙 · 상태 머신 · 스키마 · ViewModel | 없음 | `_G`, `C_*`, `CreateFrame`, `GetTime` |
| **1** | `Api` | `Api/Adapters/` | `C_*` 어댑터 8분할 + `ProfileStore` + `AddonProbe` + `EventBus` | Rank 0 | Frame 생성 |
| **2** | `Secure` | `Secure/` | `CombatQueue`, `SecureHandlerWrapScript`, `QuestItemDock`, `FishingCastButton` | Rank ≤ 1 | `UI`, `Features`, `Blizzard` |
| **3** | `Blizzard` | `Blizzard/` | 기본 프레임 읽기전용 후크(`Tooltip`, `WorldMap`, `ObjectiveTracker`, `CharacterDock`) | Rank ≤ 2 | `Bridges` 상호참조 금지 |
| **3** | `Bridges` | `Bridges/` | `BridgeHost` + 외부 최고봉 공식 API 어댑터 6종 (`Baganator`, `Syndicator`, `Auctionator`, `DialogueUI`, `Spoken`, `Platynator`) | Rank ≤ 2 | `Blizzard` 상호참조 금지 |
| **4** | `UI` | `UI/` | `Tokens`, `PixelUtil`, `TextureSlice`, `HudLayout`, `Widgets/*`, `CommandHub`, `Director` | Rank ≤ 3 | `Features` |
| **5** | `Features` | `Features/` | Composition Root · 6-Phase `Boot/` · `Manifest` · 핵심 기능 모듈 | Rank ≤ 4 | — |

- **강제 수단**: `local _, ns = ...` 유지 + `ns.Define(layer, name, deps)` 런타임 Rank 검증 + **Rust `fsx check` (`full_moon 2.0`) AST 하드 게이트** (`rank(owner) <= rank(self)`, `Blizzard↔Bridges` 상호 배제, 전 파일 **≤ 450 LOC**, TOC 로드 순서 = Rank 오름차순).

### A-2. God-File 4종 분할 & Strangler Fig 11단계 무중단 전환 전략

| 현 v5 God-File (LOC) | v6 분할 타겟 | 목표 LOC |
| --- | --- | --- |
| `Api/GameAdapters.lua` (2,048L · 110함수) | `Api/Adapters/{Unit, Aura, Spell, Duration, Item, Map, Social, System}.lua` | 8 × ≤ 290L |
| `UI/Widgets.lua` (1,493L) + `CompositeWidgets.lua` (1,124L) | `UI/Widgets/{Primitives, Button, Input, ScrollList, StatusBar, Arrow3D, Composites}.lua` | 7 × ≤ 280L |
| `Features/Bootstrap.lua` (1,238L) | `Features/Boot/{Phases, Schemas, Slash, Migrate}.lua` + `Features/Manifest.lua` | 5 × ≤ 320L |
| `Features/UtilitiesPage.lua` (1,200L) | `Features/{ChatTools, AltDecision, Bookmarks, UtilitiesHub}.lua` + `GdkpModule`(Optional-LoD) | 5 × ≤ 280L |

- **Strangler Fig 무중단 전환 순서 (매 커밋 `fsx test` 100% Green 유지)**:
  1. **경계 선설치 (동작 변화 0)**: ① `CombatQueue` v6 수정 + `CQ.Run` 별칭 ② `Domain/Coexistence.lua` + `Api/AddonProbe.lua` 추가 ③ `ProfileMigrationModel` 5→6 Expand ④ `fsx check` 신규 규칙 경고 모드 + baseline ratchet 파일 생성.
  2. **점진 분할 (`setmetatable(..., {__index=Merged})` 재수출 shim 유지)**: ⑤ `GameAdapters` 분할(말단 영향 최소) → ⑥ `Widgets` → ⑦ `UtilitiesPage` → ⑧ `Bootstrap` (`Features/Manifest.lua` 도입 후 커밋당 모듈 1개씩 `BridgeHost` 이관, `.toc`에서 신규 파일을 shim보다 먼저 로드).
  3. **정리 & 하드 게이트 전환**: ⑨ AST로 shim 참조 0건 확인 후 삭제 → ⑩ 계층 순위·`≤450L`·`@secret` 규칙 hard-fail 승격 → ⑪ v5 구 `settings`/`layout` 제거(Contract).

### A-3. `CoexistenceRegistry` 5-상태 머신 (`Domain/Coexistence.lua` + `Api/AddonProbe.lua`)

*(Rev 6.1 보강: `Syndicator.API.IsReady()` 콜드부팅 지연으로 인한 `FAULTED` 영구 고착 방지를 위해 비결함 대기 상태 **`BRIDGE_WARMING`** 신설 — 5상태 × 8이벤트 = **40셀 DDT**)*

| 현재 상태 \ 이벤트 | `ABSENT` | `PRESENT` | `BRIDGE_WAIT` | `BRIDGE_OK` | `BRIDGE_FAIL` | `CONFLICT` | `OVERRIDE(self)` | `RESET` |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **`SELF`** | `SELF` | `YIELD→YIELDED` / `BRIDGE→BRIDGE_WARMING` | `BRIDGE_WARMING` | `BRIDGE_ONLY` | `FAULTED` | `FAULTED` | `SELF` | `SELF` |
| **`YIELDED`** | `SELF` | `YIELDED` | `FAULTED` | `FAULTED` | `FAULTED` | `FAULTED` | `SELF*` | `SELF` |
| **`BRIDGE_WARMING`** | `SELF` | `BRIDGE_WARMING` | `BRIDGE_WARMING` | **`BRIDGE_ONLY`** | `FAULTED` | `FAULTED` | `SELF*` | `SELF` |
| **`BRIDGE_ONLY`** | `SELF` | `BRIDGE_ONLY` | `BRIDGE_WARMING` | `BRIDGE_ONLY` | `FAULTED` | `FAULTED` | `SELF*` | `SELF` |
| **`FAULTED`** | `FAULTED` | `FAULTED` | `FAULTED` | `FAULTED` | `FAULTED` | `FAULTED` | `FAULTED` | `SELF` |

- `BRIDGE_WARMING`은 정상 비결함 대기 상태(값 조회 시 `"—"` 반환, 콜백/`BAG_UPDATE_DELAYED`/`ADDON_LOADED` 수신 시 `BRIDGE_ONLY`로 즉시 승격). 오직 `pcall`/`xpcall` 런타임 예외만 `FAULTED`(흡수 상태, `/fs reset` 해제)로 격리.
- **Bootstrap 6-Phase 불변 순서** (`Features/Boot/Phases.lua`, 각 Phase 모듈별 `xpcall` 격리):
  `1. cvarRestoreJournal 원복 & SavedVars 마이그레이션` ➔ `2. Domain 초기화` ➔ `3. Api/AddonProbe` ➔ **`4. Coexistence Resolve (Secure/UI 선행!)`** ➔ `5. Secure 빌드(CombatQueue 경유, SELF/BRIDGE만)` ➔ `6. UI / Director / Features 마운트`.

### A-4. 핵심 4대 모듈 정밀 Lua 인터페이스 계약 (Contract-First)

```lua
-- ① Domain/Coexistence.lua (순수) + Api/AddonProbe.lua (I/O)
-- policy = { conflictsWith = { "AddonA" }, mode = "yield" | "bridge" | "coexist" }
function Coexistence.Transition(state, event, policy) --> newState, reason
function Coexistence.ResolveAll(probes, overrides)    --> { [moduleId] = { state, reason } } | BLOCKED
function AddonProbe.Probe(addonName)                  --> { loaded = bool, enabled = bool, loadable = bool }

-- ② Bridges/BridgeHost.lua (단일 브리지 생명주기 · O(1) 구독 해제 · xpcall 격리)
BridgeHost:Register({ id = "baganator", target = "Baganator", init = fn, teardown = fn, protected = false })
BridgeHost:Subscribe(id, event, fn)                   -- 현재 상태가 SELF|BRIDGE_ONLY일 때만 분배, 상태 전이 시 O(1) 해제
BridgeHost:OnAddonLoaded(addonName)                   -- 지연 로드 시 재-Probe → Transition → xpcall(init)
-- protected == true인 init은 CombatQueue:RunOrDefer("bridge:" .. id, fn) 강제 경유

-- ③ Secure/CombatQueue.lua v6 (항목별 InCombat 재확인 · 꼬리 보존 · 재진입 가드)
function CombatQueue:RunOrDefer(key, fn)              --> executedBool, reason ("DEFERRED"|"INVALID_FN"|err)
CombatQueue.Run = CombatQueue.RunOrDefer              -- v6 호환 별칭
function CombatQueue:Flush()                          --> ranCount, failedCount
-- Flush 계약: flushing 재진입 가드 · while i <= #order and not InCombat() (항목마다 재확인)
-- 미실행 tail을 플러시 중 신규 등록된 key보다 앞에 유지 · pass <= 3 · xpcall + maxRetry = 2

-- ④ Domain/ProfileMigrationModel.lua v6 (Expand → Migrate → Contract on ForeverSuiteV2DB)
function ProfileMigrationModel.Migrate(rawV2DB, defaults, optionalV1DB, ctx)
  --> newDb | nil, readOnlyBool, report { status = "OK"|"NOOP"|"BLOCKED", reason }
  -- schemaVersion > 6 → BLOCKED(ReadOnly=true, 쓰기 0건)
  -- schemaVersion == 5 → 사본 DeepCopy(_v1_backup 제외 → _backup_v5 저장) + profiles={account, devices={legacy=layout}, chars={}}
function ProfileMigrationModel.Resolve(profiles, section, key, charKey, deviceKey, defaultVal)
  -- 우선순위: chars[charKey] > devices[deviceKey] > account > defaultVal (신규 기기는 devices.legacy copy-on-first-sight)
```

### A-5. 7대 절대 불변식 (`I1 ~ I7`), `full_moon 2.0` AST 알고리즘 & 인수조건 (`AC-1 ~ AC-10`)

| ID | 불변식 | 강제 게이트 (`tools/fsx/src/check.rs` · `full_moon 2.0`) |
| :-: | --- | --- |
| **I1** | **Secret 불투명성**: `---@secret` 값에 `== < > + - * / .. # tostring format`, 테이블 키, `ProfileStore:Set`, `SendChatMessage` 금지. 허용 sink는 `CreateDurationTextBinding`, `CreateNumericRuleFormatter`, `StatusBar:SetValue`, `FontString:SetText` 한정 | **보수적 함수 내부 오염 추적**: `---@secret`/API source → 이항연산/테이블/upvalue 전파 → `SafeRead`/`if IsSecret(x) then return end` 정화 → 합류점 `must=Error / may=Warn`, 루프 고정점 ≤3회 + `mlua` 프록시 퍼저 교차검증 |
| **I2** | **전투 타이머 단일 경로**: 전투 오라·쿨기·스택은 `C_UnitAuras.GetAuraDuration` · `C_Spell.GetSpellCooldownDuration` · `C_DurationUtil.CreateDurationTextBinding` · `GetAuraApplicationDisplayCount` 전용 | AST + `ForeverTotems` 검증 패턴 *(비전투 낚시·XP/h·풀링은 active-only Ticker 허용)* |
| **I3** | **CombatQueue 단일화**: `SetAttribute`, secure `Show/Hide/SetPoint/SetScale`, `SetCVar`, `SetOverrideBindingClick`, `C_EditMode.SetActiveLayout`은 `CombatQueue:RunOrDefer` 단일 경유 | `Secure/` 외 직접 호출 AST 금지 |
| **I4** | **Secure/Blizzard 격리**: 전투 중 보호 동작은 `SecureHandlerWrapScript` 한정 · `hooksecurefunc`는 `Blizzard/` 한정 · 블리자드 프레임 필드 직접 대입 금지(Weak-Key 테이블 전용) · 전 Secure 프레임은 `UIParent` 직계 형제 격리 | 경로 화이트리스트 + 7계층 심볼 소유권 AST (`ns.X` 별칭 연쇄 추적 + TOC 선행 로드 검증) |
| **I5** | **SavedVariables 3계층**: 활성 전역은 **`ForeverSuiteV2DB` + `ForeverSuiteV2CharDB`**(`schemaVersion=6`), 기기 키 **`"%dx%d@%.2f:%s"`**, 구형 `ForeverSuiteDB` 쓰기 금지 | `Domain/ProfileMigrationModel.Resolve` + AST 전역 쓰기 차단 |
| **I6** | **스키마 Fail-Closed**: `schemaVersion > 6` 또는 예외 시 `ReadOnly = true`(쓰기 0건). 사본 검증 후 원자적 교체 + `_backup_v5` 보존 + `cvarRestoreJournal` 부팅 원복 | `Migrate` + `ProfileStore:CanWrite` 가드 |
| **I7** | **Zero Fabricated Status**: secret·함수 SV 저장 금지. 미조회/미캐시(`BRIDGE_WARMING` 포함) 시 가짜 `0`·`"Ready"` 대신 `"—"` 또는 숨김 | `Store.Commit` 타입 검증 + DDT |

| ID | 검증 대상 | 자동 PASS 기준 |
| :-: | --- | --- |
| **AC-1** | 7계층 단방향 의존 | `fsx check` 계층 위반 `0`, `Blizzard↔Bridges` 상호참조 `0`, `ForeverSuiteDB` 쓰기 `0` |
| **AC-2** | 파일 크기 상한 | `v2/ForeverSuite/**/*.lua` 전 파일 **≤ 450 LOC**, God-File 4종 제거 |
| **AC-3** | TOC 정합성 | `## Interface: 16001`, `OptionalDeps` 외부 8종+LSM 명시, 로드 순서 Rank 오름차순 |
| **AC-4** | `Coexistence` 상태 머신 DDT | **5상태 × 8이벤트 = 40셀 전수 테스트 PASS**, `BRIDGE_WARMING→BRIDGE_ONLY` 승격 및 `FAULTED` 흡수 검증 |
| **AC-5** | 외부 9종 공존 격리 | 외부 Mock `PRESENT` 시 `{YIELDED, BRIDGE_WARMING, BRIDGE_ONLY}` 전이 · 중복 프레임/훅/이벤트 분배 `0` |
| **AC-6** | `@secret` AST 게이트 | 실코드 위반 `0` + 주입 뮤턴트(`if dur > 0`, `dur..""` 등 5종) **전수 Red 검출** |
| **AC-7** | `CombatQueue` 전투 잠금 & 재진입 | Lockdown 중 50건 실행 `0` + **플러시 중 전투 재진입 시 잔여 꼬리 100% 보존** → 재이탈 후 정확히 1회 실행 |
| **AC-8** | SV 무손실 마이그레이션 | v5 `ForeverSuiteV2DB` 4종 fixture → v6 3계층 왕복 무손실(`PresetManager` 흡수·보호목록·원장·HUD 보존), v7 주입 시 쓰기 `0` |
| **AC-9** | Boot 순서 & 격리 | Phase 로그 `cvarRestore/Migrate < Coexistence < Secure(CombatQueue) < UI`, 단일 모듈 예외 시 타 모듈 정상 기동 |
| **AC-10** | 실클라이언트 무오염 & 성능 | `Stage A~E` + **`Q1~Q5`** 전수 PASS: `taint.log` FS 귀속 `0`, 유휴 `0.00ms`, 전투 `≤1.0ms`, `YIELDED` `0.00ms` |

---

## Part B. 외부 6대 공식 API 브리지 · Rust `fsx` CLI · 5단계 실클라 QA (`GPT-6.2 Sol` + `Carbon High`)

### B-1. `Bridges/*.lua` 6대 공식 브리지 + `ForeverTotems`/`RareScanner` 공존 계약

| 대상 / 파일 | 공식 API & 로드 방어 | 핵심 길 C 연출 · 실전 함정 방어 (Rev 6.1 보강) | Taint / 전투 안전 규칙 |
| --- | --- | --- | --- |
| **`Bridges/Baganator.lua`** | `Baganator.API`: `RegisterCornerWidget`, `RegisterJunkPlugin`, `RegisterUpgradePlugin`, `RegisterRegion(backpack, bottom_left)`, `ImportString` | ① **4코너 배지**: 사전 빌드 **O(1) 해시맵 조회**만 허용(200칸 고속 스크롤 스파이크 `<2.0ms`, 미캐시만 `return nil` 재시도) ② `/fs protect` 잡템 제외 + BiS/`+iLvl` 녹색 화살표 직결 ③ **`bottom_left` 도킹**: 8열 화폐 침범 방지를 위해 **폭 `≤52px×20px` 초소형 `"정리"` 필 버튼**(호버 시 최저가 Top 5) ④ `ImportString`은 `/fs setup` 명시 동의 시 1회 한정 | 등록·Import 비전투 1회. 표시 전용(이동/판매 호출 금지) |
| **`Bridges/Syndicator.lua`** | `Syndicator.API`: `IsReady`, `GetInventoryInfoByItemID`, `GetCurrencyInfo`, `GetAllCharacters` | ① 콜드 부팅 시 `IsReady()==false`면 **`BRIDGE_WARMING`** 대기(`"—"` 반환, 절대 `FAULTED` 금지) → 콜백/`BAG_UPDATE_DELAYED` 수신 시 `BRIDGE_ONLY` 승격 ② 부캐 재고·화폐·골드 읽어 부캐 결정 계층 & 부족 재료 차감 | 100% 읽기 전용, 이벤트 기반 갱신 |
| **`Bridges/Auctionator.lua`** | `Auctionator.API.v1`: `GetAuctionPriceByItemID`, `GetDisenchantPriceByItemID`, `GetVendorPriceByItemID`, `CreateShoppingList`, `RegisterForDBUpdate` | ① `RegisterForDBUpdate` 수신 시 시세 캐시 즉시 무효화 ② 미조회 시 `0c` 금지(`"—"`, I7) ③ `Auctionator` 툴팁 시세 활성 시 FS 상점가 라인 자동 양보 ④ 부족 재료 1클릭 쇼핑리스트 생성 | `CreateShoppingList` 비전투 사용자 클릭 전용. 자동 매매/스캔 금지 |
| **`Bridges/DialogueUI.lua`** | `DialogueUIAPI`: `AddItemEvaluator("ForeverSuite", ...)`, `SetTranslator(...)`, `GetActiveTranslator`, `IsAnyDUIWindowShown` | ① `GetActiveTranslator()` 기등록 시 기존 번역기 존중 양보 ② **`questDataGetter`는 실시간 텍스트에 완성형 한글(`[\234-\237][\128-\191][\128-\191]`) 부재 시에만** 번역 주입(본편 85%+ 순정 한글 퀘스트는 `return nil` 원문 보존!) ③ 완료 보상 카드에 BiS/`+iLvl` 업글 공식 주입 ④ `QuestAutomation` 기본 `YIELDED` | 등록 비전투 1회. 자동 수락/완료 강제 금지 |
| **`Bridges/Spoken.lua`** | `Spoken:IsPlaying`, `GetNowPlaying`, `RegisterCallback`, `AddGate` | ① `Spoken:IsPlaying()` 중 **비생존 효과음·토스트 스킵 + 낚시 사운드 부스트 일시 해제**(단, 저체력 `≤30%` 생존 경보는 무음 우회) ② `QuestAutomation` 기본 `YIELDED` | 콜백은 상태 플래그만 갱신, `AddGate`는 FS 소유 클립만 제어 |
| **`Bridges/Platynator.lua`** + **`ForeverTotems`/`RareScanner`** | `Platynator.API.ImportString` + `LibSharedMedia-3.0`(4종 폰트) + `AddonProbe` | ① `Platynator`: 이름표 전권 `YIELDED` + `/fs setup` 선택 시 1클릭 프리셋 Import ② **`ForeverTotems` + `SHAMAN`**: 주술사 무기마부/번개보호막 체크 `YIELDED`(`0.00ms`) + 하단 중앙 토템바 안전영역(`y=140..210`) 예약 ③ **`RareScanner`**: 희귀몹 핀/경보 `YIELDED` | 비전투 사용자 클릭 전용. 이름표 프레임/CVar 직접 변경 금지 |

- **TOC `OptionalDeps` 필수 명시**: `Baganator, Syndicator, Auctionator, DialogueUI, Spoken, Platynator, ForeverTotems, RareScanner, LibSharedMedia-3.0, ForeverSuite_Data, ForeverSuite_Media`.

### B-2. Rust `fsx` v6 CLI & CI/배포 파이프라인 (`release.yml` 재작성)

| 커맨드 / 워크플로 | 핵심 역할 | FAIL 조건 (Fail-Closed) |
| --- | --- | --- |
| `fsx check v2/ForeverSuite` | 7계층 AST(`full_moon 2.0`) · `@secret` 오염 추적 · `≤450L` · TOC `16001` & `OptionalDeps` · `ForeverSuiteDB` 쓰기 차단 · `Private/` 유출 검사 | 위반 1건이라도 존재 시 exit 1 |
| `fsx test v2` | Lua 5.1 `mlua` VM + `C_Secrets` 퍼저 + `Coexistence` **40셀** + 외부 9종 조합 12케이스 + `CombatQueue` 재진입 테스트 + **0팩 로드 생존** + SV 마이그레이션 T1~T6 | 실패·스킵·타임아웃 시 exit 1 |
| `fsx install --keep 2` | 백업을 게임 폴더 밖 **`~/.foreversuite/backups/`**에 저장(기존 `AddOns/.fsx_prev_backup_*` 1.1GB 정리!) · SHA-256 검증 후 원자적 스왑 · 최신 2세대만 유지 + `fsx rollback` | 해시 불일치·부분 설치·백업 검증 전 삭제 시 롤백 |
| `fsx package` & `release.yml` | 삭제된 v1 `scripts/` 폐기 → `cargo run --bin fsx -- package`로 macOS/Windows ZIP + SHA-256 생성, 태그↔TOC 일치 검증 후 GitHub Release 발행 | 용량 > 18MB, 태그 불일치, `Private/` 포함 시 차단 |
| `fsx taint-report --taint-log` | 실클라이언트 `Logs/taint.log` 파싱 → `ForeverSuite` 귀속 라인 0건 판정 및 릴리스 증거 번들링 | FS 귀속 `taint`/`ADDON_ACTION_BLOCKED` 1건이라도 발견 시 FAIL |

### B-3. 5단계 실클라이언트 QA (`Stage A ~ E`) & 필수 포착 5대 치명 시나리오 (`Q1 ~ Q5`)

| # | Stage | 구체적 재현 절차 | PASS 판정 기준 |
| :-: | :-: | --- | --- |
| **Q1** | **Stage C (전투·Taint)** | `/console taintLog 2` → 낚싯대 장착(`fishingDoubleClick=ON`) → 월드 우클릭 1회(`BUTTON2` 무장) 후 0.2초 내 몹 애드 → 우클릭 시점 회전·추적창 스크롤 → **전투 중 `/reload`** → 재접속 즉시 `죽은척하기(5384)`/`소멸(1856)` 후 0.5초 내 재타격 | 시점 먹통 `0회`, `taint.log` FS 귀속 **`0건`**, `ADDON_ACTION_BLOCKED` **`0건`**, `1.2s` 홀드 중 스트로빙 `0회`, 전투 종료 후 `QuestItemDock` 정상 복구 |
| **Q2** | **Stage B (공존·지연)** | 외부 9종 ON + **주술사** 콜드 실행 → 0.5초 내 가방 오픈 → 순정 한글 퀘스트 1개 + 미번역 영문 다중보상 퀘스트 1개 대화(`Spoken` 재생) → 대화창 열린 채 몹 애드 | `Syndicator` `BRIDGE_WARMING("—")→BRIDGE_ONLY` 승격(`FAULTED` 0), 한글 원문 보존·영문만 번역+`+iLvl/BiS` 주입, `Spoken` 조기 절단 `0회`, 주술사 중복 배너 `0개` |
| **Q3** | **Stage D (복구·예산)** | `Sound_SFXVolume=0.35` → 낚시 부스트 ON & 장착 → `Alt+F4` 강제종료 후 재접속 → `Baganator` 200칸 고속 스크롤 → 5인 던전 10마리 전투 60초 `C_AddOnProfiler` 계측 | 재접속 즉시 `cvarRestoreJournal`이 `0.35` 원복, 가방 스크롤 스파이크 `<2.0ms`, 전투 중앙값 **`≤1.0ms`** · 유휴 **`0.00ms`** · `YIELDED` **`0.00ms`** |
| **Q4** | **Stage A/E (0팩·노후)** | ① `ForeverSuite_Data` 삭제 부팅 후 추적창·화살표·낚시·캐릭터창(`C`) 3탭·상점·보호배지 조작 ② 복원 후 `manifest.lua` `builtForInterface=15999` 변조 `/reload` | Lua 에러 **`0건`**, 가짜 `0` 생성 `0건`(`"—"`), 구버전 팩 감지 즉시 `LIVE`+`Embedded` 전환 및 진단 탭 `[STALE_PACK]` 표기 |
| **Q5** | **Stage E (Setup·3기기)** | `C_EditMode` 5/5 슬롯 포화 + 커스텀 `Baganator` 테마 상태에서 `/fs setup` 2회 연속 완주 → `/fs setup undo` → `3840×2160@0.65` ↔ `1920×1080@1.00` 전환 | `LAYOUT_LIMIT` 에러·중복 생성 `0건`(제자리 갱신), `undo` 시 CVar·`EditMode`·외부 스킨 100% 원복, 해상도 전환 즉시 이탈/겹침 `0건` 및 물리 `1px` 테두리 유지 |

---

## Part C. Director 연출 엔진 · 디자인 시스템 · 5대 맥락형 화면 (`GLM-5.3` + `Carbon High` + `Neon`)

### C-1. Director State-Morphing 상태 머신 & 히스테리시스 (`UI/Director.lua`)

- **상태 우선순위**: **`EDIT_OVERRIDE(/fs move)` > `COMBAT` > `DEAD` > `FISHING` > `DIALOGUE` > `EXPLORATION`**
- **단일 트윈 엔진**: `AnimationGroup` 다중 생성 금지 → 단일 `60Hz` `Director._tweenFrame`이 현재 `GetAlpha()`에서 이어받아 보간하고 수렴(`|Δα| < 0.01`) 즉시 `OnUpdate = nil` 분리(**유휴 `0.00ms`**).

| HUD \ 상태 | `EXPLORATION` | `FISHING` | `DIALOGUE` | `COMBAT` | `DEAD` |
| --- | --- | --- | --- | --- | --- |
| **퀘스트 추적창** | `α 1.00` (300/150ms) | `α 0.45` | `α 0.35` (시선 양보) | `α 0.35` (200/80ms) | `α 0.25` |
| **3D 화살표** | 웨이포인트 시 `α 0.90` | 어군 핀 시만 `0.85` / 외 `0` | `α 0.00` | `α 0.65` | **시체 자동 `α 1.00`** |
| **낚시 대상어 HUD** | `α 0.00` (0px) | **`α 1.00`** (200ms) | `α 0.00` | **즉시 `α 0.00`** *(비보안 페이드 + `_onstate-combat` 바인딩 해제)* | `α 0.00` |
| **상단 상태 필 바** | `α 0.88` | `α 0.55` | `α 0.40` | `α 0.95` | `α 0.50` (유령 톤) |
| **전투 보조 HUD** | 비전투 자버프 누락만 | `α 0.00` | `α 0.00` | **`α 1.00`** (200ms) | `α 0.00` |
| **알림 토스트** | `α 1.00` | 낚시 로그만 | **보류** (`Spoken` 재생 중 무음) | 전투 필수 경고만 *(생존 경보 무음 우회)* | 부활/시체 안내 |

- **실전 엣지케이스 & 히스테리시스 확정 규칙 (Rev 6.1)**:
  1. **죽은척(`5384`)·소멸(`1856`) 스트로빙 차단**: `UnitIsFeignDeath("player") == true` 시 `DEAD`·`CorpseGuide` 진입 절대 차단. 전투 이탈 시 `CombatQueue`/`NavPort` 플러시는 `0ms` 즉시 실행하되, 시각 복귀 및 `FishingCastButton:SetActive(true)` 재무장은 **`1.2s` 무교전 홀드** 후 실행(재교전 시 취소).
  2. **탑승 & 대화 디바운스**: `IsMounted()` 중엔 낚싯대 장착이어도 `EXPLORATION` 유지(`UNIT_INVENTORY_CHANGED` `250ms` 디바운스). 다단계 수락/완료 깜빡임 방지용 `DIALOGUE` 이탈 **`350ms` 디바운스**. 전투 종료(`1.2s`) 시 대화창이 열려 있으면 `EXPLORATION` 생략 후 `DIALOGUE` 직행.
  3. **유령 `PLAYER_ALIVE` 오판 & 수동 `/way` 보호**: `DEAD` 판정을 `UnitIsDeadOrGhost("player") and not UnitIsFeignDeath("player")`로 단일화. 사망 진입 시 기존 `/way`를 `preDeathTarget`에 백업 후 부활 **`0.4s` 안정화 뒤 복원**(인던 사망으로 좌표 `nil` 시 가짜 화살표 숨김).
  4. **보안/비보안 경계**: **Non-Secure(전투 허용)** = `UIParent` 직계 HUD 6종 `SetAlpha`/`SetText`/`StatusBar:SetValue`/`C_DurationUtil`. **Secure(`CombatQueue` 전용)** = `QuestItemDock`·`FishingCastButton`·`ObjectiveTrackerAdapter` `Show/Hide/SetPoint/SetAttribute`/`SetScale`(전 Secure 프레임은 `UIParent` 직계 형제로 격리).

### C-2. 통합 디자인 토큰 & 3기기 HiDPI (`PixelUtil` + `TextureSlice`)

| 의미 토큰 | Hex | 용도 | 배경/중립 토큰 | Hex |
| --- | --- | --- | --- | --- |
| **`GOLD`** | `#E6C35C` | 퀘스트 · 목표 · 가치 · 강조 | **`BG_PANEL`** | `#14161A` @92% |
| **`GREEN`** | `#55D46A` | 완료 · BiS 업글 · 안전 | **`BORDER`** | `#2A2E38` (`onePixel`) |
| **`SKY`** | `#4FA6E0` | **`보호` 배지** · 시세 · 정보 | **`TEXT_MAIN`** | `#EDEDF0` |
| **`CRIMSON`** | `#D93A3A` | 위험 · 저체력 · 최저가 경고 | **`TEXT_MUTED`** | `#9AA0AC` |

- **1px 물리 픽셀 공식 (`UI/PixelUtil.lua`, `Tokens.lua:269` 교정)**: `onePixel = (768.0 / physH) / frame:GetEffectiveScale()`, `SetSnapToPixelGrid(false)` · `SetTexelSnappingBias(0)`.
- **네이티브 9-Slice (`SetTextureSliceMargins`)**: `1.60.1` 네이티브 슬라이스 우선(드로우콜 1/9 절감, 미지원 폴백 유지).
- **3기기 자동 레이아웃 (`HudLayout.lua`)**:
  - 저장 키: `format("%dx%d@%.2f:%s", physW, physH, uiScale, IsMacClient() and "MAC" or "WIN")` + **정규화 중심 좌표 `(nx, ny) ∈ [0, 1]`**(사분면 오프셋 탈피).
  - 타이포 토큰: **FHD**(`12/10pt`) · **Retina**(`13/11pt`) · **4K `physH ≥ 2000`**(`14/12pt` + L0 `OUTLINE`).

### C-3. 5대 맥락형 핵심 화면 & `/fs setup` 3단계 마법사 (Rev 6.1 실코드 정밀화)

1. **퀘스트 추적창 + 3D 화살표**: `C_QuestLog.GetQuestObjectives` 기반 · 최근접 미완료 목표 자동 승계(`4.0s` 히스테리시스)는 **`NavigationHud.target.source == "quest"`일 때만 동작**(수동 `/way`·어군 핀 침범 0건) · `UIParent` 직계 Secure 아이템 버튼(1~6).
2. **낚시 대상어 HUD**: 낚싯대 장착(비탑승) 시만 200ms 페이드인(평소 0px) · 지역 어종 + `Auctionator` 실시간 단가 + 퀘스트 `★` + 어군 좌클릭 3D 화살표 + 미끼 `<60s` 골드 펄스 + 정지 우클릭 0.5초 안전 바인딩 + `Sound_SFXVolume` 크래시 안전 부스트(기본 `OFF`, `cvarRestoreJournal` 보호) *(찌 물기 자동 감지 불가 → 미구현)*.
3. **3단 계층 툴팁 + `Baganator` 4코너 배지 & 하단 `"정리"` 필**: `TooltipDataProcessor` 고정 순서 `[1단 번역·iLvl / 2단 착용 델타·특성점수·BiS / 3단 드랍처·부캐재고(Syndicator)·보호]` + `Auctionator` 시세 중복 양보 + `Baganator` O(1) 4코너 배지 + `bottom_left` `≤52×20px` `"정리"` 버튼.
4. **캐릭터창(`C`) 우측 Zero-Taint 도킹 패널**: `UIParent` 직계 형제 프레임(`EngravingFrame`/평판 탭 폭 변화를 열림 중 `0.15s` 티커로 `(CharacterFrame:GetRight()*charScale/uiScale)+4` 추적, 우측 초과 시 좌측 도킹):
   - **[확장 스탯]**: `GetSpellBonusHealing()`(치유량) · `UnitRangedAttackPower`(원거리 전투력) · `GetManaRegen()*5`(시전/비시전 MP5) · 물리/주문 적중% + 60렙 레이드 캡(`8~9% / 16%`) 잔여치(불명 시 `"—"`).
   - **[업글 Top 3]**: `BiSBrowserModel`에 `reqLevel <= playerLevel + 3` · 고유장착 중복 제외 · 양손무기 `16+17` 합산 비교 추가 + 드랍 보스/퀘스트 `[길안내]` 직결.
   - **[다음 5레벨 스킬]**: `CharacterGuideModel`을 `현재 습득 가능`과 `[curLv+1..min(60, curLv+5)] 예정`(`cost > 0`만 합산)으로 분리 → `부족 골드 = max(0, Σcost - GetMoney())`(`Syndicator` 계정 총골드 병기) + `[상급자 화살표]`.
5. **Command Palette (`Ctrl+K`) + `/fs setup` 3단계 마법사 (멱등·비파괴)**:
   - **Step 1**: 기기 해상도·Mac/Win·외부 9종 자동 스캔 → 공존 매트릭스 프리뷰.
   - **Step 2**: `_setupUndoSnapshot` 백업 후 LSM 4폰트 자동 배급 + **`C_EditMode` `"ForeverSuite"` 존재 시 제자리 갱신**(5슬롯 포화 시 교체 슬롯 선택) + 외부 `ImportString` 체크박스 **기본 `OFF`** + **`/fs setup undo` 1클릭 원복**.
   - **Step 3**: `EXPLORATION → FISHING → COMBAT` 4.5초 라이브 시연 → 기기 키 저장 & `C_EncodingUtil` 3기기 프로필 문자열 Export.

---

## Part D. 148MB→17MB 자산 파이프라인 · 무손실 마이그레이션 · 3단 폴백 · 실행 계획 (`DeepSeek` + `Carbon High` + `Neon`)

### D-1. 폴더 슬림화 (15폴더 148MB → **3폴더 ~16.8MB**, Hard Cap **18.0MB**)

```text
v2/
├── ForeverSuite/           # [필수 Core · ~2.5MB] Lua 7계층 + Embed(≤60KB) + UI TGA(RLE ~0.8MB) + SoundKit(0KB) + .ogg 6개(0.2MB)
├── ForeverSuite_Data/      # [Optional-LoD · ~2.8MB] manifest.lua + 정적 7팩 (0팩이어도 Core 100% 기동!)
├── ForeverSuite_Media/     # [Optional-LoD · ~11.5MB] OFL 한글 폰트 4종(5.5MB) + POT TGA(RLE)/BLP 지도·히트맵(6.0MB)
└── (ForeverSuite_Dev/)     # [.gitignore · 로컬 전용] 원본 덤프 · fonttools/magick/ffmpeg 빌드 스크립트 (배포물 0B!)
```

- **자산 최적화 실측 규칙**:
  - **Fonts (`60.57MB → 5.5MB`)**: SIL OFL 4종(`Pretendard Regular/SemiBold/Bold` + `D2Coding`, `pyftsubset`으로 `U+0020-007E` + `U+AC00-D7A3` + 게임 기호 서브셋팅, `.ttf`).
  - **Audio (`3.10MB → 0.2MB`)**: 내장 `SoundKit ID` (`"SFX"` 채널, 0KB) · 핵심 6개만 `ffmpeg -c:a libvorbis -q:a 2 -ac 1 -ar 22050` `.ogg`.
  - **Textures (`77.3MB → ~7.2MB`)**: **`.png` 금지!** POT(256²/512²) `.tga -compress RLE` 또는 `.blp` 변환 + 미사용 타일 LoD/로컬 분리.
  - **Git 위생**: `.git 65MB → ≤ 8MB` (`git-filter-repo` 백업 후 대용량 바이너리 이관 + `Private/` `.gitignore` 봉쇄).

### D-2. `v5 → v6` 무손실 멱등 마이그레이션 & 롤백 (`Domain/ProfileMigrationModel.lua` + `Features/Boot/Migrate.lua`)

- 활성 전역 **`ForeverSuiteV2DB` + `ForeverSuiteV2CharDB`**에서 `schemaVersion 5 → 6` Expand-Migrate-Contract 수행(구형 v1 `ForeverSuiteDB`는 읽기 전용).
- `_backup_v5 = DeepCopy(db.v2)`(기존 `_v1_backup` 중복 복사 제외로 용량 폭증 방지), `PresetManager`의 `syncedSharedSettings` 1회 흡수, 보호목록·골드원장·HUD 좌표(`devices.legacy` copy-on-first-sight)·부캐 전문기술 다일 쿨다운(`altCooldowns`: 변환 48h·소금 72h·달빛옷감 96h)·`TrackingSwitcher` 100% 보존.
- `/fsdb restore v5` 즉시 롤백 + `schemaVersion > 6` 시 하드 `ReadOnly = true` + v5.x 호환 핫픽스(6일 때 `v2.settings`/`layout` 읽기) 선행 배포로 `fsx rollback` 안전 보장.

### D-3. `Data/manifest.lua` 3단 폴백 & `FS.Data.epoch` 캐시 무효화 계약

- **Manifest 스키마**: `{ schema = 6, builtForInterface = 16001, builtForBuild = "71037", generatedEpoch = ..., packs = { [id] = { shards, sha256_8, ttlDays } } }`.
- `FS.Data:Get(kind, key)` 단일 관문: **① STATIC(`builtForInterface == 16001` & TTL 유효 & 전 샤드 `ACTIVE`)** ➔ **② LIVE(`pcall` 블리자드 `C_*` API)** ➔ **③ OFFLINE 임베디드(`Embedded.lua ≤ 60KB`)**.
- **`FS.Data.epoch` 카운터**: 샤드 로드 완료 · `GET_ITEM_INFO_RECEIVED(id, true)`(단건 LRU 축출) · `SPELLS_CHANGED` 시 증가 → `TooltipEnhanceModule` 등 파생 인덱스는 `_builtEpoch ~= FS.Data.epoch`일 때만 재빌드. **`ForeverSuite_Data` 폴더를 통째로 삭제해도** 코어 전체 오류 0건 100% 기동!

### D-4. Phase 1 ~ Phase 4 구현 실행 계획 & 리스크 레지스터

| Phase | 목표 & 핵심 작업 (WP) | 종료 게이트 (DoD) |
| --- | --- | --- |
| **Phase 1 (P0 · 결함차단·위생·공존·브리지)** | ① **`D1`·`D3` 최우선 수정**: `CombatQueue:Flush()` 재진입/꼬리보존 + `ForeverSuiteV2DB` 쓰기 경계 + `cvarRestoreJournal` ② `AddOns/.fsx_prev_backup_*` **1.1GB 정리** & `fsx install --keep 2` 외부화 ③ `Domain/Coexistence.lua`(40셀 `BRIDGE_WARMING`) + `Api/AddonProbe.lua` + `Bridges/BridgeHost.lua` ④ **외부 6대 공식 브리지 구현**(`Baganator` O(1) 4코너·`"정리"` 필, `Syndicator`, `Auctionator`, `DialogueUI` 한글보호/보상, `Spoken` 덕킹, `Platynator`/`ForeverTotems`/`RareScanner`) | **G1**: AC-4(40셀), AC-5, AC-7 PASS · 외부 9종 충돌/중복 0건 · 게임 폴더 1.1GB 회수 |
| **Phase 2 (P1 · 자산 148→17MB & 배포)** | ① 15폴더 → 3폴더 재편 + OFL 폰트 4종 + 내장 `SoundKit` + POT TGA RLE/BLP ② `Data/manifest.lua` 3단 폴백 + `FS.Data.epoch` + `RegisterPack(2|6)` 원자 샤드 + 0팩 생존 테스트 ③ `v5→v6` 멱등 마이그레이션(`ForeverSuiteV2DB` 3계층 + `PresetManager` 흡수 + `devices.legacy`) T1~T6 ④ `.github/workflows/release.yml` Rust `fsx package` 기반 전면 복구 | **G2**: 총 용량 **≤ 18MB**, AC-8 PASS, 0팩 부팅 PASS, CI Green |
| **Phase 3 (P1 · Strangler Fig 분할 & 연출 UX)** | ① Strangler Fig 11단계로 God-File 4종 분할(`≤450L`) + Rust `full_moon 2.0` 7계층·`@secret` AST 게이트 hard-fail 전환 ② `C_DurationUtil` 전투 타이머 + `TrackingSwitcher`(50L) + 부캐 다일 쿨다운 ③ `UI/Director.lua` 5-State(+`EDIT_OVERRIDE`, `1.2s` 홀드, 단일 60Hz 트윈) + `PixelUtil` + 3기기 `HudLayout(nx,ny)` + 캐릭터창(`C`) 우측 도킹(3탭) + `/fs setup` 3단계 마법사 & `/fs setup undo` | **G3**: AC-1, AC-2, AC-3, AC-6, AC-9 PASS |
| **Phase 4 (P2 · 실클라 QA & 문서)** | ① `Stage A~E` + **`Q1~Q5`** 실클라이언트 검증(`taint.log` 0건 · `C_AddOnProfiler ≤1.0ms` / 유휴·`YIELDED` `0.00ms` · 전투 중 `/reload` · `Alt+F4` CVar 복구) ② `README` · `CHANGELOG` · `ARCHITECTURE` · 노션 정본 v6.0.0 동기화 ③ Track L 3-Family 감사 후 `v6.0.0` 릴리스 승인 요청 | **G4**: AC-10 PASS · Track L 3-Family 감사(`SHIP`) |

#### 핵심 리스크 Top 6 완화책
1. **R1 (폰트 글리프 누락/tofu)**: 완성형 한글 전체(`U+AC00–D7A3`) 포함 + 기본 폰트 폴백 체인.
2. **R2 (`Baganator`/`DialogueUI`/`Syndicator` 업스트림 변경·지연)**: 전 브리지 `pcall` + 함수 존재 검사 + `BRIDGE_WARMING` 비결함 대기 → 런타임 예외만 `FAULTED` 격리, 코어 무영향.
3. **R3 (`v5→v6` 데이터 유실·롤백)**: `ForeverSuiteV2DB` 유지 + `_backup_v5`(`_v1_backup` 제외) + `/fsdb restore v5` + v5.x 호환 핫픽스 선행.
4. **R4 (`1.60.1` 패치 후 정적 팩 노후화)**: `builtForInterface != toc` 감지 즉시 `LIVE` API + `Embedded.lua` 자동 전환 + `[STALE_PACK]` 진단 표기.
5. **R5 (전투 중 `/reload`·죽은척 Taint)**: Phase 5 Secure 전량 `CombatQueue` 지연 + `Flush()` 항목별 `InCombat()` 재확인 + `1.2s` 홀드 + `Q1` 실클라 검증.
6. **R6 (Private/추출 에셋 유출)**: `ForeverSuite_Dev/Private/` `.gitignore` + CI `fsx check` 차단 게이트.
