# ForeverSuite — WoW 포에버 개인용 초경량 통합 애드온

- **대상 클라이언트**: `World of Warcraft: Forever` (`_forever_`, 빌드 `1.60.1.70707`, TOC `11701`)
- **지원 OS**: **macOS & Windows 양방향 100% 호환**
- **개발 저장소**: macOS `~/WoW_Forever/ForeverSuite` · GitHub Private `https://github.com/ssacho3-blip/WoW-ForeverSuite`
- **설계 원칙**: `Reuse First` · `Modular Fault Isolation (xpcall)` · `Zero Combat Automation` · `C_Secrets Safe` · `Zero Idle OnUpdate`

---

## 1. 주요 기능 요약 (`P0` ~ `P2`)

| 모듈 | 우선순위 | 핵심 기능 | 외부 애드온 자동 공존 (`YIELDED`) |
|---|:-:|---|---|
| **Core / Profile / UI** | **P0** | 단일 프레임 `EventBus`(버킷 쓰로틀), 계층형 프로필(캐릭터>직업>계정), 60초 3회 오류 시 `FAULTED` 서킷 브레이커, `/fs` 통합 설정창 & 미니맵 Addon Compartment | — |
| **Utility** | **P1** | 자동 수리(길드 금고 우선 → 개인 골드 안전 폴백), 회색 잡템 배치 판매(1회 12개 되사기 한도·보호목록·`Shift` 정지), 고속 자동 전리품, 쿨다운 숫자 CVar | `Leatrix_Plus` |
| **Inventory** | **P1** | 가방 여유 슬롯 실시간 HUD(`BAG_UPDATE_DELAYED` 0.2s 버킷), 원클릭 가방 정렬, 툴팁 상점 판매가·아이템 레벨 표시 | `Baganator`, `Bagnon` |
| **Map** | **P1** | 월드맵 열림 시에만 동작하는 `0.15s` 플레이어 좌표(유휴 CPU `0.00ms`), `/way <X> <Y> [메모]` → 내장 `C_Map.SetUserWaypoint` + `C_SuperTrack` 3D 화살표 연동 | `TomTom` |
| **Quest** | **P1** | 안전한 퀘스트 자동 수락·완료(복수 보상 선택 시 자동 정지, `Shift` 홀드 수동), 수락 퀘스트 자동 `SuperTrack` 포커스 | `Questie` |
| **Profession** | **P1** | 비전투 안전 더블 우클릭 낚시(`CombatQueue` + 시전 직후 & 전투 진입 2중 해제), 크래시 안전 효과음 부스트, 채광·무두질·낚시 세션 시간당 수확량 집계, 채집 추적 누락 알림 | `FishingBuddy` |
| **Economy** | **P2** | `PLAYER_MONEY` 증감분 100% 정합성 검증 세션 골드 수지 원장(상점 판매 / 수리 / 퀘스트 / 기타) | `Auctionator` |
| **Combat** | **P2** | 비전투 직업 필수 자가 버프 누락 알림(`C_UnitAuras`), `issecretvalue` 완벽 준수 저체력 시각 경고 (전투 자동화 0%) | — |

---

## 2. 게임 내 명령어

- `/fs` 또는 `/forever` : 통합 설정 및 모듈 상태/성능 창 열기·닫기
- `/fs status` : 전체 모듈 활성화 / `YIELDED` / `FAULTED` 상태 출력
- `/fs perf` : 실시간 메모리 및 `C_AddOnProfiler` 평균 CPU, 활성 이벤트/Ticker 수 확인
- `/fs gold` : 현재 세션 골드 수입·지출 원장 출력
- `/fs gather` : 현재 세션 채집·전리품 수확량 및 시간당 속도 출력
- `/fs probe` : 실제 클라이언트 `C_*` API 및 전역 심볼 진단 리포트를 `ForeverSuiteDB.lastProbe`에 저장
- `/way 52.4 38.1 광맥 루트` : 현재 맵에 네이티브 3D 화살표 목표 핀 설정 (`/way clear` 해제)

---

## 3. 설치 및 테스트 (macOS & Windows)

```bash
# 1. 자동 검증 스위트 실행 (AC-1 ~ AC-7 + 실제 로컬 WoW 바이너리 심볼 대조)
/Users/choyoungseo/LifeOS_System/LifeOS-System/.venv/bin/pytest tests/ -q

# 2. macOS WoW Forever 클라이언트에 원자적 배포
chmod +x scripts/deploy_mac.sh
./scripts/deploy_mac.sh

# 3. Windows PC 배포용 포터블 ZIP 패키지 빌드 (또는 Windows에서 scripts/deploy_win.ps1 실행)
python3 scripts/package_release.py
```

상세 문서:
- [Phase 1 유명 애드온 26종 조사·비교 및 통합 전략](docs/PHASE1_ADDON_SURVEY.md)
- [통합 아키텍처 및 Taint/Secret/성능 계약서](docs/ARCHITECTURE.md)
- [Windows & macOS 듀얼 OS 동기화 가이드](docs/WINDOWS_MAC_SYNC.md)
