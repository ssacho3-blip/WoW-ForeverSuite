-- Module: Features/QuestGuidePage.lua
-- Responsibility: Dedicated KPI-6 Leveling Planner & 638-Quest Class Quest Walkthrough / Chain Guide Page.
-- Layer: Features (uses UI/Widgets + Domain/QuestGuideModel + Api/SafeAPI/GameAdapters).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs
local tostring = tostring
local type = type
local math_max = math.max
local math_min = math.min

local LEFT_ROWS = 13

local QuestGuidePage = {
    id = "questguide",
    label = "육성·공략",
    host = nil,
    activeTab = "class", -- class | leveling | special
    myClassOnly = true,
    scrollOffset = 0,
    selectedQuest = nil,
    selectedSpecial = nil,
    lastQuery = "",
    leftRows = {},
    detailTitle = nil,
    detailBody = nil,
    navBtn = nil,
}
ns.Features.QuestGuidePage = QuestGuidePage

function QuestGuidePage:RenderDetail()
    if not self.detailTitle then return end
    if self.activeTab == "leveling" then
        self.detailTitle:SetText("✦ 내 레벨·진영 맞춤 육성 가이드")
        local lvl = ns.Api.GameAdapters.GetPlayerLevel()
        local fac = ns.Api.GameAdapters.GetPlayerFaction()
        local lvlTxt = (type(lvl) == "number" and lvl >= 1) and ("Lv." .. tostring(lvl)) or "Lv.—"
        local facTxt = (type(fac) == "string" and fac ~= "") and fac or "확인 불가"
        self.detailBody:SetText(
            "현재 캐릭터: " .. lvlTxt .. " (" .. facTxt .. ")\n\n"
            .. "좌측 목록에서 강조된 지역이 현재 레벨에 가장 적합한 육성 구간입니다.\n"
            .. "지역을 클릭하면 바로 /way 화살표 내비게이션이 연결됩니다.\n\n"
            .. "팁: 상단 '직업 퀘스트 공략' 탭에서는 내 직업 전용 퀘스트의 단계별 한글 공략과 완료 여부를 확인할 수 있습니다."
        )
        self.navBtn:Hide()
        return
    end

    if self.activeTab == "special" then
        local sp = self.selectedSpecial
        if not sp then
            self.detailTitle:SetText("좌측에서 특수 퀘스트 또는 도서관 책을 선택하세요")
            self.detailBody:SetText("")
            self.navBtn:Hide()
            return
        end
        local compTag = ""
        if type(sp.questID) == "number" and sp.questID > 0 then
            local comp = ns.Api.GameAdapters.IsQuestCompleted(sp.questID)
            compTag = (comp == true) and "[완료] " or ((comp == false) and "[미완료] " or "")
        end
        self.detailTitle:SetText(compTag .. tostring(sp.title))
        local body = "지역: " .. tostring(sp.zone or "정보 없음")
            .. (sp.altName and sp.altName ~= "" and ("\n영문명: " .. sp.altName) or "")
            .. "\n\n위치 및 공략:\n" .. tostring(sp.note or "아래 버튼으로 /way 안내를 시작하세요.")
        self.detailBody:SetText(body)
        if type(sp.mapID) == "number" and type(sp.x) == "number" and type(sp.y) == "number" then
            self.navBtn:Show()
        else
            self.navBtn:Hide()
        end
        return
    end

    local q = self.selectedQuest
    if not q then
        self.detailTitle:SetText("좌측에서 직업 퀘스트를 선택하세요")
        self.detailBody:SetText("")
        self.navBtn:Hide()
        return
    end

    local comp = ns.Api.GameAdapters.IsQuestCompleted(q.questID)
    local compTag = (comp == true) and "[완료]" or ((comp == false) and "[미완료]" or "[확인 불가]")
    local qLvlTxt = (type(q.level) == "number" and q.level > 0) and ("Lv." .. tostring(q.level)) or "Lv.—"
    local minLvlTxt = (type(q.minLevel) == "number" and q.minLevel > 0) and tostring(q.minLevel) or "—"
    self.detailTitle:SetText(compTag .. " " .. tostring(q.title) .. " (" .. qLvlTxt .. ")")

    local parts = {
        "퀘스트 ID: #" .. tostring(q.questID) .. " · 최소 레벨: " .. minLvlTxt,
    }
    if type(q.chainCsv) == "string" and q.chainCsv ~= "" then
        parts[#parts + 1] = "연계 후속 퀘스트 ID: " .. q.chainCsv
    end
    if type(q.walkthrough) == "string" and q.walkthrough ~= "" then
        parts[#parts + 1] = "\n단계별 공략:\n" .. q.walkthrough
    else
        parts[#parts + 1] = "\n상세 공략 텍스트가 등록되지 않은 퀘스트입니다. 아래 버튼으로 시작 위치로 이동하세요."
    end
    self.detailBody:SetText(table.concat(parts, "\n"))
    if type(q.mapID) == "number" and type(q.x) == "number" and type(q.y) == "number" then
        self.navBtn:Show()
    else
        self.navBtn:Hide()
    end
end

function QuestGuidePage:Render(query)
    if not self.host then return end
    self.lastQuery = query or ""

    local items = {}
    if self.activeTab == "leveling" then
        local zones = ns.Domain.QuestGuideModel.RecommendLevelingZones(
            ns.Api.GameAdapters.GetPlayerLevel(),
            ns.Api.GameAdapters.GetPlayerFaction()
        )
        for _, z in ipairs(zones) do
            items[#items + 1] = {
                left = (z.recommended and "★ " or "") .. z.zone,
                right = z.range,
                color = z.recommended and T.TEXT.GOLD or T.TEXT.PRIMARY,
                onClick = function()
                    if ns.Features.NavigationHud then
                        ns.Features.NavigationHud:SetTarget(z.mapID, z.x, z.y, z.zone)
                    end
                    ns.Api.SafeAPI.Print("육성 지역 안내: " .. z.zone .. " — " .. z.tip)
                end,
            }
        end
    elseif self.activeTab == "special" then
        ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_Atlas")
        local pack = _G.ForeverSuiteData and _G.ForeverSuiteData.packs and _G.ForeverSuiteData.packs.special_guides
        local filtered = ns.Domain.TravelQuestModel.FilterSpecialGuides(
            (type(pack) == "table" and pack.entries) or {},
            "all",
            self.lastQuery
        )
        if (not self.selectedSpecial) and filtered[1] then
            self.selectedSpecial = filtered[1]
        end
        for _, sp in ipairs(filtered) do
            local sel = (self.selectedSpecial and self.selectedSpecial.title == sp.title)
            local comp = (type(sp.questID) == "number" and sp.questID > 0) and ns.Api.GameAdapters.IsQuestCompleted(sp.questID) or nil
            items[#items + 1] = {
                left = ((comp == true) and "✓ " or "") .. tostring(sp.title),
                right = (sp.kind == "special") and "특수" or "도서관",
                color = (comp == true) and T.SEMANTIC.SUCCESS or (sel and T.TEXT.GOLD or T.TEXT.PRIMARY),
                selected = sel,
                onClick = function()
                    QuestGuidePage.selectedSpecial = sp
                    QuestGuidePage:Render(QuestGuidePage.lastQuery)
                end,
            }
        end
    else
        ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_Atlas")
        local pack = _G.ForeverSuiteData and _G.ForeverSuiteData.packs and _G.ForeverSuiteData.packs.class_quests
        local filtered = ns.Domain.QuestGuideModel.FilterClassQuests(
            (type(pack) == "table" and pack.entries) or {},
            {
                playerClass = ns.Api.GameAdapters.GetPlayerClass(),
                myClassOnly = self.myClassOnly,
                query = self.lastQuery,
            }
        )
        if (not self.selectedQuest) and filtered[1] then
            self.selectedQuest = filtered[1]
        end
        for _, q in ipairs(filtered) do
            local sel = (self.selectedQuest and self.selectedQuest.questID == q.questID)
            local comp = ns.Api.GameAdapters.IsQuestCompleted(q.questID)
            local mark = (comp == true) and "✓ " or (q.walkthrough and q.walkthrough ~= "" and "📖 " or "")
            items[#items + 1] = {
                left = mark .. tostring(q.title),
                right = (type(q.level) == "number" and q.level > 0) and ("Lv." .. tostring(q.level)) or "Lv.—",
                color = (comp == true) and T.SEMANTIC.SUCCESS or (sel and T.TEXT.GOLD or T.TEXT.PRIMARY),
                selected = sel,
                onClick = function()
                    QuestGuidePage.selectedQuest = q
                    QuestGuidePage:Render(QuestGuidePage.lastQuery)
                end,
            }
        end
    end

    local maxOff = math_max(0, #items - LEFT_ROWS)
    self.scrollOffset = math_max(0, math_min(maxOff, self.scrollOffset))
    for i = 1, LEFT_ROWS do
        local row = self.leftRows[i]
        local d = items[self.scrollOffset + i]
        if d then
            row._left:SetText(d.left)
            local c = d.color or T.TEXT.PRIMARY
            row._left:SetTextColor(c[1], c[2], c[3], 1)
            row._right:SetText(d.right or "")
            row:SetRowStyle(d.selected and T.SURFACE.GOLD_TINT or { 0, 0, 0, 0 }, d.selected and T.BORDER.GOLD or nil, 0, 2, nil, 6)
            row._onActivate = d.onClick
            row:Show()
        else
            row._onActivate = nil
            row:Hide()
        end
    end
    self:RenderDetail()
end

function QuestGuidePage:Build(parent)
    self.host = parent
    local hdr = W.SectionHeader(parent, "레벨링 육성 플래너 · 직업 퀘스트 단계별 공략서")
    hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    local tabBar = W.PillBar(parent, {
        { value = "class", label = "직업 퀘스트 공략", width = 116 },
        { value = "leveling", label = "레벨링 구간", width = 94 },
        { value = "special", label = "특수·도서관", width = 94 },
    }, self.activeTab, function(v)
        QuestGuidePage.activeTab = v
        QuestGuidePage.scrollOffset = 0
        QuestGuidePage:Render(QuestGuidePage.lastQuery)
    end)
    tabBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -28)
    tabBar:SetWidth(320)

    local clsTgl = W.Toggle(parent, "내 직업만 보기", self.myClassOnly, function(v)
        QuestGuidePage.myClassOnly = v
        QuestGuidePage.selectedQuest = nil
        QuestGuidePage.scrollOffset = 0
        QuestGuidePage:Render(QuestGuidePage.lastQuery)
        return true
    end)
    clsTgl:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -28)
    clsTgl:SetWidth(140)

    local leftPane = W.Card(parent, 250, 386, nil, nil)
    leftPane:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -60)
    if type(leftPane.EnableMouseWheel) == "function" then
        leftPane:EnableMouseWheel(true)
        leftPane:SetScript("OnMouseWheel", function(_, delta)
            if not delta or delta == 0 then return end
            QuestGuidePage.scrollOffset = QuestGuidePage.scrollOffset + (delta > 0 and -3 or 3)
            QuestGuidePage:Render(QuestGuidePage.lastQuery)
        end)
    end
    for i = 1, LEFT_ROWS do
        local row = W.ListRow(leftPane, 28, function(btn)
            if type(btn._onActivate) == "function" then btn._onActivate() end
        end)
        row:SetPoint("TOPLEFT", leftPane, "TOPLEFT", 4, -(6 + (i - 1) * 28))
        row:SetPoint("TOPRIGHT", leftPane, "TOPRIGHT", -4, -(6 + (i - 1) * 28))
        self.leftRows[i] = row
    end

    local rightPane = W.Card(parent, 390, 386, nil, nil)
    rightPane:SetPoint("TOPLEFT", leftPane, "TOPRIGHT", 10, 0)
    rightPane:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 16)

    self.detailTitle = W.Label(rightPane, "", "heading", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    self.detailTitle:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 10, -10)
    self.detailTitle:SetPoint("TOPRIGHT", rightPane, "TOPRIGHT", -10, -10)

    self.detailBody = W.Label(rightPane, "", "body", T.TEXT.PRIMARY, { justifyH = "LEFT", wordWrap = true })
    if type(self.detailBody.SetJustifyV) == "function" then self.detailBody:SetJustifyV("TOP") end
    self.detailBody:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 10, -36)
    self.detailBody:SetPoint("BOTTOMRIGHT", rightPane, "BOTTOMRIGHT", -10, 42)

    self.navBtn = W.Button(rightPane, "시작 위치 /way 안내", 154, 26, function()
        local target = (QuestGuidePage.activeTab == "special") and QuestGuidePage.selectedSpecial or QuestGuidePage.selectedQuest
        if target and type(target.mapID) == "number" and type(target.x) == "number" and type(target.y) == "number" then
            if ns.Features.NavigationHud then
                ns.Features.NavigationHud:SetTarget(target.mapID, target.x, target.y, target.title)
            end
            ns.Api.SafeAPI.Print("퀘스트 위치 안내: " .. tostring(target.title))
        end
    end, true)
    self.navBtn:SetPoint("BOTTOMLEFT", rightPane, "BOTTOMLEFT", 10, 10)
    self.navBtn:Hide()
end

function QuestGuidePage:OnShow()
    self:Render(ns.UI.CommandHub.lastQuery or "")
    ns.UI.CommandHub:RefreshStatusBar()
end

function QuestGuidePage:OnSearch(query)
    self.scrollOffset = 0
    self:Render(query)
end
