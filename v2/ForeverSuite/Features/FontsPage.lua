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
        local okSet, setRet = pcall(fontObj.SetFont, fontObj, spec.path, spec.size, spec.flags)
        local verified = okSet and (setRet ~= false)
        if verified and type(fontObj.GetFont) == "function" then
            local okV, curPath = pcall(fontObj.GetFont, fontObj)
            if (not okV) or (NormFontPath(curPath) == nil) or (NormFontPath(curPath) ~= NormFontPath(spec.path)) then
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
            self.statusLbl:SetText("폰트 적용 실패 (" .. tostring(failed) .. "건) — 기존 폰트로 전체 복원했습니다.")
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
        presetOpts[#presetOpts + 1] = { value = p.id, label = p.label, width = 122 }
    end
    local curPreset = ns.Api.ProfileStore:Get("ui", "fontPreset") or "default_kr"
    local pBar = W.PillBar(parent, presetOpts, curPreset, function(v)
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
    pBar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -68)

    local outlineLbl = W.Label(parent, "외곽선 스타일", "small", T.TEXT.SECONDARY)
    outlineLbl:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -106)
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
    oBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -126)
    oBar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -126)

    local curDelta = ns.Api.ProfileStore:GetState("fontSizeDelta") or 0
    local slider = W.Slider(parent, "글자 크기 보정 (-2 ~ +4 pt)", -2, 4, 1, curDelta, function(v)
        ns.Api.ProfileStore:SetState("fontSizeDelta", ns.Domain.FontModel.NormalizeSizeDelta(v))
        FontsPage:ApplySavedFonts()
    end)
    slider:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -166)
    slider:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -140, -166)

    local resetBtn = W.Button(parent, "기본값 복원", 112, 26, function()
        ns.Api.ProfileStore:Set("ui", "fontPreset", "default_kr")
        ns.Api.ProfileStore:Set("ui", "fontOutline", "none")
        ns.Api.ProfileStore:SetState("fontSizeDelta", 0)
        FontsPage:ApplySavedFonts()
        ns.Api.SafeAPI.Print("폰트 설정을 기본값으로 복원했습니다.")
    end, true)
    resetBtn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -172)

    local previewCard = W.Card(parent, 580, 96, nil, nil)
    previewCard:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -216)
    previewCard:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -216)
    W.SetBorderColor(previewCard, T.BORDER.GOLD_SOFT)
    local pHdr = W.Label(previewCard, "미리보기 표본 (완성형 · 자모 · 숫자 · 기호)", "small", T.TEXT.GOLD)
    pHdr:SetPoint("TOPLEFT", previewCard, "TOPLEFT", 12, -10)
    local pBody = W.Label(previewCard, ns.Domain.FontModel.SAMPLE_TEXT, "heading", T.TEXT.PRIMARY, { justifyH = "LEFT", wordWrap = true })
    pBody:SetPoint("TOPLEFT", previewCard, "TOPLEFT", 12, -34)
    pBody:SetPoint("BOTTOMRIGHT", previewCard, "BOTTOMRIGHT", -12, 10)
    self.previewLbl = pBody

    local st = W.Label(parent, "", "small", T.TEXT.MUTED)
    st:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 4)
    self.statusLbl = st
    self:ApplySavedFonts()
end

function FontsPage:OnShow()
    self:ApplySavedFonts()
end
