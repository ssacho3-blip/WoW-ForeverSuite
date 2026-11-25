-- Module: Features/DiagnosticsPage.lua
-- Responsibility: Diagnostics, live Taint Canary breakdown, module active/yielded matrix, GodJohnson exit readiness, and quick actions inside L2 /fs2 Command Hub.
-- Layer: Features (zero raw CreateFrame / C_*; uses UI/Widgets + Api/SafeAPI).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local pairs = pairs
local ipairs = ipairs
local tostring = tostring

local DiagnosticsPage = {
    id = "diagnostics",
    label = "진단 · HUD",
    host = nil,
    summaryLabel = nil,
    readinessLabel = nil,
    moduleRows = {},
}
ns.Features.DiagnosticsPage = DiagnosticsPage

local MODULE_STATUS_DEFS = {
    { label = "상점 자동 수리·판매 (Merchant)", yieldsToV1 = true, toggles = { { "merchant", "autoRepair" }, { "merchant", "autoSellJunk" } } },
    { label = "퀘스트 자동 수락·완료 (QuestAuto)", yieldsToV1 = true, toggles = { { "quest", "autoAccept" }, { "quest", "autoTurnIn" }, { "quest", "autoSuperTrack" } } },
    { label = "편의 자동화 (QoL · 루팅/부활/전장)", yieldsToV1 = true, toggles = { { "qol", "fastLoot" }, { "qol", "autoReleaseBG" }, { "qol", "autoAcceptRes" }, { "qol", "autoAcceptFriends" }, { "qol", "maxCameraZoom" } } },
    { label = "웨이포인트 내비 HUD (/way2)", yieldsToV1 = false, toggles = nil },
    { label = "전투·버프 & 인던 타이머 HUD", yieldsToV1 = false, toggles = { { "combat", "buffReminder" }, { "combat", "lowHealthAlert" }, { "combat", "showEncounterTimer" } } },
    { label = "낚시 카드 & 5종 LoD 도감", yieldsToV1 = false, toggles = { { "profession", "showFishingCard" } } },
}

local function IsModuleEnabledInSettings(def)
    if not def.toggles then
        return true
    end
    for _, pair in ipairs(def.toggles) do
        if ns.Api.ProfileStore:Get(pair[1], pair[2]) == true then
            return true
        end
    end
    return false
end

function DiagnosticsPage:Build(parent)
    self.host = parent
    local hdr = W.SectionHeader(parent, "Zero-Taint 진단 · 모듈 상태 · GodJohnson 전환 준비도")
    hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    local card = W.Card(parent, 550, 118)
    card:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -32)

    local lbl = W.Label(card, "", "body", T.TEXT.PRIMARY)
    lbl:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -10)
    self.summaryLabel = lbl

    local ready = W.Label(card, "", "small", T.TEXT.SECONDARY)
    ready:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -8)
    self.readinessLabel = ready

    local resetBtn = W.Button(card, "HUD 기본 위치 초기화", 164, 24, function()
        ns.UI.HudLayout:ResetAll()
        ns.Api.SafeAPI.Print("모든 HUD 위치를 4px 기본 그리드로 초기화했습니다.")
    end, true)
    resetBtn:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 12, 10)

    local loadBtn = W.Button(card, "도감 LoD 팩 로드", 136, 24, function()
        local ok = ns.Api.SafeAPI.LoadDataPack()
        ns.Api.SafeAPI.Print(ok and "ForeverSuite_Data LoD 팩을 로드했습니다." or "ForeverSuite_Data 로드에 실패했습니다.")
        DiagnosticsPage:OnShow()
        ns.UI.CommandHub:RefreshStatusBar()
    end)
    loadBtn:SetPoint("LEFT", resetBtn, "RIGHT", T.SPACE.SM, 0)

    local xpResetBtn = W.Button(card, "세션 XP 초기화", 124, 24, function()
        if ns.Features.QoLModule then
            ns.Features.QoLModule:ResetSessionXP()
            ns.Api.SafeAPI.Print("세션 XP 통계를 초기화했습니다.")
        end
    end)
    xpResetBtn:SetPoint("LEFT", loadBtn, "RIGHT", T.SPACE.SM, 0)

    local modHdr = W.SectionHeader(parent, "모듈 활성 · v1 공존 양보 매트릭스")
    modHdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -162)
    modHdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -162)

    self.moduleRows = {}
    local y = 192
    for i, def in ipairs(MODULE_STATUS_DEFS) do
        local row = W.ListRow(parent, 24)
        row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -y)
        row._left:SetText(def.label)
        self.moduleRows[i] = { row = row, def = def }
        y = y + 26
    end

    self:OnShow()
end

function DiagnosticsPage:OnShow()
    if not self.summaryLabel then
        return
    end
    local db = ns.Api.ProfileStore.db
    local hasV1Backup = (type(db) == "table" and type(db._v1_backup) == "table") and "보존됨" or "없음"
    local realm = ns.Api.SafeAPI.GetCanonicalRealm()
    local pending = ns.Secure.CombatQueue:PendingCount()
    local taintText
    if ns.Api.ProfileStore.readOnly then
        taintText = "읽기전용"
    elseif db and db.v2 and db.v2.diagnostics and type(db.v2.diagnostics.taintTotal) == "number" then
        taintText = tostring(db.v2.diagnostics.taintTotal) .. "건"
    else
        taintText = "집계 없음"
    end

    self.summaryLabel:SetText(
        "렐름: " .. realm ..
        "  |  Taint: " .. taintText ..
        "  |  v1 백업: " .. hasV1Backup ..
        "  |  전투큐: " .. tostring(pending) .. "건"
    )

    local gjPres = ns.Api.SafeAPI.GetAddOnPresenceState("GodJohnson")
    local bridgePres = ns.Api.SafeAPI.GetAddOnPresenceState("ForeverSuite_GJBridge")
    local gjText
    if gjPres == "LOADED" or bridgePres == "LOADED" then
        gjText = "GodJohnson 공존 중"
    elseif gjPres == "NOT_INSTALLED" and bridgePres == "NOT_INSTALLED" then
        gjText = "GodJohnson 미설치 (완전 독립)"
    elseif (gjPres == "DISABLED" or gjPres == "NOT_INSTALLED") and (bridgePres == "DISABLED" or bridgePres == "NOT_INSTALLED") then
        gjText = "GodJohnson 미로드 (독립 완료)"
    else
        gjText = "확인 불가 (AddOn API 오류)"
    end

    local packCount = 0
    local entryCount = 0
    if type(_G.ForeverSuiteData) == "table" and type(_G.ForeverSuiteData.packs) == "table" then
        for _, p in pairs(_G.ForeverSuiteData.packs) do
            packCount = packCount + 1
            if type(p.entries) == "table" then
                entryCount = entryCount + #p.entries
            end
        end
    end
    local dataText = (packCount > 0)
        and (tostring(packCount) .. "팩 / " .. tostring(entryCount) .. "항목 로드됨")
        or "미로드 (로그인 RAM 0MB)"
    self.readinessLabel:SetText("전환 상태: " .. gjText .. "  |  도감 LoD: " .. dataText)

    local v1State = ns.Api.SafeAPI.GetAddOnLoadedState("ForeverSuite")
    for _, item in ipairs(self.moduleRows) do
        local text, col
        if item.def.yieldsToV1 and v1State ~= false then
            text = (v1State == true) and "v1 양보" or "양보(v1 확인불가)"
            col = T.SEMANTIC.WARN
        elseif not IsModuleEnabledInSettings(item.def) then
            text = "비활성(설정 꺼짐)"
            col = T.TEXT.MUTED
        else
            text = "v2 활성"
            col = T.SEMANTIC.SUCCESS
        end
        item.row._right:SetText(text)
        item.row._right:SetTextColor(col[1], col[2], col[3], 1)
    end
end
