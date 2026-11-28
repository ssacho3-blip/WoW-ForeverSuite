# ForeverSuite v6.1 — 경쟁 최고봉 7종 실코드 UI REA & 5사 대표 모델 설계 토론 종합 보고서

> **조사 기준**: `/Applications/World of Warcraft/_forever_/Interface/AddOns/` 실설치 WoW Forever `1.60.1.71037` 애드온 7종 + `ForeverSuite v6.0.0` UI 코드 직접 역공학(REA)
> **참여 패널 (5사 5모델)**: Anthropic `Claude Opus 5.5` · OpenAI `GPT-6.2 Sol` · Zhipu AI `GLM-5.3` · DeepSeek `DeepSeek-V4.1-Flash` · Google `Gemini 4 Neon High`(중재·종합)

---

## 1. 실설치 경쟁 최고봉 7종 vs ForeverSuite v6.0 정량 REA 비교

### 1-1. 렌더링 프리미티브 실측 매트릭스

| UI 프리미티브 | `DialogueUI` (106 Lua · 258 Art) | `Baganator` (122 Lua · 22 Art) | `Platynator` (90 Lua · 290 Art) | `Auctionator` (344 Lua · 24 Art) | `RareScanner` (189 Lua · 119 Art) | `Spoken` (57 Lua · 118 Art) | `WhatTheWhisper` (90 Lua · 5 Art) | **`ForeverSuite v6.0`** (103 Lua) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **`SetTextureSliceMargins`** (GPU 9-Slice) | **21** | 1 | **17** | 0 | 0 | 0 | 0 | **0** (수동 9-tex) |
| **`CreateAnimationGroup` / `Easing` / `Lerp`** | **6 / 40 / 30** | 3 / 0 / 0 | **5 / 0 / 0** | 0 | 3 / 0 / 3 | 2 / 0 / 3 | **7 / 1 / 0** | **0 / 0 / 0** |
| **`SetSpacing`** (줄간격/행간) | **25** | **9** | 1 | 0 | 0 | 2 | **7** | **0** |
| **`CreateMaskTexture`** (라운드·원형 마스크) | **4** | 1 | **10** | 0 | 0 | **9** | 2 | 2 |
| **`ScrollBox`** (1.60.1 네이티브 가상 스크롤) | 0 | **101** | **45** | **102** | 6 | 1 | 0 | **0** |
| **`SetGradient`** (깊이·스크림) | 2 | 0 | 0 | 0 | 0 | **12** | **22** | 3 |
| **`SetBackdrop`** | 0 | 23 | 0 | 0 | 70 | 34 | **0** | 2 |
| **`PlaySound`** (촉각 피드백) | **25** | 10 | 4 | 6 | **52** | 18 | 9 | 10 |

### 1-2. 애드온별 핵심 UI 기법 코드-레벨 해부 & 장단점

1. **`DialogueUI` (Peterodox — RPG 감성·가독성 끝판왕)**
   - **실코드 기법**: `Code/Utility/TextureSlice.lua`(스케일 연동 `GetPixelForScale` 9-Slice + `SetSnapToPixelGrid` 일괄 전파), `ThemeUtil.lua`(`AdjustTextColor`로 테마별 원색 가독성 자동 보정 + `CallbackRegistry`), `FontUtil.lua`(`NUMBER_FONT_FILE.korean = "Fonts/2002.TTF"`, 5단계 폰트 스케일, `SetSpacing` 25회), 40 Easing + 30 Lerp + 25 PlaySound.
   - **장점**: WoW 세계관 일체감 최상, 장문 한글 가독성과 대비가 가장 뛰어남.
   - **단점**: 아트 리소스 258개 의존으로 유지비용 높음; 정보 밀도가 높은 대시보드/표에는 여백이 과도함.

2. **`WhatTheWhisper` (모던 네이티브 앱 UI 공학 끝판왕 — 아트 파일 단 5개!)**
   - **실코드 기법**: `UI/Draw.lua`(**단 1장의 `Round.tga` 원판에서 4코너+3밴드 = 7텍스처로 임의 반경·개별 코너 라운드 사각형 구현**, `BackdropTemplate` 0건 + `__wtwHairline` 이중 테두리 자동 감사), `UI/Anim.lua`(**이중 모션 엔진**: 알파/스케일/이동은 C++ `AnimationGroup`, 동적 색/폭/스크롤은 숨겨진 단일 공유 `driver` 프레임 `OnUpdate` — 트윈 0건 시 `driver:Hide()`로 `0.00ms` 유휴!), `Skins/`(7종 스킨: `bg0~bg3` 계층 + `hover=#FFF@9%` / `selected=#FFF@15%` / `pressed=#FFF@20%` 화이트 알파 오버레이).
   - **장점**: 최소 용량(5 파일)으로 가장 세련된 모던 라운드·유리·다크 UI 및 `0.00ms` 유휴 모션 달성.
   - **단점**: 패널 30개 × 7텍스처 시 드로우콜 증가 우려(아틀라스 통합 필수), WoW 1.60.1에 실제 가우시안 블러가 없어 `Glass` 스킨은 밝은 지형에서 대비 저하.

3. **`Baganator` & `Auctionator` & `Platynator` (plusmouse 계열 — 데이터 밀도 & 1.60.1 네이티브)**
   - **실코드 기법**: `Baganator/Skins/Dark.lua`(`ToHSL`/`FromHSL`/`Lighten(shift)` 기반 동적 버튼 상태 머신, `0.08~0.92` 아이콘 줌 크롭 + 1px 품질 테두리), `Platynator/CustomiseDialog/Components.lua`(1.60.1 네이티브 `SettingsCheckboxTemplate`, `PanelTopTabButtonTemplate`, `WowStyle1DropdownTemplate` + 통합 `Skins.AddFrame()`), 3종 합계 **248회 `ScrollBox`** 네이티브 가상 스크롤.
   - **장점**: 수백~수천 행 목록에서도 60fps 매끄러운 스크롤, 일관된 상태 전이, 최소 유지보수.
   - **단점**: `WowStyle1Dropdown`은 공유 `Menu` 매니저 경유로 전투 중/외부 스킨 충돌 검증 범위가 넓음; 순수 HSL 밝기 이동은 골드 계열에서 탁해질 수 있음.

4. **`Spoken` (시네마틱 연출 & 소프트 드롭 섀도)**
   - **실코드 기법**: `UI/DialogueUITransitions.lua`(2차 베지어 궤적 `Bend()`, 감쇠 스프링 `exp(-6t)*sin()`, `PlaceShadow(region, anchor, dx, dy, blur, scale)` 소프트 그림자, `CreateMaskTexture` 9회).
   - **장점**: 화면 위 붕 뜬 카드의 깊이감과 생동감이 탁월.
   - **단점**: OS 셸에서 반복 열람 시 바운스/베지어 모션은 피로감을 유발하며, 풀사이즈 섀도는 오버드로우 증가.

5. **`ForeverSuite v6.0` 현재 UI 적나라한 자가 감사**
   - `SetSpacing` **0건**(한글 받침 밀착), `AnimationGroup`/이징 **0건**(2008년식 즉시 스냅), 라운드 코너 **0건**(전면 90° 박스), `ScrollBox` **0건**(이산 행 점프), `FS-Frame-Gold/Dark.tga` **859KB 대형 512×512 TGA**(픽셀 스냅/코너 스케일 미적용), 인접 카드 **이중 테두리**, `CharacterDockPanel`·`SetupWizard`가 **`\n` 단일 `Label` 텍스트 덤프**.

---

## 2. 5사 대표 모델별 UI 설계 입장 & 장단점 토론

### ① Anthropic — `Claude Opus 5.5` (시각 정체성 · 한국어 타이포 · 테마 철학)
- **핵심 입장**: **Hybrid Skin System (토큰 1개, 스킨 2종: 기본 `Forever Gold` + 보조 `Midnight Glass`)**. 클래식 1.60.1 감성 유지 + WtW식 `bg0~bg3` & white-alpha 오버레이(`hover 6% / selected 12% / pressed 18%`) 결합. 스킨 7종은 QA 표면만 7배 폭증하므로 2종으로 절제.
- **한국어 타이포·격자 기준**: 5단계(`10` 보조숫자 / `12` / **`13` 본문** / `15` / `18`), **`SetSpacing` 본문 3px · 제목 2px**, 4px 격자(내부 패딩 12, 섹션 간격 16, 행 높이 22/28, 반경 패널 6 / 버튼 4), 본문 대비 ≥4.5:1 · 골드 대비 ≥7:1, 모션 진입 `0.15s outCubic` · 퇴장 `0.10s`.
- **채택 vs 폐기**: `Round.tga` 7-tex, `SetTextureSliceMargins`, `ScrollBox`, `AdjustTextColor`, 아이콘 크롭 **채택** / `outBack`, `Bounce/Bezier`, 이중 테두리, `\n` 덤프 **폐기**.

### ② OpenAI — `Codex GPT-6.2 Sol` (1.60.1 엔지니어링 · Zero-Taint · 성능 ROI)
- **핵심 입장**: **점진적 저위험 ROI 우선** — ① `\n` 텍스트 덤프 구조화 + `SetSpacing` → ② 공용 라운드 텍스처 + 짧은 `AnimationGroup` → ③ 긴 목록 1곳부터 `ScrollBox` 파일럿 검증 후 확대.
- **기술별 함정 경고**:
  - `ScrollBox`: 긴 목록엔 압도적이나, 가변 높이+전체 리빌드 시 CPU 피크 및 재바인딩 시 이전 선택/툴팁/콜백 잔류 주의. 짧은 고정 목록은 자체 풀이 단순·안전.
  - `WowStyle1Dropdown`: 공유 `Menu` 매니저를 타므로 `SettingsCheckbox`보다 Taint/전투 검증 범위가 넓음 → 전면 교체 금지, 애드온 소유 비보호 프레임 유지 권장.
  - `859KB TGA`: 파일 크기와 VRAM은 별개이나(해상도·포맷 기준), 공용 소형 텍스처+`SetVertexColor`가 메모리·패키지 모두 유리.
  - **절대 금지**: Blizzard 전역/공유 믹스인 변조, 전투 중 보호 프레임 앵커/표시 변경, 유휴 `OnUpdate`/애니메이션 잔류.

### ③ Zhipu AI — `GLM-5.3` (모션 코레오그래피 · 3-Skin 표면 아키텍처)
- **핵심 입장**: **모션 3계층 분리** (`AnimationGroup` 정형 150ms fade/scale + 단일 숨김 Lua Tween Driver 동적 호버/리플로우 + 전투·긴급 팝업 모션 금지 & `Reduced Motion` 접근성 토글 + `FPS<30` 자동 강등).
- **3-Skin 트레이드오프**:
  - `Classic Gold RPG`: 감성·차별화 최상 vs 7-tex 드로우콜 최고·밝은 지형 대비 주의.
  - `Clean Dark Minimal`: 최저 비용·최고 가독성(전투/저사양 최적) vs 개성 부족.
  - `Translucent Glass`: 프리미엄 인상 vs **1.60.1 클라이언트 실시간 블러 미지원** → 밝은 설원/사막 배경에서 가독성 붕괴 위험(자동 불투명도 상승 다크 폴백 필수).
- **4대 도입 조건**: `Round.tga` 아틀라스 통합, 정적 섀도(애니메이션 금지), HSL→RGB 변환 캐시, 전투 구역 모션 차단.

### ④ DeepSeek — `DeepSeek-V4.1-Flash` (정보구조 · HUD 인체공학 · 대시보드 밀도)
- **핵심 입장**: **"밀도는 줄이는 게 아니라 계층화(오버플로 · 요약 바 · 2-Pane)로 해결"**.
- **구체 리디자인**:
  - **상시 HUD**: `StatusPillHud` 22px 3분할 캡슐(라벨 축약, 아이콘+숫자 중심), `QuestTrackerView` "3+1" 축약(중요 3개 + `+N` 오버플로), `NavigationHud` 화살표·거리·방향 3요소 집중. *(단점: 축약 규칙 학습 필요, 전체 목록 선호 유저를 위한 토글 필요)*
  - **`CharacterDockPanel` & `SetupWizard`**: Dock 상단 요약 바 + 2열 아이콘/라벨/값/진행바 그리드(`SetSpacing` + 1px 구분선); Wizard 상단 스텝 인디케이터(`1/3 · 2/3 · 3/3`) + 컨트롤 카드 + 하단 고정 `[이전][다음]`.
  - **`/fs` CommandHub**: `HomePage` 4개 StatCard를 단일 요약 바로 병합하고 8개 QuickTile 반복을 줄여 대시보드 피로감 해소, 12페이지는 좌측 검색+4그룹 / 우측 상세 2-Pane 통일. *(단점: 960×640에서 2-Pane 우측 폭 압박 주의)*

### ⑤ Google — `Gemini 4 Neon High` (중재 · 합의안 & 충돌 조정)

#### 합의 완료 항목 (5/5 만장일치)
1. **`CharacterDockPanel` + `SetupWizard`의 `\n` 텍스트 덤프 즉각 폐기** → 아이콘·2열 스탯 그리드·적중 캡 진행바·3스텝 프로그레스 헤더로 리치 컴포넌트화.
2. **한국어 타이포그래피 전면 교정**: 전 멀티라인 `Label`에 `SetSpacing(3)`(제목 `2`) 적용, 4px 여백 격자, 본문 13pt · 대비 ≥4.5:1, `2002.TTF` 기반 한글+숫자 안전성 유지.
3. **라운드 코너 + 단일 1px Hairline 전환**: `WhatTheWhisper`식 소형 `Round.tga` 7-텍스처(아틀라스 통합)로 `90°` 박스·이중 테두리·859KB TGA 의존 제거.
4. **이중 모션 엔진 + `0.00ms` 유휴 보장**: 창 열림/닫힘은 C++ `AnimationGroup(0.15s)`, 호버/탭 인디케이터는 숨김 단일 Lua Tween Driver(`outCubic`), 전투/긴급 경보는 `0ms` 즉시 전환 + `Reduced Motion` 스위치.
5. **화려한 과잉 모션(`outBack`, `Bounce`, `Bezier`) 배제**: OS 셸 피로도 방지.

#### 모델 간 핵심 의견 충돌 & 최종 중재안

| 충돌 쟁점 | 찬성 측 | 신중/반대 측 | **최종 중재 결정 (v6.1)** |
|---|---|---|---|
| **스킨 개수 (`Glass` 포함 여부)** | GLM-5.3 (3종: Gold·Dark·Glass) | Opus 5.5 (2종 제한, QA 폭증 & 1.60.1 블러 미지원) | **2종 우선(`Forever Gold` 기본 + `Midnight Dark`), `Glass`는 불투명도 슬라이더 옵션으로 흡수** (블러 미지원 가독성 붕괴 원천 차단) |
| **네이티브 `ScrollBox` 전면 도입** | Opus 5.5 (즉시 전환) | GPT-6.2 Sol (긴 목록 1곳 파일럿 후 확대, 짧은 목록은 풀 유지) | **단계적 도입**: `BiSBrowser`·`Codex` 같은 100+행 긴 목록부터 `ScrollBox` 파일럿 검증 후 확산 |
| **Blizzard 네이티브 Dropdown 템플릿** | Platynator REA 참고 | GPT-6.2 Sol (공유 `Menu` 매니저 Taint 위험) | **비채택**: 기존 Zero-Taint 애드온 소유 `PillBar`/`FlowPillGroup`의 시각 완성도(라운드+알파 호버)만 업그레이드 |
| **`HomePage` 카드 수 축소** | DeepSeek (StatCard 4→요약바 1, Tile 8→5) | 기존 대시보드 직관성 유지 필요 | **시각 계층 재정비**: 상단 Hero+4 KPI는 슬림 1줄 리본(52px)으로 압축하고, 중앙에 **외부 브리지 상태 + 부캐 쿨다운 카드**를 추가해 v6 OS 셸 정체성 강화 |

---

## 3. ForeverSuite v6.1 UI 비주얼 오버홀 실행 로드맵 (제안)

- **Wave 1 (체감 임팩트 최상 · 저위험)**:
  1. `UI/Draw.lua` (`Round.tga` 1장 기반 7-tex 라운드 사각형 + `__fsHairline` 단일 1px 보더) & `UI/Motion.lua` (C++ `AnimationGroup` + 숨김 `0.00ms` 공유 `outCubic` Tween Driver + `Reduced Motion` 옵션)
  2. `UI/Tokens.lua` & `UI/Widgets.lua` 전면 리프레시 (`SetSpacing(3)`, 4px 여백 격자, white-alpha 호버/선택/프레스, `0.08~0.92` 아이콘 줌 크롭, `AdjustTextColor` 대비 보정, 캐시된 HSL 하이라이트)
  3. **`CharacterDockPanel` & `SetupWizard` 리치 위젯화** (2열 스탯 그리드 + 적중 캡 게이지바 + BiS 아이콘/툴팁 행 + 3단계 스테퍼 카드)
- **Wave 2 (상시 HUD & CommandHub 완성도)**:
  4. **L0 상시 HUD 리디자인** (`QuestTrackerView` 헤더 슬림화·접기 애니메이션·진행바, `StatusPillHud` 라운드 캡슐, `NavigationHud` 깔끔한 거리 게이지)
  5. **`CommandHub` + `HomePage` 재구성** (부드러운 탭 인디케이터 슬라이드, 슬림 KPI 요약 바, v6 부캐 쿨다운 & 외부 브리지 상태 카드)
- **Wave 3 (긴 목록 스크롤 파일럿 & 실기 검증)**:
  6. `CodexPage` / `BiSBrowserPage` 1.60.1 네이티브 `ScrollBox` 파일럿 + 실기 `taint.log` 0건 & 유휴 `0.00ms` 측정

---

## 4. 보강 REA: `GodJohnsonGoldBorder v5.312` 실코드 해부 & 5사 통합 토론

> **누락 보완 사유**: Phase 1에서 AddOns 외부로 이관해 두었던 원본 `GodJohnsonGoldBorder v5.312` (`.upstream_cache/GodJohnson-5.312.zip` · `.ForeverSuite_prev_backup/GodJohnsonGoldBorder`)를 8번째 벤치마크로 추가 역공학하여, 영어권 7종이 다루지 않는 **한국 WoW 전용 UI 인체공학**을 완성했습니다.

### 4-1. `GodJohnsonGoldBorder v5.312` 정량 실측 (8종 중 3개 지표 1위)

- **규모**: **346 Lua 파일 · 395 아트 파일**
- **UI 프리미티브 실측**:
  - **`SetSpacing`: 68** (8종 중 **1위** — `DialogueUI` 25의 2.7배, `ForeverSuite v6.0`은 0)
  - **`SetGradient`: 56** (8종 중 **1위** — `WhatTheWhisper` 22의 2.5배)
  - **`CreateMaskTexture`: 24** (8종 중 **1위** — `Surface5098/CornerTopLeft..BottomRight.tga` + `OuterInnerShadow`)
  - `SetWordWrap`: 311 · `SetShadowOffset`: 32 · `SetAlpha`: 142 · `SetBackdrop`: 131 · `NineSlice`: 20 · `ScrollBox`: 7 · `CreateAnimationGroup`: 2

### 4-2. 실코드에서 발견한 6대 강점 vs 4대 치명적 약점

| 구분 | 실코드 위치 & 메커니즘 | 장점 (Pros) | 단점 / 함정 (Cons) |
|---|---|---|---|
| **① `InkUV` 연속 질감 시트** | `Theme401.lua:161-180` (`SoftInk.tga`를 `(GetLeft-rootLeft, GetTop-rootTop)`으로 샘플링) | 인접 카드가 하나의 연속된 차콜·가죽 면처럼 이어져 블러 없이도 프리미엄 깊이감 형성 | 리사이즈 시 UV 재계산 필요; 어두운 밝기(0.35)에서 입자 노이즈가 글자와 경쟁 |
| **② `TintLeather` 6팔레트 + 밝기 슬라이더 2종** | `Theme401.lua:129-153` (`textureBrightness 0.35~1.0`, `goldBrightness 0.40~1.0`) | 텍스처 1장으로 6색(기본/갈색/검정/청회/녹색/버건디)과 모니터별 밝기 취향 흡수 | 곱연산 틴트 특성상 저명도(`0.35~0.40`)에서 골드 강조와 하이라이트 디테일 소실 |
| **③ `SurfaceRim5097` 오버레이 테두리** | `Theme401.lua:50-78` (`EnableMouse(false)` 자식 림을 `highest+1`에 배치) | 내부 스크롤/카드가 외곽 골드 림을 절대 덮어 자르지 않음 | `coroutine.yield` 트리 순회(`RefreshSurfaceDepth5097`)로 매번 전체 자식 탐색하는 과잉 비용 |
| **④ `Label:Fit()` + `GrowthTextScroll5042`** | `MainShell5010.lua:64-95`, `GrowthTheme5042.lua:99-118` | 대형 한글 폰트에서 잘림(`...`) 없이 축소 맞춤 + 고정 읽기 영역 자동 스크롤 전환 | 모든 라벨 `SetText/SetFont`에 `hooksecurefunc` + 3회 재측정 루프 → CPU/재진입 부담 |
| **⑤ `BasaltButton5030` + `처음이라면 · 도움말`** | `Home472.lua:64-150`, `GrowthTheme5042.lua:139-150` | 차콜 면 + 3px 좌측 골드 바 + `OUTLINE` + `(1,-1)` 그림자 + Toggle/Priority 명확 분리 + 페이지별 맥락 도움말 | 홈 화면에 21개 버튼 동시 나열(인지 부하) + `1280×878` 초대형 창(1080p/맥북 시야 과점유) |
| **⑥ 대형 아틀라스 & 버전 패치 누적** | `MainShell5010.lua:14` (`4096×2048` 32 MiB/장), `5010..5098` 접미사, `SetBackdrop` 131건 | 화려한 전용 일러스트 외곽 프레임 | **32 MiB/장 VRAM 부담**, 346 Lua 스파게티 누적, 모션 거의 전무(`AnimationGroup` 2건) |

### 4-3. 5사 대표 모델 통합 결론 (갓존슨 × DialogueUI × WhatTheWhisper × Baganator 최종 융합)

1. **Anthropic (`Claude Opus 5.5`)**: `SurfaceRim` 오버레이 테두리 + 명시적 `SetTextFit()`(훅 제거) + `Ink/Gold` 밝기 슬라이더 + `Basalt` 3px 골드 바 문법을 `Forever Gold` 기본 스킨에 직결. 갓존슨 원화/넥슨 폰트 재배포는 라이선스 준수를 위해 패턴만 자체 재구현.
2. **OpenAI (`GPT-6.2 Sol`)**: `hooksecurefunc`·`coroutine` 트리 순회·`4096×2048`(32 MiB) 아틀라스 전면 배제. 대신 ① 등록된 FS 표면만 테마 변경 시 1-pass 갱신, ② 한글 비공백 줄바꿈 + `SetSpacing(3)` + `GetStringHeight()` 높이 확장, ③ 바깥 형제 림 프레임 분리로 **0.00ms 유휴·≤18MB·Zero-Taint** 달성.
3. **Zhipu AI (`GLM-5.3`)**: **1.60.1 블러 없는 가짜 Glass보다 갓존슨의 "불투명 + 연속 입자(`InkUV`) + 밝기 2종"이 실전 가독성·성능 모두 우위!** 여기에 WhatTheWhisper식 **150ms ease-out 3px 골드 바 마이크로 모션 + 패널 150ms 페이드인(종료 0ms 스냅)**만 절제해 결합(입자/대형 프레임 스케일 애니메이션은 금지).
4. **DeepSeek (`DeepSeek-V4.1-Flash`)**: 한국 유저가 사랑하는 **큰 한글 가독성 + `처음이라면 · 도움말`(복잡 페이지 우상단 고정 1개) + 형태가 다른 Toggle/Priority 구분**만 취하고, 갓존슨의 단점(`1280×878` 과점유·홈 21버튼)은 ForeverSuite의 **`960×640`(가변 최대 `1040×680`) + 2단 요약 구조**로 절제.
5. **Google (`Gemini 4 Neon High` 최종 통합)**: **v6.1 `Forever Gold` 정체성 확정** —
   - **표면**: `512×512` 경량 공용 `InkUV` 연속 질감 + `Round.tga` 7-tex 라운드 코너 + 바깥 형제 `SurfaceRim` + `textureBrightness`/`goldBrightness` 슬라이더 2종 (`Forever Gold` 기본 + `Midnight Dark` 보조)
   - **버튼·타이포**: `Basalt` 3px 좌측 골드 바(Toggle=체크+채움 / Priority=골드 바+강조) + `SetSpacing(3)` + 명시적 `SetTextFit()` + 대형 폰트 자동 스크롤 + `처음이라면 · 도움말` 호버 버튼
   - **모션**: 150ms `AnimationGroup` 페이드인 + 숨김 `0.00ms` `outCubic` 호버/탭 바 + 전투 모션 0ms 차단 & `Reduced Motion` 스위치
