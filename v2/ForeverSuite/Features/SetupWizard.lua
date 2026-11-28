-- Module: Features/SetupWizard.lua
-- Responsibility: Idempotent 3-step /fs setup wizard (Step 1: device/bridge scan, Step 2: non-destructive theme/LSM
--                 alignment with default-OFF external ImportString, Step 3: 4.5s Director live preview) + /fs setup undo.
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local tostring = tostring
local table_concat = table.concat

local SetupWizard = {
    frame = nil,
    bodyLbl = nil,
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

    -- Register curated Korean fonts into LibSharedMedia-3.0 ONLY if ForeverSuite_Media_Assets addon exists on disk
    local lsmCount = 0
    local hasFontAssets = (ns.Api.AddonProbe and type(ns.Api.AddonProbe.Exists) == "function"
        and ns.Api.AddonProbe.Exists("ForeverSuite_Media_Assets")) and true or false
    if hasFontAssets and ns.Bridges and ns.Bridges.Platynator then
        local okReg, cnt = ns.Bridges.Platynator:RegisterSharedFonts({
            { name = "ForeverSuite Gmarket Bold", path = "Interface\\AddOns\\ForeverSuite_Media_Assets\\Fonts\\GmarketSansTTFBold.ttf" },
            { name = "ForeverSuite Gothic A1", path = "Interface\\AddOns\\ForeverSuite_Media_Assets\\Fonts\\GothicA1-Black.ttf" },
        })
        if okReg and type(cnt) == "number" then
            lsmCount = cnt
        end
    end

    -- External ImportString is strictly opt-in (default OFF) so existing user bag/nameplate themes are never clobbered
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

function SetupWizard:Open(stepNum)
    self.step = tonumber(stepNum) or 1
    if not self.frame then
        local win = W.PopupCard(_G.UIParent, 380, 230, "ForeverSuiteSetupWizard", T.ELEVATION.L3_OVERLAY)
        win:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 40)
        local title = W.Label(win, "★ ForeverSuite v6 초기 연출 마법사 (/fs setup)", "heading", T.TEXT.GOLD)
        title:SetPoint("TOPLEFT", win, "TOPLEFT", 14, -12)

        local body = W.Label(win, "", "small", T.TEXT.PRIMARY, { justifyH = "LEFT", wordWrap = true })
        body:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
        body:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -14, 42)

        local bPrev = W.Button(win, "1. 환경감지", 92, 24, function() SetupWizard:Open(1) end)
        bPrev:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 14, 10)
        local bAlign = W.Button(win, "2. 테마정렬", 92, 24, function()
            SetupWizard:ApplyStep2({})
            SetupWizard:Open(2)
        end)
        bAlign:SetPoint("LEFT", bPrev, "RIGHT", 6, 0)
        local bDemo = W.Button(win, "3. 연출시연", 92, 24, function()
            SetupWizard:Open(3)
            if ns.UI and ns.UI.Director then
                ns.UI.Director:RunSetupPreview()
            end
        end)
        bDemo:SetPoint("LEFT", bAlign, "RIGHT", 6, 0)
        local bClose = W.Button(win, "닫기", 52, 24, function() win:Hide() end)
        bClose:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -14, 10)

        self.frame = win
        self.bodyLbl = body
    end

    local devKey = ns.Api.ProfileStore:GetDeviceKey()
    local tier = ns.UI.PixelUtil and ns.UI.PixelUtil.GetDisplayTier() or "FHD"
    local text
    if self.step == 1 then
        local summary = (ns.Bridges and ns.Bridges.BridgeHost) and ns.Bridges.BridgeHost:GetSummary() or {}
        local active = {}
        for i = 1, #summary do
            if summary[i].state ~= "SELF" then
                active[#active + 1] = summary[i].target .. "(" .. summary[i].state .. ")"
            end
        end
        text = table_concat({
            "[Step 1/3] 기기 & 외부 공존 자동 감지",
            "기기 키: " .. tostring(devKey) .. "  |  해상도 티어: " .. tostring(tier),
            "감지된 외부 전문 앱: " .. (#active > 0 and table_concat(active, ", ") or "단독 기동 모드"),
        }, "\n")
    elseif self.step == 2 then
        local r = self.lastStep2Result
        local statusLine
        if type(r) == "table" and r.ok == false then
            statusLine = "· 적용 보류: " .. tostring(r.reason) .. " (전투 종료 후 다시 실행하세요)"
        elseif type(r) == "table" and r.lsmCount > 0 then
            statusLine = "· LibSharedMedia-3.0 한글 폰트 등록 완료 (" .. tostring(r.lsmCount) .. "종)"
        else
            statusLine = "· LSM 폰트 미등록 (ForeverSuite_Media_Assets 또는 LSM 미로드)"
        end
        local snapLine = (type(ns.Api.ProfileStore:GetState("_setupUndoSnapshot")) == "table")
            and "· 원복 스냅샷 저장됨 - 언제든 /fs setup undo 로 1클릭 복원 가능"
            or "· 아직 적용 전 (2. 테마정렬 클릭 시 원복 스냅샷 자동 생성)"
        text = table_concat({
            "[Step 2/3] 비파괴 테마 & LSM 공통 폰트 정렬",
            statusLine,
            "· 외부 Baganator/Platynator 프리셋 덮어쓰기: 기본 OFF (사용자 동의 시에만 적용)",
            snapLine,
        }, "\n")
    else
        text = table_concat({
            "[Step 3/3] Director 5-State 라이브 연출 시연 (4.5초)",
            "EXPLORATION -> FISHING -> COMBAT 상태 전환을 실시간 확인합니다 (전투 시 즉시 중단).",
            "HUD 위치 변경 시 현재 기기 키(" .. tostring(devKey) .. ") 슬롯으로 자동 격리 저장됩니다.",
        }, "\n")
    end
    self.bodyLbl:SetText(text)
    self.frame:Show()
    return text
end

function SetupWizard:HandleCommand(arg)
    if arg == "undo" then
        return self:Undo()
    end
    return self:Open(1)
end
