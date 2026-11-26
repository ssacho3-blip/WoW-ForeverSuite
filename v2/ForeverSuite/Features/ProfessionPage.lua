-- Module: Features/ProfessionPage.lua
-- Responsibility: ForeverSuite v3.0 13-Profession Guide Page (13 built-in WoW profession icons,
--                 W.ScrollText full leveling guides without truncation, W.IconRow recipes & trainers + W.ScrollBar).
-- Layer: Features (uses UI/Widgets + CompositeWidgets + Domain/ProfessionBrowserModel + Api/SafeAPI/GameAdapters).
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
local RIGHT_ROWS = 12

local ProfessionPage = {
    id = "professions",
    label = "전문기술",
    group = "life",
    host = nil,
    activeTab = "guide", -- guide | recipes | trainers | materials | picks
    selectedProf = nil,
    rightOffset = 0,
    lastQuery = "",
    leftRows = {},
    rightRows = {},
    rightScrollBar = nil,
}
ns.Features.ProfessionPage = ProfessionPage

-- F5: Read-only bag & bank material cross-character ledger (zero Baganator/Syndicator UI conflict!)
function ProfessionPage:RecordBagBankMaterials(includeBank)
    if not (ns.Api.ProfileStore and ns.Api.ProfileStore:CanWrite()) then return false end
    local pName = ns.Api.GameAdapters.GetPlayerName()
    if not pName then return false end
    local counts = ns.Api.GameAdapters.ScanBagsAndBankCounts(includeBank == true)
    local store = ns.Api.ProfileStore:GetState("altMaterials")
    if type(store) ~= "table" then store = {} end
    local charRec = type(store[pName]) == "table" and store[pName] or {}
    if includeBank then
        charRec = counts
    else
        for iid, qty in pairs(counts) do
            charRec[iid] = qty
        end
    end
    store[pName] = charRec
    return ns.Api.ProfileStore:SetState("altMaterials", store) == true
end

function ProfessionPage:GetOwnedCountSummary(itemID)
    local store = ns.Api.ProfileStore and ns.Api.ProfileStore:GetState("altMaterials")
    if type(store) ~= "table" or type(itemID) ~= "number" or itemID <= 0 then return 0, "" end
    local total = 0
    local parts = {}
    for charName, bagMap in pairs(store) do
        if type(bagMap) == "table" and type(bagMap[itemID]) == "number" and bagMap[itemID] > 0 then
            total = total + bagMap[itemID]
            parts[#parts + 1] = tostring(charName) .. ":" .. tostring(bagMap[itemID])
        end
    end
    return total, table.concat(parts, ", ")
end

local function ResolveProfIcon(title)
    if type(title) == "string" and T.ICON and T.ICON.PROF_TEX and T.ICON.PROF_TEX[title] then
        return T.ICON.PROF_TEX[title]
    end
    return "Interface\\Icons\\Trade_BlackSmithing"
end

function ProfessionPage:RenderRight()
    if not (self.host and self.guideBody and self.rightTitle) then return end
    for i = 1, RIGHT_ROWS do
        if self.rightRows[i] then self.rightRows[i]:Hide() end
    end
    self.guideBody:Hide()
    if self.rightScrollBar then self.rightScrollBar:SetMetrics(0, RIGHT_ROWS, 0) end

    local p = self.selectedProf
    if not p then
        self.rightTitle:SetText("좌측에서 전문기술을 선택하세요")
        return
    end
    self.rightTitle:SetText("✦ " .. tostring(p.title) .. " (제조법 " .. tostring(p.recipeCount or 0) .. " · 교관 " .. tostring(p.npcCount or 0) .. ")")

    if self.activeTab == "guide" then
        local parts = {}
        if type(p.summary) == "string" and p.summary ~= "" then parts[#parts + 1] = "■ 개요\n" .. p.summary end
        if type(p.startGuide) == "string" and p.startGuide ~= "" then parts[#parts + 1] = "\n■ 시작 방법\n" .. p.startGuide end
        if type(p.routesText) == "string" and p.routesText ~= "" then parts[#parts + 1] = "\n■ 숙련 구간별 육성 루트\n" .. p.routesText end
        if type(p.masterGuide) == "string" and p.masterGuide ~= "" then parts[#parts + 1] = "\n■ 대가(300) 안내\n" .. p.masterGuide end
        if type(p.tips) == "string" and p.tips ~= "" then parts[#parts + 1] = "\n■ 실전 팁\n" .. p.tips end
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
                title = tostring(r.title),
                subtitle = (r.note and r.note ~= "") and r.note or nil,
                right = (type(r.skill) == "number" and r.skill > 0) and ("숙련 " .. tostring(r.skill)) or "—",
                icon = (type(r.itemID) == "number") and ns.Api.GameAdapters.GetItemIconSafe(r.itemID) or ResolveProfIcon(p.title),
                itemID = r.itemID,
            }
        end
    elseif self.activeTab == "trainers" then
        local list = ns.Domain.ProfessionBrowserModel.FilterTrainers(
            packs.prof_trainers and packs.prof_trainers.entries or {}, p, self.lastQuery
        )
        for _, t in ipairs(list) do
            items[#items + 1] = {
                title = tostring(t.title),
                subtitle = (t.note and t.note ~= "") and t.note or "클릭하여 /way 교관 길안내",
                right = tostring(t.zone or ""),
                icon = "Interface\\Icons\\INV_Misc_Map_01",
                entry = t,
            }
        end
    elseif self.activeTab == "materials" then
        local mats = packs.prof_materials and packs.prof_materials.entries or {}
        local q = string.lower(tostring(self.lastQuery or ""))
        for _, m in ipairs(mats) do
            if type(m.itemID) == "number" and m.itemID > 0 then
                local totalOwned, whoStr = self:GetOwnedCountSummary(m.itemID)
                local link = ns.Api.GameAdapters.GetItemLinkSafe(m.itemID)
                local label = (type(link) == "string" and link ~= "") and link or ("재료 #" .. tostring(m.itemID))
                local hay = string.lower(label .. " " .. tostring(m.kind or "") .. " " .. tostring(m.itemID))
                if q == "" or string.find(hay, q, 1, true) then
                    items[#items + 1] = {
                        title = label,
                        subtitle = (whoStr ~= "" and ("보유 내역(가방·은행·부캐): " .. whoStr)) or ("분류: " .. tostring(m.kind or "재료")),
                        right = (totalOwned > 0) and ("보유 " .. tostring(totalOwned) .. "개") or "미보유",
                        icon = ns.Api.GameAdapters.GetItemIconSafe(m.itemID) or ResolveProfIcon(p.title),
                        itemID = m.itemID,
                    }
                end
            end
        end
    elseif self.activeTab == "picks" then
        local picks = packs.prof_recommendations and packs.prof_recommendations.entries or {}
        local q = string.lower(tostring(self.lastQuery or ""))
        for _, pk in ipairs(picks) do
            local link = (type(pk.itemID) == "number") and ns.Api.GameAdapters.GetItemLinkSafe(pk.itemID) or nil
            local title = (type(link) == "string" and link ~= "") and link or ("추천 품목 #" .. tostring(pk.itemID or 0))
            local hay = string.lower(title .. " " .. tostring(pk.label or "") .. " " .. tostring(pk.reason or ""))
            if q == "" or string.find(hay, q, 1, true) then
                items[#items + 1] = {
                    title = "[" .. tostring(pk.label or "추천") .. "] " .. title,
                    subtitle = tostring(pk.reason or ""),
                    right = "Shift+클릭 링크",
                    icon = (type(pk.itemID) == "number") and ns.Api.GameAdapters.GetItemIconSafe(pk.itemID) or ResolveProfIcon(p.title),
                    itemID = pk.itemID,
                }
            end
        end
    end

    local total = #items
    local maxOff = math_max(0, total - RIGHT_ROWS)
    self.rightOffset = math_max(0, math_min(maxOff, self.rightOffset))
    for i = 1, RIGHT_ROWS do
        local row = self.rightRows[i]
        local d = items[self.rightOffset + i]
        if d then
            row:SetData({
                icon = d.icon,
                borderCol = T.BORDER.GOLD_SOFT,
                title = d.title,
                subtitle = d.subtitle,
                rightText = d.right,
                rightCol = T.TEXT.GOLD,
                sepCol = T.BORDER.SUBTLE,
            })
            row._entry = d.entry
            row._itemID = d.itemID
            row._title = d.title
            row:Show()
        else
            row._entry = nil
            row._itemID = nil
            row:Hide()
        end
    end
    if self.rightScrollBar then
        self.rightScrollBar:SetMetrics(self.rightOffset, RIGHT_ROWS, total)
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
            row:SetData({
                icon = ResolveProfIcon(p.title),
                borderCol = sel and T.BORDER.GOLD or T.BORDER.HAIRLINE,
                title = tostring(p.title),
                titleCol = sel and T.TEXT.GOLD or T.TEXT.PRIMARY,
                rightText = tostring(p.recipeCount or 0),
                rightCol = T.TEXT.MUTED,
                selected = sel,
            })
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
    local hdr = W.SectionHeader(parent, "13대 전문기술 전용 가이드 (아이콘 목록 · 스크롤 육성 루트 · 제조법 · 교관)")
    hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    local tabBar = W.PillBar(parent, {
        { value = "guide",     label = "육성 가이드", width = 88 },
        { value = "recipes",   label = "제조법",      width = 66 },
        { value = "materials", label = "재료·은행",   width = 76 },
        { value = "picks",     label = "추천 품목",   width = 76 },
        { value = "trainers",  label = "교관·길안내", width = 88 },
    }, self.activeTab, function(v)
        ProfessionPage.activeTab = v
        ProfessionPage.rightOffset = 0
        ProfessionPage:RenderRight()
    end)
    tabBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 224, -28)
    tabBar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -28)

    local leftPane = W.Card(parent, 214, 470)
    leftPane:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -60)
    leftPane:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 14)
    for i = 1, LEFT_ROWS do
        local row = W.IconRow(leftPane, 34, function(btn)
            if btn._prof then
                ProfessionPage.selectedProf = btn._prof
                ProfessionPage.rightOffset = 0
                ProfessionPage:RenderLeft()
            end
        end)
        row:SetPoint("TOPLEFT", leftPane, "TOPLEFT", 4, -(6 + (i - 1) * 35))
        row:SetPoint("TOPRIGHT", leftPane, "TOPRIGHT", -4, -(6 + (i - 1) * 35))
        self.leftRows[i] = row
    end

    local rightPane = W.Card(parent, 544, 470)
    rightPane:SetPoint("TOPLEFT", leftPane, "TOPRIGHT", 10, 0)
    rightPane:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 14)
    if type(rightPane.EnableMouseWheel) == "function" then
        rightPane:EnableMouseWheel(true)
        rightPane:SetScript("OnMouseWheel", function(_, delta)
            if not delta or delta == 0 then return end
            ProfessionPage.rightOffset = ProfessionPage.rightOffset + (delta > 0 and -3 or 3)
            ProfessionPage:RenderRight()
        end)
    end

    self.rightTitle = W.Label(rightPane, "", "heading", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    self.rightTitle:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 12, -10)
    self.rightTitle:SetPoint("TOPRIGHT", rightPane, "TOPRIGHT", -12, -10)

    self.guideBody = W.ScrollText(rightPane, 520, 420, { lineHeight = 18 })
    self.guideBody:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 10, -36)
    self.guideBody:SetPoint("BOTTOMRIGHT", rightPane, "BOTTOMRIGHT", -10, 10)

    for i = 1, RIGHT_ROWS do
        local row = W.IconRow(rightPane, 34, function(btn)
            local e = btn._entry
            if type(e) == "table" and type(e.mapID) == "number" and type(e.x) == "number" and type(e.y) == "number" then
                if ns.Features.NavigationHud then
                    ns.Features.NavigationHud:SetTarget(e.mapID, e.x, e.y, e.title)
                end
                ns.Api.SafeAPI.Print("교관 위치 안내: " .. tostring(e.title) .. (e.note and e.note ~= "" and (" — " .. e.note) or ""))
                return
            end
            if type(btn._itemID) == "number" and ns.Api.GameAdapters.IsShiftDown() then
                ns.Api.GameAdapters.InsertItemChatLink(btn._itemID, btn._title)
            end
        end)
        row:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 6, -(36 + (i - 1) * 35))
        row:SetPoint("TOPRIGHT", rightPane, "TOPRIGHT", -16, -(36 + (i - 1) * 35))
        row:Hide()
        self.rightRows[i] = row
    end

    local rsb = W.ScrollBar(rightPane, 420, function(newOff)
        ProfessionPage.rightOffset = newOff
        ProfessionPage:RenderRight()
    end)
    rsb:SetPoint("TOPRIGHT", rightPane, "TOPRIGHT", -3, -36)
    rsb:SetPoint("BOTTOMRIGHT", rightPane, "BOTTOMRIGHT", -3, 10)
    self.rightScrollBar = rsb
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
