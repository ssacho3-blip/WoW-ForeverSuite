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
    shopListBtn = nil,
    lastFilteredMaterials = {},
    lastCooldownSyncAt = 0,
    announcedReadyAlts = false,
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
    if type(itemID) ~= "number" or itemID <= 0 then return 0, "" end
    -- Prefer official Syndicator cross-alt inventory when ready (zero duplicate scan!)
    local syn = ns.Bridges and ns.Bridges.Syndicator
    if syn and type(syn.GetItemInventory) == "function" then
        local info, status = syn:GetItemInventory(itemID)
        if status == "OK" and type(info) == "table" then
            local total = 0
            local parts = {}
            if type(info.characters) == "table" then
                for i = 1, #info.characters do
                    local c = info.characters[i]
                    if type(c) == "table" then
                        local q = (c.bags or 0) + (c.bank or 0) + (c.mail or 0) + (c.equipped or 0)
                        if q > 0 then
                            total = total + q
                            local cname = (type(c.character) == "string" and c.character ~= "") and c.character or ("캐릭" .. tostring(i))
                            parts[#parts + 1] = cname .. ":" .. tostring(q)
                        end
                    end
                end
            end
            if type(info.warband) == "number" and info.warband > 0 then
                total = total + info.warband
                parts[#parts + 1] = "전투부대:" .. tostring(info.warband)
            elseif type(info.warband) == "table" then
                local wb = 0
                for i = 1, #info.warband do
                    local w = info.warband[i]
                    if type(w) == "number" then wb = wb + w
                    elseif type(w) == "table" then wb = wb + (w.bank or 0) end
                end
                if wb > 0 then
                    total = total + wb
                    parts[#parts + 1] = "전투부대:" .. tostring(wb)
                end
            end
            return total, table.concat(parts, ", "), "SYNDICATOR"
        end
    end
    local store = ns.Api.ProfileStore and ns.Api.ProfileStore:GetState("altMaterials")
    if type(store) ~= "table" then return 0, "", "LOCAL" end
    local total = 0
    local parts = {}
    for charName, bagMap in pairs(store) do
        if type(bagMap) == "table" and type(bagMap[itemID]) == "number" and bagMap[itemID] > 0 then
            total = total + bagMap[itemID]
            parts[#parts + 1] = tostring(charName) .. ":" .. tostring(bagMap[itemID])
        end
    end
    return total, table.concat(parts, ", "), "LOCAL"
end

function ProfessionPage:CreateMissingShoppingList()
    if ns.Api.SafeAPI.InCombat() then
        ns.Api.SafeAPI.Print("전투 중에는 경매장 쇼핑리스트를 생성할 수 없습니다.")
        return false, "IN_COMBAT"
    end
    local auc = ns.Bridges and ns.Bridges.Auctionator
    if not (auc and type(auc.CreateShoppingList) == "function") then
        ns.Api.SafeAPI.Print("Auctionator 브리지가 비활성 상태입니다.")
        return false, "API_UNAVAILABLE"
    end
    local rows = self.lastFilteredMaterials
    if type(rows) ~= "table" or #rows == 0 then
        local packs = (_G.ForeverSuiteData and _G.ForeverSuiteData.packs) or {}
        rows = packs.prof_materials and packs.prof_materials.entries or {}
    end
    local built = ns.Domain.ProfessionBrowserModel.BuildShoppingEntries(
        rows,
        function(iid)
            local owned = ProfessionPage:GetOwnedCountSummary(iid)
            return owned
        end,
        function(iid)
            return type(auc.GetAuctionPrice) == "function" and auc:GetAuctionPrice(iid) or nil
        end,
        function(iid)
            return ns.Api.GameAdapters.GetItemNameSafe and ns.Api.GameAdapters.GetItemNameSafe(iid) or nil
        end,
        40
    )
    if type(built) ~= "table" or type(built.searchStrings) ~= "table" or #built.searchStrings == 0 then
        ns.Api.SafeAPI.Print("부족한 재료 항목이 없거나 아이템 이름이 아직 캐시되지 않았습니다.")
        return false, "EMPTY"
    end
    local rawTitle = self.selectedProf and self.selectedProf.title
    local profLabel = (type(rawTitle) == "string" and rawTitle ~= "") and rawTitle or "전문기술"
    local listName = "ForeverSuite: " .. profLabel
    local ok, err = auc:CreateShoppingList(listName, built.searchStrings)
    if not ok then
        ns.Api.SafeAPI.Print("Auctionator 쇼핑리스트 생성 실패 (" .. tostring(err or "UNAVAILABLE") .. "). Auctionator 설치 여부를 확인하세요.")
        return false, err
    end
    local estTxt = (type(built.pricedCount) == "number" and built.pricedCount > 0
        and type(built.estimatedCopper) == "number" and built.estimatedCopper > 0
        and ns.Domain and ns.Domain.LedgerModel)
        and (" · 예상 경매가 " .. ns.Domain.LedgerModel.FormatCopper(built.estimatedCopper))
        or ""
    ns.Api.SafeAPI.Print("Auctionator 쇼핑리스트 생성 완료: [" .. listName .. "] (" .. tostring(#built.searchStrings) .. "종" .. estTxt .. ")")
    return true, built
end

-- Auto-record multi-day crafting cooldowns (Transmute 48h, Salt Shaker 72h, Mooncloth 96h).
-- Fail-closed: never overwrites existing timestamps on nil/secret/NaN/mono-unavailable reads.
-- Debounced (5s) & OOC-gated on spell/bag cooldown bursts; force-bypassed on PEW (announceReady=true) & PLAYER_LOGOUT (forceFlush=true).
function ProfessionPage:SyncAltCooldowns(announceReady, forceFlush)
    if not (ns.Api.ProfileStore and ns.Api.ProfileStore:CanWrite()) then
        return false, "READ_ONLY"
    end
    if (not announceReady) and (not forceFlush) and ns.Api.SafeAPI.InCombat() then
        return false, "IN_COMBAT"
    end
    local cdModel = ns.Domain and ns.Domain.AltCooldownModel
    if not cdModel then return false, "NO_MODEL" end
    local ga = ns.Api.GameAdapters
    local mono = ga.GetMonotonicTime and ga.GetMonotonicTime() or nil
    if type(mono) ~= "number" or mono ~= mono then
        return false, "UNAVAILABLE"
    end
    if (not announceReady) and (not forceFlush) and (mono - (self.lastCooldownSyncAt or 0)) < 5.0 then
        return false, "THROTTLED"
    end
    local nowUnix = ga.GetServerTimeSafe and ga.GetServerTimeSafe() or nil
    local charKey = ga.GetPlayerCharKeySafe and ga.GetPlayerCharKeySafe() or nil
    if not (nowUnix and charKey) then
        return false, "UNAVAILABLE"
    end
    self.lastCooldownSyncAt = mono

    local store = ns.Api.ProfileStore:GetState("altCooldowns")
    if type(store) ~= "table" then store = {} end
    local updated = false

    -- 1. Check known Transmute & Mooncloth spells (fail-closed: skip on nil/secret/disabled read)
    local spellIds = {}
    for sid in pairs(cdModel.SPELL_RECIPE_MAP or {}) do
        spellIds[#spellIds + 1] = sid
    end
    local known = ga.GetKnownSpellSet and ga.GetKnownSpellSet(spellIds) or {}
    local recipeRemaining = {}
    for sid, recipeId in pairs(cdModel.SPELL_RECIPE_MAP or {}) do
        if known[sid] then
            local st, dur, en
            if ga.GetSpellCooldownSafe then
                st, dur, en = ga.GetSpellCooldownSafe(sid)
            end
            local readOk = (type(st) == "number" and st == st and type(dur) == "number" and dur == dur)
            if readOk and en ~= false then
                local rem = 0
                if dur > 60 then
                    local r = (st + dur) - mono
                    if r == r and r > 0 then rem = r end
                end
                if recipeRemaining[recipeId] == nil or rem > recipeRemaining[recipeId] then
                    recipeRemaining[recipeId] = rem
                end
            end
        end
    end
    for recipeId, rem in pairs(recipeRemaining) do
        if cdModel.RecordRemaining(store, charKey, recipeId, rem, nowUnix) then
            updated = true
        end
    end

    -- 2. Check Salt Shaker (itemID 15846) if carried in bags (fail-closed: skip on nil/secret/disabled read)
    local shakerID = cdModel.SALT_SHAKER_ITEM_ID
    if type(shakerID) == "number" and ga.HasItemInBagsSafe and ga.HasItemInBagsSafe(shakerID) then
        local st, dur, en
        if ga.GetItemCooldownSafe then
            st, dur, en = ga.GetItemCooldownSafe(shakerID)
        end
        local readOk = (type(st) == "number" and st == st and type(dur) == "number" and dur == dur)
        if readOk and en ~= false then
            local rem = 0
            if dur > 60 then
                local r = (st + dur) - mono
                if r == r and r > 0 then rem = r end
            end
            if cdModel.RecordRemaining(store, charKey, "salt_shaker", rem, nowUnix) then
                updated = true
            end
        end
    end

    if updated then
        ns.Api.ProfileStore:SetState("altCooldowns", store)
    end

    -- 3. Notify once per session if any OTHER alt has a multi-day crafting cooldown ready
    if announceReady and not self.announcedReadyAlts then
        local _, _, readyList = cdModel.CountReady(store, nowUnix)
        local otherReady = {}
        for i = 1, #(readyList or {}) do
            local r = readyList[i]
            if r.charKey ~= charKey then
                otherReady[#otherReady + 1] = tostring(r.charKey) .. "(" .. tostring(r.label) .. ")"
            end
        end
        if #otherReady > 0 then
            self.announcedReadyAlts = true
            ns.Api.SafeAPI.Print("[부캐 전문기술 쿨다운 완료] " .. table.concat(otherReady, ", "))
        end
    end

    return updated, store
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
    if self.shopListBtn then
        if self.activeTab == "materials" then self.shopListBtn:Show() else self.shopListBtn:Hide() end
    end
    if self.rightScrollBar then self.rightScrollBar:SetMetrics(0, RIGHT_ROWS, 0) end

    local p = self.selectedProf
    if not p then
        self.rightTitle:SetText("좌측에서 전문기술을 선택하세요")
        return
    end
    self.rightTitle:SetText("★ " .. tostring(p.title) .. " (제조법 " .. tostring(p.recipeCount or 0) .. " · 교관 " .. tostring(p.npcCount or 0) .. ")")

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
                right = (type(r.skill) == "number" and r.skill > 0) and ("숙련 " .. tostring(r.skill)) or "-",
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
        local auc = ns.Bridges and ns.Bridges.Auctionator
        local filteredMats = {}
        for _, m in ipairs(mats) do
            if type(m.itemID) == "number" and m.itemID > 0 then
                local totalOwned, whoStr, srcTag = self:GetOwnedCountSummary(m.itemID)
                local link = ns.Api.GameAdapters.GetItemLinkSafe(m.itemID)
                local label = (type(link) == "string" and link ~= "") and link or ("재료 #" .. tostring(m.itemID))
                local hay = string.lower(label .. " " .. tostring(m.kind or "") .. " " .. tostring(m.itemID))
                if q == "" or string.find(hay, q, 1, true) then
                    filteredMats[#filteredMats + 1] = m
                    local ahPrice = (auc and type(auc.GetAuctionPrice) == "function") and auc:GetAuctionPrice(m.itemID) or nil
                    local priceTxt = (type(ahPrice) == "number" and ahPrice > 0 and ns.Domain and ns.Domain.LedgerModel)
                        and (" · 경매 " .. ns.Domain.LedgerModel.FormatCopper(ahPrice)) or ""
                    local srcNote = (srcTag == "SYNDICATOR") and "Syndicator 부캐 합산" or "가방·은행·부캐"
                    items[#items + 1] = {
                        title = label,
                        subtitle = (whoStr ~= "" and ("보유 내역(" .. srcNote .. "): " .. whoStr)) or ("분류: " .. tostring(m.kind or "재료")),
                        right = ((totalOwned > 0) and ("보유 " .. tostring(totalOwned) .. "개") or "미보유") .. priceTxt,
                        icon = ns.Api.GameAdapters.GetItemIconSafe(m.itemID) or ResolveProfIcon(p.title),
                        itemID = m.itemID,
                    }
                end
            end
        end
        self.lastFilteredMaterials = filteredMats
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

    local shopListBtn = W.Button(rightPane, "부족 재료 쇼핑리스트", 136, 22, function()
        ProfessionPage:CreateMissingShoppingList()
    end, true)
    shopListBtn:SetPoint("TOPRIGHT", rightPane, "TOPRIGHT", -10, -7)
    shopListBtn:Hide()
    self.shopListBtn = shopListBtn

    self.rightTitle = W.Label(rightPane, "", "heading", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    self.rightTitle:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 12, -10)
    self.rightTitle:SetPoint("TOPRIGHT", shopListBtn, "TOPLEFT", -8, -3)

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
                ns.Api.SafeAPI.Print("교관 위치 안내: " .. tostring(e.title) .. (e.note and e.note ~= "" and (" - " .. e.note) or ""))
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
