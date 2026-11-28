-- Module: Features/CharacterDockPanel.lua
-- Responsibility: Zero-Taint UIParent-owned right-docking panel beside CharacterFrame (C) with 3 tabs:
--                 [확장 스탯] (SP/Heal/RAP/MP5/Hit+Lv60 Cap/Speed), [업글 Top 3], [다음 5레벨 스킬 & 부족 골드].
--                 0.00ms idle when CharacterFrame is closed (active-only 0.15s position ticker while shown).
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local tostring = tostring
local string_format = string.format
local table_concat = table.concat

local PANEL_WIDTH = 248
local PANEL_HEIGHT = 286

local CharacterDockPanel = {
    frame = nil,
    bodyLbl = nil,
    activeTab = "stats",
    ticker = nil,
    initialized = false,
}
ns.Features.CharacterDockPanel = CharacterDockPanel

local function FmtNum(v, suffix)
    if type(v) ~= "number" then
        return "—"
    end
    return tostring(v) .. (suffix or "")
end

local function StopTicker()
    if CharacterDockPanel.ticker then
        ns.Api.GameAdapters.CancelTicker(CharacterDockPanel.ticker)
        CharacterDockPanel.ticker = nil
    end
end

local function SyncPosition()
    if not CharacterDockPanel.frame then return end
    if not ns.Blizzard.CharacterDockAdapter.IsShown() then
        StopTicker()
        CharacterDockPanel.frame:Hide()
        return
    end
    local pt, x, y = ns.Blizzard.CharacterDockAdapter.ComputeDockPosition(PANEL_WIDTH)
    CharacterDockPanel.frame:ClearAllPoints()
    if pt == "BOTTOMLEFT" then
        CharacterDockPanel.frame:SetPoint("TOPLEFT", _G.UIParent, "BOTTOMLEFT", x, y)
    else
        CharacterDockPanel.frame:SetPoint(pt, _G.UIParent, pt, x, y)
    end
end

local function BuildTabText(tabId)
    if tabId == "stats" then
        local st = ns.Api.GameAdapters.GetExtendedCharacterStats and ns.Api.GameAdapters.GetExtendedCharacterStats() or {}
        local physCapRem = (type(st.meleeHitPct) == "number") and string_format(" (캡 잔여 %.1f%%)", math.max(0, 9.0 - st.meleeHitPct)) or ""
        local spellCapRem = (type(st.spellHitPct) == "number") and string_format(" (캡 잔여 %.1f%%)", math.max(0, 16.0 - st.spellHitPct)) or ""
        return table_concat({
            "주문력: " .. FmtNum(st.spellPower) .. "   |   치유량: " .. FmtNum(st.healingPower),
            "근접/원거리 전투력: " .. FmtNum(st.meleeAP) .. " / " .. FmtNum(st.rangedAP),
            "MP5 (비시전/시전): " .. FmtNum(st.mp5Base) .. " / " .. FmtNum(st.mp5Cast),
            "물리 적중: " .. FmtNum(st.meleeHitPct, "%") .. physCapRem,
            "주문 적중: " .. FmtNum(st.spellHitPct, "%") .. spellCapRem,
            "이동 속도: " .. FmtNum(st.speedPct, "%"),
        }, "\n")
    elseif tabId == "upgrades" then
        local okPack, stPack = ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_BiS")
        local packs = _G.ForeverSuiteData and _G.ForeverSuiteData.packs
        local bisRows = packs and packs.bis and packs.bis.entries or {}
        if (not okPack) and #bisRows == 0 then
            return "BiS 데이터팩 미로드 (" .. tostring(stPack) .. ")"
        end
        local lvl = ns.Api.GameAdapters.GetPlayerLevel() or 60
        local eq = ns.Api.GameAdapters.GetEquippedItemLevelMap and ns.Api.GameAdapters.GetEquippedItemLevelMap() or {}
        local top3 = ns.Domain.CharacterGuideModel.RankTopUpgrades(bisRows, lvl, eq, 3)
        if #top3 == 0 then
            return "현재 레벨(+3) 기준 추천 업그레이드 데이터 없음"
        end
        local lines = {}
        for i = 1, #top3 do
            local u = top3[i]
            lines[#lines + 1] = string_format("%d. %s (+%d iLvl) — %s", i, u.title, u.delta, u.acq)
        end
        return table_concat(lines, "\n")
    end

    -- tabId == "skills"
    local okAtlas, stAtlas = ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_Atlas")
    local packs = _G.ForeverSuiteData and _G.ForeverSuiteData.packs
    local rows = packs and packs.training_spells and packs.training_spells.entries or {}
    if (not okAtlas) and #rows == 0 then
        return "직업 스킬 데이터팩 미로드 (" .. tostring(stAtlas) .. ")"
    end
    local cls = ns.Api.GameAdapters.GetPlayerClass() or ""
    local lvl = ns.Api.GameAdapters.GetPlayerLevel() or 1
    local candidateIDs = {}
    for i = 1, #rows do
        local sp = rows[i]
        if type(sp) == "table" and sp.class == cls and type(sp.level) == "number" and sp.level <= (lvl + 5) and type(sp.spellID) == "number" then
            candidateIDs[#candidateIDs + 1] = sp.spellID
        end
    end
    local known = ns.Api.GameAdapters.GetKnownSpellSet and ns.Api.GameAdapters.GetKnownSpellSet(candidateIDs) or {}
    local money = ns.Api.SafeAPI.GetPlayerMoney()
    local split = ns.Domain.CharacterGuideModel.SplitUpcomingSpells(rows, cls, lvl, known, type(money) == "number" and money or 0)
    local deficitStr = (type(money) == "number")
        and ns.Domain.LedgerModel.FormatCopper(split.deficit)
        or "확인 불가 (소지 골드 조회 실패)"
    return table_concat({
        "현재 습득 가능 스킬: " .. tostring(#split.learnableNow) .. "개",
        "다음 5레벨 예정 스킬: " .. tostring(#split.upcoming5) .. "개",
        "예상 총 습득 비용: " .. ns.Domain.LedgerModel.FormatCopper(split.totalCost),
        "부족 골드: " .. deficitStr,
    }, "\n")
end

function CharacterDockPanel:Render(tabId)
    if type(tabId) == "string" and tabId ~= "" then
        self.activeTab = tabId
    end
    if not self.frame then
        local card = W.PopupCard(_G.UIParent, PANEL_WIDTH, PANEL_HEIGHT, "ForeverSuiteCharacterDock", T.ELEVATION.L2_WORKSPACE)
        local title = W.Label(card, "✦ 캐릭터 확장 브리핑", "heading", T.TEXT.GOLD, { justifyH = "LEFT" })
        title:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -10)

        local b1 = W.Button(card, "스탯", 66, 22, function() CharacterDockPanel:Render("stats") end)
        b1:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
        local b2 = W.Button(card, "업글 Top3", 76, 22, function() CharacterDockPanel:Render("upgrades") end)
        b2:SetPoint("LEFT", b1, "RIGHT", 6, 0)
        local b3 = W.Button(card, "5레벨 스킬", 76, 22, function() CharacterDockPanel:Render("skills") end)
        b3:SetPoint("LEFT", b2, "RIGHT", 6, 0)

        local body = W.Label(card, "", "small", T.TEXT.PRIMARY, { justifyH = "LEFT", wordWrap = true })
        body:SetPoint("TOPLEFT", b1, "BOTTOMLEFT", 0, -10)
        body:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -12, 10)

        self.frame = card
        self.bodyLbl = body
        card:Hide()
    end
    local text = BuildTabText(self.activeTab)
    self.bodyLbl:SetText(text)
    return text
end

function CharacterDockPanel:OnCharacterShow()
    self:Render(self.activeTab)
    SyncPosition()
    self.frame:Show()
    if not self.ticker then
        self.ticker = ns.Api.GameAdapters.StartTicker(0.15, SyncPosition)
    end
end

function CharacterDockPanel:OnCharacterHide()
    StopTicker()
    if self.frame then
        self.frame:Hide()
    end
end

function CharacterDockPanel:Init()
    if self.initialized then
        return true
    end
    local hooked = ns.Blizzard.CharacterDockAdapter:Init(function()
        CharacterDockPanel:OnCharacterShow()
    end, function()
        CharacterDockPanel:OnCharacterHide()
    end)
    self.initialized = hooked == true
    return self.initialized
end
