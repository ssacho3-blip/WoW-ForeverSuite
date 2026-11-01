# Windows & macOS 듀얼 OS 운영 가이드 (`WoW Forever`)

본 프로젝트(`ForeverSuite`)는 순수 WoW Lua 5.1 + TOC 표준(`LF` 줄바꿈, 포워드 슬래시 `/` 경로, UTF-8 무 BOM)으로 작성되어 **macOS 클라이언트와 Windows 클라이언트 양쪽에서 100% 동일하게 동작**합니다.

---

## 1. 운영체제별 설치 경로

| 운영체제 | 기본 애드온 설치 경로 (`_forever_`) | 자동 배포 스크립트 |
|---|---|---|
| **macOS** (현재 MacBook) | `/Applications/World of Warcraft/_forever_/Interface/AddOns/ForeverSuite` | `./scripts/deploy_mac.sh` |
| **Windows** (게이밍 PC) | `C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns\ForeverSuite` | `.\scripts\deploy_win.ps1` |

---

## 2. 배포 및 동기화 방법

### A. macOS에서 즉시 반영
```bash
./scripts/deploy_mac.sh
```
임시 스테이징 디렉터리에서 파일 무결성을 검증한 뒤 원자적 교체(Atomic Swap)로 `/Applications/World of Warcraft/_forever_/Interface/AddOns/ForeverSuite`에 반영합니다. 게임 실행 중이라면 채팅창에 `/reload`만 입력하면 즉시 적용됩니다.

### B. Windows PC로 전달 / 동기화
1. **GitHub 비공개 리포지토리 동기화 (권장 — `ssacho3-blip/WoW-ForeverSuite`)**:
   Windows PC PowerShell에서 최초 1회 클론 후 배포 스크립트를 실행합니다(이후 업데이트 시 `git pull` + `deploy_win.ps1`):
   ```powershell
   git clone https://github.com/ssacho3-blip/WoW-ForeverSuite.git C:\WoW_Forever\ForeverSuite
   cd C:\WoW_Forever\ForeverSuite
   powershell -ExecutionPolicy Bypass -File .\scripts\deploy_win.ps1
   ```
2. **단일 포터블 ZIP 패키지 생성**:
   macOS에서 아래 명령을 실행하면 `dist/ForeverSuite-v0.1.0.zip`이 생성됩니다:
   ```bash
   python3 scripts/package_release.py
   ```
   생성된 ZIP 파일을 Windows PC의 `_forever_\Interface\AddOns\` 폴더에 압축 해제하면 즉시 인식됩니다.

---

## 3. 중요 주의사항 (`WTF` 폴더 동기화 금지 원칙)

- **동기화 대상**: `ForeverSuite/` **애드온 코드 폴더만** Git 또는 ZIP으로 동기화합니다.
- **`WTF/` 폴더 자동 클라우드 동기화 주의**: Windows와 macOS의 화면 해상도, 그래픽 API(Metal vs DirectX 12), 사운드 출력 장치 CVar가 서로 다르며, 두 기기에서 번갈아 접속할 때 클라우드 드라이브(OneDrive 등)가 `WTF/Account/.../SavedVariables/ForeverSuiteDB.lua`를 덮어쓰면 세션 골드 원장이나 프로필이 유실될 수 있습니다. 캐릭터 설정 이전이 필요할 때만 수동 백업 후 복사하십시오.
