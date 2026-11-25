-- Module: Features/DiagnosticsPage.lua
-- Responsibility: Diagnostics, Taint Canary overview, v1 backup status, and HUD layout reset inside L2 /fs Command Hub.
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens

local DiagnosticsPage = {
    id = "diagnostics",
    label = "진단 · HUD",
    summaryLabel = nil,
}
ns.Features.DiagnosticsPage = DiagnosticsPage

function DiagnosticsPage:Build(parent)
    local hdr = W.SectionHeader(parent, "Zero-Taint 진단 & HUD 레이아웃")
    hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    local card = W.Card(parent, 540, 110)
    card:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -34)

    local lbl = W.Label(card, "", "body", T.TEXT.PRIMARY)
    lbl:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -12)
    self.summaryLabel = lbl

    local resetBtn = W.Button(card, "모든 HUD 기본 위치로 초기화", 200, 26, function()
        ns.UI.HudLayout:ResetAll()
        ns.Api.SafeAPI.Print("모든 HUD 위치를 4px 기본 그리드로 초기화했습니다.")
    end, true)
    resetBtn:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 12, 12)

    self:OnShow()
end

function DiagnosticsPage:OnShow()
    if not self.summaryLabel then
        return
    end
    local db = ns.Api.ProfileStore.db
    local hasV1 = (type(db) == "table" and type(db._v1_backup) == "table") and "보존됨" or "없음"
    local realm = ns.Api.SafeAPI.GetCanonicalRealm()
    local pending = ns.Secure.CombatQueue:PendingCount()
    self.summaryLabel:SetText(
        "렐름 정규화: " .. realm ..
        "  |  v1 백업: " .. hasV1 ..
        "  |  전투 지연 큐: " .. tostring(pending) .. "건"
    )
end
