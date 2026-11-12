# ForeverSuite v0.2.0 — WoW 포에버 개인용 통합 애드온 (`GodJohnson v5.0.132` 3-Tier Bridge Edition)

- **대상 클라이언트**: `World of Warcraft: Forever` (`_forever_`, 빌드 `1.60.1.70790`, TOC `11701, 16001, 120105`)
- **지원 OS**: **macOS & Windows 양방향 100% 호환** (Windows 원클릭 `.exe` 설치기 포함)
- **개발 저장소**: macOS `~/WoW_Forever/ForeverSuite` · GitHub Private `https://github.com/ssacho3-blip/WoW-ForeverSuite`
- **설계 원칙 (`Claude Opus 5.5` Tech Lead 합의 아키텍처)**:
  - **Tier 1 (Upstream Read-Only Base)**: 유튜버 **갓존슨(GodJohnson) 통합 애드온 `v5.0.132`** 원본 21개 폴더 무수정(`0 diff`, SHA-256 고정 `pinned_upstream.json`, 14개 `GodJohnsonFontChoice_*` 7비트 레지스터 폴더 100% 보존)
  - **Tier 2 (`ForeverSuite`)**: 개인용 코어/경제/전투/유틸리티 스위트 (`xpcall` 서킷 브레이커, `C_Secrets` 가드, 4대 중복 도메인 Single-Owner 자동 양보)
  - **Tier 3 (`ForeverSuite_GJBridge`)**: 비침습 런타임 브리지 (`GJCompanion` 개인용 브랜딩 오버라이드 5종 + 지연 생성 프레임 `GodJohnsonGoldBorderLauncher` 스킨 + 4대 중복 기능 Fail-Safe 단일 소유자 중재)

---

## 1. 3-Tier 구조 및 주요 기능 요약

| 계층 / 모듈 | 우선순위 | 핵심 역할 | 단일 소유자 중재 (`Single-Owner Arbitration`) |
|---|:-:|---|---|
| **`GodJohnson*` (21개 폴더)** | **Base** | 한국어 위상/지도/도감/던전·레이드/할일/거래/미니게임 방대한 DB 및 UI (원본 무수정 보존) | `pinned_upstream.json` SHA-256 해시 고정 |
| **`ForeverSuite_GJBridge`** | **Bridge** | `GJCompanion.Say` 접두어 개인화(`[포에버]:`), 유튜브 버튼 비활성화, 404 홈 배너 개인화, 거래 귓속말 기본 OFF, 런처 아이콘(`134063`) 지연 스킨 | `GJ` 설정 활성 또는 판독 불가 시 `ForeverSuite`가 자동 양보(`Fail-Safe YIELD`) |
| **Core / Profile / UI** | **P0** | 단일 프레임 `EventBus`, 계층형 프로필(캐릭터>직업>계정), 60초 3회 오류 시 `FAULTED` 서킷 브레이커, `/fs` 통합 설정창 | — |
| **Utility (`repair`, `sell`)** | **P1** | 자동 수리(길드 금고 우선 → 개인 골드 폴백), 회색 잡템 배치 판매(1회 12개 되사기 한도·보호목록·`Shift` 정지) | `GJCompanion.ExtraSettings("merchantAutomation")` 활성 시 자동 양보 |
| **Quest (`questAuto` + 추적창)** | **P1** | **지역별(현재 지역 최상단)·레벨별(수월·적정·도전) 온스크린 퀘스트 추적창 HUD**, 안전 자동 수락·완료(`Shift` 우회), `SuperTrack` 화살표 연동 | `Questie` 로드 시 전체 양보, `GJCompanion.ExtraSettings("automation")` 활성 시 자동 수락·완료만 양보 |
| **Profession (`fishing`)** | **P1** | 비전투 안전 더블 우클릭 낚시(`CombatQueue` + 시전 직후 & 전투 진입 2중 해제), 크래시 안전 효과음 부스트, 채집 시간당 수확량 집계 | `GJCompanion.FishingSettings()` 활성 시 자동 양보 |
| **Map (`/way`)** | **P1** | 월드맵 열림 시에만 동작하는 `0.15s` 플레이어 좌표, `/way <X> <Y> [메모]` → 내장 `C_Map.SetUserWaypoint` + `C_SuperTrack` 연동 | 실제 외부 `/way` 슬래시 명령(`TomTom` 등) 존재 시에만 양보 (`GJ`에는 양보 안 함) |
| **Inventory / Economy / Combat** | **P1~P2** | 가방 여유 슬롯 HUD·툴팁 판매가, `PLAYER_MONEY` 세션 골드 원장, 비전투 자가 버프 누락 알림 & `issecretvalue` 안전 저체력 경고 | `Baganator`, `Bagnon`, `Auctionator` |

---

## 2. 게임 내 명령어

- `/fsgj` 또는 `/fsgj status` : **갓존슨 브리지(`ForeverSuite_GJBridge`) 오버라이드 5종 적용 상태(`APPLIED`/`PENDING`/`MISSING`) 및 5대 기능 단일 소유자(`OWNED_BY_FS`/`YIELDED`) 상태 점검**
- `/fsgj sync` : 갓존슨 설정 변경 후 브리지 소유권 및 런처 아이콘 즉시 재동기화
- `/fs` 또는 `/forever` : ForeverSuite 통합 설정 및 모듈 상태/성능 창 열기·닫기
- `/fs quest [zone | level | here | toggle | default | reset]` : **온스크린 퀘스트 추적창 지역별/레벨별 분류 전환, 현재 지역 필터, 기본 추적기 동시 표시, 위치 초기화** (추적창 상단 `[지역별]` `[레벨별]` `[현지역]` `[–]` 버튼으로도 즉시 클릭 제어 가능)
- `/fs status` : ForeverSuite 전체 모듈 활성화 / `YIELDED` / `FAULTED` 상태 출력
- `/fs perf` : 실시간 메모리 및 `C_AddOnProfiler` 평균 CPU, 활성 이벤트/Ticker 수 확인
- `/fs gold` : 현재 세션 골드 수입·지출 원장 출력
- `/fs gather` : 현재 세션 채집·전리품 수확량 및 시간당 속도 출력
- `/way 52.4 38.1 광맥 루트` : 현재 맵에 네이티브 3D 화살표 목표 핀 설정 (`/way clear` 해제)

---

## 3. 설치 및 테스트 (macOS 즉시 설치 & Windows 원클릭 `.exe`)

```bash
# 1. 자동 검증 스위트 실행 (27개 BDD/DDT 테스트 — 브리지·단일 소유자 중재·Windows PE32+ 실행파일 검증 포함)
/Users/choyoungseo/LifeOS_System/LifeOS-System/.venv/bin/pytest tests/ -v

# 2. macOS WoW Forever 클라이언트에 전체 23개 폴더(GodJohnson 21 + ForeverSuite + ForeverSuite_GJBridge) 원자적 설치
chmod +x scripts/deploy_mac.sh
./scripts/deploy_mac.sh

# 3. Windows 원클릭 설치 파일(dist/ForeverSuite_Installer.exe) 및 포터블 ZIP 패키지 빌드
python3 scripts/package_release.py

# 4. 갓존슨 업스트림 신규 버전 출시 시 해시 고정 및 호환성 검증
python3 scripts/sync_upstream.py --verify-dir /Applications/World\ of\ Warcraft/_forever_/Interface/AddOns
```

상세 문서:
- [Claude Opus 5.5 합의 아키텍처 및 브리지 감사 명세서](docs/OPUS_CONSENSUS_AND_AUDIT.md)
- [Windows 원클릭 `.exe` 설치 및 macOS 듀얼 OS 운영 가이드](docs/WINDOWS_MAC_SYNC.md)
- [Phase 1 유명 애드온 26종 조사·비교 및 통합 전략](docs/PHASE1_ADDON_SURVEY.md)
- [통합 아키텍처 및 Taint/Secret/성능 계약서](docs/ARCHITECTURE.md)
