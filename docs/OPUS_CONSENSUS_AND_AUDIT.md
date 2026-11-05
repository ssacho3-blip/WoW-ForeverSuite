# Claude Opus 5.5 × Antigravity 합의 아키텍처 및 Phase 0 전수 감사 보고서

- **문서 ID**: `WOWF-20261105-GJBRIDGE-001`
- **승인 상태**: **Tech Lead (`Claude Opus 5.5`) `APPROVED` (조건 4개 전수 반영)**
- **대상 클라이언트**: `World of Warcraft: Forever` (`_forever_`, 빌드 `1.60.1.70790`, TOC `11701, 16001, 120105`)
- **업스트림 고정 버전**: `GodJohnson Integrated Addon v5.0.132` (개정 484, `2026-11-04`, CurseForge Project ID `1707376`, File ID `9432165`, SHA-256 `2cf3a5044f379aa2071dd734c35c6094c8765f923965db6afd39cae7736d1efd`)

---

## 1. 아키텍처 합의 핵심 원칙 (`3-Tier Zero Upstream Patch`)

1. **원본 21개 폴더 무수정 (`Zero Upstream Mutation`)**:
   - `GodJohnson*` 21개 폴더(`GodJohnsonGoldBorder` 본체 + `GodJohnsonEngineStartup` + `LoadOnDemand` 데이터 팩 5종 + `GodJohnsonFontChoice_*` 14종)는 바이트 단위로 수정하지 않으며 [`pinned_upstream.json`](../pinned_upstream.json)으로 SHA-256 해시를 고정합니다.
   - 특히 `GodJohnsonFontChoice_damage_1~7` 및 `world_1~7` (총 14개 폴더)는 `GodJohnsonEngineStartup/EarlyEngineFonts.lua:69-83`에서 `GetAddOnEnableState` 7비트 레지스터로 읽어 `SavedVariables` 로드 전에 엔진 폰트를 적용하므로 **전수 유지**합니다.
2. **제3의 브리지 애드온 (`ForeverSuite_GJBridge`) 분리**:
   - `## Dependencies: GodJohnsonGoldBorder, ForeverSuite`를 선언하여 두 애드온 로드 직후에 실행됩니다.
   - `_G.GJCompanion`이 `nil`이면 아무 동작도 하지 않고 진단 상태를 `UNAVAILABLE`로 기록합니다 (Opus 승인 조건 #2).
3. **단일 소유자 불변식 (`Single Owner Invariant` & Fail-Safe Yield)**:
   - `GodJohnsonGoldBorder`와 `ForeverSuite`가 겹치는 4대 자동화 기능(`repair`, `sell`, `questAuto`, `fishing`)은 `ForeverSuite_GJBridge`가 `GJCompanion`의 설정 활성 여부를 `pcall`로 읽어, **GJ에서 켜져 있거나 설정값을 읽을 수 없는 경우(보수적 Fail-Safe)** 즉시 `ForeverSuite`의 해당 기능을 `YIELDED` 상태로 전환합니다 (Opus 승인 조건 #4).
   - `/way` 슬래시 명령어는 `GodJohnsonGoldBorder`에 존재하지 않으므로 무조건 양보하지 않고, 외부 애드온의 `SLASH_WAY1` / `SlashCmdList["WAY"]` 선점 여부만 충돌 검사합니다 (Opus 승인 조건 #3).

---

## 2. Phase 0 — `SendChatMessage` 외부 채팅 발송 지점 전수 감사표

`GodJohnsonGoldBorder` 내 279개 Lua 파일 전수 스캔 결과 확인된 `SendChatMessage` 호출 지점 및 기본값/조치 내역입니다:

| # | 파일 및 위치 | 기능 설명 | 원본 기본값 | 브리지 조치 (`ForeverSuite_GJBridge`) |
|:-:|---|---|---|--|
| 1 | `AutoGreeting.lua:294` | 파티/길드 자동 인사 발송 | `enabled = false` (`OFF`) | 기본 `OFF` 확인 완료 (유지) |
| 2 | `QuestAnnounce.lua:127` | 퀘스트 진행/완료 채팅 알림 | `enabled = false`, 채널 `LOCAL` | 기본 `OFF` 및 `LOCAL` 확인 완료 (유지) |
| 3 | `VitalAlerts.lua:87` | 저체력/저마나 채팅 알림 | `enabled = false`, 채널 `LOCAL`, 문구 `[갓존슨] ...` | 기본 `OFF`/`LOCAL` 유지 + 기본 문구 내 `[갓존슨]` 접두사를 `[알림]`으로 비파괴 치환 |
| 4 | `TradeManager404.lua:127` | 거래 완료 시 상대방에게 `[갓존슨 거래 완료]` 귓속말 자동 발송 | **`d.notify = true` (`ON`)** | **주의 지점**: 브리지에서 신규/미지정 시 `d.notify = false`로 안전 기본값 오버라이드 (사용자가 직접 켠 경우만 허용) |
| 5 | `GDKPRuntime5102.lua:569,623,939,1093` | 골팟 경매 시작/입찰/낙찰/현황 공지 | 수동 버튼 클릭 시에만 발송 | 사용자 명시 클릭 기반 동작 확인 완료 (유지) |
| 6 | `GDKPPayout5120.lua:125` | 골팟 총 분배금 변경 공지 | 수동 버튼 클릭 시에만 발송 | 사용자 명시 클릭 기반 동작 확인 완료 (유지) |

---

## 3. Phase 0 — 비파괴 브랜딩/UI 오버라이드 타겟 명세표

| 타겟 ID | 원본 정의 위치 | 바인딩 특성 | 브리지 오버라이드 방식 (`ForeverSuite_GJBridge`) |
|---|---|---|---|
| `sayPrefix` | `CompanionCore.lua:74` (`GJCompanion.Say`) | 런타임 테이블 참조 (`local` 선캡처 `0건`) | `GJCompanion.Say`를 교체하여 `\|cffffd36a[포에버]:\|r ` 접두사로 출력 |
| `youtubeLink` | `ChannelLink.lua:19-23` (`OpenYouTube`, `BuildYouTubeButton`) | 런타임 테이블 참조 + `GJCompanion.YouTubeButton` 프레임 참조 | `OpenYouTube`를 로컬 버전 안내로 교체, `YouTubeButton` 즉시 `Hide()` 및 `BuildYouTubeButton` 후킹 |
| `homeScreen` | `Home404.lua:12` (`BuildHome404`), `CompanionUI.lua:347` 지연 호출 | 홈 탭 최초 오픈 시 지연 호출 (`builders.home`) | `BuildHome404` 래핑 → 유튜브 로고 클릭 무해화, 순정 아이콘(`134063`) 적용, 개인용 안내 문구로 교체 |
| `launcherIcon` | `GodJohnsonGoldBorder.lua:230-236` (`_G.GodJohnsonGoldBorderLauncher`) | `EnsureUI()` 내 지연 생성 프레임 (Opus 승인 조건 #1) | `PLAYER_LOGIN` / `PLAYER_ENTERING_WORLD` 및 `RestoreLauncher` 후킹 → 프레임 존재 확인 후 `.logo` 텍스처를 순정 아이콘(`134063`)으로 교체 |
| `tradeWhisper` | `TradeManager404.lua:25-32` (`TradeManager404Config`) | 런타임 설정 함수 호출 | 사용자가 명시적으로 켜지 않은 자동 거래 완료 귓속말(`notify`) 기본 `false` 가드 |
