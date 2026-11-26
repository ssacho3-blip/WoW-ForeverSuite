-- Module: Features/ProfessionPage.lua
-- Responsibility: Dedicated KPI-3 13-Profession Guide Page (step-by-step routes, 2,541 recipes, 582 trainers + Fishing/Cooking/Rogue Poison).
-- Layer: Features (uses UI/Widgets + Domain/ProfessionBrowserModel + Api/SafeAPI).
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
local RIGHT_ROWS = 11

local ProfessionPage = {
    id = "professions",
    label = "전문기술",
    host = nil,
    activeTab = "guide", -- guide | recipes | trainers
    selectedProf = nil,
    rightOffset = 0,
    lastQuery = "",
    leftRows = {},
    rightRows = {},
}
ns.Features.ProfessionPage = ProfessionPage

function ProfessionPage:RenderRight()
    if not (self.host and self.guideBody and self.rightTitle) then return end
    for i = 1, RIGHT_ROWS do
        if self.rightRows[i] then self.rightRows[i]:Hide() end
    end
    self.guideBody:Hide()

    local p = self.selectedProf
    if not p then
        self.rightTitle:SetText("좌측에서 전문기술을 선택하세요")
        return
    end
    self.rightTitle:SetText("✦ " .. tostring(p.title) .. " (제조법 " .. tostring(p.recipeCount or 0) .. " · 교관 " .. tostring(p.npcCount or 0) .. ")")

    if self.activeTab == "guide" then
        local parts = {}
        if type(p.summary) == "string" and p.summary ~= "" then parts[#parts + 1] = "개요: " .. p.summary end
        if type(p.startGuide) == "string" and p.startGuide ~= "" then parts[#parts + 1] = "\n시작 방법:\n" .. p.startGuide end
        if type(p.routesText) == "string" and p.routesText ~= "" then parts[#parts + 1] = "\n숙련 구간별 육성 루트:\n" .. p.routesText end
        if type(p.masterGuide) == "string" and p.masterGuide ~= "" then parts[#parts + 1] = "\n대가(300) 안내:\n" .. p.masterGuide end
        if type(p.tips) == "string" and p.tips ~= "" then parts[#parts + 1] = "\n실전 팁:\n" .. p.tips end
        self.guideBody:SetText(#parts > 0 and table.concat(parts, "\n") or "상단 탭에서 제조법과 교관 위치를 확인하세요.")
        self.guideBody:Show()
        return
    end

    local packs = (_G.ForeverSuiteData and _G.ForeverSuiteData.packs) or {}
    local items = {}
    if self.activeTab == "recipes" then
        local list = ns.Domain.ProfessionBrowserModel.FilterRecipes(
            packs.professions and packs.professions.entries or {}, p, self.lastQuery
        )
        for _, r in ipairs(list) do
            items[#items + 1] = {
                left = tostring(r.title) .. (r.note and r.note ~= "" and (" · " .. r.note) or ""),
                right = (type(r.skill) == "number" and r.skill > 0) and ("숙련 " .. tostring(r.skill)) or "—",
                itemID = r.itemID,
            }
        end
    elseif self.activeTab == "trainers" then
        local list = ns.Domain.ProfessionBrowserModel.FilterTrainers(
            packs.prof_trainers and packs.prof_trainers.entries or {}, p, self.lastQuery
        )
        for _, t in ipairs(list) do
            items[#items + 1] = {
                left = "▸ " .. tostring(t.title),
                right = tostring(t.zone or ""),
                entry = t,
            }
        end
    end

    local maxOff = math_max(0, #items - RIGHT_ROWS)
    self.rightOffset = math_max(0, math_min(maxOff, self.rightOffset))
    for i = 1, RIGHT_ROWS do
        local row = self.rightRows[i]
        local d = items[self.rightOffset + i]
        if d then
            row._left:SetText(d.left)
            row._right:SetText(d.right or "")
            row._entry = d.entry
            row._itemID = d.itemID
            row:Show()
        else
            row._entry = nil
            row._itemID = nil
            row:Hide()
        end
    end
end

function ProfessionPage:RenderLeft()
    if not self.host then return end
    local ok = ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_Profession")
    local packs = (_G.ForeverSuiteData and _G.ForeverSuiteData.packs) or {}
    local guides = (ok and packs.prof_guides and packs.prof_guides.entries) or {}
    if (not self.selectedProf) and guides[1] then
        self.selectedProf = guides[1]
    end
    for i = 1, LEFT_ROWS do
        local row = self.leftRows[i]
        local p = guides[i]
        if p then
            local sel = (self.selectedProf and self.selectedProf.title == p.title)
            row._prof = p
            row._left:SetText((sel and "▸ " or "") .. tostring(p.title))
            local c = sel and T.TEXT.GOLD or T.TEXT.PRIMARY
            row._left:SetTextColor(c[1], c[2], c[3], 1)
            row._right:SetText(tostring(p.recipeCount or 0))
            row:SetRowStyle(sel and T.SURFACE.GOLD_TINT or { 0, 0, 0, 0 }, sel and T.BORDER.GOLD or nil, 0, 2, nil, 6)
            row:Show()
        else
            row._prof = nil
            row:Hide()
        end
    end
    self:RenderRight()
end

function ProfessionPage:Build(parent)
    self.host = parent
    local hdr = W.SectionHeader(parent, "13대 전문기술 전용 가이드 (육성 루트 · 제조법 · 교관 · 도적 독)")
    hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    local tabBar = W.PillBar(parent, {
        { value = "guide", label = "육성 가이드", width = 94 },
        { value = "recipes", label = "제조법", width = 76 },
        { value = "trainers", label = "교관·길안내", width = 96 },
    }, self.activeTab, function(v)
        ProfessionPage.activeTab = v
        ProfessionPage.rightOffset = 0
        ProfessionPage:RenderRight()
    end)
    tabBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 196, -28)
    tabBar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -28)

    local leftPane = W.Card(parent, 186, 386, nil, nil)
    leftPane:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -60)
    for i = 1, LEFT_ROWS do
        local row = W.ListRow(leftPane, 28, function(btn)
            if btn._prof then
                ProfessionPage.selectedProf = btn._prof
                ProfessionPage.rightOffset = 0
                ProfessionPage:RenderLeft()
            end
        end)
        row:SetPoint("TOPLEFT", leftPane, "TOPLEFT", 4, -(6 + (i - 1) * 28))
        row:SetPoint("TOPRIGHT", leftPane, "TOPRIGHT", -4, -(6 + (i - 1) * 28))
        self.leftRows[i] = row
    end

    local rightPane = W.Card(parent, 456, 386, nil, nil)
    rightPane:SetPoint("TOPLEFT", leftPane, "TOPRIGHT", 10, 0)
    rightPane:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 16)
    if type(rightPane.EnableMouseWheel) == "function" then
        rightPane:EnableMouseWheel(true)
        rightPane:SetScript("OnMouseWheel", function(_, delta)
            if not delta or delta == 0 then return end
            ProfessionPage.rightOffset = ProfessionPage.rightOffset + (delta > 0 and -3 or 3)
            ProfessionPage:RenderRight()
        end)
    end

    self.rightTitle = W.Label(rightPane, "", "heading", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    self.rightTitle:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 10, -10)
    self.rightTitle:SetPoint("TOPRIGHT", rightPane, "TOPRIGHT", -10, -10)

    self.guideBody = W.Label(rightPane, "", "body", T.TEXT.PRIMARY, { justifyH = "LEFT", wordWrap = true })
    if type(self.guideBody.SetJustifyV) == "function" then self.guideBody:SetJustifyV("TOP") end
    self.guideBody:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 10, -36)
    self.guideBody:SetPoint("BOTTOMRIGHT", rightPane, "BOTTOMRIGHT", -10, 10)

    for i = 1, RIGHT_ROWS do
        local row = W.ListRow(rightPane, 28, function(btn)
            local e = btn._entry
            if type(e) == "table" and type(e.mapID) == "number" and type(e.x) == "number" and type(e.y) == "number" then
                if ns.Features.NavigationHud then
                    ns.Features.NavigationHud:SetTarget(e.mapID, e.x, e.y, e.title)
                end
                ns.Api.SafeAPI.Print("교관 위치 안내: " .. tostring(e.title) .. (e.note and e.note ~= "" and (" — " .. e.note) or ""))
            end
        end)
        row:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 6, -(36 + (i - 1) * 30))
        row:SetPoint("TOPRIGHT", rightPane, "TOPRIGHT", -6, -(36 + (i - 1) * 30))
        row:Hide()
        self.rightRows[i] = row
    end
end

function ProfessionPage:OnShow()
    self:RenderLeft()
    ns.UI.CommandHub:RefreshStatusBar()
end

function ProfessionPage:OnSearch(query)
    self.lastQuery = query or ""
    self.rightOffset = 0
    self:RenderRight()
end
