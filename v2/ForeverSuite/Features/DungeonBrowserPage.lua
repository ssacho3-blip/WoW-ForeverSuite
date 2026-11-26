-- Module: Features/DungeonBrowserPage.lua
-- Responsibility: Dedicated KPI-1 2-Pane Dungeon Browser (40 dungeons, 272 bosses -> drops, 432-quest live readiness
--                 checklist with C_QuestLog completion & /way, entrance navigation, and live Dungeon Run Report).
-- Layer: Features (uses UI/Widgets + Domain/DungeonBrowserModel + Api/SafeAPI/GameAdapters).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs
local tostring = tostring
local type = type
local math_max = math.max
local math_min = math.min

local LEFT_ROWS = 14
local RIGHT_ROWS = 10

local QUALITY_COLORS = {
    [0] = { 0.62, 0.62, 0.62, 1.0 },
    [1] = T.TEXT.PRIMARY,
    [2] = { 0.12, 0.90, 0.25, 1.0 },
    [3] = { 0.28, 0.64, 1.00, 1.0 },
    [4] = { 0.72, 0.36, 0.98, 1.0 },
    [5] = { 1.00, 0.54, 0.10, 1.0 },
}

local DungeonBrowserPage = {
    id = "dungeons",
    label = "던전 도감",
    host = nil,
    leftRows = {},
    rightRows = {},
    raidFilter = "all",
    activeTab = "overview", -- overview | bosses | quests | report
    selectedDungeon = nil,
    selectedBoss = nil,
    leftOffset = 0,
    rightOffset = 0,
    lootByID = nil,
    lastQuery = "",
    -- Live Dungeon Run Report state
    activeRun = nil,
    runHistory = {},
}
ns.Features.DungeonBrowserPage = DungeonBrowserPage

function DungeonBrowserPage:EnsureDataLoaded()
    local ok, st = ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_Dungeon")
    if ok and not self.lootByID then
        local lootPack = _G.ForeverSuiteData and _G.ForeverSuiteData.packs and _G.ForeverSuiteData.packs.dungeon_loot
        if type(lootPack) == "table" and type(lootPack.entries) == "table" then
            self.lootByID = ns.Domain.DungeonBrowserModel.IndexLootByItemID(lootPack.entries)
        end
    end
    return ok, st
end

function DungeonBrowserPage:OnInstanceChanged()
    local inInst, instType, instName = ns.Api.GameAdapters.GetInstanceContext()
    local now = ns.Api.GameAdapters.GetMonotonicTime() or 0
    local money = ns.Api.SafeAPI.GetPlayerMoney() or 0
    if inInst and (instType == "party" or instType == "raid") and instName ~= "" then
        if (not self.activeRun) or self.activeRun.name ~= instName then
            self.activeRun = {
                name = instName,
                instType = instType,
                startedAt = now,
                startMoney = money,
                bossesKilled = {},
            }
        end
    elseif self.activeRun then
        local run = self.activeRun
        run.endedAt = now
        run.elapsed = math_max(0, now - (run.startedAt or now))
        run.goldDelta = money - (run.startMoney or money)
        table.insert(self.runHistory, 1, run)
        if #self.runHistory > 15 then
            table.remove(self.runHistory)
        end
        self.activeRun = nil
    end
end

function DungeonBrowserPage:OnBossKilled(encounterName, success)
    if success == 1 or success == true then
        if self.activeRun and type(encounterName) == "string" and encounterName ~= "" then
            self.activeRun.bossesKilled[#self.activeRun.bossesKilled + 1] = encounterName
        end
    end
end

local function ShowItemHover(btn)
    local it = btn and btn._item
    if type(it) ~= "table" or not (_G.GameTooltip and type(_G.GameTooltip.SetOwner) == "function") then return end
    pcall(function()
        _G.GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        _G.GameTooltip:ClearLines()
        if type(it.itemID) == "number" and it.itemID > 0 and type(_G.GameTooltip.SetHyperlink) == "function" then
            pcall(_G.GameTooltip.SetHyperlink, _G.GameTooltip, "item:" .. tostring(it.itemID))
        end
        local col = QUALITY_COLORS[it.quality or 1] or T.TEXT.GOLD
        _G.GameTooltip:AddLine(tostring(it.title or "아이템"), col[1], col[2], col[3])
        if type(it.itemLevel) == "number" and it.itemLevel > 0 then
            _G.GameTooltip:AddLine("아이템 레벨: " .. tostring(it.itemLevel), T.TEXT.GOLD[1], T.TEXT.GOLD[2], T.TEXT.GOLD[3])
        end
        if type(it.slot) == "string" and it.slot ~= "" then
            _G.GameTooltip:AddLine("부위: " .. it.slot, T.TEXT.SECONDARY[1], T.TEXT.SECONDARY[2], T.TEXT.SECONDARY[3])
        end
        _G.GameTooltip:Show()
    end)
end

local function HideHover()
    if _G.GameTooltip and type(_G.GameTooltip.Hide) == "function" then
        pcall(_G.GameTooltip.Hide, _G.GameTooltip)
    end
end

function DungeonBrowserPage:RenderRight()
    if not (self.host and self.overviewBody and self.entranceBtn and self.rightTitle and self.rightSub) then return end
    for i = 1, RIGHT_ROWS do
        if self.rightRows[i] then self.rightRows[i]:Hide() end
    end
    self.overviewBody:Hide()
    self.entranceBtn:Hide()

    local d = self.selectedDungeon
    if not d and self.activeTab ~= "report" then
        self.rightTitle:SetText("좌측 목록에서 던전을 선택하세요")
        self.rightSub:SetText("")
        return
    end

    if d then
        self.rightTitle:SetText("✦ " .. tostring(d.title) .. (d.levels and d.levels ~= "" and (" (" .. d.levels .. ")") or ""))
        self.rightSub:SetText(tostring(d.zone or ""))
    end

    if self.activeTab == "overview" then
        local bossTxt = (type(d.bossCount) == "number") and (tostring(d.bossCount) .. "명") or "정보 없음"
        local questTxt = (type(d.questCount) == "number") and (tostring(d.questCount) .. "개") or "정보 없음"
        local txt = "추천/구성: " .. tostring(d.zone or "정보 없음")
            .. "\n\n진입 루트:\n" .. (d.note and d.note ~= "" and d.note or "월드맵에서 입구 위치를 확인하세요.")
            .. (d.entranceNote and d.entranceNote ~= "" and ("\n\n입구 상세:\n" .. d.entranceNote) or "")
            .. "\n\n수록 보스: " .. bossTxt .. " · 던전 퀘스트: " .. questTxt
        self.overviewBody:SetText(txt)
        self.overviewBody:Show()
        if type(d.mapID) == "number" and type(d.x) == "number" and type(d.y) == "number" then
            self.entranceBtn:Show()
        end
        return
    end

    local packs = (_G.ForeverSuiteData and _G.ForeverSuiteData.packs) or {}
    local rowsToShow = {}

    if self.activeTab == "bosses" then
        local bosses = ns.Domain.DungeonBrowserModel.GetBossesForDungeon(
            packs.dungeon_bosses and packs.dungeon_bosses.entries or {}, d
        )
        if not self.selectedBoss and bosses[1] then
            self.selectedBoss = bosses[1]
        end
        -- Show boss header rows + expanded drops of selected boss
        for _, b in ipairs(bosses) do
            local isSel = (self.selectedBoss and self.selectedBoss.title == b.title)
            rowsToShow[#rowsToShow + 1] = {
                left = (isSel and "▾ " or "▸ ") .. tostring(b.title),
                right = (type(b.itemCount) == "number") and (tostring(b.itemCount) .. "종 드랍") or "드랍 정보",
                color = isSel and T.TEXT.GOLD or T.TEXT.PRIMARY,
                onClick = function()
                    if isSel then
                        DungeonBrowserPage.selectedBoss = nil
                    else
                        DungeonBrowserPage.selectedBoss = b
                    end
                    DungeonBrowserPage.rightOffset = 0
                    DungeonBrowserPage:RenderRight()
                end,
            }
            if isSel then
                local drops = ns.Domain.DungeonBrowserModel.GetDropsForBoss(b, self.lootByID)
                for _, it in ipairs(drops) do
                    rowsToShow[#rowsToShow + 1] = {
                        left = "   • " .. tostring(it.title),
                        right = (it.slot and it.slot ~= "" and it.slot or "") .. (it.itemLevel and it.itemLevel > 0 and (" · iLvl " .. tostring(it.itemLevel)) or ""),
                        color = it.placeholder and T.TEXT.MUTED or (QUALITY_COLORS[it.quality or 1] or T.TEXT.PRIMARY),
                        item = it,
                    }
                end
            end
        end
        if #rowsToShow == 0 then
            rowsToShow[1] = { left = "등록된 보스 드랍 정보가 없습니다.", right = "", color = T.TEXT.MUTED }
        end

    elseif self.activeTab == "quests" then
        local allQ = packs.dungeon_quests and packs.dungeon_quests.entries or {}
        local statusMap = { completed = {}, inLog = {} }
        for _, q in ipairs(allQ) do
            if q.dungeonKey == d.id or q.dungeonName == d.title then
                statusMap.completed[q.questID] = ns.Api.GameAdapters.IsQuestCompleted(q.questID)
                statusMap.inLog[q.questID] = ns.Api.SafeAPI.IsQuestInLog(q.questID)
                if type(q.prereqID) == "number" and q.prereqID > 0 then
                    statusMap.completed[q.prereqID] = ns.Api.GameAdapters.IsQuestCompleted(q.prereqID)
                end
            end
        end
        local qRows, counts = ns.Domain.DungeonBrowserModel.BuildQuestReadiness(allQ, d, statusMap)
        self.rightSub:SetText(
            "준비 현황: 완료 " .. tostring(counts.completed) .. " · 진행중 " .. tostring(counts.inLog)
            .. " · 수락가능 " .. tostring(counts.available) .. " · 선행필요 " .. tostring(counts.prereq)
        )
        for _, qr in ipairs(qRows) do
            local q = qr.quest
            local tag, col
            if qr.state == "COMPLETED" then tag, col = "[완료] ", T.SEMANTIC.SUCCESS
            elseif qr.state == "IN_LOG" then tag, col = "[진행] ", T.TEXT.GOLD
            elseif qr.state == "PREREQ_NEEDED" then tag, col = "[선행필요] ", T.SEMANTIC.DANGER
            else tag, col = "[미수락] ", T.TEXT.PRIMARY end
            rowsToShow[#rowsToShow + 1] = {
                left = tag .. tostring(q.title) .. (q.inside and " (내부)" or ""),
                right = (q.level and q.level > 0 and ("Lv." .. tostring(q.level)) or "") .. (q.mapID and " · /way" or ""),
                color = col,
                onClick = function()
                    if type(q.mapID) == "number" and type(q.x) == "number" and type(q.y) == "number" then
                        if ns.Features.NavigationHud then
                            ns.Features.NavigationHud:SetTarget(q.mapID, q.x, q.y, q.title)
                        end
                        ns.Api.SafeAPI.Print("던전 퀘스트 안내: " .. tostring(q.title) .. " — " .. tostring(q.npc or ""))
                    else
                        ns.Api.SafeAPI.Print(tostring(q.title) .. " (" .. tostring(q.npc or "") .. "): " .. tostring(q.objective or ""))
                    end
                end,
            }
        end
        if #rowsToShow == 0 then
            rowsToShow[1] = { left = "등록된 던전 퀘스트가 없습니다.", right = "", color = T.TEXT.MUTED }
        end

    elseif self.activeTab == "report" then
        self.rightTitle:SetText("✦ 던전 클리어 리포트 (실시간 기록)")
        self.rightSub:SetText("던전 입장·보스 처치·퇴장 시 소요 시간과 골드 변화 자동 기록")
        local ledger = ns.Domain and ns.Domain.LedgerModel
        local fmtCopper = (ledger and type(ledger.FormatCopper) == "function")
            and ledger.FormatCopper
            or function(v) return tostring(v or 0) .. "c" end
        if self.activeRun then
            local now = ns.Api.GameAdapters.GetMonotonicTime() or 0
            local el = ns.Domain.DungeonBrowserModel.FormatDuration(now - (self.activeRun.startedAt or now))
            rowsToShow[#rowsToShow + 1] = {
                left = "[진행중] " .. tostring(self.activeRun.name) .. " · 보스 " .. tostring(#self.activeRun.bossesKilled) .. "처치",
                right = el,
                color = T.TEXT.GOLD,
            }
        end
        for _, r in ipairs(self.runHistory) do
            rowsToShow[#rowsToShow + 1] = {
                left = tostring(r.name) .. " · 보스 " .. tostring(#(r.bossesKilled or {})) .. "처치",
                right = ns.Domain.DungeonBrowserModel.FormatDuration(r.elapsed or 0) .. " · " .. fmtCopper(r.goldDelta or 0),
                color = T.SEMANTIC.SUCCESS,
            }
        end
        if #rowsToShow == 0 then
            rowsToShow[1] = { left = "던전 입장 시 경과 시간·보스 처치·골드 수익이 자동 기록됩니다.", right = "", color = T.TEXT.MUTED }
        end
    end

    local maxOff = math_max(0, #rowsToShow - RIGHT_ROWS)
    self.rightOffset = math_max(0, math_min(maxOff, self.rightOffset))
    for i = 1, RIGHT_ROWS do
        local row = self.rightRows[i]
        local data = rowsToShow[self.rightOffset + i]
        if data then
            row._left:SetText(data.left)
            local c = data.color or T.TEXT.PRIMARY
            row._left:SetTextColor(c[1], c[2], c[3], 1)
            row._right:SetText(data.right or "")
            row._item = data.item
            row._onActivate = data.onClick
            row:Show()
        else
            row._item = nil
            row._onActivate = nil
            row:Hide()
        end
    end
end

function DungeonBrowserPage:RenderLeft(query)
    if not self.host then return end
    self.lastQuery = query or ""
    local packs = (_G.ForeverSuiteData and _G.ForeverSuiteData.packs) or {}
    local allD = packs.dungeons and packs.dungeons.entries or {}
    local filtered = ns.Domain.DungeonBrowserModel.FilterDungeons(allD, self.lastQuery, self.raidFilter)
    if (not self.selectedDungeon) and filtered[1] then
        self.selectedDungeon = filtered[1]
    end
    local maxOff = math_max(0, #filtered - LEFT_ROWS)
    self.leftOffset = math_max(0, math_min(maxOff, self.leftOffset))
    for i = 1, LEFT_ROWS do
        local row = self.leftRows[i]
        local d = filtered[self.leftOffset + i]
        if d then
            local sel = (self.selectedDungeon and self.selectedDungeon.id == d.id)
            row._dungeon = d
            row._left:SetText((sel and "▸ " or "") .. tostring(d.title))
            local c = sel and T.TEXT.GOLD or T.TEXT.PRIMARY
            row._left:SetTextColor(c[1], c[2], c[3], 1)
            row._right:SetText(d.isRaid and "공격대" or "5인")
            row:SetRowStyle(sel and T.SURFACE.GOLD_TINT or { 0, 0, 0, 0 }, sel and T.BORDER.GOLD or nil, 0, 2, nil, 6)
            row:Show()
        else
            row._dungeon = nil
            row:Hide()
        end
    end
    self:RenderRight()
end

function DungeonBrowserPage:Build(parent)
    self.host = parent
    local hdr = W.SectionHeader(parent, "던전 통합 도감 (개요 · 보스·드랍 · 퀘스트 준비 · 클리어 리포트)")
    hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    local filterBar = W.PillBar(parent, {
        { value = "all", label = "전체", width = 52 },
        { value = "dungeon", label = "5인 던전", width = 72 },
        { value = "raid", label = "공격대", width = 62 },
    }, self.raidFilter, function(v)
        DungeonBrowserPage.raidFilter = v
        DungeonBrowserPage.leftOffset = 0
        DungeonBrowserPage:RenderLeft(DungeonBrowserPage.lastQuery)
    end)
    filterBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -28)
    filterBar:SetWidth(205)

    local tabBar = W.PillBar(parent, {
        { value = "overview", label = "개요·입구", width = 82 },
        { value = "bosses", label = "보스·드랍", width = 82 },
        { value = "quests", label = "퀘스트 준비", width = 92 },
        { value = "report", label = "클리어 리포트", width = 100 },
    }, self.activeTab, function(v)
        DungeonBrowserPage.activeTab = v
        DungeonBrowserPage.rightOffset = 0
        DungeonBrowserPage:RenderRight()
    end)
    tabBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 214, -28)
    tabBar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -28)

    local leftPane = W.Card(parent, 204, 386, nil, nil)
    leftPane:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -60)
    if type(leftPane.EnableMouseWheel) == "function" then
        leftPane:EnableMouseWheel(true)
        leftPane:SetScript("OnMouseWheel", function(_, delta)
            if not delta or delta == 0 then return end
            DungeonBrowserPage.leftOffset = DungeonBrowserPage.leftOffset + (delta > 0 and -3 or 3)
            DungeonBrowserPage:RenderLeft(DungeonBrowserPage.lastQuery)
        end)
    end
    for i = 1, LEFT_ROWS do
        local row = W.ListRow(leftPane, 26, function(btn)
            if btn._dungeon then
                DungeonBrowserPage.selectedDungeon = btn._dungeon
                DungeonBrowserPage.selectedBoss = nil
                DungeonBrowserPage.rightOffset = 0
                DungeonBrowserPage:RenderLeft(DungeonBrowserPage.lastQuery)
            end
        end)
        row:SetPoint("TOPLEFT", leftPane, "TOPLEFT", 4, -(6 + (i - 1) * 26))
        row:SetPoint("TOPRIGHT", leftPane, "TOPRIGHT", -4, -(6 + (i - 1) * 26))
        self.leftRows[i] = row
    end

    local rightPane = W.Card(parent, 440, 386, nil, nil)
    rightPane:SetPoint("TOPLEFT", leftPane, "TOPRIGHT", 10, 0)
    rightPane:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 26)
    if type(rightPane.EnableMouseWheel) == "function" then
        rightPane:EnableMouseWheel(true)
        rightPane:SetScript("OnMouseWheel", function(_, delta)
            if not delta or delta == 0 then return end
            DungeonBrowserPage.rightOffset = DungeonBrowserPage.rightOffset + (delta > 0 and -3 or 3)
            DungeonBrowserPage:RenderRight()
        end)
    end

    self.rightTitle = W.Label(rightPane, "", "heading", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    self.rightTitle:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 10, -10)
    self.rightTitle:SetPoint("TOPRIGHT", rightPane, "TOPRIGHT", -10, -10)

    self.rightSub = W.Label(rightPane, "", "small", T.TEXT.SECONDARY, { justifyH = "LEFT", wordWrap = false })
    self.rightSub:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 10, -30)
    self.rightSub:SetPoint("TOPRIGHT", rightPane, "TOPRIGHT", -10, -30)

    self.overviewBody = W.Label(rightPane, "", "body", T.TEXT.PRIMARY, { justifyH = "LEFT", wordWrap = true })
    if type(self.overviewBody.SetJustifyV) == "function" then self.overviewBody:SetJustifyV("TOP") end
    self.overviewBody:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 10, -54)
    self.overviewBody:SetPoint("BOTTOMRIGHT", rightPane, "BOTTOMRIGHT", -10, 42)

    self.entranceBtn = W.Button(rightPane, "던전 입구 /way 안내 시작", 180, 26, function()
        local d = DungeonBrowserPage.selectedDungeon
        if d and type(d.mapID) == "number" and type(d.x) == "number" and type(d.y) == "number" then
            if ns.Features.NavigationHud then
                ns.Features.NavigationHud:SetTarget(d.mapID, d.x, d.y, d.title .. " 입구")
            end
            ns.Api.SafeAPI.Print("던전 입구 내비게이션: " .. tostring(d.title))
        end
    end, true)
    self.entranceBtn:SetPoint("BOTTOMLEFT", rightPane, "BOTTOMLEFT", 10, 10)
    self.entranceBtn:Hide()

    for i = 1, RIGHT_ROWS do
        local row = W.ListRow(rightPane, 28, function(btn)
            if type(btn._onActivate) == "function" then btn._onActivate() end
        end)
        row:SetTooltipHandler(ShowItemHover, HideHover)
        row:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 6, -(52 + (i - 1) * 30))
        row:SetPoint("TOPRIGHT", rightPane, "TOPRIGHT", -6, -(52 + (i - 1) * 30))
        row:Hide()
        self.rightRows[i] = row
    end
end

function DungeonBrowserPage:OnShow()
    self:EnsureDataLoaded()
    self:RenderLeft(ns.UI.CommandHub.lastQuery or "")
    ns.UI.CommandHub:RefreshStatusBar()
end

function DungeonBrowserPage:OnSearch(query)
    self.leftOffset = 0
    self:RenderLeft(query)
end
