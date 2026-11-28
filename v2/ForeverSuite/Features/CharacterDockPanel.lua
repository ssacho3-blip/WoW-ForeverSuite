-- Module: Features/CharacterDockPanel.lua
-- Responsibility: ForeverSuite v6.1.0 Zero-Taint UIParent-owned right-docking rich panel beside CharacterFrame (C):
--                 [확장 스탯] 2-column stat grid + Hit Cap gauge bars (no raw \n dump, zero fabricated numbers),
--                 [업글 Top 3] W.IconRow with item icons & GameTooltip,
--                 [5레벨 스킬] structured metric rows & deficit summary.
--                 0.00ms idle when CharacterFrame is closed (active-only 0.15s position ticker while shown).
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local Motion = ns.UI.Motion
local tostring = tostring
local string_format = string.format
local table_concat = table.concat
local math_max = math.max
local math_min = math.min

local PANEL_WIDTH = 264
local PANEL_HEIGHT = 326

local CLASS_TRAINER_KEYWORDS = {
    WARRIOR = "전사",
    MAGE = "마법사",
    ROGUE = "도적",
    HUNTER = "사냥꾼",
    PRIEST = "사제",
    WARLOCK = "흑마법사",
    PALADIN = "성기사",
    SHAMAN = "주술사",
    DRUID = "드루이드",
}

local CharacterDockPanel = {
    frame = nil,
    tabButtons = {},
    statGrid = nil,
    hitCapBar = nil,
    hitCapLbl = nil,
    spellHitCapBar = nil,
    spellHitCapLbl = nil,
    upgradeRows = nil,
    upgradeEmpty = nil,
    skillRows = nil,
    trainerArrowBtn = nil,
    activeTab = "stats",
    ticker = nil,
    initialized = false,
}
ns.Features.CharacterDockPanel = CharacterDockPanel

local function FmtNum(v, suffix)
    if type(v) ~= "number" then
        return "집계 없음"
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
        if Motion and type(Motion.InstantHide) == "function" then
            Motion.InstantHide(CharacterDockPanel.frame)
        else
            CharacterDockPanel.frame:Hide()
        end
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

local function ShowUpgradeTooltip(rowBtn)
    local u = rowBtn and rowBtn._payload
    if type(u) ~= "table" or not (_G.GameTooltip and type(_G.GameTooltip.SetOwner) == "function") then return end
    pcall(function()
        _G.GameTooltip:SetOwner(rowBtn, "ANCHOR_RIGHT")
        _G.GameTooltip:ClearLines()
        if type(u.itemID) == "number" and u.itemID > 0 and type(_G.GameTooltip.SetHyperlink) == "function" then
            pcall(_G.GameTooltip.SetHyperlink, _G.GameTooltip, "item:" .. tostring(u.itemID))
        end
        _G.GameTooltip:AddLine(tostring(u.title or "업그레이드 후보"), T.TEXT.GOLD[1], T.TEXT.GOLD[2], T.TEXT.GOLD[3])
        _G.GameTooltip:AddLine("아이템 레벨 상승: +" .. tostring(u.delta or 0) .. " iLvl", T.SEMANTIC.SUCCESS[1], T.SEMANTIC.SUCCESS[2], T.SEMANTIC.SUCCESS[3])
        if type(u.acq) == "string" and u.acq ~= "" then
            _G.GameTooltip:AddLine("획득처: " .. u.acq, T.TEXT.PRIMARY[1], T.TEXT.PRIMARY[2], T.TEXT.PRIMARY[3], true)
        end
        _G.GameTooltip:Show()
    end)
end

local function HideUpgradeTooltip()
    if _G.GameTooltip and type(_G.GameTooltip.Hide) == "function" then
        pcall(_G.GameTooltip.Hide, _G.GameTooltip)
    end
end

local function EnsureUI()
    if CharacterDockPanel.frame then return CharacterDockPanel.frame end

    local card = W.PopupCard(_G.UIParent, PANEL_WIDTH, PANEL_HEIGHT, "ForeverSuiteCharacterDock", T.ELEVATION.L2_WORKSPACE)
    local title = W.Label(card, "★ 캐릭터 확장 브리핑", "heading", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    title:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -10)

    local b1 = W.Button(card, "스탯", 72, 22, function() CharacterDockPanel:Render("stats") end, true)
    b1:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    local b2 = W.Button(card, "업글 Top3", 80, 22, function() CharacterDockPanel:Render("upgrades") end)
    b2:SetPoint("LEFT", b1, "RIGHT", 6, 0)
    local b3 = W.Button(card, "5레벨 스킬", 76, 22, function() CharacterDockPanel:Render("skills") end)
    b3:SetPoint("LEFT", b2, "RIGHT", 6, 0)
    CharacterDockPanel.tabButtons = { stats = b1, upgrades = b2, skills = b3 }

    -- Tab 1: 2-Column Stat Grid (6 cells) + 2 Hit Cap Gauge Bars
    local statGrid = {}
    local cellW = 116
    local cellH = 44
    local cellLabels = { "주문력", "치유량", "근접 전투력", "원거리 전투력", "MP5 (비시전/시전)", "이동 속도" }
    for i = 1, 6 do
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)
        local cell = W.Card(card, cellW, cellH)
        cell:SetPoint("TOPLEFT", card, "TOPLEFT", 12 + col * (cellW + 8), -(66 + row * (cellH + 6)))
        local cap = W.Label(cell, cellLabels[i], "small", T.TEXT.MUTED, { justifyH = "LEFT", wordWrap = false })
        cap:SetPoint("TOPLEFT", cell, "TOPLEFT", 8, -6)
        cap:SetPoint("TOPRIGHT", cell, "TOPRIGHT", -6, -6)
        local val = W.Label(cell, "집계 없음", "body", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
        val:SetPoint("BOTTOMLEFT", cell, "BOTTOMLEFT", 8, 6)
        val:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", -6, 6)
        cell._cap = cap
        cell._val = val
        statGrid[i] = cell
    end
    CharacterDockPanel.statGrid = statGrid

    local physLbl = W.Label(card, "물리 적중 (목표 9%): 집계 없음", "small", T.TEXT.SECONDARY, { justifyH = "LEFT", wordWrap = false })
    physLbl:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -218)
    physLbl:SetPoint("TOPRIGHT", card, "TOPRIGHT", -12, -218)
    local physBar = W.StatusBarTrack(card, PANEL_WIDTH - 24, 10)
    physBar:SetPoint("TOPLEFT", physLbl, "BOTTOMLEFT", 0, -4)
    CharacterDockPanel.hitCapLbl = physLbl
    CharacterDockPanel.hitCapBar = physBar

    local spellLbl = W.Label(card, "주문 적중 (목표 16%): 집계 없음", "small", T.TEXT.SECONDARY, { justifyH = "LEFT", wordWrap = false })
    spellLbl:SetPoint("TOPLEFT", physBar, "BOTTOMLEFT", 0, -10)
    spellLbl:SetPoint("TOPRIGHT", card, "TOPRIGHT", -12, -252)
    local spellBar = W.StatusBarTrack(card, PANEL_WIDTH - 24, 10)
    spellBar:SetPoint("TOPLEFT", spellLbl, "BOTTOMLEFT", 0, -4)
    CharacterDockPanel.spellHitCapLbl = spellLbl
    CharacterDockPanel.spellHitCapBar = spellBar

    -- Tab 2: BiS Top-3 Upgrade IconRows with tooltips
    local upgradeRows = {}
    for i = 1, 3 do
        local row = W.IconRow(card, 48, function(btn)
            local u = btn._payload
            if u and type(u.itemID) == "number" and ns.Api.GameAdapters.IsShiftDown() then
                ns.Api.GameAdapters.InsertItemChatLink(u.itemID, u.title)
            end
        end)
        row:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -(68 + (i - 1) * 56))
        row:SetPoint("TOPRIGHT", card, "TOPRIGHT", -12, -(68 + (i - 1) * 56))
        row:SetTooltipHandler(ShowUpgradeTooltip, HideUpgradeTooltip)
        row:Hide()
        upgradeRows[i] = row
    end
    local upgEmpty = W.Label(card, "", "small", T.TEXT.MUTED, { justifyH = "CENTER", wordWrap = true })
    upgEmpty:SetPoint("TOPLEFT", card, "TOPLEFT", 16, -90)
    upgEmpty:SetPoint("TOPRIGHT", card, "TOPRIGHT", -16, -90)
    upgEmpty:Hide()
    CharacterDockPanel.upgradeRows = upgradeRows
    CharacterDockPanel.upgradeEmpty = upgEmpty

    -- Tab 3: Upcoming 5-level skill structured cards + [상급자 화살표] 1-click navigation
    local skillRows = {}
    local skillTitles = { "현재 습득 가능 스킬", "다음 5레벨 예정 스킬", "예상 총 습득 비용", "부족 골드" }
    for i = 1, 4 do
        local row = W.Card(card, PANEL_WIDTH - 24, 42)
        row:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -(68 + (i - 1) * 47))
        local cap = W.Label(row, skillTitles[i], "small", T.TEXT.MUTED, { justifyH = "LEFT", wordWrap = false })
        cap:SetPoint("TOPLEFT", row, "TOPLEFT", 10, -5)
        local val = W.Label(row, "집계 없음", "body", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
        val:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 10, 5)
        val:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -10, 5)
        row._cap = cap
        row._val = val
        row:Hide()
        skillRows[i] = row
    end
    CharacterDockPanel.skillRows = skillRows

    local trainerBtn = W.Button(card, "★ 직업 상급자 3D 화살표 안내", PANEL_WIDTH - 24, 24, function()
        CharacterDockPanel:NavigateToNearestClassTrainer()
    end, true)
    trainerBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -260)
    trainerBtn:Hide()
    CharacterDockPanel.trainerArrowBtn = trainerBtn

    CharacterDockPanel.frame = card
    card:Hide()
    return card
end

local function SetTabSectionVisibility(active)
    local isStats = (active == "stats")
    local isUpg = (active == "upgrades")
    local isSkills = (active == "skills")

    for i = 1, #(CharacterDockPanel.statGrid or {}) do
        if isStats then CharacterDockPanel.statGrid[i]:Show() else CharacterDockPanel.statGrid[i]:Hide() end
    end
    if CharacterDockPanel.hitCapLbl then
        if isStats then CharacterDockPanel.hitCapLbl:Show() else CharacterDockPanel.hitCapLbl:Hide() end
    end
    if CharacterDockPanel.hitCapBar then
        if isStats then CharacterDockPanel.hitCapBar:Show() else CharacterDockPanel.hitCapBar:Hide() end
    end
    if CharacterDockPanel.spellHitCapLbl then
        if isStats then CharacterDockPanel.spellHitCapLbl:Show() else CharacterDockPanel.spellHitCapLbl:Hide() end
    end
    if CharacterDockPanel.spellHitCapBar then
        if isStats then CharacterDockPanel.spellHitCapBar:Show() else CharacterDockPanel.spellHitCapBar:Hide() end
    end
    for i = 1, #(CharacterDockPanel.upgradeRows or {}) do
        if not isUpg then CharacterDockPanel.upgradeRows[i]:Hide() end
    end
    if CharacterDockPanel.upgradeEmpty and not isUpg then
        CharacterDockPanel.upgradeEmpty:Hide()
    end
    for i = 1, #(CharacterDockPanel.skillRows or {}) do
        if isSkills then CharacterDockPanel.skillRows[i]:Show() else CharacterDockPanel.skillRows[i]:Hide() end
    end
    if CharacterDockPanel.trainerArrowBtn then
        if isSkills then CharacterDockPanel.trainerArrowBtn:Show() else CharacterDockPanel.trainerArrowBtn:Hide() end
    end
end

function CharacterDockPanel:NavigateToNearestClassTrainer()
    local cls = ns.Api.GameAdapters.GetPlayerClass()
    local kw = cls and CLASS_TRAINER_KEYWORDS[cls] or nil
    if not kw then
        ns.Api.SafeAPI.Print("직업 정보를 확인할 수 없습니다.")
        return false, "NO_CLASS"
    end
    ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_Atlas")
    local packs = _G.ForeverSuiteData and _G.ForeverSuiteData.packs
    local npcs = packs and packs.atlas_npcs and packs.atlas_npcs.entries or {}
    local pPos = ns.Api.GameAdapters.GetPlayerPosition and ns.Api.GameAdapters.GetPlayerPosition() or nil
    local pMap = type(pPos) == "table" and pPos.mapID or nil
    local px = type(pPos) == "table" and pPos.x or nil
    local py = type(pPos) == "table" and pPos.y or nil
    local faction = ns.Api.GameAdapters.GetPlayerFaction()
    local wantFacShort = (faction == "Horde") and "H" or ((faction == "Alliance") and "A" or nil)
    local best, bestSameMap, bestDistSq = nil, false, 1e18
    for i = 1, #npcs do
        local n = npcs[i]
        if type(n) == "table" and type(n.mapID) == "number" and type(n.x) == "number" and type(n.y) == "number" then
            local isTrainer = (n.category == "trainer" and n.class == cls)
            if not isTrainer then
                local title = tostring(n.title or "")
                local note = tostring(n.note or n.service or "")
                local hay = title .. " " .. note
                isTrainer = (string.find(hay, kw, 1, true) ~= nil and string.find(hay, "상급", 1, true) ~= nil)
            end
            local nf = n.faction
            local factionOk = (not wantFacShort) or (not nf) or (nf == "N") or (nf == "Neutral") or (nf == wantFacShort) or (nf == faction)
            if isTrainer and factionOk then
                local sameMap = (type(pMap) == "number" and n.mapID == pMap)
                local distSq = 1e18
                if sameMap and type(px) == "number" and type(py) == "number" then
                    local dx, dy = n.x - px, n.y - py
                    distSq = dx * dx + dy * dy
                end
                if (best == nil) or (sameMap and not bestSameMap) or (sameMap == bestSameMap and distSq < bestDistSq) then
                    best = n
                    bestSameMap = sameMap
                    bestDistSq = distSq
                end
            end
        end
    end
    if not best then
        ns.Api.SafeAPI.Print(kw .. " 상급자 좌표가 로드되지 않았습니다 (ForeverSuite-DataPack 확인).")
        return false, "NOT_FOUND"
    end
    if ns.Features.NavigationHud and type(ns.Features.NavigationHud.SetTarget) == "function" then
        ns.Features.NavigationHud:SetTarget(best.mapID, best.x, best.y, tostring(best.title or (kw .. " 상급자")))
    end
    ns.Api.SafeAPI.Print("직업 상급자 안내: " .. tostring(best.title or kw) .. " (" .. tostring(best.zone or "") .. ")")
    return true, best
end

function CharacterDockPanel:Render(tabId)
    if type(tabId) == "string" and tabId ~= "" then
        self.activeTab = tabId
    end
    EnsureUI()
    for k, btn in pairs(self.tabButtons or {}) do
        if type(btn.SetAccent) == "function" then
            btn:SetAccent(k == self.activeTab)
        end
    end
    SetTabSectionVisibility(self.activeTab)

    if self.activeTab == "stats" then
        local st = ns.Api.GameAdapters.GetExtendedCharacterStats and ns.Api.GameAdapters.GetExtendedCharacterStats() or {}
        self.statGrid[1]._val:SetText(FmtNum(st.spellPower))
        self.statGrid[2]._val:SetText(FmtNum(st.healingPower))
        self.statGrid[3]._val:SetText(FmtNum(st.meleeAP))
        self.statGrid[4]._val:SetText(FmtNum(st.rangedAP))
        local mp5Str = (type(st.mp5Base) == "number" or type(st.mp5Cast) == "number")
            and (FmtNum(st.mp5Base) .. " / " .. FmtNum(st.mp5Cast))
            or "집계 없음"
        self.statGrid[5]._val:SetText(mp5Str)
        self.statGrid[6]._val:SetText(FmtNum(st.speedPct, "%"))

        local physRatio = 0
        if type(st.meleeHitPct) == "number" then
            physRatio = math_max(0, math_min(1, st.meleeHitPct / 9.0))
            local rem = math_max(0, 9.0 - st.meleeHitPct)
            self.hitCapLbl:SetText(string_format("물리 적중 %.1f%% / 9.0%% (잔여 %.1f%%)", st.meleeHitPct, rem))
            self.hitCapBar:SetProgress(physRatio, (physRatio >= 1) and T.SEMANTIC.SUCCESS or T.BORDER.GOLD, PANEL_WIDTH - 24)
        else
            self.hitCapLbl:SetText("물리 적중 (목표 9%): 집계 없음")
            self.hitCapBar:SetProgress(0, T.BORDER.GOLD, PANEL_WIDTH - 24)
        end

        if type(st.spellHitPct) == "number" then
            local spellRatio = math_max(0, math_min(1, st.spellHitPct / 16.0))
            local rem = math_max(0, 16.0 - st.spellHitPct)
            self.spellHitCapLbl:SetText(string_format("주문 적중 %.1f%% / 16.0%% (잔여 %.1f%%)", st.spellHitPct, rem))
            self.spellHitCapBar:SetProgress(spellRatio, (spellRatio >= 1) and T.SEMANTIC.SUCCESS or T.SEMANTIC.INFO, PANEL_WIDTH - 24)
        else
            self.spellHitCapLbl:SetText("주문 적중 (목표 16%): 집계 없음")
            self.spellHitCapBar:SetProgress(0, T.SEMANTIC.INFO, PANEL_WIDTH - 24)
        end

        return table_concat({
            "주문력: " .. FmtNum(st.spellPower),
            "치유량: " .. FmtNum(st.healingPower),
            "MP5: " .. mp5Str,
            "물리 적중: " .. FmtNum(st.meleeHitPct, "%"),
            "주문 적중: " .. FmtNum(st.spellHitPct, "%"),
        }, " | ")
    elseif self.activeTab == "upgrades" then
        local okPack, stPack = ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_BiS")
        local packs = _G.ForeverSuiteData and _G.ForeverSuiteData.packs
        local bisRows = packs and packs.bis and packs.bis.entries or {}
        if (not okPack) and #bisRows == 0 then
            for i = 1, 3 do self.upgradeRows[i]:Hide() end
            self.upgradeEmpty:SetText("BiS 데이터팩 미로드 (" .. tostring(stPack) .. ")")
            self.upgradeEmpty:Show()
            return "BiS 데이터팩 미로드 (" .. tostring(stPack) .. ")"
        end
        local lvl = ns.Api.GameAdapters.GetPlayerLevel() or 60
        local eq = ns.Api.GameAdapters.GetEquippedItemLevelMap and ns.Api.GameAdapters.GetEquippedItemLevelMap() or {}
        local top3 = ns.Domain.CharacterGuideModel.RankTopUpgrades(bisRows, lvl, eq, 3)
        if #top3 == 0 then
            for i = 1, 3 do self.upgradeRows[i]:Hide() end
            self.upgradeEmpty:SetText("현재 레벨(+3) 기준 추천 업그레이드 데이터 없음")
            self.upgradeEmpty:Show()
            return "현재 레벨(+3) 기준 추천 업그레이드 데이터 없음"
        end
        self.upgradeEmpty:Hide()
        local parts = {}
        for i = 1, 3 do
            local row = self.upgradeRows[i]
            local u = top3[i]
            if u then
                local iconTex = (type(u.itemID) == "number" and ns.Api.GameAdapters.GetItemIconSafe)
                    and ns.Api.GameAdapters.GetItemIconSafe(u.itemID) or T.ICON.FALLBACK
                row:SetData({
                    icon = iconTex,
                    borderCol = T.BORDER.GOLD,
                    title = tostring(u.title),
                    subtitle = tostring(u.acq or "획득처 확인"),
                    rightText = "+" .. tostring(u.delta) .. " iLvl",
                    rightCol = T.SEMANTIC.SUCCESS,
                    sepCol = T.BORDER.SUBTLE,
                    payload = u,
                })
                row:Show()
                parts[#parts + 1] = string_format("%d. %s (+%d iLvl)", i, u.title, u.delta)
            else
                row:Hide()
            end
        end
        return table_concat(parts, " | ")
    end

    -- tabId == "skills"
    local okAtlas, stAtlas = ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_Atlas")
    local packs = _G.ForeverSuiteData and _G.ForeverSuiteData.packs
    local rows = packs and packs.training_spells and packs.training_spells.entries or {}
    if (not okAtlas) and #rows == 0 then
        self.skillRows[1]._val:SetText("데이터팩 미로드 (" .. tostring(stAtlas) .. ")")
        self.skillRows[2]._val:SetText("집계 없음")
        self.skillRows[3]._val:SetText("집계 없음")
        self.skillRows[4]._val:SetText("집계 없음")
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
        or "집계 없음"
    local syn = ns.Bridges and ns.Bridges.Syndicator
    if syn and type(syn.GetTotalAccountMoney) == "function" then
        local acctCopper, countedChars, acctStatus, totalChars = syn:GetTotalAccountMoney()
        if acctStatus == "OK" and type(acctCopper) == "number" then
            local lbl = (type(totalChars) == "number" and countedChars == totalChars) and "계정 " or "계정 일부 "
            deficitStr = deficitStr .. " (" .. lbl .. ns.Domain.LedgerModel.FormatCopper(acctCopper) .. ")"
        end
    end
    self.skillRows[1]._val:SetText(tostring(#split.learnableNow) .. "개")
    self.skillRows[2]._val:SetText(tostring(#split.upcoming5) .. "개")
    self.skillRows[3]._val:SetText(ns.Domain.LedgerModel.FormatCopper(split.totalCost))
    self.skillRows[4]._val:SetText(deficitStr)
    return "습득 가능: " .. tostring(#split.learnableNow) .. "개 | 다음 5레벨: " .. tostring(#split.upcoming5) .. "개 | 부족 골드: " .. deficitStr
end

function CharacterDockPanel:OnCharacterShow()
    self:Render(self.activeTab)
    SyncPosition()
    if Motion and type(Motion.FadeIn) == "function" then
        Motion.FadeIn(self.frame, 0.15)
    else
        self.frame:Show()
    end
    if not self.ticker then
        self.ticker = ns.Api.GameAdapters.StartTicker(0.15, SyncPosition)
    end
end

function CharacterDockPanel:OnCharacterHide()
    StopTicker()
    if self.frame then
        if Motion and type(Motion.InstantHide) == "function" then
            Motion.InstantHide(self.frame)
        else
            self.frame:Hide()
        end
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
