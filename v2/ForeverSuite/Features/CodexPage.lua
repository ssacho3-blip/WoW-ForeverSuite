-- Module: Features/CodexPage.lua
-- Responsibility: ForeverSuite v3.0 Multi-Pack LoadOnDemand Codex Browser with pooled W.IconRow
--                 (0 new frames during search!), built-in WoW item/pack icons, quality borders, W.EmptyState,
--                 C_QuestLog completion badges, and 1-click /way navigation.
-- Layer: Features (uses UI/Widgets + CompositeWidgets + Api/SafeAPI/GameAdapters only; zero raw CreateFrame).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs
local tostring = tostring
local type = type
local math_max = math.max
local math_min = math.min
local math_ceil = math.ceil
local string_lower = string.lower
local string_find = string.find

local PAGE_SIZE = 13

local TABS = {
    { value = "fishing",      label = "낚시",     addon = "ForeverSuite_Data",            width = 48, icon = "Interface\\Icons\\Trade_Fishing" },
    { value = "dungeons",     label = "던전",     addon = "ForeverSuite_Data_Dungeon",    width = 48, icon = "Interface\\Icons\\INV_Misc_Map_01" },
    { value = "dungeon_loot", label = "드랍",     addon = "ForeverSuite_Data_Dungeon",    width = 48, icon = "Interface\\Icons\\INV_Box_01" },
    { value = "bis",          label = "BiS",      addon = "ForeverSuite_Data_BiS",        width = 46, icon = "Interface\\Icons\\INV_Helmet_03" },
    { value = "item_catalog", label = "전체아이템", addon = "ForeverSuite_Data_Items",      width = 76, icon = "Interface\\Icons\\INV_Misc_Bag_10_Blue" },
    { value = "professions",  label = "전문기술",  addon = "ForeverSuite_Data_Profession", width = 66, icon = "Interface\\Icons\\Trade_BlackSmithing" },
    { value = "rewards",      label = "보상",     addon = "ForeverSuite_Data_Reward",     width = 48, icon = "Interface\\Icons\\INV_Misc_Coin_01" },
    { value = "hunter_pets",  label = "펫",       addon = "ForeverSuite_Data_Pet",        width = 42, icon = "Interface\\Icons\\Ability_Hunter_BeastTaming" },
    { value = "class_quests", label = "직업퀘",   addon = "ForeverSuite_Data_Atlas",      width = 56, icon = "Interface\\Icons\\INV_Misc_Book_09" },
    { value = "atlas_npcs",   label = "NPC",      addon = "ForeverSuite_Data_Atlas",      width = 48, icon = "Interface\\Icons\\INV_Misc_Map_01" },
    { value = "quest_tips",   label = "퀵팁·성장", addon = "ForeverSuite_Data_QuestExtra", width = 72, icon = "Interface\\Icons\\INV_Scroll_03" },
}

local TAB_BY_ID = {}
for _, t in ipairs(TABS) do
    TAB_BY_ID[t.value] = t
end

local STATUS_MESSAGES = {
    IN_COMBAT = "전투 중에는 도감 데이터팩을 불러올 수 없습니다. 비전투 후 다시 열어주세요.",
    NOT_INSTALLED = "선택한 도감 데이터팩이 설치되어 있지 않습니다.",
    DISABLED = "선택한 도감 데이터팩이 애드온 목록에서 비활성화되어 있습니다.",
    LOAD_FAILED = "도감 데이터팩을 불러오지 못했습니다.",
}

local CodexPage = {
    id = "codex",
    label = "도감 (LoD)",
    group = "combat",
    host = nil,
    rowPool = {},
    visibleRows = 0,
    activePack = "fishing",
    rewardModeFilter = "all",
    petRareOnly = false,
    petAbilityFilter = "all",
    petAbilityMap = nil,
    petSpawnCycle = {},
    pageIndex = 1,
    totalMatches = 0,
    lastQuery = "",
    lastLoadStatus = "LOADED",
    emptyState = nil,
    scrollBar = nil,
    statusLbl = nil,
    pageLbl = nil,
    prevBtn = nil,
    nextBtn = nil,
}
ns.Features.CodexPage = CodexPage

local function QualityColor(q)
    return (type(q) == "number" and T.QUALITY[q]) or T.TEXT.PRIMARY
end

function CodexPage:EnsureDataLoaded(packId)
    local pid = packId or self.activePack
    local tab = TAB_BY_ID[pid]
    local addonName = (tab and tab.addon) or "ForeverSuite_Data"
    local dataRoot = _G.ForeverSuiteData
    local existing = type(dataRoot) == "table" and type(dataRoot.packs) == "table" and dataRoot.packs[pid] or nil
    local needsFullPack = (addonName ~= "ForeverSuite_Data")
    if type(existing) == "table" and ((not needsFullPack) or existing._schema == 2) then
        self.lastLoadStatus = "LOADED"
        return true, "LOADED"
    end
    local ok, status = ns.Api.SafeAPI.LoadDataPack(addonName)
    self.lastLoadStatus = status or (ok and "LOADED" or "LOAD_FAILED")
    return ok, self.lastLoadStatus
end

local function ShowCodexTooltip(rowBtn)
    local entry = rowBtn and rowBtn._entry
    if type(entry) ~= "table" or not (_G.GameTooltip and type(_G.GameTooltip.SetOwner) == "function") then
        return
    end
    pcall(function()
        _G.GameTooltip:SetOwner(rowBtn, "ANCHOR_RIGHT")
        _G.GameTooltip:ClearLines()
        local hasItem = type(entry.itemID) == "number" and entry.itemID > 0
        if hasItem and type(_G.GameTooltip.SetHyperlink) == "function" then
            pcall(_G.GameTooltip.SetHyperlink, _G.GameTooltip, "item:" .. tostring(entry.itemID))
        end
        local qCol = QualityColor(entry.quality)
        _G.GameTooltip:AddLine(tostring(entry.title or entry.name or "항목"), qCol[1], qCol[2], qCol[3])
        if type(entry.altName) == "string" and entry.altName ~= "" then
            _G.GameTooltip:AddLine(entry.altName, T.TEXT.MUTED[1], T.TEXT.MUTED[2], T.TEXT.MUTED[3])
        end
        if type(entry.itemLevel) == "number" and entry.itemLevel > 0 then
            _G.GameTooltip:AddLine("아이템 레벨: " .. tostring(entry.itemLevel), T.TEXT.GOLD[1], T.TEXT.GOLD[2], T.TEXT.GOLD[3])
        end
        if type(entry.zone) == "string" and entry.zone ~= "" then
            _G.GameTooltip:AddLine("분류/위치: " .. entry.zone, T.TEXT.SECONDARY[1], T.TEXT.SECONDARY[2], T.TEXT.SECONDARY[3])
        end
        if type(entry.costText) == "string" and entry.costText ~= "" then
            _G.GameTooltip:AddLine("교환 비용/조건: " .. entry.costText, T.TEXT.GOLD[1], T.TEXT.GOLD[2], T.TEXT.GOLD[3])
        end
        if type(entry.note) == "string" and entry.note ~= "" then
            _G.GameTooltip:AddLine(entry.note, T.TEXT.PRIMARY[1], T.TEXT.PRIMARY[2], T.TEXT.PRIMARY[3])
        end
        if type(entry.mapID) == "number" and type(entry.x) == "number" and type(entry.y) == "number" then
            _G.GameTooltip:AddLine("클릭하여 /way 내비게이션 안내 시작", T.SEMANTIC.SUCCESS[1], T.SEMANTIC.SUCCESS[2], T.SEMANTIC.SUCCESS[3])
        end
        _G.GameTooltip:Show()
    end)
end

local function HideCodexTooltip()
    if _G.GameTooltip and type(_G.GameTooltip.Hide) == "function" then
        pcall(_G.GameTooltip.Hide, _G.GameTooltip)
    end
end

function CodexPage:EnsureRow(idx)
    if self.rowPool[idx] then
        return self.rowPool[idx]
    end
    local row = W.IconRow(self.host, 30, function(btn)
        local entry = btn._entry
        if type(entry) ~= "table" then return end
        if ns.Api.GameAdapters.IsShiftDown() and type(entry.itemID) == "number" then
            ns.Api.GameAdapters.InsertItemChatLink(entry.itemID, entry.title or entry.name)
            return
        end
        if type(entry.mapID) == "number" and type(entry.x) == "number" and type(entry.y) == "number" then
            local targetMap, targetX, targetY = entry.mapID, entry.x, entry.y
            local title = tostring(entry.title or entry.name or "항목")
            if type(entry.allLocs) == "string" and entry.allLocs ~= "" then
                local locs = ns.Domain.PetRewardModel.ParseMultiLocs(entry.allLocs)
                if #locs > 1 then
                    local key = tostring(entry.npcID or title)
                    local cIdx = ((CodexPage.petSpawnCycle[key] or 0) % #locs) + 1
                    CodexPage.petSpawnCycle[key] = cIdx
                    targetMap, targetX, targetY = locs[cIdx].mapID, locs[cIdx].x, locs[cIdx].y
                    title = title .. " (출현 " .. tostring(cIdx) .. "/" .. tostring(#locs) .. ")"
                end
            end
            local ok, status
            if ns.Features.NavigationHud then
                ok, status = ns.Features.NavigationHud:SetTarget(targetMap, targetX, targetY, title)
            else
                ok, status = ns.Api.NavPort.SetWaypoint(targetMap, targetX, targetY)
            end
            if status == "ARRIVED" then
                ns.Api.SafeAPI.Print("이미 목적지 근처입니다: " .. title)
            elseif ok and status == "APPLIED" then
                ns.Api.SafeAPI.Print("도감 내비게이션 연결: " .. title)
            elseif status == "DEFERRED" then
                ns.Api.SafeAPI.Print("화살표 활성화 (기본 핀은 전투/지도 종료 후 적용): " .. title)
            elseif status == "MAP_NOT_SUPPORTED" then
                ns.Api.SafeAPI.Print("화살표 활성화 (기본 핀 미지원 지역): " .. title)
            else
                ns.Api.SafeAPI.Print("내비게이션 연결에 실패했습니다: " .. title .. " (" .. tostring(status or "ERROR") .. ")")
            end
        elseif type(entry.note) == "string" and entry.note ~= "" then
            ns.Api.SafeAPI.Print(tostring(entry.title or "도감") .. " — " .. entry.note)
        end
    end)
    row:SetTooltipHandler(ShowCodexTooltip, HideCodexTooltip)
    self.rowPool[idx] = row
    return row
end

function CodexPage:StepPage(delta)
    local maxPage = math_max(1, math_ceil((self.totalMatches or 0) / PAGE_SIZE))
    local nextP = math_max(1, math_min(maxPage, (self.pageIndex or 1) + delta))
    if nextP ~= self.pageIndex then
        self.pageIndex = nextP
        self:RenderPack(self.lastQuery)
    end
end

function CodexPage:RenderPack(query)
    if not self.host then return end
    local q = string_lower(tostring(query or ""))
    if q ~= self.lastQuery then
        self.lastQuery = q
        self.pageIndex = 1
    end

    for i = 1, #self.rowPool do
        self.rowPool[i]:Hide()
    end
    self.visibleRows = 0
    self.totalMatches = 0

    local dataRoot = _G.ForeverSuiteData
    if type(dataRoot) ~= "table" or type(dataRoot.packs) ~= "table" then
        if self.emptyState then
            self.emptyState:SetMessage("도감 데이터팩 미로드", STATUS_MESSAGES[self.lastLoadStatus] or "ForeverSuite_Data (LoD) 팩을 불러오지 못했습니다.")
            self.emptyState:Show()
        end
        if self.statusLbl then
            self.statusLbl:SetText(STATUS_MESSAGES[self.lastLoadStatus] or "ForeverSuite_Data (LoD) 팩을 불러오지 못했습니다.")
        end
        if self.pageLbl then self.pageLbl:SetText("") end
        return
    end

    local pack = dataRoot.packs[self.activePack]
    if not pack then
        local msg = STATUS_MESSAGES[self.lastLoadStatus]
            or ("선택한 도감 데이터팩(" .. tostring(self.activePack) .. ")이 아직 빌드되지 않았습니다.")
        if self.emptyState then
            self.emptyState:SetMessage("데이터팩 없음", msg)
            self.emptyState:Show()
        end
        if self.statusLbl then self.statusLbl:SetText(msg) end
        if self.pageLbl then self.pageLbl:SetText("") end
        return
    end

    if pack._schema == 2 and pack._complete == false then
        if self.emptyState then
            self.emptyState:SetMessage("샤드 불완전", "재설치를 권장합니다.")
            self.emptyState:Show()
        end
        if self.statusLbl then
            self.statusLbl:SetText("도감 샤드가 불완전합니다 (" .. tostring(pack._shardCount or 0) .. "/" .. tostring(pack._totalShards or 0) .. "). 재설치를 권장합니다.")
        end
        if self.pageLbl then self.pageLbl:SetText("") end
        return
    end

    local tab = TAB_BY_ID[self.activePack]
    local isFallbackSummary = (tab and tab.addon ~= "ForeverSuite_Data" and pack._schema ~= 2)

    local cacheKey = tostring(self.activePack) .. "|" .. tostring(#(pack.entries or {})) .. "|" .. tostring(self.rewardModeFilter) .. "|" .. tostring(self.petRareOnly) .. "|" .. tostring(self.petAbilityFilter) .. "|" .. q
    local matches
    if self._cacheKey == cacheKey and type(self._cachedMatches) == "table" then
        matches = self._cachedMatches
    else
        if self.activePack == "hunter_pets" then
            if (not self.petAbilityMap) and dataRoot.packs.pet_abilities and type(dataRoot.packs.pet_abilities.entries) == "table" then
                self.petAbilityMap = ns.Domain.PetRewardModel.IndexAbilitiesByID(dataRoot.packs.pet_abilities.entries)
            end
            matches = ns.Domain.PetRewardModel.FilterPets(pack.entries, {
                rareOnly = self.petRareOnly,
                abilityFilter = self.petAbilityFilter,
                abilityMap = self.petAbilityMap,
                query = q,
            })
        elseif self.activePack == "rewards" then
            matches = ns.Domain.PetRewardModel.FilterRewards(pack.entries, { mode = self.rewardModeFilter, query = q })
        else
            matches = {}
            for _, entry in ipairs(pack.entries or {}) do
                local title = tostring(entry.title or entry.fish or entry.boss or entry.name or "항목")
                local sub = tostring(entry.zone or entry.slot or entry.category or "")
                local alt = tostring(entry.altName or "")
                local note = tostring(entry.note or "")
                if q == "" then
                    matches[#matches + 1] = entry
                else
                    local hay = string_lower(title .. " " .. sub .. " " .. alt .. " " .. note)
                    if string_find(hay, q, 1, true) then
                        matches[#matches + 1] = entry
                    end
                end
            end
        end
        self._cacheKey = cacheKey
        self._cachedMatches = matches
    end

    self.totalMatches = #matches
    if self.totalMatches == 0 then
        if self.emptyState then
            self.emptyState:SetMessage("검색 결과 없음", "입력하신 조건과 일치하는 도감 항목이 없습니다.")
            self.emptyState:Show()
        end
        if self.pageLbl then self.pageLbl:SetText("0 / 0") end
        if self.statusLbl then
            self.statusLbl:SetText((pack.title or self.activePack) .. " · 0건 일치")
        end
        return
    end

    if self.emptyState then self.emptyState:Hide() end
    local maxPage = math_max(1, math_ceil(self.totalMatches / PAGE_SIZE))
    if self.pageIndex > maxPage then self.pageIndex = maxPage end
    if self.pageIndex < 1 then self.pageIndex = 1 end

    local startIdx = (self.pageIndex - 1) * PAGE_SIZE + 1
    local endIdx = math_min(self.totalMatches, startIdx + PAGE_SIZE - 1)
    local hasSubBar = (self.activePack == "rewards" or self.activePack == "hunter_pets")
    local y = hasSubBar and 92 or 66
    local rightMargin = (self.totalMatches > PAGE_SIZE) and -14 or 0
    local shown = 0
    local fallbackIcon = (tab and tab.icon) or T.ICON.FALLBACK
    for idx = startIdx, endIdx do
        local entry = matches[idx]
        shown = shown + 1
        local row = self:EnsureRow(shown)
        row._entry = entry
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", self.host, "TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", self.host, "TOPRIGHT", rightMargin, -y)

        local title = tostring(entry.title or entry.fish or entry.boss or entry.name or "항목")
        if type(entry.questID) == "number" and entry.questID > 0 then
            local comp = ns.Api.GameAdapters.IsQuestCompleted(entry.questID)
            local tag = (comp == true) and "[완료] " or ((comp == false) and "[미완료] " or "[확인 불가] ")
            title = tag .. title
        elseif type(entry.mapID) == "number" and type(entry.x) == "number" then
            title = "▸ " .. title
        end

        local qCol = QualityColor(entry.quality)
        local sub = tostring(entry.zone or entry.slot or entry.category or "")
        if type(entry.costText) == "string" and entry.costText ~= "" then
            sub = sub .. (sub ~= "" and " · " or "") .. entry.costText
        elseif self.activePack == "hunter_pets" and self.petAbilityMap and type(entry.abilitiesCsv) == "string" and entry.abilitiesCsv ~= "" then
            local abSum = ns.Domain.PetRewardModel.ResolveAbilitySummary(entry.abilitiesCsv, self.petAbilityMap)
            if abSum ~= "" then sub = sub .. " · [" .. abSum .. "]" end
        end
        if type(entry.itemLevel) == "number" and entry.itemLevel > 0 and not string_find(sub, "iLvl", 1, true) then
            sub = sub .. (sub ~= "" and " · " or "") .. "iLvl " .. tostring(entry.itemLevel)
        end
        local iconTex = (type(entry.itemID) == "number" and ns.Api.GameAdapters.GetItemIconSafe(entry.itemID)) or fallbackIcon

        row:SetData({
            icon = iconTex,
            borderCol = (type(entry.quality) == "number" and entry.quality >= 2) and qCol or T.BORDER.HAIRLINE,
            title = title,
            titleCol = qCol,
            rightText = sub,
            rightCol = T.TEXT.SECONDARY,
            sepCol = T.BORDER.SUBTLE,
        })
        row:Show()
        y = y + 32
    end
    self.visibleRows = shown

    if self.scrollBar then
        self.scrollBar:ClearAllPoints()
        self.scrollBar:SetPoint("TOPRIGHT", self.host, "TOPRIGHT", -2, -(hasSubBar and 92 or 66))
        self.scrollBar:SetPoint("BOTTOMRIGHT", self.host, "BOTTOMRIGHT", -2, 30)
        self.scrollBar:SetMetrics(self.pageIndex - 1, 1, maxPage)
    end

    if self.pageLbl then
        self.pageLbl:SetText(tostring(self.pageIndex) .. " / " .. tostring(maxPage))
    end
    if self.statusLbl then
        local fallbackTag = isFallbackSummary
            and (" [요약본 · 풀 팩 상태: " .. tostring(STATUS_MESSAGES[self.lastLoadStatus] or self.lastLoadStatus) .. "]") or ""
        self.statusLbl:SetText(
            (pack.title or self.activePack) .. " · 전체 " .. tostring(self.totalMatches) .. "건 중 "
            .. tostring(shown) .. "건 표시 (출처: " .. tostring(pack.source or "Curated") .. ")" .. fallbackTag
        )
    end
end

function CodexPage:Build(parent)
    self.host = parent
    if type(parent.EnableMouseWheel) == "function" then
        parent:EnableMouseWheel(true)
        local prevWheel = type(parent.GetScript) == "function" and parent:GetScript("OnMouseWheel") or nil
        parent:SetScript("OnMouseWheel", function(f, delta)
            if type(prevWheel) == "function" then pcall(prevWheel, f, delta) end
            if not delta or delta == 0 then return end
            CodexPage:StepPage(delta > 0 and -1 or 1)
        end)
    end

    local hdr = W.SectionHeader(parent, "ForeverSuite 통합 도감 (8대 LoadOnDemand 풀 DB · 내장 아이콘)")
    hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    local bar = W.FlowPillGroup(parent, TABS, self.activePack, 760, function(v)
        CodexPage.activePack = v
        CodexPage.pageIndex = 1
        CodexPage:SyncSubFilters()
        CodexPage:EnsureDataLoaded(v)
        CodexPage:RenderPack(CodexPage.lastQuery)
        ns.UI.CommandHub:RefreshStatusBar()
    end)
    bar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -30)
    self.packBar = bar

    -- Pre-allocate all PAGE_SIZE rows up front so OnSearch creates ZERO new frames!
    for i = 1, PAGE_SIZE do
        self:EnsureRow(i):Hide()
    end

    local rewBar = W.PillBar(parent, {
        { value = "all",        label = "전체 보상", width = 76 },
        { value = "honor",      label = "명예(PvP)", width = 82 },
        { value = "reputation", label = "평판",      width = 56 },
        { value = "merchant",   label = "상인 상자", width = 78 },
    }, self.rewardModeFilter, function(v)
        CodexPage.rewardModeFilter = v
        CodexPage.pageIndex = 1
        CodexPage:RenderPack(CodexPage.lastQuery)
    end)
    rewBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -60)
    rewBar:SetWidth(330)
    rewBar:Hide()

    local petRareTgl = W.Toggle(parent, "★ 희귀만", self.petRareOnly, function(v)
        CodexPage.petRareOnly = v
        CodexPage.pageIndex = 1
        CodexPage:RenderPack(CodexPage.lastQuery)
        return true
    end)
    petRareTgl:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -60)
    petRareTgl:SetWidth(96)
    petRareTgl:Hide()

    local petAbBar = W.PillBar(parent, {
        { value = "all",   label = "전체기술", width = 62 },
        { value = "물기",  label = "물기",    width = 46 },
        { value = "할퀴기", label = "할퀴기",  width = 54 },
        { value = "질주",  label = "질주",    width = 46 },
        { value = "급강하", label = "급강하",  width = 54 },
        { value = "비명",  label = "비명",    width = 46 },
        { value = "돌진",  label = "돌진",    width = 46 },
    }, self.petAbilityFilter, function(v)
        CodexPage.petAbilityFilter = v
        CodexPage.pageIndex = 1
        CodexPage:RenderPack(CodexPage.lastQuery)
    end)
    petAbBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 104, -60)
    petAbBar:SetWidth(420)
    petAbBar:Hide()

    self.rewBar = rewBar
    self.petRareTgl = petRareTgl
    self.petAbBar = petAbBar

    local empty = W.EmptyState(parent, { title = "도감 항목 없음", desc = "" })
    empty:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -92)
    empty:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 30)
    self.emptyState = empty

    local sb = W.ScrollBar(parent, 400, function(newOff)
        local targetPage = newOff + 1
        if targetPage ~= CodexPage.pageIndex then
            CodexPage.pageIndex = targetPage
            CodexPage:RenderPack(CodexPage.lastQuery)
        end
    end)
    sb:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -2, -66)
    sb:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -2, 30)
    self.scrollBar = sb

    local prevBtn = W.MiniButton(parent, "◀ 이전", 56, 22, function()
        CodexPage:StepPage(-1)
    end, "이전 페이지")
    prevBtn:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -124, 2)

    local pageLbl = W.Label(parent, "1 / 1", "mono", T.TEXT.GOLD, { justifyH = "CENTER", wordWrap = false })
    pageLbl:SetPoint("LEFT", prevBtn, "RIGHT", 4, 0)
    pageLbl:SetWidth(56)

    local nextBtn = W.MiniButton(parent, "다음 ▶", 56, 22, function()
        CodexPage:StepPage(1)
    end, "다음 페이지")
    nextBtn:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 2)

    local st = W.Label(parent, "", "small", T.TEXT.MUTED, { justifyH = "LEFT", wordWrap = false })
    st:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 5)
    st:SetPoint("RIGHT", prevBtn, "LEFT", -8, 0)

    self.statusLbl = st
    self.pageLbl = pageLbl
    self.prevBtn = prevBtn
    self.nextBtn = nextBtn
end

function CodexPage:SyncSubFilters()
    if self.rewBar then
        if self.activePack == "rewards" then self.rewBar:Show() else self.rewBar:Hide() end
    end
    if self.petRareTgl then
        if self.activePack == "hunter_pets" then self.petRareTgl:Show() else self.petRareTgl:Hide() end
    end
    if self.petAbBar then
        if self.activePack == "hunter_pets" then self.petAbBar:Show() else self.petAbBar:Hide() end
    end
end

function CodexPage:SelectPack(packId)
    if type(packId) ~= "string" or not TAB_BY_ID[packId] then return false end
    self.activePack = packId
    self.pageIndex = 1
    if self.packBar and type(self.packBar.SetValue) == "function" then
        self.packBar:SetValue(packId, true)
    end
    self:SyncSubFilters()
    self:EnsureDataLoaded(packId)
    self:RenderPack(self.lastQuery)
    ns.UI.CommandHub:RefreshStatusBar()
    return true
end

function CodexPage:OnShow()
    self:SyncSubFilters()
    self:EnsureDataLoaded(self.activePack)
    self:RenderPack("")
    ns.UI.CommandHub:RefreshStatusBar()
end

function CodexPage:OnSearch(query)
    self:RenderPack(query)
end
