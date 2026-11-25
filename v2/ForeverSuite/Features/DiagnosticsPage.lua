-- Module: Features/DiagnosticsPage.lua
-- Responsibility: Clean standalone ForeverSuite 2.0.0 diagnostics, live Taint Canary count, LoD pack stats, and module status matrix inside /fs Command Hub.
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
    { label = "상점 자동 수리·판매 (Merchant)", toggles = { { "merchant", "autoRepair" }, { "merchant", "autoSellJunk" } } },
    { label = "퀘스트 추적기 & 자동화 (Quest)", toggles = { { "quest", "autoAccept" }, { "quest", "autoTurnIn" }, { "quest", "autoSuperTrack" } } },
    { label = "편의 자동화 (QoL · 루팅/부활/전장)", toggles = { { "qol", "fastLoot" }, { "qol", "autoReleaseBG" }, { "qol", "autoAcceptRes" }, { "qol", "autoAcceptFriends" }, { "qol", "maxCameraZoom" } } },
    { label = "웨이포인트 내비 & 미니맵 · 툴팁", toggles = { { "ui", "showMinimapButton" }, { "ui", "enhanceTooltips" } } },
    { label = "전투·버프 & 인던 타이머 HUD", toggles = { { "combat", "buffReminder" }, { "combat", "lowHealthAlert" }, { "combat", "showEncounterTimer" } } },
    { label = "낚시 카드 & 5종 LoD 도감", toggles = { { "profession", "showFishingCard" } } },
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
    local hdr = W.SectionHeader(parent, "ForeverSuite 2.0 · Zero-Taint 진단 & HUD 레이아웃")
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

    local modHdr = W.SectionHeader(parent, "핵심 모듈 상태")
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
        "버전: 2.0.0  |  렐름: " .. realm ..
        "  |  Taint: " .. taintText ..
        "  |  전투큐: " .. tostring(pending) .. "건"
    )

    local packCount = 0
    local entryCount = 0
    if type(_G.ForeverSuiteData) == "table" and type(_G.ForeverSuiteData.packs) == "table" then
        for _, p in pairs(_G.ForeverSuiteData.packs) do
            if type(p) == "table" then
                packCount = packCount + 1
                if type(p.entries) == "table" then
                    entryCount = entryCount + #p.entries
                end
            end
        end
    end
    local dataText = (packCount > 0)
        and (tostring(packCount) .. "팩 / " .. tostring(entryCount) .. "항목 로드됨")
        or "미로드 (로그인 RAM 0MB)"
    self.readinessLabel:SetText("독립 실행: Zero-Taint 6-Layer  |  도감 LoD: " .. dataText)

    for _, item in ipairs(self.moduleRows) do
        local active = IsModuleEnabledInSettings(item.def)
        item.row._right:SetText(active and "활성" or "비활성(설정 꺼짐)")
        local col = active and T.SEMANTIC.SUCCESS or T.TEXT.MUTED
        item.row._right:SetTextColor(col[1], col[2], col[3], 1)
    end
end
