# ForeverSuite v0.3.0 — WoW 포에버 개인용 통합 애드온 (`GodJohnson v5.0.213+` 3-Tier Bridge Edition)

- **대상 클라이언트**: `World of Warcraft: Forever` (`_forever_`, 빌드 `1.60.1.70790`, TOC `11701, 16001, 120105`)
- **지원 OS**: **macOS & Windows 양방향 100% 호환** (Windows 원클릭 `.exe` 설치기 포함)
- **개발 저장소**: macOS `/Users/choyoungseo/WoW_Forever/ForeverSuite` · GitHub Private `https://github.com/ssacho3-blip/WoW-ForeverSuite`
- **설계 원칙 (`Claude Opus 5.5` & `Claude Fable 5.2` 합의 아키텍처)**:
  - **Tier 1 (Upstream Read-Only Base)**: 유튜버 **갓존슨(GodJohnson) 통합 애드온 `v5.0.213`** 원본 21개 폴더 무수정(`0 diff`, SHA-256 고정 [`pinned_upstream.json`](pinned_upstream.json), 14개 `GodJohnsonFontChoice_*` 7비트 레지스터 폴더 100% 보존)
  - **Tier 2 (`ForeverSuite` v0.3.0, 18개 Lua 모듈)**: 개인용 코어/경제/전투/유틸리티 스위트 (`xpcall` 서킷 브레이커, `C_Secrets` 가드, `CombatQueue` 전투 격리, 4대 중복 도메인 Single-Owner 자동 양보)
  - **Tier 3 (`ForeverSuite_GJBridge` v0.3.0)**: 비침습 런타임 브리지 (`GJCompanion` 개인용 브랜딩·사운드 오버라이드 + 지연 생성 프레임 `GodJohnsonGoldBorderLauncher` 스킨 + 4대 중복 기능 Fail-Safe 단일 소유자 중재)

---

## 1. 3-Tier 구조 및 주요 기능 요약

| 계층 / 모듈 | 우선순위 | 핵심 역할 | 단일 소유자 중재 (`Single-Owner Arbitration`) |
|---|:-:|---|---|
| **`GodJohnson*` (21개 폴더)** | **Base** | 한국어 위상/지도/도감/던전·레이드/할일/거래/미니게임 방대한 DB 및 UI (원본 무수정 보존) | `pinned_upstream.json` SHA-256 해시 고정 |
| **`ForeverSuite_GJBridge`** | **Bridge** | `GJCompanion.Say` 접두어 개인화(`[포에버]:`), 유튜브 버튼 비활성화, 404 홈 배너 개인화, 오이쉬 사운드 `dingdong` 치환, 거래 귓속말 기본 OFF, 런처 아이콘(`134063`) 지연 스킨 | `GJ` 설정 활성 또는 판독 불가 시 `ForeverSuite`가 자동 양보(`Fail-Safe YIELD`) |
| **Core / Profile / UI** | **P0** | 단일 프레임 `EventBus`, `MoneyLedgerQueue`, 계층형 프로필(캐릭터>직업>계정, 미래 스키마 Read-Only 가드), 60초 3회 오류 시 `FAULTED` 서킷 브레이커, `/fs` 3탭 통합 제어판(`ESC` 닫기·세부 설정 서랍) | — |
| **Utility (`repair`, `sell`)** | **P1** | 자동 수리(길드 금고 우선 → 개인 골드 폴백), 회색 잡템 배치 판매(1회 12개 되사기 한도·잔여 수량 안내·`/fs sell` 수동 판매·`/fs protect` 보호목록·`Shift` 정지) | `GJCompanion.ExtraSettings("merchantAutomation")` 활성 시 자동 양보 |
| **Quest (`questAuto` + 추적창)** | **P1~P2** | **지역별(현재 지역 최상단)·레벨별 온스크린 퀘스트 추적창 HUD**, `Ctrl+클릭` 상세열기, `Alt+클릭` 채팅 링크, 말줄임 목표 전체 툴팁, `[잠금]` 토글, **`UIParent` 직계 `SecureActionButtonTemplate` 퀘스트 특수 아이템 버튼 풀(6개)** | `Questie` 로드 시 전체 양보, `GJCompanion.ExtraSettings("automation")` 활성 시 자동 수락·완료만 양보 |
| **Profession (`fishing`, 채집)** | **P1** | 비전투 안전 더블 우클릭 낚시(`CombatQueue` + 시전 직후 & 전투 진입 2중 해제), 크래시 안전 효과음 부스트, `classID==7` 채집물 vs 일반 전리품 분리 집계(비동기 캐시 무손실 보정) | `GJCompanion.FishingSettings()` 활성 시 자동 양보 |
| **Map (`/way`, 좌표)** | **P1** | 월드맵 열림 시 전용 `0.15s` **플레이어 + 마우스 커서 좌표**, `/way <X> <Y> [메모]` → 내장 `C_Map.SetUserWaypoint` + `C_SuperTrack` 연동 | 실제 외부 `/way` 슬래시 명령(`TomTom` 등) 존재 시에만 양보 (`GJ`에는 양보 안 함) |
| **Inventory / Economy / Combat** | **P1~P2** | 가방 여유 슬롯 HUD(호버 시 실시간 골드 원장 툴팁)·묶음 상점가(`xN`)·보호 배지, `PLAYER_MONEY` 세션 골드 원장, **9개 클래식 전 직업 버프 패밀리·무기 마법부여 체크**, `/fs move` 통합 HUD 잠금 해제·위치 저장 | `Baganator`, `Bagnon`, `Auctionator` |

---

## 2. 게임 내 명령어

- `/fs` 또는 `/forever` : ForeverSuite 3탭 통합 제어판(`[모듈 · 세부설정]`, `[GJ 브리지 상태]`, `[골드 원장]`) 열기·닫기 (`ESC` 지원)
- `/fs quest [zone | level | here | lock | toggle | default | reset]` : **온스크린 퀘스트 추적창 지역별/레벨별 전환, 현재 지역 필터, 드래그 잠금(`[잠금]`), 기본 추적기 동시 표시, 위치 초기화**
- `/fs protect <아이템링크 | itemID | list>` : 상점 자동 판매 제외 보호 아이템 등록/해제 및 목록 조회
- `/fs sell` : 상점 창이 열려 있을 때 회색 잡템 최대 12개 수동 안전 배치 판매
- `/fs move [reset]` : 가방 HUD 및 저체력 경고 프레임 드래그 잠금/해제 토글 (`reset` 시 기본 위치 복원)
- `/fs enable <모듈>` / `/fs disable <모듈>` : 개별 모듈 활성화·비활성화
- `/fs status` / `/fs perf` / `/fs gold` / `/fs gather` : 모듈 상태, 실시간 메모리·CPU, 세션 골드 원장, 채집 수확량 출력
- `/fsgj` 또는 `/fsgj status` / `/fsgj sync` : **갓존슨 브리지 오버라이드 및 단일 소유자(`OWNED_BY_FS`/`YIELDED`) 상태 점검·재동기화**
- `/way 52.4 38.1 광맥 루트` : 현재 맵에 네이티브 3D 화살표 목표 핀 설정 (`/way clear` 해제)

---

## 3. 설치 및 테스트 (macOS 즉시 설치 & Windows 원클릭 `.exe`)

```bash
# 1. 자동 검증 스위트 실행 (전체 BDD/DDT 스위트 — 8대 인수조건 AC-1~AC-8, 전투 격리, PE32+ 검증 포함)
/Users/choyoungseo/LifeOS_System/LifeOS-System/.venv/bin/pytest tests/ -v

# 2. macOS WoW Forever 클라이언트에 전체 23개 폴더(GodJohnson 21 + ForeverSuite + ForeverSuite_GJBridge) 원자적 설치
chmod +x scripts/deploy_mac.sh
./scripts/deploy_mac.sh

# 3. Windows 원클릭 설치 파일(dist/ForeverSuite_Installer.exe) 및 포터블 ZIP(dist/ForeverSuite-v0.3.0.zip) 빌드
python3 scripts/package_release.py

# 4. 갓존슨 업스트림 신규 버전 출시 시 해시 고정 및 호환성 검증
python3 scripts/sync_upstream.py --verify-dir "/Applications/World of Warcraft/_forever_/Interface/AddOns"
```

상세 문서:
- [버전별 변경 이력 (`CHANGELOG.md`)](CHANGELOG.md)
- [Claude Opus 5.5 합의 아키텍처 및 브리지 감사 명세서](docs/OPUS_CONSENSUS_AND_AUDIT.md)
- [Windows 원클릭 `.exe` 설치 및 macOS 듀얼 OS 운영 가이드](docs/WINDOWS_MAC_SYNC.md)
- [Phase 1 유명 애드온 26종 조사·비교 및 통합 전략](docs/PHASE1_ADDON_SURVEY.md)
- [통합 아키텍처 및 Taint/Secret/성능 계약서](docs/ARCHITECTURE.md)
