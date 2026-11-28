-- Module: Features/FontsPage.lua
-- Responsibility: Unified Korean Font Selector replacing 14 GodJohnsonFontChoice_* folders.
--                 Invariant I3: mutates ONLY ForeverSuite's own FS_Font_* objects OOC, verifies ALL 5 via GetFont,
--                 and rolls back ALL 5 objects cleanly if any single font fails (ZERO writes to Blizzard globals).
-- Layer: Features (uses UI/Widgets only; zero raw CreateFrame).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs
local tostring = tostring
local string_lower = string.lower
local string_gsub = string.gsub

local FontsPage = {
    id = "fonts",
    label = "폰트",
    host = nil,
    previewLbl = nil,
    statusLbl = nil,
    lastAppliedPreset = nil,
}
ns.Features.FontsPage = FontsPage

local function NormFontPath(p)
    if type(p) ~= "string" then return nil end
    return string_lower((string_gsub(p, "/", "\\")))
end

function FontsPage:ApplySavedFonts()
    if ns.Api.SafeAPI.InCombat() then
        return false, "IN_COMBAT"
    end
    local presetId = ns.Api.ProfileStore:Get("ui", "fontPreset") or "default_kr"
    local sizeDelta = ns.Api.ProfileStore:GetState("fontSizeDelta") or 0
    local outlineKey = ns.Api.ProfileStore:Get("ui", "fontOutline") or "none"

    local specs = ns.Domain.FontModel.BuildRoleSpecs(presetId, sizeDelta, outlineKey)
    local backups = {}
    local allPresent = true

    -- Snapshot ALL target font objects before mutating any of them (atomic rollback on partial failure)
    for i, spec in ipairs(specs) do
        local fontObj = _G[spec.obj]
        if type(fontObj) == "table" and type(fontObj.SetFont) == "function" then
            local prevPath, prevSize, prevFlags
            if type(fontObj.GetFont) == "function" then
                local okG, p, s, fl = pcall(fontObj.GetFont, fontObj)
                if okG then prevPath, prevSize, prevFlags = p, s, fl end
            end
            backups[i] = { obj = fontObj, path = prevPath, size = prevSize, flags = prevFlags }
        else
            allPresent = false
        end
    end

    if not allPresent then
        if self.statusLbl then
            self.statusLbl:SetText("ForeverSuite_Media 폰트 객체를 찾을 수 없어 폰트를 변경하지 않았습니다.")
        end
        return false, "NO_FONT_OBJECTS"
    end

    local applied = 0
    local failed = 0
    for i, spec in ipairs(specs) do
        local fontObj = backups[i].obj
        local resolvedPath = (T and T.ResolveMediaPath) and T.ResolveMediaPath(spec.path) or spec.path
        local okSet, setRet = pcall(fontObj.SetFont, fontObj, resolvedPath, spec.size, spec.flags)
        local verified = okSet and (setRet ~= false)
        if verified and type(fontObj.GetFont) == "function" then
            local okV, curPath = pcall(fontObj.GetFont, fontObj)
            if (not okV) or (NormFontPath(curPath) == nil) or (NormFontPath(curPath) ~= NormFontPath(resolvedPath)) then
                verified = false
            end
        end
        if verified then
            applied = applied + 1
        else
            failed = failed + 1
        end
    end

    -- Atomic rollback of ALL 5 font objects if any single one failed (F1)
    if failed > 0 or applied ~= #specs then
        for i = 1, #specs do
            local b = backups[i]
            if b and b.obj and b.path and b.size then
                pcall(b.obj.SetFont, b.obj, b.path, b.size, b.flags or "")
            end
        end
        if self.statusLbl then
            self.statusLbl:SetText("폰트 적용 실패 (" .. tostring(failed) .. "건) - 기존 폰트로 전체 복원했습니다.")
        end
        return false, "ROLLED_BACK"
    end

    self.lastAppliedPreset = presetId
    if self.statusLbl then
        local preset = ns.Domain.FontModel.GetPreset(presetId)
        self.statusLbl:SetText(
            "적용 폰트: " .. preset.label .. " · 크기 보정 " .. tostring(ns.Domain.FontModel.NormalizeSizeDelta(sizeDelta))
            .. " · 외곽선 " .. tostring(outlineKey) .. " (5/5 검증 완료)"
        )
    end
    return true, "APPLIED"
end

function FontsPage:Build(parent)
    self.host = parent
    local hdr = W.SectionHeader(parent, "ForeverSuite 통합 한글 폰트 관리 (Zero-Taint)")
    hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    local desc = W.Label(parent, "기존 14개 폰트 선택 애드온을 단일 설정으로 통합했습니다. Blizzard 전역 폰트를 오염시키지 않고 ForeverSuite UI에만 안전하게 적용합니다.", "small", T.TEXT.SECONDARY, { justifyH = "LEFT", wordWrap = true })
    desc:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -30)
    desc:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -30)

    local presetOpts = {}
    for _, p in ipairs(ns.Domain.FontModel.PRESETS) do
        presetOpts[#presetOpts + 1] = { value = p.id, label = p.label, width = 178 }
    end
    local curPreset = ns.Api.ProfileStore:Get("ui", "fontPreset") or "default_kr"
    local pBar = W.FlowPillGroup(parent, presetOpts, curPreset, 756, function(v)
        local prev = ns.Api.ProfileStore:Get("ui", "fontPreset") or "default_kr"
        if not ns.Api.ProfileStore:Set("ui", "fontPreset", v) then
            return false
        end
        local ok = FontsPage:ApplySavedFonts()
        if not ok then
            ns.Api.ProfileStore:Set("ui", "fontPreset", prev)
            return false
        end
        return true
    end)
    pBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -68)
    self.presetBar = pBar

    local nextY = 68 + (pBar._totalHeight or 52) + 14
    local outlineLbl = W.Label(parent, "외곽선 스타일", "small", T.TEXT.SECONDARY)
    outlineLbl:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -nextY)
    local curOutline = ns.Api.ProfileStore:Get("ui", "fontOutline") or "none"
    local oBar = W.PillBar(parent, {
        { value = "none", label = "그림자만(기본)", width = 108 },
        { value = "outline", label = "얇은 외곽선", width = 96 },
        { value = "thick", label = "굵은 외곽선", width = 96 },
    }, curOutline, function(v)
        if ns.Api.ProfileStore:Set("ui", "fontOutline", v) then
            return FontsPage:ApplySavedFonts()
        end
        return false
    end)
    oBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(nextY + 20))
    oBar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(nextY + 20))
    self.outlineBar = oBar

    local curDelta = ns.Api.ProfileStore:GetState("fontSizeDelta") or 0
    local slider = W.Slider(parent, "글자 크기 보정 (-2 ~ +4 pt)", -2, 4, 1, curDelta, function(v)
        ns.Api.ProfileStore:SetState("fontSizeDelta", ns.Domain.FontModel.NormalizeSizeDelta(v))
        FontsPage:ApplySavedFonts()
    end)
    slider:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(nextY + 60))
    slider:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -140, -(nextY + 60))
    self.sizeSlider = slider

    local resetBtn = W.Button(parent, "기본값 복원", 112, 26, function()
        if ns.Api.SafeAPI.InCombat() then
            ns.Api.SafeAPI.Print("전투 중에는 폰트를 초기화할 수 없습니다.")
            return
        end
        ns.Api.ProfileStore:Set("ui", "fontPreset", "default_kr")
        ns.Api.ProfileStore:Set("ui", "fontOutline", "none")
        ns.Api.ProfileStore:SetState("fontSizeDelta", 0)
        if FontsPage.presetBar and type(FontsPage.presetBar.SetValue) == "function" then
            FontsPage.presetBar:SetValue("default_kr", true)
        end
        if FontsPage.outlineBar and type(FontsPage.outlineBar.SetValue) == "function" then
            FontsPage.outlineBar:SetValue("none")
        end
        if FontsPage.sizeSlider and FontsPage.sizeSlider._slider and type(FontsPage.sizeSlider._slider.SetValue) == "function" then
            FontsPage.sizeSlider._slider:SetValue(0)
        end
        FontsPage:ApplySavedFonts()
        ns.Api.SafeAPI.Print("폰트 설정을 기본값으로 복원했습니다.")
    end, true)
    resetBtn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(nextY + 66))

    local previewCard = W.Card(parent, 580, 74, nil, nil)
    previewCard:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(nextY + 104))
    previewCard:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(nextY + 104))
    W.SetBorderColor(previewCard, T.BORDER.GOLD_SOFT)
    local pHdr = W.Label(previewCard, "미리보기 표본 (완성형 · 자모 · 숫자 · 기호)", "small", T.TEXT.GOLD)
    pHdr:SetPoint("TOPLEFT", previewCard, "TOPLEFT", 12, -8)
    local pBody = W.Label(previewCard, ns.Domain.FontModel.SAMPLE_TEXT, "heading", T.TEXT.PRIMARY, { justifyH = "LEFT", wordWrap = true })
    pBody:SetPoint("TOPLEFT", previewCard, "TOPLEFT", 12, -28)
    pBody:SetPoint("BOTTOMRIGHT", previewCard, "BOTTOMRIGHT", -12, 8)
    self.previewLbl = pBody

    -- K2: Opt-in Global World / Combat Damage / Chat Font Override Switcher (ForeverSuite_Fonts_Global - all 18 fonts, independent World vs Damage selectors)
    local gCard = W.Card(parent, 580, 212, nil, nil)
    gCard:SetPoint("TOPLEFT", previewCard, "BOTTOMLEFT", 0, -8)
    gCard:SetPoint("TOPRIGHT", previewCard, "BOTTOMRIGHT", 0, -8)
    W.SetBorderColor(gCard, T.BORDER.GOLD)
    local gHdr = W.Label(gCard, "★ 게임 전역 · 전투 데미지 · 채팅 한글 폰트 (18종 · 월드/데미지 독립 선택)", "small", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    gHdr:SetPoint("TOPLEFT", gCard, "TOPLEFT", 12, -8)

    local gApi = _G.ForeverSuiteGlobalFonts
    local gCfg = (type(gApi) == "table" and type(gApi.GetConfig) == "function") and gApi.GetConfig() or { enabled = false, worldFont = "default_blizz", damageFont = "default_blizz", damageScale = 1.0, chatFontSize = 14 }
    local gToggle = W.Toggle(gCard, "전역 월드·데미지·채팅 폰트 적용 활성화 (변경 후 /reload 권장)", gCfg.enabled == true, function(v)
        if type(_G.ForeverSuiteGlobalFonts) == "table" and type(_G.ForeverSuiteGlobalFonts.Configure) == "function" then
            _G.ForeverSuiteGlobalFonts.Configure({ enabled = v })
            ns.Api.SafeAPI.Print(v and "전역 폰트 적용 ON (/reload 시 월드·데미지 텍스트 전체 반영)" or "전역 폰트 적용 OFF (다음 접속/리로드부터 블리자드 기본 폰트)")
            return true
        end
        ns.Api.SafeAPI.Print("ForeverSuite_Fonts_Global 애드온이 활성화되어 있지 않습니다.")
        return false
    end)
    gToggle:SetPoint("TOPLEFT", gCard, "TOPLEFT", 12, -24)
    gToggle:SetWidth(460)

    local gFontOpts = {}
    if type(gApi) == "table" and type(gApi.FONT_LABELS) == "table" and #gApi.FONT_LABELS > 0 then
        for _, fl in ipairs(gApi.FONT_LABELS) do
            gFontOpts[#gFontOpts + 1] = { value = fl.id, label = fl.label, width = 108 }
        end
    else
        gFontOpts = {
            { value = "default_blizz", label = "기본(2002)", width = 76 },
            { value = "gmarket",       label = "지마켓산스", width = 78 },
            { value = "gyeonggi",      label = "경기천년",  width = 68 },
            { value = "gothic_a1",     label = "고딕A1",    width = 62 },
            { value = "dnf_blade",     label = "던파블레이드", width = 88 },
            { value = "dnf_bitbit",    label = "던파비트비트", width = 88 },
            { value = "galmuri11",     label = "갈무리11",  width = 68 },
            { value = "kcc_ganpan",    label = "KCC간판",   width = 68 },
            { value = "levelup",       label = "레벨업",    width = 58 },
        }
    end
    local gMode = "world"
    local gModeBar = W.PillBar(gCard, {
        { value = "world",  label = "월드·UI 폰트", width = 106 },
        { value = "damage", label = "전투 데미지 폰트", width = 122 },
    }, "world", function(v)
        gMode = v
        local cfgNow = (type(_G.ForeverSuiteGlobalFonts) == "table" and type(_G.ForeverSuiteGlobalFonts.GetConfig) == "function")
            and _G.ForeverSuiteGlobalFonts.GetConfig() or gCfg
        if FontsPage.globalFontBar and type(FontsPage.globalFontBar.SetValue) == "function" then
            FontsPage.globalFontBar:SetValue((gMode == "damage") and cfgNow.damageFont or cfgNow.worldFont, true)
        end
    end)
    gModeBar:SetPoint("TOPRIGHT", gCard, "TOPRIGHT", -12, -24)
    gModeBar:SetWidth(236)

    local gBar = W.FlowPillGroup(gCard, gFontOpts, gCfg.worldFont or "default_blizz", 732, function(v)
        if type(_G.ForeverSuiteGlobalFonts) == "table" and type(_G.ForeverSuiteGlobalFonts.Configure) == "function" then
            if gMode == "damage" then
                _G.ForeverSuiteGlobalFonts.Configure({ damageFont = v })
                ns.Api.SafeAPI.Print("전투 데미지 폰트 선택: " .. tostring(v) .. " (/reload 시 전체 적용)")
            else
                _G.ForeverSuiteGlobalFonts.Configure({ worldFont = v })
                ns.Api.SafeAPI.Print("월드·UI 전역 폰트 선택: " .. tostring(v) .. " (/reload 시 전체 적용)")
            end
            return true
        end
        return false
    end)
    gBar:SetPoint("TOPLEFT", gCard, "TOPLEFT", 12, -50)
    self.globalFontBar = gBar

    local chatSlider = W.Slider(gCard, "채팅창 글자 크기 (10 ~ 22 pt)", 10, 22, 1, (gCfg.chatFontSize and gCfg.chatFontSize >= 10) and gCfg.chatFontSize or 14, function(v)
        ns.Api.ProfileStore:SetState("chatFontSize", v)
        if ns.Features.ChatToolsModule then ns.Features.ChatToolsModule:ApplyChatFontSize(v) end
        if type(_G.ForeverSuiteGlobalFonts) == "table" and type(_G.ForeverSuiteGlobalFonts.Configure) == "function" then
            _G.ForeverSuiteGlobalFonts.Configure({ chatFontSize = v })
        end
    end)
    chatSlider:SetPoint("BOTTOMLEFT", gCard, "BOTTOMLEFT", 12, 8)
    chatSlider:SetWidth(330)

    local dmgSlider = W.Slider(gCard, "전투 데미지 숫자 배율 (70% ~ 200%)", 70, 200, 10, math.floor((gCfg.damageScale or 1.0) * 100 + 0.5), function(v)
        local scale = v / 100.0
        ns.Api.GameAdapters.SetCVarSafe("WorldTextScale", tostring(scale))
        if type(_G.ForeverSuiteGlobalFonts) == "table" and type(_G.ForeverSuiteGlobalFonts.Configure) == "function" then
            _G.ForeverSuiteGlobalFonts.Configure({ damageScale = scale })
        end
    end)
    dmgSlider:SetPoint("BOTTOMRIGHT", gCard, "BOTTOMRIGHT", -12, 8)
    dmgSlider:SetWidth(330)

    local st = W.Label(parent, "", "small", T.TEXT.MUTED)
    st:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 4)
    self.statusLbl = st
    self:ApplySavedFonts()
end

function FontsPage:OnShow()
    local curPreset = ns.Api.ProfileStore:Get("ui", "fontPreset") or "default_kr"
    local curOutline = ns.Api.ProfileStore:Get("ui", "fontOutline") or "none"
    local curDelta = ns.Api.ProfileStore:GetState("fontSizeDelta") or 0
    if self.presetBar and type(self.presetBar.SetValue) == "function" then
        self.presetBar:SetValue(curPreset, true)
    end
    if self.outlineBar and type(self.outlineBar.SetValue) == "function" then
        self.outlineBar:SetValue(curOutline)
    end
    if self.sizeSlider and self.sizeSlider._slider and type(self.sizeSlider._slider.SetValue) == "function" then
        self.sizeSlider._slider:SetValue(curDelta)
    end
    self:ApplySavedFonts()
end
