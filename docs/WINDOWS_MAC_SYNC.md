# Windows 원클릭 `.exe` 설치 및 macOS 듀얼 OS 운영 가이드 (`WoW Forever`)

본 프로젝트(`ForeverSuite v0.2.0` + `ForeverSuite_GJBridge` + `GodJohnson v5.0.132` 21개 폴더)는 순수 WoW Lua 5.1 + TOC 표준(`LF` 줄바꿈, 포워드 슬래시 `/` 경로, UTF-8 무 BOM)으로 작성되어 **macOS 클라이언트와 Windows 클라이언트 양쪽에서 100% 동일하게 동작**합니다.

---

## 1. 운영체제별 설치 요약 (총 23개 애드온 폴더)

| 운영체제 | 기본 애드온 설치 경로 (`_forever_`) | 원클릭 설치 도구 |
|---|---|---|
| **macOS** (MacBook Pro) | `/Applications/World of Warcraft/_forever_/Interface/AddOns/` | `./scripts/deploy_mac.sh` |
| **Windows** (게이밍 PC) | `C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns\` | **`dist\ForeverSuite_Installer.exe` (더블클릭 원클릭 설치)** |

설치 완료 시 `Interface/AddOns` 폴더에는 아래 **총 23개 폴더**가 원자적으로 설치됩니다:
- `GodJohnson*` 원본 **21개 폴더** (`GodJohnsonGoldBorder` 등 코어 7종 + `GodJohnsonFontChoice_*` 7비트 레지스터 폰트 폴더 14종, 원본 100% 무수정)
- `ForeverSuite` (개인용 코어 스위트)
- `ForeverSuite_GJBridge` (갓존슨 런타임 개인화 & 중복 기능 단일 소유자 중재 브리지)

---

## 2. Windows PC에서 원클릭 `.exe`로 설치하는 방법 (권장)

1. 비공개 GitHub 리포지토리(`https://github.com/ssacho3-blip/WoW-ForeverSuite`)에서 `dist/ForeverSuite_Installer.exe` 파일만 다운로드하거나 클론합니다.
2. **`ForeverSuite_Installer.exe`를 더블클릭**합니다.
3. 설치기가 자동으로 수행하는 작업:
   - Windows 레지스트리 및 `C:\`, `D:\`, `E:\` 기본 경로를 탐색해 `World of Warcraft\_forever_\Interface\AddOns` 폴더를 자동 감지합니다 (커스텀 경로인 경우 폴더 선택 창이 자동으로 열립니다).
   - CurseForge 공식 CDN에서 `GodJohnson-5.0.132.zip` (`273MB`)을 다운로드하고 **SHA-256 해시(`2cf3a504...d1efd`)를 검증**합니다 (이미 설치되어 있고 해시가 일치하면 재다운로드를 건너뜁니다).
   - `.exe` 내부에 내장된 `ForeverSuite` 및 `ForeverSuite_GJBridge` 최신 버전을 추출해 총 **23개 폴더를 원자적(Atomic Swap)으로 설치**합니다.
   - 완료 안내 메시지 창이 뜨면 확인을 누르고 게임에 접속합니다(게임 실행 중이면 채팅창에 `/reload` 입력).

---

## 3. macOS에서 즉시 설치 / 업데이트하는 방법

```bash
./scripts/deploy_mac.sh
```
- 로컬에 캐시된 `GodJohnson v5.0.132` 21개 폴더의 `.toc` SHA-256 무결성을 먼저 검증한 뒤, `/Applications/World of Warcraft/_forever_/Interface/AddOns`에 23개 폴더 전체를 원자적으로 배포합니다.

---

## 4. 주의사항 (`WTF` 폴더 동기화 금지 원칙)

- **동기화 대상**: `ForeverSuite/` 및 `ForeverSuite_GJBridge/` **애드온 코드만** Git 또는 `.exe` 설치기로 동기화합니다 (`GodJohnson*` 대용량 바이너리 273MB는 Git 리포지토리에 커밋하지 않고 `pinned_upstream.json`의 해시 매니페스트로 버전 관리합니다).
- **`WTF/` 폴더 자동 클라우드 동기화 주의**: Windows와 macOS의 화면 해상도, 그래픽 API(Metal vs DirectX 12), 사운드 출력 장치 CVar가 서로 다르므로 `WTF/` 폴더는 기기별로 독립 유지하십시오.
