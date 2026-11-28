-- Module: Features/QuestGuidePage.lua
-- Responsibility: ForeverSuite v3.0 Leveling Planner & 638-Quest Class Walkthrough / Special Library Page
--                 (W.IconRow list w/ W.ScrollBar + W.DetailPanel w/ class icon header & W.ScrollText full walkthrough).
-- Layer: Features (uses UI/Widgets + CompositeWidgets + Domain/QuestGuideModel + Api/SafeAPI/GameAdapters).
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
    label = "퀘스트 가이드",
    group = "now",
    host = nil,
    activeTab = "class", -- class | leveling | books | routes | special
    myClassOnly = true,
    scrollOffset = 0,
    selectedQuest = nil,
    selectedSpecial = nil,
    selectedRoute = nil,
    lastQuery = "",
    leftRows = {},
    leftScrollBar = nil,
    detailPanel = nil,
    navBtn = nil,
}
ns.Features.QuestGuidePage = QuestGuidePage

function QuestGuidePage:RenderDetail()
    if not self.detailPanel then return end
    local cls = ns.Api.GameAdapters.GetPlayerClass()
    local clsIcon = (cls and T.ICON.CLASS_TEX[cls]) or "Interface\\Icons\\INV_Misc_Book_09"
    local clsCol = (cls and T.CLASS_COLORS[cls]) or T.BORDER.GOLD

    if self.activeTab == "leveling" then
        local lvl = ns.Api.GameAdapters.GetPlayerLevel()
        local fac = ns.Api.GameAdapters.GetPlayerFaction()
        local lvlTxt = (type(lvl) == "number" and lvl >= 1) and ("Lv." .. tostring(lvl)) or "Lv.-"
        local facTxt = (type(fac) == "string" and fac ~= "") and fac or "확인 불가"
        self.detailPanel:SetHeader("내 레벨·진영 맞춤 육성 가이드", "현재 캐릭터: " .. lvlTxt .. " (" .. facTxt .. ")", clsIcon, clsCol)
        self.detailPanel:SetBodyText(
            "좌측 목록에서 금색(★)으로 강조된 지역이 현재 레벨에 가장 적합한 육성 구간입니다.\n\n"
            .. "■ 사용 방법\n"
            .. "· 지역을 클릭하면 바로 /way 화살표 내비게이션이 연결됩니다.\n"
            .. "· 상단 '직업 퀘스트 공략' 탭에서 내 직업 전용 퀘스트의 전체 단계별 한글 공략과 완료 여부를 확인할 수 있습니다.\n"
            .. "· '특수·도서관' 탭에서는 아제로스 특수 퀘스트 및 도서관 서적 위치를 즉시 검색할 수 있습니다."
        )
        self.navBtn:Hide()
        return
    end

    if self.activeTab == "books" or self.activeTab == "special" then
        local sp = self.selectedSpecial
        if not sp then
            local emptyT = (self.activeTab == "books") and "포에버 도서관 서적 아틀라스" or "특수 퀘스트 가이드"
            self.detailPanel:SetHeader(emptyT, "좌측에서 항목을 선택하세요", "Interface\\Icons\\INV_Misc_Book_09", T.BORDER.GOLD_SOFT)
            self.detailPanel:SetBodyText("")
            self.navBtn:Hide()
            return
        end
        local compTag = ""
        if type(sp.questID) == "number" and sp.questID > 0 then
            local comp = ns.Api.GameAdapters.IsQuestCompleted(sp.questID)
            compTag = (comp == true) and "[완료] " or ((comp == false) and "[미완료] " or "")
        end
        self.detailPanel:SetHeader(compTag .. tostring(sp.title), "지역: " .. tostring(sp.zone or "정보 없음") .. ((sp.set and sp.set ~= "") and (" · 세트: " .. sp.set) or ""), "Interface\\Icons\\INV_Misc_Book_09", T.BORDER.GOLD)
        local body = (sp.altName and sp.altName ~= "" and ("■ 영문명: " .. sp.altName .. "\n\n") or "")
            .. "■ 위치 및 상세 공략\n" .. tostring(sp.note or "아래 버튼으로 /way 안내를 시작하세요.")
        self.detailPanel:SetBodyText(body)
        if type(sp.mapID) == "number" and type(sp.x) == "number" and type(sp.y) == "number" then
            self.navBtn:Show()
        else
            self.navBtn:Hide()
        end
        return
    end

    if self.activeTab == "routes" then
        local rt = self.selectedRoute
        if not rt then
            self.detailPanel:SetHeader("퀘스트 대화 루트 · 호위 · 상호작용 · 퀵팁", "좌측에서 항목을 선택하세요", "Interface\\Icons\\INV_Scroll_03", T.BORDER.GOLD)
            self.detailPanel:SetBodyText("퀘스트 NPC 대화·보고 좌표, 상호작용 오브젝트, 호위 퀘스트 주의사항, 파티 퀘스트 동기화 상태 및 실전 퀵팁을 확인할 수 있습니다.")
            self.navBtn:Hide()
            return
        end
        self.detailPanel:SetHeader(tostring(rt.title or "퀘스트 힌트"), tostring(rt.sub or ""), "Interface\\Icons\\INV_Scroll_03", T.BORDER.GOLD)
        self.detailPanel:SetBodyText(tostring(rt.body or rt.note or "아래 버튼으로 /way 이동을 시작하세요."))
        if type(rt.mapID) == "number" and type(rt.x) == "number" and type(rt.y) == "number" then
            self.navBtn:Show()
        else
            self.navBtn:Hide()
        end
        return
    end

    local q = self.selectedQuest
    if not q then
        self.detailPanel:SetHeader("직업 퀘스트 단계별 공략", "좌측에서 직업 퀘스트를 선택하세요", clsIcon, clsCol)
        self.detailPanel:SetBodyText("")
        self.navBtn:Hide()
        return
    end

    local comp = ns.Api.GameAdapters.IsQuestCompleted(q.questID)
    local compTag = (comp == true) and "[완료]" or ((comp == false) and "[미완료]" or "[확인 불가]")
    local qLvlTxt = (type(q.level) == "number" and q.level > 0) and ("Lv." .. tostring(q.level)) or "Lv.-"
    local minLvlTxt = (type(q.minLevel) == "number" and q.minLevel > 0) and tostring(q.minLevel) or "-"
    self.detailPanel:SetHeader(
        compTag .. " " .. tostring(q.title),
        "퀘스트 #" .. tostring(q.questID) .. " · " .. qLvlTxt .. " (최소 Lv." .. minLvlTxt .. ")",
        clsIcon,
        (comp == true) and T.SEMANTIC.SUCCESS or clsCol
    )

    local parts = {}
    if type(q.rewardSummary) == "string" and q.rewardSummary ~= "" then
        parts[#parts + 1] = "■ 완료 보상 (ClassQuestReward)\n" .. q.rewardSummary
    end
    if type(q.chainCsv) == "string" and q.chainCsv ~= "" then
        parts[#parts + 1] = "■ 연계 후속 퀘스트 ID: " .. q.chainCsv
    end
    if type(q.walkthrough) == "string" and q.walkthrough ~= "" then
        parts[#parts + 1] = "■ 단계별 공략 (스크롤 지원)\n" .. q.walkthrough
    else
        parts[#parts + 1] = "상세 공략 텍스트가 등록되지 않은 퀘스트입니다. 아래 버튼으로 시작 위치로 이동하세요."
    end
    self.detailPanel:SetBodyText(table.concat(parts, "\n\n"))
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
                title = (z.recommended and "★ " or "") .. z.zone,
                subtitle = z.tip,
                right = z.range,
                color = z.recommended and T.TEXT.GOLD or T.TEXT.PRIMARY,
                icon = "Interface\\Icons\\INV_Misc_Map_01",
                borderCol = z.recommended and T.BORDER.GOLD or T.BORDER.HAIRLINE,
                onClick = function()
                    if ns.Features.NavigationHud then
                        ns.Features.NavigationHud:SetTarget(z.mapID, z.x, z.y, z.zone)
                    end
                    ns.Api.SafeAPI.Print("육성 지역 안내: " .. z.zone .. " - " .. z.tip)
                end,
            }
        end
    elseif self.activeTab == "books" or self.activeTab == "special" then
        ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_Atlas")
        local pack = _G.ForeverSuiteData and _G.ForeverSuiteData.packs and _G.ForeverSuiteData.packs.special_guides
        local kindFilter = (self.activeTab == "books") and "book" or "special"
        local filtered = ns.Domain.TravelQuestModel.FilterSpecialGuides(
            (type(pack) == "table" and pack.entries) or {},
            kindFilter,
            self.lastQuery
        )
        if (not self.selectedSpecial) and filtered[1] then
            self.selectedSpecial = filtered[1]
        end
        for _, sp in ipairs(filtered) do
            local sel = (self.selectedSpecial and self.selectedSpecial.title == sp.title)
            local comp = (type(sp.questID) == "number" and sp.questID > 0) and ns.Api.GameAdapters.IsQuestCompleted(sp.questID) or nil
            items[#items + 1] = {
                title = ((comp == true) and "V " or "") .. tostring(sp.title),
                subtitle = tostring(sp.zone or ""),
                right = (sp.kind == "special") and "특수" or "도서관",
                color = (comp == true) and T.SEMANTIC.SUCCESS or (sel and T.TEXT.GOLD or T.TEXT.PRIMARY),
                icon = "Interface\\Icons\\INV_Misc_Book_09",
                borderCol = (comp == true) and T.SEMANTIC.SUCCESS or (sel and T.BORDER.GOLD or T.BORDER.HAIRLINE),
                selected = sel,
                onClick = function()
                    QuestGuidePage.selectedSpecial = sp
                    QuestGuidePage:Render(QuestGuidePage.lastQuery)
                end,
            }
        end
    elseif self.activeTab == "routes" then
        ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_QuestExtra")
        local packs = (_G.ForeverSuiteData and _G.ForeverSuiteData.packs) or {}
        local qLower = string.lower(tostring(self.lastQuery or ""))
        local combined = {}
        for _, r in ipairs((packs.quest_routes and packs.quest_routes.entries) or {}) do
            local sub = (r.kind == "dialogue") and ("대화·보고 루트 · #" .. tostring(r.questID or 0)) or ("상호작용 대상 · #" .. tostring(r.questID or 0))
            combined[#combined + 1] = {
                title = tostring(r.title or ("퀘스트 #" .. tostring(r.questID or 0))),
                sub = sub,
                body = (r.kind == "dialogue") and ("■ 보고/대화 대상\n" .. tostring(r.title or "") .. "\n퀘스트 ID: #" .. tostring(r.questID or 0))
                    or ("■ 상호작용 오브젝트/대상\n" .. tostring(r.title or "") .. " (x" .. tostring(r.count or 1) .. ")\n행동: " .. tostring(r.note or r.action or "")),
                tag = (r.kind == "dialogue") and "루트" or "대상",
                mapID = r.mapID, x = r.x, y = r.y,
            }
        end
        for _, t in ipairs((packs.quest_tips and packs.quest_tips.entries) or {}) do
            combined[#combined + 1] = {
                title = tostring(t.title or "팁"),
                sub = tostring(t.summary or t.category or t.kind or ""),
                body = (t.meta and t.meta ~= "" and ("[" .. t.meta .. "]\n\n") or "") .. tostring(t.note or ""),
                tag = (t.kind == "escort") and "호위" or ((t.kind == "growth") and "성장" or "퀵팁"),
            }
        end
        for _, rec in ipairs(combined) do
            local hay = string.lower(tostring(rec.title) .. " " .. tostring(rec.sub) .. " " .. tostring(rec.body))
            if qLower == "" or string.find(hay, qLower, 1, true) then
                if not self.selectedRoute then self.selectedRoute = rec end
                local sel = (self.selectedRoute == rec)
                items[#items + 1] = {
                    title = rec.title,
                    subtitle = rec.sub,
                    right = rec.tag,
                    color = sel and T.TEXT.GOLD or T.TEXT.PRIMARY,
                    icon = "Interface\\Icons\\INV_Scroll_03",
                    borderCol = sel and T.BORDER.GOLD or T.BORDER.HAIRLINE,
                    selected = sel,
                    onClick = function()
                        QuestGuidePage.selectedRoute = rec
                        QuestGuidePage:Render(QuestGuidePage.lastQuery)
                    end,
                }
            end
        end
    else
        ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_Atlas")
        local pack = _G.ForeverSuiteData and _G.ForeverSuiteData.packs and _G.ForeverSuiteData.packs.class_quests
        local playerCls = ns.Api.GameAdapters.GetPlayerClass()
        local filtered = ns.Domain.QuestGuideModel.FilterClassQuests(
            (type(pack) == "table" and pack.entries) or {},
            {
                playerClass = playerCls,
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
            local qIcon = (q.class and T.ICON.CLASS_TEX[q.class]) or (playerCls and T.ICON.CLASS_TEX[playerCls]) or "Interface\\Icons\\INV_Misc_Book_09"
            items[#items + 1] = {
                title = ((comp == true) and "V " or "") .. tostring(q.title),
                subtitle = (q.walkthrough and q.walkthrough ~= "") and "한글 상세 공략 수록" or "좌표 안내",
                right = (type(q.level) == "number" and q.level > 0) and ("Lv." .. tostring(q.level)) or "Lv.-",
                color = (comp == true) and T.SEMANTIC.SUCCESS or (sel and T.TEXT.GOLD or T.TEXT.PRIMARY),
                icon = qIcon,
                borderCol = (comp == true) and T.SEMANTIC.SUCCESS or (sel and T.BORDER.GOLD or T.BORDER.HAIRLINE),
                selected = sel,
                onClick = function()
                    QuestGuidePage.selectedQuest = q
                    QuestGuidePage:Render(QuestGuidePage.lastQuery)
                end,
            }
        end
    end

    local total = #items
    local maxOff = math_max(0, total - LEFT_ROWS)
    self.scrollOffset = math_max(0, math_min(maxOff, self.scrollOffset))
    for i = 1, LEFT_ROWS do
        local row = self.leftRows[i]
        local d = items[self.scrollOffset + i]
        if d then
            row:SetData({
                icon = d.icon,
                borderCol = d.borderCol,
                title = d.title,
                subtitle = d.subtitle,
                titleCol = d.color,
                rightText = d.right,
                selected = d.selected,
                sepCol = T.BORDER.SUBTLE,
            })
            row._onActivate = d.onClick
            row:Show()
        else
            row._onActivate = nil
            row:Hide()
        end
    end
    if self.leftScrollBar then
        self.leftScrollBar:SetMetrics(self.scrollOffset, LEFT_ROWS, total)
    end
    self:RenderDetail()
end

function QuestGuidePage:Build(parent)
    self.host = parent
    local hdr = W.SectionHeader(parent, "레벨링 육성 플래너 · 직업 퀘스트 공략 (전체 스크롤 지원)")
    hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    local tabBar = W.PillBar(parent, {
        { value = "class",    label = "직업 퀘스트",  width = 86 },
        { value = "leveling", label = "레벨링 플랜",  width = 86 },
        { value = "books",    label = "도서관 서적",  width = 86 },
        { value = "routes",   label = "루트·호위·팁", width = 94 },
        { value = "special",  label = "특수 퀘스트",  width = 86 },
    }, self.activeTab, function(v)
        QuestGuidePage.activeTab = v
        QuestGuidePage.selectedSpecial = nil
        QuestGuidePage.selectedRoute = nil
        QuestGuidePage.scrollOffset = 0
        QuestGuidePage:Render(QuestGuidePage.lastQuery)
    end)
    tabBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -28)
    tabBar:SetWidth(480)

    local clsTgl = W.Toggle(parent, "내 직업만 보기", self.myClassOnly, function(v)
        QuestGuidePage.myClassOnly = v
        QuestGuidePage.selectedQuest = nil
        QuestGuidePage.scrollOffset = 0
        QuestGuidePage:Render(QuestGuidePage.lastQuery)
        return true
    end)
    clsTgl:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -28)
    clsTgl:SetWidth(140)

    local leftPane = W.Card(parent, 276, 470)
    leftPane:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -60)
    leftPane:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 14)
    if type(leftPane.EnableMouseWheel) == "function" then
        leftPane:EnableMouseWheel(true)
        leftPane:SetScript("OnMouseWheel", function(_, delta)
            if not delta or delta == 0 then return end
            QuestGuidePage.scrollOffset = QuestGuidePage.scrollOffset + (delta > 0 and -3 or 3)
            QuestGuidePage:Render(QuestGuidePage.lastQuery)
        end)
    end
    for i = 1, LEFT_ROWS do
        local row = W.IconRow(leftPane, 34, function(btn)
            if type(btn._onActivate) == "function" then btn._onActivate() end
        end)
        row:SetPoint("TOPLEFT", leftPane, "TOPLEFT", 4, -(6 + (i - 1) * 35))
        row:SetPoint("TOPRIGHT", leftPane, "TOPRIGHT", -14, -(6 + (i - 1) * 35))
        self.leftRows[i] = row
    end
    local lsb = W.ScrollBar(leftPane, 456, function(newOff)
        QuestGuidePage.scrollOffset = newOff
        QuestGuidePage:Render(QuestGuidePage.lastQuery)
    end)
    lsb:SetPoint("TOPRIGHT", leftPane, "TOPRIGHT", -3, -6)
    lsb:SetPoint("BOTTOMRIGHT", leftPane, "BOTTOMRIGHT", -3, 6)
    self.leftScrollBar = lsb

    local detail = W.DetailPanel(parent, 482, 470, { hasFooter = true, lineHeight = 18 })
    detail:SetPoint("TOPLEFT", leftPane, "TOPRIGHT", 10, 0)
    detail:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 14)
    self.detailPanel = detail

    self.navBtn = W.Button(detail._footer, "시작 위치 /way 안내", 156, 24, function()
        local target = (QuestGuidePage.activeTab == "books" or QuestGuidePage.activeTab == "special") and QuestGuidePage.selectedSpecial
            or ((QuestGuidePage.activeTab == "routes") and QuestGuidePage.selectedRoute or QuestGuidePage.selectedQuest)
        if target and type(target.mapID) == "number" and type(target.x) == "number" and type(target.y) == "number" then
            if ns.Features.NavigationHud then
                ns.Features.NavigationHud:SetTarget(target.mapID, target.x, target.y, target.title)
            end
            ns.Api.SafeAPI.Print("퀘스트 위치 안내: " .. tostring(target.title))
        end
    end, true)
    self.navBtn:SetPoint("LEFT", detail._footer, "LEFT", 0, 0)
    self.navBtn:Hide()
end

function QuestGuidePage:OnShow()
    self:Render("")
    ns.UI.CommandHub:RefreshStatusBar()
end

function QuestGuidePage:OnSearch(query)
    self.scrollOffset = 0
    self:Render(query)
end
