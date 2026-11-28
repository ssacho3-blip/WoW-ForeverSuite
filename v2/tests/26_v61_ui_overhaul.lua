-- Test 26: ForeverSuite v6.1.0 UI Visual Overhaul (Waves 1-3) — ATDD / BDD / DDT Suite
-- Verifies AC1..AC8 from Claude Opus 5.5 Track L Architecture Brief:
--   AC1: FS-Round.tga & FS-SoftInk.tga art registration
--   AC2: UI/Draw.lua (7-tex Round.tga, __fsHairline single-border guard, sibling SurfaceRim, InkUV, cached HSL Lighten & AdjustTextColor)
--   AC3: UI/Motion.lua (outCubic, 150ms fade-in / 0ms hide, 0.00ms idle driver:Hide(), combat 0ms snap + Reduced Motion)
--   AC4: UI/Tokens.lua (2 skins Forever Gold/Midnight Dark, brightness sliders clamping DDT, white-alpha overlays, 4px grid, SetSpacing 3/2, 1-pass surface registry)
--   AC5: UI/Widgets.lua (Basalt Toggle vs Priority distinct forms, SetTextFit <= 4 iterations + overflow scroll, 0.08..0.92 icon crop, HelpPill, Fail-Closed number slider schema)
--   AC6: CharacterDockPanel & SetupWizard (zero raw \n dump in visible labels, 2-col stat grid, Hit Cap gauge + no-fake-zero, BiS icons/tooltips, 3-step stepper + fixed footer)
--   AC7: StatusPillHud (22px 3-segment capsule), QuestTrackerView compact 3+1 mode, CommandHub 960x640 sliding tab indicator, HomePage bridge/alt-cd card, ProfileStore v6.1 keys
--   AC8: UI/VirtualList.lua (native ScrollBox + pool fallback parity, <= visible+2 frames for 1000 rows, clean recycle)
local ns = _G.ForeverSuite
__FS_FIRE_EVENT("PLAYER_LOGIN")

local function assertEq(actual, expected, msg)
    assert(actual == expected, (msg or "assertEq failed") .. " (got=" .. tostring(actual) .. ", expected=" .. tostring(expected) .. ")")
end

local T = ns.UI.Tokens
local W = ns.UI.Widgets
local Draw = ns.UI.Draw
local Motion = ns.UI.Motion
local VirtualList = ns.UI.VirtualList

------------------------------------------------------------------------
-- AC1: Art Kit Registration (FS-Round.tga & FS-SoftInk.tga)
------------------------------------------------------------------------
assert(type(T.UI_ART.roundDisc) == "string" and string.find(T.UI_ART.roundDisc, "FS%-Round%.tga", 1) ~= nil, "AC1: roundDisc token must point to FS-Round.tga")
assert(type(T.UI_ART.softInk) == "string" and string.find(T.UI_ART.softInk, "FS%-SoftInk%.tga", 1) ~= nil, "AC1: softInk token must point to FS-SoftInk.tga")

------------------------------------------------------------------------
-- AC2: UI/Draw.lua Primitives
------------------------------------------------------------------------
assert(type(Draw) == "table", "AC2: ns.UI.Draw must exist")

local rfFrame = CreateFrame("Frame", nil, _G.UIParent)
rfFrame:SetSize(80, 12)
local rf = Draw.CreateRoundedFill(rfFrame, 20, { 0.1, 0.1, 0.12, 0.95 })
assertEq(#rf.textures, 7, "AC2: CreateRoundedFill must create exactly 7 textures (4 corners + 3 bands)")
assertEq(rf.clampedRadius, 6, "AC2: radius must clamp to min(w,h)/2 = 6")

-- Single hairline double-border guard
local hlFrame = CreateFrame("Frame", nil, _G.UIParent)
hlFrame:SetSize(120, 40)
local h1 = Draw.CreateHairline(hlFrame, T.BORDER.HAIRLINE)
local h2 = Draw.CreateHairline(hlFrame, T.BORDER.GOLD)
assert(h1 == h2 and hlFrame.__fsHairline == h1, "AC2: CreateHairline must guard against double borders via __fsHairline")

-- Outer non-mouse sibling SurfaceRim (zero GetChildren tree walk)
local rimParent = CreateFrame("Frame", nil, _G.UIParent)
local rimTarget = CreateFrame("Frame", nil, rimParent)
rimTarget:SetSize(200, 120)
rimTarget:SetFrameLevel(10)
local getChildrenCalls = 0
rimTarget.GetChildren = function() getChildrenCalls = getChildrenCalls + 1; return nil end
local rim = Draw.CreateSurfaceRim(rimTarget, T.BORDER.GOLD)
assert(rim ~= nil and rim:GetParent() == rimParent, "AC2: SurfaceRim must be a sibling sharing target's parent")
assertEq(rim:IsMouseEnabled(), false, "AC2: SurfaceRim must have EnableMouse(false)")
assertEq(rim:GetFrameLevel(), 11, "AC2: SurfaceRim frame level must be target+1")
assertEq(getChildrenCalls, 0, "AC2: SurfaceRim must never call GetChildren")

-- InkUV seamless charcoal grain (OnSizeChanged 1-pass recalc)
local inkRoot = CreateFrame("Frame", nil, _G.UIParent)
inkRoot._rect = { left = 100, bottom = 100, width = 960, height = 640 }
inkRoot:SetSize(960, 640)
local inkChild = CreateFrame("Frame", nil, inkRoot)
inkChild._rect = { left = 220, bottom = 300, width = 300, height = 200 }
inkChild:SetSize(300, 200)
local inkTex = Draw.ApplyInkUV(inkChild, inkRoot)
assert(inkTex ~= nil and inkTex._texture == T.UI_ART.softInk, "AC2: ApplyInkUV must bind FS-SoftInk.tga")
local u1, u2, v1, v2 = inkTex:GetTexCoord()
assert(u2 > u1 and v2 > v1, "AC2: ApplyInkUV must compute valid UV span")

-- Cached HSL Lighten & AdjustTextColor WCAG contrast
local cA = Draw.Lighten({ 0.2, 0.3, 0.4, 1 }, 0.15)
local cB = Draw.Lighten({ 0.2, 0.3, 0.4, 1 }, 0.15)
assert(cA == cB, "AC2: Draw.Lighten must hit cache on identical inputs")

local bodyAdj = Draw.AdjustTextColor({ 0.42, 0.40, 0.38, 1 }, { 0.05, 0.05, 0.06, 1 }, 4.5)
assert(Draw.ContrastRatio(bodyAdj, { 0.05, 0.05, 0.06 }) >= 4.5, "AC2: AdjustTextColor body contrast >= 4.5:1")
local goldAdj = Draw.AdjustTextColor({ 0.65, 0.50, 0.18, 1 }, { 0.05, 0.05, 0.06, 1 }, 7.0)
assert(Draw.ContrastRatio(goldAdj, { 0.05, 0.05, 0.06 }) >= 7.0, "AC2: AdjustTextColor gold contrast >= 7.0:1")

------------------------------------------------------------------------
-- AC3: UI/Motion.lua Dual Motion Engine & 0.00ms Idle Guarantee
------------------------------------------------------------------------
assert(type(Motion) == "table", "AC3: ns.UI.Motion must exist")
assertEq(Motion.OutCubic(0), 0, "AC3: OutCubic(0) == 0")
assertEq(Motion.OutCubic(1), 1, "AC3: OutCubic(1) == 1")
local prevE = -1
for i = 0, 10 do
    local curE = Motion.OutCubic(i / 10)
    assert(curE >= prevE, "AC3: OutCubic must be monotonic non-decreasing")
    prevE = curE
end

-- FadeIn 150ms / Hide 0ms
local mFrame = CreateFrame("Frame", nil, _G.UIParent)
Motion.SetReducedMotion(false)
_G.__FS_MOCK.inCombat = false
Motion.FadeIn(mFrame, 0.15)
assert(mFrame:IsShown() == true, "AC3: FadeIn shows frame")
assert(mFrame._fsFadeGroup ~= nil and mFrame._fsFadeAnim:GetDuration() == 0.15, "AC3: FadeIn uses 150ms C++ AnimationGroup")
Motion.InstantHide(mFrame)
assertEq(mFrame:IsShown(), false, "AC3: InstantHide hides immediately (0ms)")

-- Shared hidden Lua Tween Driver -> hides when count == 0 (0.00ms idle)
mFrame:Show()
local tweenTargetVal = 0
local tId = Motion.Tween(mFrame, "x", 0, 100, 0.15, function(v) tweenTargetVal = v end)
assert(tId ~= nil, "AC3: Tween returns id")
assertEq(Motion.GetDriver():IsShown(), true, "AC3: driver shown while tween active")
Motion.Step(0.075)
assert(tweenTargetVal > 50 and tweenTargetVal < 100, "AC3: outCubic midpoint > 50%")
Motion.Step(0.10)
assertEq(tweenTargetVal, 100, "AC3: tween reaches exact final value")
assertEq(Motion.GetDriver():IsShown(), false, "AC3: driver MUST hide when all tweens finish (0.00ms idle)")

-- Target Hide mid-tween & hidden parent subtree must snap toVal + fire onDone once + hide driver (zero frozen frames or idle leak)
local hideParent = CreateFrame("Frame", nil, _G.UIParent)
hideParent:Show()
local hideChild = CreateFrame("Frame", nil, hideParent)
hideChild:Show()
local prunedVal, prunedDoneCount = 0, 0
Motion.Tween(hideChild, "alpha", 0, 1, 0.15, function(v) prunedVal = v end, function() prunedDoneCount = prunedDoneCount + 1 end)
assertEq(Motion.GetDriver():IsShown(), true, "AC3: driver active before parent hide")
hideParent:Hide()
assertEq(hideChild:IsVisible(), false, "AC3: child inside hidden parent is not visible")
Motion.Step(0.016)
assertEq(prunedVal, 1, "AC3: hidden-parent prune snaps final toVal so re-show is never frozen mid-tween")
assertEq(prunedDoneCount, 1, "AC3: hidden-parent prune invokes onDone exactly once")
assertEq(Motion.GetDriver():IsShown(), false, "AC3: driver hides after parent hidden mid-tween")

-- Combat snap (PLAYER_REGEN_DISABLED) snaps BOTH Lua tweens AND in-flight C++ AnimationGroup FadeIns!
local combatVal = 0
Motion.Tween(mFrame, "y", 0, 50, 0.15, function(v) combatVal = v end)
local fadeFrame = CreateFrame("Frame", nil, _G.UIParent)
Motion.FadeIn(fadeFrame, 0.15)
assertEq(fadeFrame:GetAlpha(), 0, "AC3: in-flight C++ FadeIn starts at alpha 0")
assertEq(fadeFrame._fsFadeGroup:IsPlaying(), true, "AC3: C++ AnimationGroup is playing before combat")
assertEq(Motion.GetDriver():IsShown(), true, "AC3: driver active before combat")
_G.__FS_MOCK.inCombat = true
Motion.SnapAllForCombat()
assertEq(combatVal, 50, "AC3: combat snap applies final value synchronously")
assertEq(fadeFrame:GetAlpha(), 1, "AC3: combat snap finishes in-flight C++ FadeIn to alpha 1")
assertEq(fadeFrame._fsFadeGroup:IsPlaying(), false, "AC3: combat snap stops in-flight C++ AnimationGroup")
assertEq(next(Motion._fading), nil, "AC3: combat snap empties Motion._fading (zero stale re-snaps on next combat)")
assertEq(Motion.GetDriver():IsShown(), false, "AC3: combat snap hides driver")

local directVal = 0
Motion.Tween(mFrame, "z", 0, 80, 0.15, function(v) directVal = v end)
assertEq(directVal, 80, "AC3: InCombatLockdown applies synchronously without starting driver")
assertEq(Motion.GetDriver():IsShown(), false, "AC3: driver stays hidden in combat")
_G.__FS_MOCK.inCombat = false

Motion.SetReducedMotion(true)
local rmVal = 0
Motion.Tween(mFrame, "r", 0, 42, 0.15, function(v) rmVal = v end)
assertEq(rmVal, 42, "AC3: reducedMotion applies synchronously")
assertEq(Motion.GetDriver():IsShown(), false, "AC3: driver stays hidden under reducedMotion")
Motion.SetReducedMotion(false)

------------------------------------------------------------------------
-- AC4: UI/Tokens.lua (2 Skins, Brightness DDT Clamping, Overlays, Spacing, 1-Pass Registry)
------------------------------------------------------------------------
local skinCount = 0
for k in pairs(T.THEMES) do
    assert(k == "gold" or k == "dark", "AC4: only 2 skins allowed (gold/dark)")
    skinCount = skinCount + 1
end
assertEq(skinCount, 2, "AC4: exact 2 skins")
assertEq(T.THEMES.gold.label, "Forever Gold", "AC4: gold skin name")
assertEq(T.THEMES.dark.label, "Midnight Dark", "AC4: dark skin name")
assertEq(T.OVERLAY.HOVER, 0.06, "AC4: hover alpha 6%")
assertEq(T.OVERLAY.SELECTED, 0.12, "AC4: selected alpha 12%")
assertEq(T.OVERLAY.PRESSED, 0.18, "AC4: pressed alpha 18%")
assertEq(T.SPACING.BODY, 3, "AC4: Korean body SetSpacing == 3")
assertEq(T.SPACING.TITLE, 2, "AC4: Korean title SetSpacing == 2")
for _, sp in pairs(T.SPACE) do
    assertEq(sp % 4, 0, "AC4: all SPACE tokens must be multiples of 4px")
end

-- DDT clamping for textureBrightness (0.35..1.0) & goldBrightness (0.40..1.0)
local nanVal = 0 / 0
assertEq(T.ClampTextureBrightness(0.10), 0.35, "AC4 DDT: low textureBrightness clamps to 0.35")
assertEq(T.ClampTextureBrightness(1.80), 1.00, "AC4 DDT: high textureBrightness clamps to 1.00")
assertEq(T.ClampTextureBrightness(nil), T.DEFAULT_TEXTURE_BRIGHTNESS, "AC4 DDT: nil -> default")
assertEq(T.ClampTextureBrightness("bad"), T.DEFAULT_TEXTURE_BRIGHTNESS, "AC4 DDT: string -> default")
assertEq(T.ClampTextureBrightness(nanVal), T.DEFAULT_TEXTURE_BRIGHTNESS, "AC4 DDT: NaN -> default")
assertEq(T.ClampGoldBrightness(0.10), 0.40, "AC4 DDT: low goldBrightness clamps to 0.40")
assertEq(T.ClampGoldBrightness(2.50), 1.00, "AC4 DDT: high goldBrightness clamps to 1.00")
assertEq(T.ClampGoldBrightness(nanVal), T.DEFAULT_GOLD_BRIGHTNESS, "AC4 DDT: NaN -> default")

-- 1-pass surface registry
local s1, s2 = CreateFrame("Frame", nil, _G.UIParent), CreateFrame("Frame", nil, _G.UIParent)
local applyHits = 0
T.RegisterSurface(s1, function() applyHits = applyHits + 1 end)
T.RegisterSurface(s2, function() applyHits = applyHits + 1 end)
T.RefreshSurfaces()
assertEq(applyHits, 2, "AC4: RefreshSurfaces calls registered surfaces exactly once each")
T.UnregisterSurface(s1)
T.UnregisterSurface(s2)

-- Composited contrast guardrail across BOTH skins (gold/dark), min & max brightness (0.35/0.40 & 1.00/1.00),
-- ALL 4 surfaces, AND worst-case 18% white PRESSED overlay alpha-composited over each surface!
for _, sk in ipairs({ "gold", "dark" }) do
    T.SetTheme(sk)
    for _, pair in ipairs({ { 0.35, 0.40 }, { 1.00, 1.00 } }) do
        T.SetBrightness(pair[1], pair[2])
        for _, surfKey in ipairs({ "CANVAS", "CARD", "ELEVATED", "HEADER" }) do
            local baseSurf = Draw.AlphaComposite(T.SURFACE[surfKey], { 0, 0, 0, 1 })
            local ratioBase = Draw.ContrastRatio(T.TEXT.GOLD, baseSurf)
            assert(ratioBase >= 7.0, "AC4: gold contrast >= 7:1 on " .. sk .. "/" .. surfKey .. " @" .. tostring(pair[1]) .. " (got " .. string.format("%.2f", ratioBase) .. ")")
            local pressedSurf = Draw.AlphaComposite({ 1, 1, 1, T.OVERLAY.PRESSED }, baseSurf)
            local ratioPressed = Draw.ContrastRatio(T.TEXT.GOLD, pressedSurf)
            assert(ratioPressed >= 7.0, "AC4: gold contrast >= 7:1 on pressed(18%) " .. sk .. "/" .. surfKey .. " @" .. tostring(pair[1]) .. " (got " .. string.format("%.2f", ratioPressed) .. ")")
        end
    end
end
T.SetTheme("gold")
T.SetBrightness(T.DEFAULT_TEXTURE_BRIGHTNESS, T.DEFAULT_GOLD_BRIGHTNESS)

------------------------------------------------------------------------
-- AC5: UI/Widgets.lua (Basalt Toggle vs Priority, SetTextFit, Icon Crop, HelpPill, Fail-Closed Slider)
------------------------------------------------------------------------
local bodyLbl = W.Label(_G.UIParent, "한글 행간 검증 본문", "body")
assertEq(bodyLbl:GetSpacing(), 3, "AC5: body Label must apply SetSpacing(3)")
local titleLbl = W.Label(_G.UIParent, "한글 제목", "title")
assertEq(titleLbl:GetSpacing(), 2, "AC5: title Label must apply SetSpacing(2)")

local pBtn = W.BasaltButton(_G.UIParent, "우선 실행", 140, 28, nil, { variant = "priority" })
local tBtn = W.BasaltButton(_G.UIParent, "토글 항목", 140, 28, nil, { variant = "toggle", checked = true })
assert(pBtn._goldBar ~= nil and pBtn._goldBar:GetWidth() == 3, "AC5: Basalt Priority button has 3px left gold bar")
assert(tBtn._checkBox ~= nil and tBtn._goldBar == nil, "AC5: Basalt Toggle button has distinct checkbox+fill form")

-- Explicit SetTextFit (<= 4 iterations, min font floor, overflow flag)
local fitLbl = W.Label(_G.UIParent, "매우 긴 한국어 안내 문자열이 좁은 영역에 들어갈 때 자동으로 폰트를 축소하고 넘치면 스크롤로 전환합니다", "body")
fitLbl:SetWidth(60)
local fittedSz, iters, overflowed = W.SetTextFit(fitLbl, 60, 14, 10, 4)
assert(iters <= 4 and fittedSz >= 10, "AC5: SetTextFit <= 4 iterations & respects min font floor")
assertEq(overflowed, true, "AC5: SetTextFit flags overflow when min font still exceeds maxW")

-- Icon 0.08..0.92 crop
local ic = W.IconFrame(_G.UIParent, 24)
local l, r, t, b = ic._tex:GetTexCoord()
assert(math.abs(l - 0.08) < 0.001 and math.abs(r - 0.92) < 0.001, "AC5: IconFrame uses 0.08..0.92 trim")

-- HelpPill exact label
local helpBtn = W.HelpPill(_G.UIParent, "도움말 본문", nil)
assertEq(helpBtn._label:GetText(), "처음이라면 · 도움말", "AC5: HelpPill label must be exact")

-- Fail-Closed number slider schema validation
assertEq(ns.Domain.SettingsSchemaModel.ValidateSliderSchema({ min = 0.35, max = 1.0, step = 0.05 }), true, "AC5: valid slider schema passes")
assertEq(ns.Domain.SettingsSchemaModel.ValidateSliderSchema({ min = 1.0, max = 0.5, step = 0.05 }), false, "AC5: min >= max rejected (Fail-Closed)")
assertEq(ns.Domain.SettingsSchemaModel.ValidateSliderSchema({ min = 0.35, max = 1.0, step = 0 }), false, "AC5: step <= 0 rejected (Fail-Closed)")

------------------------------------------------------------------------
-- AC6: CharacterDockPanel & SetupWizard Rich Components (Zero \n Dump!)
------------------------------------------------------------------------
local dock = ns.Features.CharacterDockPanel
dock:Init()
local dockRet = dock:Render("stats")
assert(string.find(dockRet, "주문력:", 1, true) ~= nil, "AC6: CharacterDock retains return string compatibility")
assert(dock.statGrid ~= nil and #dock.statGrid >= 6, "AC6: CharacterDock renders 2-col stat grid widgets")
assert(dock.hitCapBar ~= nil, "AC6: CharacterDock renders Hit Cap gauge bar")
for _, cell in ipairs(dock.statGrid) do
    assert(string.find(cell._val:GetText(), "\n", 1, true) == nil, "AC6: no raw \\n dump in dock stat cells")
end
-- P1 #6: CharacterDockPanel active tab button highlight stays synced across tab switches
dock:Render("upgrades")
assert(dock.upgradeRows ~= nil and #dock.upgradeRows >= 3, "AC6: CharacterDock renders upgrade icon rows")
assertEq(dock.tabButtons.upgrades._isGoldAccent, true, "P1 #6: upgrades tab button highlighted active")
assertEq(dock.tabButtons.stats._isGoldAccent, false, "P1 #6: stats tab button unhighlighted when inactive")
dock:Render("skills")
assertEq(dock.tabButtons.skills._isGoldAccent, true, "P1 #6: skills tab button highlighted active")
assertEq(dock.tabButtons.upgrades._isGoldAccent, false, "P1 #6: upgrades tab button unhighlighted")

local sw = ns.Features.SetupWizard
local swRet = sw:Open(1)
assert(string.find(swRet, "Step 1/3", 1, true) ~= nil, "AC6: SetupWizard retains return string compatibility")
assert(sw.stepperBadges ~= nil and #sw.stepperBadges == 3, "AC6: SetupWizard renders 3-step stepper badges")
assertEq(sw.stepperBadges[1]._label:GetText(), "1/3", "AC6: stepper badge 1/3")
assertEq(sw.prevBtn:IsEnabled(), false, "AC6: prev button disabled on step 1")
local p1 = sw.prevBtn:GetPoint(1)
sw:Open(2)
assertEq(sw.prevBtn:IsEnabled(), true, "AC6: prev button enabled on step 2")
assertEq(sw.prevBtn:GetPoint(1), p1, "AC6: footer button anchor stays fixed across steps")

------------------------------------------------------------------------
-- AC7: StatusPillHud (22px, 3 segments), QuestTracker compact 3+1, CommandHub tab slide, HomePage bridge/alts, ProfileStore v6.1 keys
------------------------------------------------------------------------
local pill = ns.Features.StatusPillHud
pill:Init()
assertEq(pill.card:GetHeight(), 22, "AC7: StatusPillHud height == 22px")
assert(pill.segments ~= nil and #pill.segments == 3, "AC7: StatusPillHud has 3 capsule segments")
-- P0 #2 & P1 #4: True rounded capsule border, NO square ribbon, and all 3 segments visibly shown!
assertEq(pill.card.__fsHairline.isRounded, true, "P0 #2: StatusPillHud uses rounded capsule border (no protruding 90-deg hairline)")
assertEq(pill.card._ribbonL:IsShown(), false, "P0 #2: StatusPillHud has no square SetRibbon covering capsule")
assertEq(pill.segments[1]:IsShown(), true, "P1 #4: StatusPill segment 1 is visibly shown")
assertEq(pill.segments[2]:IsShown(), true, "P1 #4: StatusPill segment 2 is visibly shown")
assertEq(pill.segments[3]:IsShown(), true, "P1 #4: StatusPill segment 3 is visibly shown")
assertEq(pill.label:IsShown(), false, "P1 #4: StatusPill full-string compat label is hidden so it never overlaps segments")

-- P0 #2 & P1 #7: Card and Button both use true rounded borders and true rounded alpha-composited hover/press (zero square overlay!)
local testCard = W.Card(_G.UIParent, 180, 90)
assertEq(testCard.__fsHairline.isRounded, true, "P0 #2: W.Card uses true rounded border (zero sharp corners)")
local testBtn = W.Button(_G.UIParent, "버튼", 100, 26, nil, false)
assert(testBtn._fsRoundedFill ~= nil and testBtn.__fsHairline.isRounded == true, "P1 #7: W.Button uses v6.1 rounded fill & rounded border")
assertEq(testBtn._overlay, nil, "P1 #7: W.Button uses rounded fill tinting instead of a protruding square overlay texture")
local restR = testBtn._fsRoundedFill.color[1]
testBtn:FireScript("OnEnter")
assertEq(testBtn._overlayAlpha, T.OVERLAY.HOVER, "P1 #7: OnEnter applies 6% hover alpha into rounded fill")
assert(testBtn._fsRoundedFill.color[1] > restR, "P1 #7: rounded fill lightens on hover")
testBtn:FireScript("OnMouseDown")
assertEq(testBtn._overlayAlpha, T.OVERLAY.PRESSED, "P1 #7: OnMouseDown applies 18% pressed alpha into rounded fill")
testBtn:FireScript("OnLeave")
assertEq(testBtn._overlayAlpha, 0, "P1 #7: OnLeave restores 0% overlay")

-- P0 #3: Window, PopupCard & Card SurfaceRim + InkUV tint update live on SetTheme & SetBrightness
local hubWinCheck = ns.UI.CommandHub:EnsureWindow()
local testPopup = W.PopupCard(_G.UIParent, 200, 120)
T.SetTheme("dark")
local rimDarkR = hubWinCheck._fsSurfaceRim.__fsHairline.edges[1]._color[1]
local inkDarkR = hubWinCheck._fsInkTex._vertexColor[1]
local popInkDarkR = testPopup._fsInkTex._vertexColor[1]
local cardInkDarkR = testCard._fsInkTex._vertexColor[1]
T.SetTheme("gold")
local rimGoldR = hubWinCheck._fsSurfaceRim.__fsHairline.edges[1]._color[1]
local inkGoldR = hubWinCheck._fsInkTex._vertexColor[1]
local popInkGoldR = testPopup._fsInkTex._vertexColor[1]
local cardInkGoldR = testCard._fsInkTex._vertexColor[1]
assert(rimDarkR ~= rimGoldR, "P0 #3: Window SurfaceRim updates color on SetTheme")
assert(inkDarkR ~= inkGoldR, "P0 #3: Window InkUV tint updates on SetTheme")
assert(popInkDarkR ~= popInkGoldR, "P0 #3: PopupCard InkUV tint updates on SetTheme")
assert(cardInkDarkR ~= cardInkGoldR, "P0 #3: Card InkUV tint updates on SetTheme")

-- QuestTracker compact 3+1 mode
local qtSnap = ns.Domain.QuestTrackerModel.BuildSnapshot({
    { questID = 1, title = "퀘스트 1", zone = "엘윈 숲", level = 10 },
    { questID = 2, title = "퀘스트 2", zone = "엘윈 숲", level = 10 },
    { questID = 3, title = "퀘스트 3", zone = "엘윈 숲", level = 10 },
    { questID = 4, title = "퀘스트 4", zone = "엘윈 숲", level = 10 },
    { questID = 5, title = "퀘스트 5", zone = "엘윈 숲", level = 10 },
}, { compactMode = true })
assertEq(qtSnap.overflowQuestCount, 2, "AC7: QuestTracker 3+1 compact mode reports +2 overflow quests")
local foundOverflowRow = false
for _, r in ipairs(qtSnap.rows) do
    if r.kind == "overflow" and string.find(r.text, "+2", 1, true) then
        foundOverflowRow = true
    end
end
assert(foundOverflowRow, "AC7: QuestTracker compact mode emits +2 overflow summary row")
local emptyCompact = ns.Domain.QuestTrackerModel.BuildSnapshot({}, { compactMode = true })
assertEq(emptyCompact.questCount, 0, "AC7: 0 quests compact mode produces 0 quests")

-- CommandHub 960x640 + sliding active tab indicator
local hub = ns.UI.CommandHub
local hubWin = hub:EnsureWindow()
assertEq(hubWin:GetWidth(), 960, "AC7: CommandHub width 960")
assertEq(hubWin:GetHeight(), 640, "AC7: CommandHub height 640")
assert(hub.rail._activeIndicator ~= nil, "AC7: CommandHub GroupedTabRail exposes sliding gold indicator")

-- HomePage v6 Bridge & Alt Cooldown status card + HelpPill
hub:SelectPage("home")
assert(ns.Features.HomePage.bridgeStatusLbl ~= nil, "AC7: HomePage shows v6 External Bridge status")
assert(ns.Features.HomePage.helpBtn ~= nil, "AC7: HomePage includes contextual HelpPill")

-- ProfileStore v6.1 3 keys roundtrip
assertEq(ns.Api.ProfileStore:Set("ui", "textureBrightness", 0.65), true, "AC7: save textureBrightness")
assertEq(ns.Api.ProfileStore:Set("ui", "goldBrightness", 0.80), true, "AC7: save goldBrightness")
assertEq(ns.Api.ProfileStore:Set("ui", "reducedMotion", true), true, "AC7: save reducedMotion")
assertEq(ns.Api.ProfileStore:Get("ui", "textureBrightness"), 0.65, "AC7: read textureBrightness")
assertEq(ns.Api.ProfileStore:Get("ui", "goldBrightness"), 0.80, "AC7: read goldBrightness")
assertEq(ns.Api.ProfileStore:Get("ui", "reducedMotion"), true, "AC7: read reducedMotion")
ns.Api.ProfileStore:Set("ui", "reducedMotion", false)

------------------------------------------------------------------------
-- AC8: UI/VirtualList.lua (Native ScrollBox + Pool Fallback Parity, 1000 rows <= visible+2, Clean Recycle)
------------------------------------------------------------------------
assert(type(VirtualList) == "table", "AC8: ns.UI.VirtualList must exist")
local vlHost = CreateFrame("Frame", nil, _G.UIParent)
vlHost:SetSize(400, 320)

local createdFrames = 0
local staleClicks = 0
local vl = VirtualList.Create(vlHost, {
    rowHeight = 32,
    visibleCount = 10,
    createRow = function(parent)
        createdFrames = createdFrames + 1
        return W.IconRow(parent, 32, nil)
    end,
    bindRow = function(row, item, idx)
        row._boundId = item.id
        row:SetData({ title = item.title, rightText = tostring(idx) })
        row:SetScript("OnClick", function()
            if item.id == 1 then staleClicks = staleClicks + 1 end
        end)
    end,
    resetRow = function(row)
        row._boundId = nil
        row._payload = nil
        row._onTooltipEnter = nil
        row._onTooltipLeave = nil
    end,
})
local bigData = {}
for i = 1, 1000 do
    bigData[i] = { id = i, title = "항목 " .. tostring(i) }
end
vl:SetData(bigData)
assert(createdFrames <= 12, "AC8: 1,000 rows must allocate <= visible+2 (12) frames, got " .. tostring(createdFrames))
assertEq(vl:GetBackend(), "pool", "AC8: automatically falls back to pool when native ScrollBox APIs absent")

-- Scroll down via row-level OnMouseWheel forwarding & verify recycle clears old handler + updates hovered tooltip
local row1 = vl:GetVisibleRow(1)
row1._mouseOver = true
local ttReboundId = nil
row1._onTooltipEnter = function(r) ttReboundId = r._boundId end
_G.GameTooltip:SetOwner(row1, "ANCHOR_RIGHT")
_G.GameTooltip:Show()
row1:FireScript("OnMouseWheel", -1)
assertEq(vl:GetScrollOffset(), 3, "AC8: pooled row forwards OnMouseWheel to VirtualList")
assertEq(vl:GetVisibleRow(1)._boundId, 4, "AC8: wheel scroll binds item #4 to row 1")
assertEq(_G.GameTooltip:IsShown(), false, "AC8: recycle hides stale GameTooltip owned by recycled row")
row1._mouseOver = false

vl:SetScrollOffset(50)
local firstRecycled = vl:GetVisibleRow(1)
assertEq(firstRecycled._boundId, 51, "AC8: recycled row 1 bound to item 51")
firstRecycled:FireScript("OnClick", "LeftButton")
assertEq(staleClicks, 0, "AC8: old item #1 click callback must not fire after recycle")

-- Native ScrollBox path parity test (non-mutating index wrappers + loud failure on unwrapped)
local nativeInited = false
local nativeElemTemplate = nil
local nativeBoundOrder = {}
local nativeBoundIndices = {}
local nativeInitRef = nil
local vlNative = VirtualList.Create(vlHost, {
    rowHeight = 32,
    visibleCount = 4,
    nativePort = {
        CreateScrollBoxListLinearView = function()
            return {
                SetElementInitializer = function(self, tpl, fn) nativeElemTemplate = tpl; self._initFn = fn; nativeInitRef = fn end,
                SetElementExtent = function(self, h) self._h = h end,
                SetPadding = function() end,
            }
        end,
        CreateDataProvider = function(tbl) return { _items = tbl } end,
        InitScrollBoxListWithScrollBar = function(box, _, view)
            nativeInited = true
            box._view = view
            function box:SetDataProvider(dp)
                for idx, wrapped in ipairs(dp._items) do
                    if idx <= 4 then
                        local r = CreateFrame("Button", nil, box)
                        view._initFn(r, wrapped)
                    end
                end
            end
        end,
    },
    createRow = function(parent) return W.IconRow(parent, 32, nil) end,
    bindRow = function(row, item, idx)
        row._boundId = item.id
        nativeBoundOrder[#nativeBoundOrder + 1] = item.id
        nativeBoundIndices[#nativeBoundIndices + 1] = idx
    end,
})
local rawNativeItems = { { id = 10 }, { id = 20 }, { id = 30 } }
vlNative:SetData(rawNativeItems)
assertEq(vlNative:GetBackend(), "native", "AC8: uses native ScrollBox backend when 1.60.1 ScrollBox APIs available")
assertEq(nativeElemTemplate, "Frame", "P2 #8: native ScrollBox uses Frame outer template (no nested Button inside Button)")
assertEq(nativeInited, true, "AC8: native InitScrollBoxListWithScrollBar invoked")
assertEq(#nativeBoundOrder, 3, "AC8: native path bound all 3 items in order")
assertEq(nativeBoundOrder[1], 10, "AC8: native order parity [1]")
assertEq(nativeBoundOrder[3], 30, "AC8: native order parity [3]")
assertEq(nativeBoundIndices[3], 3, "AC8: native passes exact 1-based index via wrapper")
assertEq(rawNativeItems[1].__fsVlIndex, nil, "AC8: native wrapper must NEVER mutate shared model records")
local okBadWrap = pcall(nativeInitRef, CreateFrame("Button", nil, vlHost), { id = 99 })
assertEq(okBadWrap, false, "AC8: native initializer fails loud on unwrapped elementData instead of fabricating index 1")

-- BiSBrowserPage pool-mode wheel sync, hook idempotency (6 cycles), and bottom-scroll shrink clamp test
local bis = ns.Features.BiSBrowserPage
_G.ForeverSuiteData = _G.ForeverSuiteData or { packs = {} }
local mockBisEntries = {}
for i = 1, 20 do
    mockBisEntries[i] = { itemID = 50000 + i, title = "테스트 BiS " .. tostring(i), slot = "머리", itemLevel = 60 + i, quality = 4, acq = "화산 심장부" }
end
_G.ForeverSuiteData.packs.bis = { title = "BiS", entries = mockBisEntries }
hub:SelectPage("bis")
assert(bis.virtualList ~= nil, "AC8: BiSBrowserPage uses VirtualList")
assert(bis.rows[1]._rec ~= nil and bis.rows[1]._rec.item.itemID == 50020, "AC8: BiSBrowserPage renders highest iLvl item first")
-- Run 6 recycle cycles and verify 1 wheel event STILL moves offset by exact single step (3), never stacking HookScript
for _ = 1, 6 do
    bis.virtualList:SetData(bis.virtualList._data, { offset = 0 })
end
bis.rows[1]:FireScript("OnMouseWheel", -1)
assertEq(bis.scrollOffset, 3, "AC8: after 6 recycles, 1 wheel event moves offset by exact 1 step (3) with zero hook stacking")
assert(bis.rows[1]._rec ~= nil and bis.rows[1]._rec.item.itemID == 50017, "AC8: BiSBrowserPage row 1 cleanly rebinds to offset+1 after wheel")
-- Scroll to bottom (offset 8 for 20 items) then shrink dataset to 4 items -> must clamp to 0 and render non-blank row 1!
bis.virtualList:SetScrollOffset(8)
assertEq(bis.scrollOffset, 8, "AC8: scrolled to bottom offset 8")
_G.ForeverSuiteData.packs.bis = { title = "BiS", entries = { mockBisEntries[1], mockBisEntries[2], mockBisEntries[3], mockBisEntries[4] } }
bis:Render("")
assertEq(bis.scrollOffset, 0, "AC8: shrinking list under bottom-pinned offset clamps scrollOffset to 0")
assert(bis.rows[1]:IsShown() == true and bis.rows[1]._rec ~= nil and bis.rows[1]._rec.item.itemID == 50004, "AC8: shrunken list renders non-blank top row")

-- P0 #1, P1 #5, P2 #8: Live WoW 1.60.1 native WowScrollBoxList full end-to-end simulation:
--   1) BiSBrowserPage creates ZERO duplicate legacy rows/ScrollBar over native ScrollBox
--   2) Native Frame container creates inner IconRow Button, binds item #50020 & #50019, and handles OnClick selection!
--   3) Native SetDataProvider failure surfaces explicit (0, err) instead of silently claiming success!
--   4) CodexPage honestly reports "pool" (never fake "native"!)
local origCreateView = _G.CreateScrollBoxListLinearView
local origCreateDP = _G.CreateDataProvider
local origScrollUtil = _G.ScrollUtil
local nativeCreatedRows = {}
_G.CreateScrollBoxListLinearView = function()
    return {
        SetElementInitializer = function(self, tpl, fn) self._tpl = tpl; self._initFn = fn end,
        SetElementExtent = function() end,
        SetPadding = function() end,
    }
end
_G.CreateDataProvider = function(tbl) return { _items = tbl } end
_G.ScrollUtil = {
    InitScrollBoxListWithScrollBar = function(box, _, view)
        box._view = view
        function box:SetDataProvider(dp)
            self._lastDP = dp
            nativeCreatedRows = {}
            for idx, wrapped in ipairs(dp._items or {}) do
                if idx <= 4 then
                    local outer = CreateFrame(view._tpl or "Frame", nil, box)
                    view._initFn(outer, wrapped)
                    nativeCreatedRows[idx] = outer
                end
            end
        end
    end,
}

-- Rebuild BiSBrowserPage on a fresh host under simulated live 1.60.1 native ScrollBox APIs
local savedBisHost, savedBisRows, savedBisVL, savedBisSB = bis.host, bis.rows, bis.virtualList, bis.scrollBar
bis.rows = {}
bis.virtualList = nil
bis.scrollBar = nil
local nativeBisHost = CreateFrame("Frame", nil, _G.UIParent)
nativeBisHost:SetSize(760, 520)
_G.ForeverSuiteData.packs.bis = { title = "BiS", entries = mockBisEntries }
bis:Build(nativeBisHost)
bis:Render("")
assertEq(bis.virtualList:GetBackend(), "native", "P0 #1: BiSBrowserPage selects native ScrollBox on live 1.60.1")
assertEq(#bis.rows, 0, "P0 #1: BiSBrowserPage creates ZERO duplicate legacy pool rows when native ScrollBox is active")
assert(bis.scrollBar == bis.virtualList._scrollBar, "P0 #1: BiSBrowserPage does not overwrite native MinimalScrollBar with legacy W.ScrollBar")
assertEq(#nativeCreatedRows, 4, "P2 #8: native ScrollBox instantiates rows inside Frame outer containers")
assert(nativeCreatedRows[1]._fsInner ~= nil and nativeCreatedRows[1]._fsInner._rec.item.itemID == 50020, "P2 #8: native row 1 inner IconRow bound to #50020")
assert(nativeCreatedRows[2]._fsInner ~= nil and nativeCreatedRows[2]._fsInner._rec.item.itemID == 50019, "P2 #8: native row 2 inner IconRow bound to #50019")
nativeCreatedRows[2]._fsInner:FireScript("OnClick", "LeftButton")
assert(bis.selectedRec ~= nil and bis.selectedRec.item.itemID == 50019, "P2 #8: clicking inner IconRow Button inside Frame outer updates BiS selection")

-- Verify SetDataProvider failure is surfaced BOTH by VirtualList AND by BiSBrowserPage:Render() (zero silent error!)
bis.virtualList._scrollBox.SetDataProvider = function() error("MOCK_DP_FAILURE") end
local failCnt, failErr = bis.virtualList:SetData({ { id = 1 } })
assertEq(failCnt, 0, "VirtualList surfaces 0 count when native SetDataProvider fails")
assert(type(failErr) == "string" and string.find(failErr, "MOCK_DP_FAILURE", 1, true) ~= nil, "VirtualList returns explicit error string on SetDataProvider failure")
bis:Render("")
assert(bis.emptyState:IsShown() == true, "BiSBrowserPage:Render shows emptyState error when native ScrollBox fails")
assert(string.find(bis.statusLbl:GetText(), "MOCK_DP_FAILURE", 1, true) ~= nil, "BiSBrowserPage:Render surfaces native ScrollBox error in statusLbl")

bis.host, bis.rows, bis.virtualList, bis.scrollBar = savedBisHost, savedBisRows, savedBisVL, savedBisSB

-- CodexPage honesty check under live 1.60.1 native ScrollBox APIs
hub:SelectPage("codex")
assertEq(ns.Features.CodexPage.virtualList:GetBackend(), "pool", "P1 #5: CodexPage honestly reports pool backend even when native ScrollBox exists")

_G.CreateScrollBoxListLinearView = origCreateView
_G.CreateDataProvider = origCreateDP
_G.ScrollUtil = origScrollUtil

print("Test 26 PASS: ForeverSuite v6.1.0 UI Visual Overhaul (AC1..AC8 + 10 Code-Review Fixes) verified!")
