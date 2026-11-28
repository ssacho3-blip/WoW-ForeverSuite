# ForeverSuite v6.0.0 — WoW 포에버 단일 연출자 OS 셸 & 통합 애드온

- **대상 클라이언트**: `World of Warcraft: Forever` (`_forever_`, 빌드 `1.60.1.71037`, TOC `16001, 120105`)
- **아키텍처 철학 (길 C: 단일 연출자 OS 셸 + 외부 전문 앱 편입)**:
  - **Core 3-폴더 배포 (`≤18 MB`)**: `ForeverSuite` (코어 OS 셸 · 103 Lua) + `ForeverSuite_Data` (LoadOnDemand 도감 · 7 Lua · 0-Pack 생존) + `ForeverSuite_Media` (Burnished Gold 9-Slice & 12-Layer 3D 화살표 · 1 Lua)
  - **7-Layer 엄격 격리 (`fsx check` AST 강제)**: `Domain(Rank 0)` → `Api(Rank 1)` → `Secure(Rank 2)` → `Blizzard(Rank 3)` ⊥ `Bridges(Rank 3)` → `UI(Rank 4)` → `Features(Rank 5)`
  - **Zero-Taint · `C_Secrets` 불변식**: `Blizzard/` `SetScript` 전면 금지(`HookScript` 전용), `Secure/` `UIParent` 직계 앵커, `fsx check` `@secret` 데이터플로 AST 게이트 및 `C_DurationUtil` 불투명 바인딩
  - **100% Rust `fsx` 툴체인** (`tools/fsx`): AST 정적 검증(`fsx check`), 임베디드 Lua 5.1 VM 테스트(`fsx test`), 3-폴더 릴리스 패키징(`fsx package --max-mb 18`), 외부 백업 회전·원자적 롤백 설치(`fsx install` / `fsx rollback`)

---

## 1. v6.0 핵심 기능 요약

| 영역 | 주요 기능 |
|---|---|
| **공존 중재 & 6대 외부 브리지** | `Domain/Coexistence.lua` (5상태 × 8이벤트 = 40셀 중재) · `Baganator`(5-인자 코너/영역 등록), `Syndicator`(부캐/전투부대 재고), `Auctionator`(경매 시세), `DialogueUI`(한국어 네이티브 퀘스트 감지), `Spoken`(1-인자 음성 덕킹 게이트), `Platynator`/`ForeverTotems`/`RareScanner` 공식 API 공존 |
| **5-State 연출자 (`Director`)** | `EDIT_OVERRIDE > COMBAT > DEAD(죽은 척하기 제외) > FISHING(탈것 제외) > DIALOGUE > EXPLORATION` 실시간 HUD 알파 연출 · 단일 60Hz `_tweenFrame`(수렴 시 `0.00ms` 유휴) · 전투 종료 `1.2s` 홀드 · 대화 `350ms` 디바운스 |
| **HiDPI 1px & 캐릭터창 도킹** | `UI/PixelUtil.lua` (`768 / physH / effectiveScale`, `FHD`/`RETINA`/`UHD_4K` 티어) · `CharacterFrame` 우측(자동 좌측 반전) Zero-Taint 3탭 도킹 패널(`[스탯 / 업글 Top3 / 5레벨 스킬]`, 닫힘 시 `0.00ms`) |
| **3-계층 설정 & 무손실 마이그레이션** | `ForeverSuiteV2DB` `schemaVersion = 6` (`profiles.account` + `devices.<res@scale:os>` 기기별 레이아웃 격리) · v5 자동 백업(`_backup_v5`) 및 `/fsdb restore v5` 1클릭 복원 · 레거시 `ForeverSuiteDB` 읽기 전용 불변식(`D1`) |
| **3-계층 DataHub & 0-Pack 생존** | `STATIC → LIVE → EMBEDDED(≤60KB)` 폴백 · `ForeverSuite_RegisterPack(2|6)` 에폭 무효화 · `ForeverSuite_Data` 미설치 시에도 크래시 0건 기동 |
| **초기 마법사 & QoL** | `/fs setup` 3단계 연출 마법사(기본 OFF 외부 프리셋 · `ForeverSuite_Media_Assets` LSM 한글 폰트 자동 등록 · `/fs setup undo` 1클릭 원복), `/fs track` 채집 추적 순환, 죽은 척하기 제외 시체 안내 + 사망 전 `/way`·퀘스트 자동 복원, 부캐 전문기술 쿨다운 모델(48h/72h/96h) |

---

## 2. 게임 내 주요 명령어

- `/fs` (또는 `/fs2`) : 통합 Command Hub 열기/닫기 (`ESC` 지원)
- `/fs setup [undo]` : 3단계 초기 연출 마법사 실행 또는 1클릭 원복
- `/fs move` : HUD 이동 모드 토글 (`EDIT_OVERRIDE` 즉시 전환 · 기기 키별 좌표 격리 저장)
- `/fs track` : 비전투 채집 추적(약초 / 광맥·광물 / 보물) 순환
- `/fs bridges` / `/fs reset [id]` : 외부 애드온 브리지 공존 상태 조회 및 재초기화
- `/fsdb [restore v5]` : 현재 DB 스키마·기기 키 확인 및 v5 백업 스냅샷 복원
- `/way <x> <y> [이름]` / `/fs clearway` : 12-Layer 3D 화살표 + 네이티브 웨이포인트 설정/해제
- `/fs [dungeons|bis|professions|questguide|codex|partyfinder|utilities|ledger|fonts|settings|diagnostics]` : 허브 페이지 바로가기

---

## 3. 빌드 · 검증 · 설치 (`tools/fsx`)

```bash
# 1. Rust 단위 테스트 (16/16)
cd /Users/choyoungseo/workspace/ForeverSuite/tools/fsx && cargo test

# 2. 3개 코어 애드온 AST 정적 게이트 (7-Layer, D1, A0, @secret 데이터플로)
cargo run --quiet -- check /Users/choyoungseo/workspace/ForeverSuite/v2/ForeverSuite
cargo run --quiet -- check /Users/choyoungseo/workspace/ForeverSuite/v2/ForeverSuite_Data
cargo run --quiet -- check /Users/choyoungseo/workspace/ForeverSuite/v2/ForeverSuite_Media

# 3. 임베디드 Lua 5.1 VM 통합 테스트 (25/25)
cargo run --quiet -- test /Users/choyoungseo/workspace/ForeverSuite/v2

# 4. 3-폴더 릴리스 ZIP 패키징 (≤18 MB 캡 · SHA-256 검증)
cargo run --quiet -- package --source /Users/choyoungseo/workspace/ForeverSuite/v2 --out /Users/choyoungseo/workspace/ForeverSuite/dist --max-mb 18

# 5. WoW Forever 클라이언트 원자적 설치 (외부 백업 ~/.foreversuite/backups, --keep 2 회전) & 롤백
cargo run --quiet -- install /Users/choyoungseo/workspace/ForeverSuite/v2 --keep 2 --prune-internal-backups
cargo run --quiet -- rollback
```

상세 문서:
- [v6.0 마스터 설계 명세서 (`docs/V6_MASTER_DESIGN_SPEC.md`)](docs/V6_MASTER_DESIGN_SPEC.md)
- [아키텍처 & 품질 계약서 (`docs/ARCHITECTURE.md`)](docs/ARCHITECTURE.md)
- [버전별 변경 이력 (`CHANGELOG.md`)](CHANGELOG.md)
- [macOS / Windows 동기화 가이드 (`docs/WINDOWS_MAC_SYNC.md`)](docs/WINDOWS_MAC_SYNC.md)
