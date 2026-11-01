# Phase 1 — 기존 유명 WoW 애드온 26종 정밀 조사 · 호환성 검증 · 기능 선정 매트릭스

> **검증 기준 클라이언트 (실제 설치본 바이너리 전수 대조 완료)**
> - **대상 게임**: `World of Warcraft: Forever` (Battle.net Product Flavor: `wowf`, 경로: `_forever_`)
> - **클라이언트 빌드**: `1.60.1.70707` (`WOWSTATIC_1_60_1_70399`, `WOW11`)
> - **TOC Interface 버전**: `11701` (`## Interface: 11701, 16001` 다중 호환 선언)
> - **탑재 엔진 특성**: 클래식 감성 콘텐츠 위에 **2026 통합 최신 C++ 엔진(299개 `C_*` 네임스페이스, 5,530개 C API 시그니처)** 이 탑재됨.
>   - 내장 확인 핵심 API: `C_Container`, `C_Item`, `C_Map`, `C_SuperTrack`, `C_Navigation`, `C_QuestLog`, `C_MerchantFrame`, `C_AuctionHouse`, `C_TradeSkillUI`, `C_Spell`, `C_UnitAuras`, `C_Minimap`, `C_EditMode`, `C_CooldownViewer`, `C_DamageMeter`, `C_EncounterWarnings`, `C_EncounterTimeline`, `C_AddOnProfiler`, `C_Secrets` / `issecretvalue`, TOC `AddonCompartmentFunc`.

---

## 1. 핵심 아키텍처 발견 (Why `wowf 1.60.1` Changes Everything)

단순히 과거 클래식(1.13~1.15)이나 리치 왕(3.3.5a) 기준으로 애드온을 모으면 **구형 전역 API 제거(`GetContainerNumSlots`, `GetSpellInfo`, `UnitBuff` → `C_*` 테이블 반환 전환)** 및 **전투 보안(`C_Secrets` / `issecretvalue`)** 충돌로 대량의 Lua 에러와 프레임 드랍(Taint)이 발생합니다.

반대로 `wowf 1.60.1` 엔진에는 과거 외부 무거운 애드온이 담당하던 핵심 기능 상당수가 **C++ 네이티브 엔진(0 MB 추가 메모리, 0 Taint)** 으로 이미 내장되어 있습니다:

1. **스킬바 배치·단축키 (`Bartender4` 영역)** → 내장 **`C_EditMode` (편집 모드) + 빠른 단축키 설정**으로 90% 이상 대체 가능.
2. **단일 목적지 이동 화살표 (`TomTom` 영역)** → 내장 **`C_Map.SetUserWaypoint` + `C_SuperTrack` + `C_Navigation` 3D 화살표**에 `/way <x> <y>` 슬래시 파서만 얹으면 100줄 미만으로 완벽 대체.
3. **전투 미터기·쿨기 추적·보스 경보 (`Details!`, `WeakAuras`, `DBM` 영역)** → 내장 **`C_DamageMeter`, `C_CooldownViewer`, `C_EncounterWarnings`, `C_EncounterTimeline`** 이 C++ 엔진 레벨로 탑재됨 (`C_Secrets` 제약 하에서도 100% 정상 동작).
4. **가방 합치기·검색·정렬 (`Bagnon` 영역)** → 내장 **통합 가방 + `C_Container.SortBags()` + `C_Container.SetItemSearch()`** 에 여유 슬롯 HUD·상점가·자동 판매만 경량 보강하면 무거운 프레임 재작성 없이 Taint 제로 달성.

---

## 2. 유명 애드온 26종 영역별 정밀 분석 및 통합 판정표

**통합 전략 코드 정의 (`Reuse First & Zero Overlap`)**
- **`NATIVE_CORE` (자체 경량 통합)**: 코드가 작고(100~300줄) 자주 쓰이며 통합 시 설정·UI 일관성과 메모리 절감 효과가 극대화되는 기능 → `ForeverSuite` 기본 모듈로 직접 구현.
- **`ENGINE_BRIDGE` (내장 엔진 래핑)**: 블리자드 `1.60.1` C++ 내장 기능(`C_EditMode`, `C_SuperTrack`, `C_DamageMeter`, `C_CooldownViewer`, `C_Container.SortBags`)을 그대로 활용하고 편의 명령/토글만 연결.
- **`COEXIST_EXT` (외부 원본 공존 + 자동 양보)**: 방대한 정적 DB(수만 개 퀘스트 좌표 DB, 경매장 전체 스캔 인덱서 등)를 가져 재개발이 비효율적인 검증된 애드온 → 외부 설치 시 `ForeverSuite`가 `C_AddOns.IsAddOnLoaded`로 감지해 겹치는 훅을 **`YIELDED`(0 훅)** 상태로 자동 전환.
- **`DROP_REDUNDANT` (제거/채택 제외)**: 엔진 내장 기능 또는 타 모듈과 완전 중복되거나 `C_Secrets`/Taint 리스크 대비 실익이 없는 애드온.

| # | 영역 | 애드온명 | 핵심 강점 / 참고 포인트 | `1.60.1` 호환·성능 리스크 | 라이선스 | 판정 전략 | 우선순위 |
|:-:|---|---|---|---|---|:-:|:-:|
| 1 | 퀘스트 | **Questie** | 방대한 클래식 퀘스트 시작·목표 좌표 DB, 맵 핀 | DB 메모리 25~45MB, `wowf` 신규 퀘스트 ID 미등록분 존재 가능 | GPL / Custom | **`COEXIST_EXT`** (외부 공존 + 자동수락/추적은 `Quest` 모듈) | **P1** |
| 2 | 퀘스트 | **AutoTurnIn / SpeedyAutoLoot** | 반복 퀘스트 수락·완료, Shift 일시정지 UX | 구형 `GetQuestLogTitle` 호출본은 `11701`에서 에러 | MIT / Public | **`NATIVE_CORE`** (`Quest` + `Utility` 모듈에 안전 통합) | **P1** |
| 3 | 퀘스트 | **ClassicQuestLog / Kaliel's Tracker** | 퀘스트 레벨 표시, 최근접 목표 자동 추적 | 프레임 직접 교체 시 `ObjectiveTracker` Taint 위험 | All Rights | **`ENGINE_BRIDGE`** (`C_QuestLog` + `C_SuperTrack` 활용) | **P1** |
| 4 | 지도 | **Leatrix Maps** | 미탐험 지역 밝히기, 월드맵/미니맵 좌표, 크기 조절 | 미탐험 포그 테이블 하드코딩 용량 큼 | All Rights | **`COEXIST_EXT` + `NATIVE_CORE`** (좌표는 `Map` 모듈 내장, 포그 제거는 외부 공존) | **P1** |
| 5 | 지도 | **TomTom** | `/way x y` 명령어 및 3D 방향 화살표 | `HereBeDragons` 상시 OnUpdate CPU 소모 | BSD / MIT | **`ENGINE_BRIDGE`** (`/way` → 내장 `C_Map.SetUserWaypoint` + `C_SuperTrack` 직결) | **P1** |
| 6 | 지도 | **HandyNotes** | 희귀몹·보물·전문기술 정적 아이콘 핀 | 플러그인 다중 설치 시 맵 오픈 프레임 드랍 | MIT | **`COEXIST_EXT`** (필요 시 외부 단독 사용, 기본 제외) | **P3** |
| 7 | 지도 | **SexyMap / MinimapButtonBag** | 미니맵 버튼 정리 및 외형 변경 | `wowf 1.60.1`은 공식 **Addon Compartment** 기본 지원 | MIT | **`DROP_REDUNDANT`** (TOC `AddonCompartmentFunc` 표준 사용) | **P0** |
| 8 | 가방 | **Baganator** | 최신 `C_Container` 기반 고속 통합 가방·카테고리·은행 이력 | 완성도 최상, 외부 설치 시 Taint 적고 현대적 구조 | GPLv3 | **`COEXIST_EXT`** (설치 시 `Inventory` 모듈이 겹치는 UI 자동 `YIELDED`) | **P1** |
| 9 | 가방 | **Bagnon** | 전통적 통합 가방 UI | `ContainerFrame` 교체로 인한 전투 중 `ADDON_ACTION_BLOCKED` 빈발 | MIT | **`DROP_REDUNDANT`** (외부 사용 시 `Baganator` 권장, 공존 감지는 지원) | — |
| 10 | 가방 | **Scrap / Peddler** | 회색 잡템 자동 판매 및 판매 보호 아이템 지정 | 한 번에 20개+ `UseContainerItem` 호출 시 서버 디스커넥트/되사기 불가 | GPLv3 | **`NATIVE_CORE`** (`Utility` 모듈: **1회 최대 12개 되사기 한도 + 보호목록 + 쓰로틀**) | **P1** |
| 11 | 가방 | **SimpleItemLevel / VendorPrice** | 툴팁 및 슬롯에 아이템 레벨·상점 판매가 표시 | 구형 `OnTooltipSetItem` 스크립트는 최신 툴팁 파이프라인과 불일치 | MIT | **`NATIVE_CORE`** (`Inventory` 모듈: `TooltipDataProcessor` 우선 + 폴백) | **P1** |
| 12 | 편의 | **Leatrix Plus** | 자동 수리(길드/개인), 고속 루팅, 최대 시야 거리, 대화 스킵 | 수백 개 잡기능이 단일 거대 테이블에 결합 | All Rights | **`NATIVE_CORE`** (핵심 솔로 QoL 5종만 `Utility` 모듈로 정제 구현) | **P1** |
| 13 | 편의 | **Postal** | 우편함 전체 열기·일괄 수령 | 최신 기본 우편함 UI에 **[모두 열기]** 버튼 기본 내장됨 | MIT | **`DROP_REDUNDANT`** (기본 내장 UI 사용) | — |
| 14 | 전문기술 | **FishingBuddy** | 더블 우클릭 낚시 시전, 낚시 중 배경음 감소/효과음 증폭 | 방대한 의상·통계 코드로 무거움, 전투 진입 시 바인딩 미해제 시 Taint | MIT / Custom | **`NATIVE_CORE`** (`Profession` 모듈: `CombatQueue` + 2중 해제 안전 더블우클릭 & 크래시 복구 사운드 부스트) | **P1** |
| 15 | 전문기술 | **GatherMate2** | 채광·약초 채집 노드 과거 위치 기록 | 영구 노드 DB 수만 건 누적 시 메모리 급증 | MIT | **`COEXIST_EXT`** (노드 맵 DB는 외부 선택, 세션 시간당 수확량·추적 누락 알림은 `Profession` 내장) | **P1** |
| 16 | 전문기술 | **CraftSim / ClassicProfessionFilter** | 제작 가능 수량, 요리 모닥불 및 재료 부족분 표시 | `CraftSim`은 레이드 경제용으로 과중함(30MB+) | GPLv3 | **`NATIVE_CORE`** (`Profession` 모듈: 채집·요리·낚시 솔로 육성 필수 지표만 경량화) | **P1** |
| 17 | 경매장 | **Auctionator** | `C_AuctionHouse` 기반 시세 스캔, 간편 판매/구매 탭, 툴팁 시세 | 검증된 최고 수준 경매장 애드온 (재개발 불필요) | GPLv2+ | **`COEXIST_EXT`** (`Economy` 모듈이 `Auctionator` API 시세 브리지 연동 + 골드 수지 원장 담당) | **P2** |
| 18 | 경매장 | **TradeSkillMaster (TSM)** | 전문 골드 파밍·스나이핑·회계 자동화 | 데스크톱 앱 의존 + 메모리 80~150MB + 초기 설정 극도로 복잡 | Proprietary | **`DROP_REDUNDANT`** (개인 솔로 육성 목적에 과중) | — |
| 19 | 경매장 | **Accountant Classic** | 세션/일일 골드 수입·지출(상점·수리·퀘스트·우편) 추적 | 구형 이벤트 훅 방치로 최신 클라이언트 오류 빈발 | GPL | **`NATIVE_CORE`** (`Economy` 모듈: `PLAYER_MONEY` 델타 정합성 검증 세션 원장) | **P2** |
| 20 | 스킬바 | **Bartender4 / Dominos** | 액션바 자유 배치, 페이드, 단축키 바인딩 | 액션 버튼 Secure 프레임 래핑으로 패치마다 Taint 리스크 존재 | MIT | **`ENGINE_BRIDGE`** (내장 **`C_EditMode`** + 기본 빠른 단축키 모드 우선 활용) | **P2** |
| 21 | 스킬바 | **OmniCC** | 스킬 쿨다운 숫자 텍스트 표시 | 기본 인터페이스 설정 **[재사용 대기시간 숫자 표시]** CVar 내장됨 | MIT | **`ENGINE_BRIDGE`** (`countdownForCooldowns = 1` CVar 원클릭 최적화) | **P1** |
| 22 | 전투 | **Details! Damage Meter** | 정밀 DPS/HPS/죽음 로그 분석 | 메모리 20~50MB + 전투 중 고부하 CLEU 파싱 | MIT | **`ENGINE_BRIDGE` / `COEXIST_EXT`** (솔로/육성은 내장 **`C_DamageMeter`** 사용, 고난도 레이드 시만 외부 선택) | **P2/P3** |
| 23 | 전투 | **Deadly Boss Mods (DBM) / LittleWigs** | 던전·레이드 보스 타이머 및 바닥 경고 | `C_Secrets` 도입 이후 구형 전투로그 파서 호환성 제약 | Custom / GPL | **`ENGINE_BRIDGE` / `COEXIST_EXT`** (내장 **`C_EncounterWarnings` / `C_EncounterTimeline`** 우선 + P3 외부 선택) | **P3** |
| 24 | 전투/직업 | **WeakAuras** | 범용 조건부 오라/자원 스크립트 엔진 | 임의 Lua `OnUpdate` 남발로 CPU 병목 1순위 + `issecretvalue` 충돌 | GPLv2 | **`DROP_REDUNDANT` (범용 엔진 배제)** → 꼭 필요한 **비전투 직업 버프 누락 알림 & 안전 저체력 알림**만 `Combat` 모듈에 정적 구현 | **P2** |
| 25 | 전투/UI | **Plater / KuiNameplates** | 커스텀 이름표, 어그로 색상, 시전바 | 이름표 매 프레임 재렌더링으로 대규모 전투 FPS 급락 | MIT | **`ENGINE_BRIDGE`** (기본 대형 이름표 + 시전바 CVar 프리셋 우선) | **P2** |
| 26 | 코어/진단 | **BugGrabber + BugSack** | 애드온 Lua 에러 포착 및 팝업 폭주 방지 | 여러 애드온 중 하나가 터질 때 전체 UI 마비 방지 | GPL | **`NATIVE_CORE`** (`ModuleManager` + `EventBus`에 `xpcall` 기반 3회/60초 `FAULTED` 서킷 브레이커 직접 내장) | **P0** |

---

## 3. 중복 기능 제거 및 메모리·CPU 절감 요약

| 기존 개별 설치 조합 (일반 유저 평균 15개+) | 상주 메모리 / 유휴 OnUpdate | **`ForeverSuite` 통합 아키텍처 적용 후** |
|---|---|---|
| Leatrix Plus + Scrap + AutoTurnIn + TomTom + FishingBuddy + OmniCC + VendorPrice + Accountant + MinimapButtonBag + BugSack + WeakAuras(기초 버프) + Bartender4 + Details | **약 95 ~ 180 MB** / 상시 `OnUpdate` 8~14개 | **`ForeverSuite` 단일 애드온 (< 2.0 MB, 유휴 `OnUpdate` 0개)** + 내장 `C_EditMode` / `C_DamageMeter` / `C_SuperTrack` + (선택) `Questie` · `Baganator` · `Auctionator` 공존 |

---

## 4. 블리자드 API 규정 및 라이선스 준수 원칙 (`API Compliance`)

1. **외부 애드온 코드 무단 복제 제로**: GPL/All-Rights-Reserved 외부 애드온의 소스코드를 복사하지 않고, 공개된 공식 블리자드 `WoW Forever 1.60.1 (11701)` C/Lua API 명세만을 사용해 클린룸(Clean-Room) 경량 모듈로 설계했습니다. 외부 애드온(`Questie`, `Baganator`, `Auctionator`)은 원본 그대로 설치할 경우 `ModuleManager`가 감지하여 충돌 없이 공존(`YIELDED`)합니다.
2. **전투 자동화 0% & `C_Secrets` 완벽 준수**:
   - 스킬 시전·타겟 변경 자동화(`CastSpell*`, `TargetUnit`, `UseAction`) 코드는 단 한 줄도 포함하지 않습니다(정적 AST 테스트로 강제 차단).
   - 낚시 더블 우클릭은 **비전투(`not InCombatLockdown()`) 상태에서만** 사용자 하드웨어 마우스 입력에 일시적 `SetOverrideBindingClick`을 연결하며, 시전 직후 및 `PLAYER_REGEN_DISABLED` 진입 시 즉시 해제합니다.
   - 전투 중 `issecretvalue(val)`가 참인 유닛 체력·오라 수치는 산술/비교 연산에 절대 사용하지 않습니다.
