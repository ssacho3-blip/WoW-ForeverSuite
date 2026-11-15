# Claude Opus 5.5 × Claude Fable 5.2 합의 아키텍처 및 브리지 감사 명세서

- **문서 ID**: `WOWF-20261115-GJBRIDGE-002` (`v0.3.1` Consensus Upgrade)
- **승인 상태**: **`Claude Opus 5.5` × `Claude Fable 5.2` 교차 논의 만장일치 합의 (`APPROVED`)**
- **대상 클라이언트**: `World of Warcraft: Forever` (`_forever_`, 빌드 `1.60.1.70938`, TOC `16001, 120105`)
- **업스트림 고정 버전**: `GodJohnson Integrated Addon v5.236` (개정 588, `2026-11-14`, CurseForge Project ID `1707376`, File ID `9609539`, SHA-256 `900d2c532396eec44ad21854e455326382cd88c46afc50e8bcc5fdb71c2f92ed`)

---

## 1. 아키텍처 합의 핵심 원칙 (`3-Tier Zero Upstream Patch & Zero-SV-Mutation`)

1. **원본 21개 폴더 전체 파일 무수정 (`Zero Upstream Mutation` + `folder_sha256`)**:
   - `GodJohnson*` 21개 폴더(`GodJohnsonGoldBorder` 본체 + `GodJohnsonEngineStartup` + `LoadOnDemand` 데이터 팩 5종 + `GodJohnsonFontChoice_*` 14종)는 바이트 단위로 수정하지 않으며 [`pinned_upstream.json`](../pinned_upstream.json)으로 `.toc` 해시(`toc_sha256`)와 전체 파일 트리 해시(`folder_sha256`)를 이중 고정합니다.
   - 특히 `GodJohnsonFontChoice_damage_1~7` 및 `world_1~7` (총 14개 폴더)는 `GodJohnsonEngineStartup/EarlyEngineFonts.lua:69-83`에서 `GetAddOnEnableState` 7비트 레지스터로 읽어 `SavedVariables` 로드 전에 엔진 폰트를 적용하므로 **전수 유지**합니다.
2. **제3의 브리지 애드온 (`ForeverSuite_GJBridge` v0.3.1) — `ProfileShare` 무오염 원칙**:
   - `## Dependencies: GodJohnsonGoldBorder, ForeverSuite`를 선언하여 두 애드온 로드 직후에 실행됩니다.
   - `GodJohnsonCompanionDB` 및 `GJCompanion`에는 어떠한 `_fsgj*` 사설 키도 기록하지 않습니다 (`__mode = "k"` 프라이빗 Weak 테이블 + `_G.ForeverSuiteDB.gjBridge` 저장소 사용 → `ProfileShare.lua:282` 프로필 내보내기/가져오기 검증 100% 통과).
   - `C.ApplyAuthorPreset` 전후 스냅샷 래퍼가 프리셋 적용 성공(`return true`) 시 사용자의 `notify` 및 `starterLoot` 설정을 즉시 복원합니다.
3. **6-Key 단일 소유자 불변식 (`Single Owner Invariant` & Fail-Safe Yield)**:
   - 중복 자동화 도메인은 `repair`, `sell`, `questAutoAccept` (`GJ automation.accept`), `questAutoTurnIn` (`GJ automation.complete`), `fishing`, `way` 총 6개 독립 키로 세분화됩니다.
   - `GJ`에서 켜져 있거나 설정값을 읽을 수 없는 경우(보수적 Fail-Safe) 즉시 `ForeverSuite`의 해당 키만 `YIELDED`로 전환하며, `Economy` 모듈은 `RepairAllItems` / `C_Container.UseContainerItem` / `GetQuestReward` 후크로 양보 상태에서도 세션 골드 원장을 100% 정확히 기록합니다.

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
| `sayPrefix` | `CompanionCore.lua` (`GJCompanion.Say`) | 런타임 테이블 참조 (`local` 선캡처 `0건`) | `GJCompanion.Say`를 교체하여 `\|cffffd36a[포에버]:\|r ` 접두사로 출력 |
| `youtubeLink` | `ChannelLink.lua` (`OpenYouTube`) | 런타임 테이블 참조 + `GJCompanion.YouTubeButton` 프레임 참조 | `OpenYouTube`를 로컬 버전 안내로 교체 및 `YouTubeButton` 비표시 처리 |
| `homeScreen` | `Home404.lua` (`BuildHome404`) | 홈 탭 최초 오픈 시 지연 호출 (`builders.home`) | `BuildHome404` 래핑 → 자식 `ChannelLogo` 리전 순정 아이콘(`134063`) 교체, `setupReminder`·`notice` 개인화, 반환값 전달 및 에러 재전파 |
| `launcherIcon` | `GodJohnsonGoldBorder.lua` (`_G.GodJohnsonGoldBorderLauncher`) | `EnsureUI()` 내 지연 생성 프레임 | `PLAYER_LOGIN` / `PLAYER_ENTERING_WORLD` 및 `RestoreLauncher` 후킹 → 프레임 존재 확인 후 `.logo` 텍스처를 순정 아이콘(`134063`)으로 교체 |
| `tradeWhisper` | `TradeManager404.lua` (`TradeManager404Config`) | 런타임 설정 함수 호출 | `_G.ForeverSuiteDB.gjBridge.tradeNotifySeeded` 1회 시딩으로 `notify = false` 초기화 (`GJ` SV 무오염) |
| `questSound` | `QuestAnnounce.lua` (`QuestAnnounce.Format`, `PlayNotificationSound`) | 런타임 포맷/사운드 재생 계층 | 저장된 템플릿 무변이 유지 + `Format` 선두 `[갓존슨]` → `[포에버]` 평문 치환 + `oishii_*` → `dingdong` 재생 리매핑 + `starterLoot` 최초 1회 `false` 시딩 |
