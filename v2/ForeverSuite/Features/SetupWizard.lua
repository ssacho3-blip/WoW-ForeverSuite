-- Module: Features/SetupWizard.lua
-- Responsibility: ForeverSuite v6.1.0 Idempotent 3-Step /fs setup wizard with rich Stepper Header (1/3 · 2/3 · 3/3),
--                 structured visual info cards (zero raw \n dump), and fixed footer [이전]/[실행]/[다음]/[닫기].
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local Motion = ns.UI.Motion
local tostring = tostring
local table_concat = table.concat

local SetupWizard = {
    frame = nil,
    stepperBadges = nil,
    stepTitleLbl = nil,
    infoCards = nil,
    prevBtn = nil,
    actionBtn = nil,
    nextBtn = nil,
    closeBtn = nil,
    step = 1,
    optImportExternal = false,
    lastStep2Result = nil,
}
ns.Features.SetupWizard = SetupWizard

local function SnapshotForUndo()
    local cur = ns.Api.ProfileStore:GetState("_setupUndoSnapshot")
    if type(cur) == "table" then
        return cur
    end
    local snap = {
        uiTheme = ns.Api.ProfileStore:Get("ui", "uiTheme") or "gold",
        fontPreset = ns.Api.ProfileStore:Get("ui", "fontPreset") or "default_blizz",
        deviceKey = ns.Api.ProfileStore:GetDeviceKey(),
    }
    ns.Api.ProfileStore:SetState("_setupUndoSnapshot", snap)
    return snap
end

function SetupWizard:ApplyStep2(opts)
    if ns.Api.SafeAPI.InCombat() then
        self.lastStep2Result = { ok = false, lsmCount = 0, reason = "IN_COMBAT" }
        return false, "IN_COMBAT"
    end
    opts = type(opts) == "table" and opts or {}
    SnapshotForUndo()

    local lsmCount = 0
    local hasFontAssets = (ns.Api.AddonProbe and type(ns.Api.AddonProbe.Exists) == "function"
        and (ns.Api.AddonProbe.Exists("ForeverSuite_Media_Assets") or ns.Api.AddonProbe.Exists("ForeverSuite_Media"))) and true or false
    if hasFontAssets and ns.Bridges and ns.Bridges.Platynator then
        local fontBase = T.ResolveMediaPath("Interface\\AddOns\\ForeverSuite_Media_Assets\\Fonts\\")
        local okReg, cnt = ns.Bridges.Platynator:RegisterSharedFonts({
            { name = "ForeverSuite Gmarket Bold", path = fontBase .. "GmarketSansTTFBold.ttf" },
            { name = "ForeverSuite Gothic A1", path = fontBase .. "GothicA1-Black.ttf" },
        })
        if okReg and type(cnt) == "number" then
            lsmCount = cnt
        end
    end

    local allowExt = (opts.importExternal == true) or (self.optImportExternal == true)
    if allowExt and type(opts.baganatorPreset) == "string" and ns.Bridges and ns.Bridges.Baganator then
        ns.Bridges.Baganator:ImportPreset(opts.baganatorPreset)
    end
    if allowExt and type(opts.platynatorPreset) == "string" and ns.Bridges and ns.Bridges.Platynator then
        ns.Bridges.Platynator:ImportPreset(opts.platynatorPreset)
    end

    if type(opts.uiTheme) == "string" then
        ns.Api.ProfileStore:Set("ui", "uiTheme", opts.uiTheme)
    end
    self.lastStep2Result = { ok = true, lsmCount = lsmCount, reason = "APPLIED", hasFontAssets = hasFontAssets }
    return true, "APPLIED"
end

function SetupWizard:Undo()
    if ns.Api.SafeAPI.InCombat() then
        return false, "IN_COMBAT"
    end
    local snap = ns.Api.ProfileStore:GetState("_setupUndoSnapshot")
    if type(snap) ~= "table" then
        ns.Api.SafeAPI.Print("복원할 /fs setup 스냅샷이 없습니다.")
        return false, "NO_SNAPSHOT"
    end
    local ok1 = ns.Api.ProfileStore:Set("ui", "uiTheme", snap.uiTheme)
    local ok2 = ns.Api.ProfileStore:Set("ui", "fontPreset", snap.fontPreset)
    if ok1 == false or ok2 == false then
        ns.Api.SafeAPI.Print("/fs setup 복원 실패 (프로필 쓰기 제한 상태).")
        return false, "WRITE_FAILED"
    end
    ns.Api.ProfileStore:SetState("_setupUndoSnapshot", nil)
    ns.Api.SafeAPI.Print("/fs setup 변경 사항을 이전 상태로 1클릭 복원했습니다.")
    return true, "UNDONE"
end

local function EnsureWizardUI()
    if SetupWizard.frame then return SetupWizard.frame end

    local win = W.PopupCard(_G.UIParent, 440, 296, "ForeverSuiteSetupWizard", T.ELEVATION.L3_OVERLAY)
    win:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 40)

    local ver = (ns.Api and ns.Api.SafeAPI and type(ns.Api.SafeAPI.GetAddonVersion) == "function" and ns.Api.SafeAPI.GetAddonVersion()) or "6.4.0"
    local title = W.Label(win, "★ ForeverSuite v" .. tostring(ver) .. " 초기 연출 마법사", "heading", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    title:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -14)

    -- 3-Step Stepper Badges (1/3 · 2/3 · 3/3)
    local badges = {}
    local stepTags = { "1/3", "2/3", "3/3" }
    for i = 1, 3 do
        local b = W.Badge(win, stepTags[i], "INFO")
        b:SetSize(44, 20)
        b:SetPoint("TOPRIGHT", win, "TOPRIGHT", -(16 + (3 - i) * 50), -12)
        badges[i] = b
    end
    SetupWizard.stepperBadges = badges

    local stepTitle = W.Label(win, "", "body", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    stepTitle:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -44)
    stepTitle:SetPoint("TOPRIGHT", win, "TOPRIGHT", -16, -44)
    SetupWizard.stepTitleLbl = stepTitle

    -- 3 Structured Info Cards (zero raw \n text dump!)
    local infoCards = {}
    for i = 1, 3 do
        local c = W.Card(win, 408, 52)
        c:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -(72 + (i - 1) * 58))
        local cap = W.Label(c, "", "small", T.TEXT.MUTED, { justifyH = "LEFT", wordWrap = false })
        cap:SetPoint("TOPLEFT", c, "TOPLEFT", 10, -8)
        cap:SetPoint("TOPRIGHT", c, "TOPRIGHT", -10, -8)
        local val = W.Label(c, "", "body", T.TEXT.PRIMARY, { justifyH = "LEFT", wordWrap = false })
        val:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 10, 8)
        val:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -10, 8)
        c._cap = cap
        c._val = val
        infoCards[i] = c
    end
    SetupWizard.infoCards = infoCards

    -- Fixed Footer Bar (anchors NEVER change across steps)
    local bPrev = W.Button(win, "이전", 72, 26, function()
        if SetupWizard.step > 1 then
            SetupWizard:Open(SetupWizard.step - 1)
        end
    end)
    bPrev:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 16, 14)

    local bAction = W.BasaltButton(win, "테마 정렬 적용", 148, 26, function()
        if SetupWizard.step == 2 then
            SetupWizard:ApplyStep2({})
            SetupWizard:Open(2)
        elseif SetupWizard.step == 3 then
            if ns.UI and ns.UI.Director then
                ns.UI.Director:RunSetupPreview()
            end
        else
            SetupWizard:Open(2)
        end
    end, { variant = "priority" })
    bAction:SetPoint("LEFT", bPrev, "RIGHT", 8, 0)

    local bNext = W.Button(win, "다음", 72, 26, function()
        if SetupWizard.step < 3 then
            SetupWizard:Open(SetupWizard.step + 1)
        else
            if Motion and type(Motion.InstantHide) == "function" then
                Motion.InstantHide(win)
            else
                win:Hide()
            end
        end
    end, true)
    bNext:SetPoint("LEFT", bAction, "RIGHT", 8, 0)

    local bClose = W.Button(win, "닫기", 64, 26, function()
        if Motion and type(Motion.InstantHide) == "function" then
            Motion.InstantHide(win)
        else
            win:Hide()
        end
    end)
    bClose:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -16, 14)

    SetupWizard.prevBtn = bPrev
    SetupWizard.actionBtn = bAction
    SetupWizard.nextBtn = bNext
    SetupWizard.closeBtn = bClose
    SetupWizard.frame = win
    return win
end

function SetupWizard:Open(stepNum)
    local s = tonumber(stepNum) or 1
    if s < 1 then s = 1 end
    if s > 3 then s = 3 end
    self.step = s
    EnsureWizardUI()

    for i = 1, 3 do
        local b = self.stepperBadges[i]
        local isAct = (i == self.step)
        W.SetBorderColor(b, isAct and T.BORDER.GOLD or T.BORDER.SUBTLE)
        if b._label then
            local tc = isAct and T.TEXT.GOLD or T.TEXT.MUTED
            b._label:SetTextColor(tc[1], tc[2], tc[3], 1)
        end
    end

    if type(self.prevBtn.SetEnabled) == "function" then
        self.prevBtn:SetEnabled(self.step > 1)
    end
    self.prevBtn:SetAlpha((self.step > 1) and 1.0 or 0.45)

    local devKey = ns.Api.ProfileStore:GetDeviceKey()
    local tier = ns.UI.PixelUtil and ns.UI.PixelUtil.GetDisplayTier() or "FHD"
    local summaryText

    if self.step == 1 then
        local summary = (ns.Bridges and ns.Bridges.BridgeHost) and ns.Bridges.BridgeHost:GetSummary() or {}
        local active = {}
        for i = 1, #summary do
            if summary[i].state ~= "SELF" then
                active[#active + 1] = summary[i].target .. "(" .. summary[i].state .. ")"
            end
        end
        local extStr = (#active > 0) and table_concat(active, ", ") or "단독 기동 모드"
        self.stepTitleLbl:SetText("[Step 1/3] 기기 해상도 및 외부 공존 자동 감지")
        self.infoCards[1]._cap:SetText("감지된 기기 격리 키 (3-Tier SavedVariables)")
        self.infoCards[1]._val:SetText(tostring(devKey))
        self.infoCards[2]._cap:SetText("디스플레이 해상도 티어")
        self.infoCards[2]._val:SetText(tostring(tier) .. " · 4px 격자 & 물리 1px 스냅 활성")
        self.infoCards[3]._cap:SetText("감지된 외부 전문 앱 브리지")
        self.infoCards[3]._val:SetText(extStr)
        self.actionBtn._label:SetText("2단계로 이동")
        self.nextBtn._label:SetText("다음")
        summaryText = "[Step 1/3] 기기: " .. tostring(devKey) .. " | 티어: " .. tostring(tier) .. " | 외부 앱: " .. extStr
    elseif self.step == 2 then
        local r = self.lastStep2Result
        local statusLine
        if type(r) == "table" and r.ok == false then
            statusLine = "적용 보류 (" .. tostring(r.reason) .. " · 전투 종료 후 실행)"
        elseif type(r) == "table" and r.lsmCount > 0 then
            statusLine = "LibSharedMedia-3.0 한글 폰트 " .. tostring(r.lsmCount) .. "종 등록 완료"
        else
            statusLine = "대기 중 (ForeverSuite_Media_Assets 또는 LSM 확인)"
        end
        local snapLine = (type(ns.Api.ProfileStore:GetState("_setupUndoSnapshot")) == "table")
            and "원복 스냅샷 저장됨 (/fs setup undo 로 1클릭 복원)"
            or "적용 클릭 시 원복 스냅샷을 자동 생성합니다"
        self.stepTitleLbl:SetText("[Step 2/3] 비파괴 테마 & LSM 공통 폰트 정렬")
        self.infoCards[1]._cap:SetText("한글 공통 폰트 등록 상태")
        self.infoCards[1]._val:SetText(statusLine)
        self.infoCards[2]._cap:SetText("외부 애드온 프리셋 보호 정책")
        self.infoCards[2]._val:SetText("Baganator/Platynator 덮어쓰기 기본 OFF (비파괴)")
        self.infoCards[3]._cap:SetText("1클릭 롤백 스냅샷")
        self.infoCards[3]._val:SetText(snapLine)
        self.actionBtn._label:SetText("테마·폰트 정렬 적용")
        self.nextBtn._label:SetText("다음")
        summaryText = "[Step 2/3] " .. statusLine .. " | " .. snapLine
    else
        self.stepTitleLbl:SetText("[Step 3/3] Director 5-State 라이브 연출 시연 (4.5초)")
        self.infoCards[1]._cap:SetText("실시간 5-State 시연 시퀀스")
        self.infoCards[1]._val:SetText("EXPLORATION -> FISHING -> COMBAT (전투 시 즉시 중단)")
        self.infoCards[2]._cap:SetText("기기별 레이아웃 자동 격리")
        self.infoCards[2]._val:SetText("현재 기기 키(" .. tostring(devKey) .. ") 슬롯에 저장")
        self.infoCards[3]._cap:SetText("모션 & 접근성 설정")
        self.infoCards[3]._val:SetText("전투 중 0ms 스냅 · 설정에서 모션 줄이기 토글 지원")
        self.actionBtn._label:SetText("4.5초 연출 시연")
        self.nextBtn._label:SetText("완료")
        summaryText = "[Step 3/3] Director 5-State 라이브 연출 시연 (" .. tostring(devKey) .. ")"
    end

    if Motion and type(Motion.FadeIn) == "function" then
        Motion.FadeIn(self.frame, 0.15)
    else
        self.frame:Show()
    end
    return summaryText
end

function SetupWizard:ExportPortableProfile()
    local settings = ns.Api.ProfileStore and ns.Api.ProfileStore.db and ns.Api.ProfileStore.db.v2
        and ns.Api.ProfileStore.db.v2.settings or {}
    if ns.Domain and ns.Domain.PowerQoLModel and type(ns.Domain.PowerQoLModel.SerializeProfile) == "function" then
        local body = ns.Domain.PowerQoLModel.SerializeProfile(settings)
        if type(body) == "string" and body ~= "" then
            -- Portable format omits device-specific identifiers for safe cross-machine sharing
            return "FS6|" .. body, "PORTABLE_FS6"
        end
    end
    return nil, "UNAVAILABLE"
end

function SetupWizard:HandleCommand(arg)
    if arg == "undo" then
        return self:Undo()
    elseif arg == "export" then
        local str, mode = self:ExportPortableProfile()
        if str then
            ns.Api.SafeAPI.Print("3기기 프로필 내보내기 완료 (" .. tostring(mode) .. ", " .. tostring(#str) .. "B): " .. string.sub(str, 1, 64) .. "...")
            return true, str
        end
        return false, mode
    end
    return self:Open(1)
end
