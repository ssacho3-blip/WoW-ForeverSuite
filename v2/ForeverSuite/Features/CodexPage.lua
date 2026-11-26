-- Module: Features/CodexPage.lua
-- Responsibility: Full Multi-Pack LoadOnDemand Codex Browser (Dungeons, Loot, BiS, Professions, Rewards, Hunter Pets,
--                 Class Quests, Service NPCs, Fishing) with search, pagination, quality coloring, real item tooltips,
--                 C_QuestLog.IsQuestFlaggedCompleted status badges, and 1-click /way navigation.
-- Layer: Features (uses UI/Widgets + Api/SafeAPI/GameAdapters only; zero raw CreateFrame).
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

local QUALITY_COLORS = {
    [0] = { 0.62, 0.62, 0.62, 1.0 },
    [1] = T.TEXT.PRIMARY,
    [2] = { 0.12, 0.90, 0.25, 1.0 },
    [3] = { 0.28, 0.64, 1.00, 1.0 },
    [4] = { 0.72, 0.36, 0.98, 1.0 },
    [5] = { 1.00, 0.54, 0.10, 1.0 },
}

local TABS = {
    { value = "fishing", label = "낚시", addon = "ForeverSuite_Data", width = 54 },
    { value = "dungeons", label = "던전", addon = "ForeverSuite_Data_Dungeon", width = 54 },
    { value = "dungeon_loot", label = "드랍", addon = "ForeverSuite_Data_Dungeon", width = 54 },
    { value = "bis", label = "BiS", addon = "ForeverSuite_Data_BiS", width = 50 },
    { value = "professions", label = "전문기술", addon = "ForeverSuite_Data_Profession", width = 68 },
    { value = "rewards", label = "보상", addon = "ForeverSuite_Data_Reward", width = 54 },
    { value = "hunter_pets", label = "펫", addon = "ForeverSuite_Data_Pet", width = 46 },
    { value = "class_quests", label = "직업퀘", addon = "ForeverSuite_Data_Atlas", width = 60 },
    { value = "atlas_npcs", label = "NPC", addon = "ForeverSuite_Data_Atlas", width = 52 },
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
    label = "도감 (Codex)",
    host = nil,
    rowPool = {},
    visibleRows = 0,
    activePack = "fishing",
    rewardModeFilter = "all",
    petRareOnly = false,
    petSpawnCycle = {},
    pageIndex = 1,
    totalMatches = 0,
    lastQuery = "",
    lastLoadStatus = "LOADED",
    statusLbl = nil,
    pageLbl = nil,
    prevBtn = nil,
    nextBtn = nil,
}
ns.Features.CodexPage = CodexPage

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
        local qCol = QUALITY_COLORS[entry.quality or 1] or T.TEXT.GOLD
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
    local row = W.ListRow(self.host, 24, function(btn)
        local entry = btn._entry
        if type(entry) ~= "table" then
            return
        end
        if type(entry.mapID) == "number" and type(entry.x) == "number" and type(entry.y) == "number" then
            local targetMap, targetX, targetY = entry.mapID, entry.x, entry.y
            local title = tostring(entry.title or entry.name or "항목")
            -- KPI-4: For Hunter Pets with multiple spawn locations, cycle through all observed coords on each click!
            if type(entry.allLocs) == "string" and entry.allLocs ~= "" then
                local locs = ns.Domain.PetRewardModel.ParseMultiLocs(entry.allLocs)
                if #locs > 1 then
                    local key = tostring(entry.npcID or title)
                    local idx = ((CodexPage.petSpawnCycle[key] or 0) % #locs) + 1
                    CodexPage.petSpawnCycle[key] = idx
                    targetMap, targetX, targetY = locs[idx].mapID, locs[idx].x, locs[idx].y
                    title = title .. " (출현 " .. tostring(idx) .. "/" .. tostring(#locs) .. ")"
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
    if not self.host then
        return
    end
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
        if self.statusLbl then
            self.statusLbl:SetText(STATUS_MESSAGES[self.lastLoadStatus] or "ForeverSuite_Data (LoD) 팩을 불러오지 못했습니다.")
        end
        if self.pageLbl then self.pageLbl:SetText("") end
        return
    end

    local pack = dataRoot.packs[self.activePack]
    if not pack then
        if self.statusLbl then
            local msg = STATUS_MESSAGES[self.lastLoadStatus]
                or ("선택한 도감 데이터팩(" .. tostring(self.activePack) .. ")이 아직 빌드되지 않았습니다.")
            self.statusLbl:SetText(msg)
        end
        if self.pageLbl then self.pageLbl:SetText("") end
        return
    end

    if pack._schema == 2 and pack._complete == false then
        if self.statusLbl then
            self.statusLbl:SetText("도감 샤드가 불완전합니다 (" .. tostring(pack._shardCount or 0) .. "/" .. tostring(pack._totalShards or 0) .. "). 재설치를 권장합니다.")
        end
        if self.pageLbl then self.pageLbl:SetText("") end
        return
    end

    local tab = TAB_BY_ID[self.activePack]
    local isFallbackSummary = (tab and tab.addon ~= "ForeverSuite_Data" and pack._schema ~= 2)

    local cacheKey = tostring(self.activePack) .. "|" .. tostring(#(pack.entries or {})) .. "|" .. tostring(self.rewardModeFilter) .. "|" .. tostring(self.petRareOnly) .. "|" .. q
    local matches
    if self._cacheKey == cacheKey and type(self._cachedMatches) == "table" then
        matches = self._cachedMatches
    else
        if self.activePack == "hunter_pets" then
            matches = ns.Domain.PetRewardModel.FilterPets(pack.entries, { rareOnly = self.petRareOnly, query = q })
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
    local maxPage = math_max(1, math_ceil(self.totalMatches / PAGE_SIZE))
    if self.pageIndex > maxPage then self.pageIndex = maxPage end
    if self.pageIndex < 1 then self.pageIndex = 1 end

    local startIdx = (self.pageIndex - 1) * PAGE_SIZE + 1
    local endIdx = math_min(self.totalMatches, startIdx + PAGE_SIZE - 1)
    local hasSubBar = (self.activePack == "rewards" or self.activePack == "hunter_pets")
    local y = hasSubBar and 88 or 66
    local shown = 0
    for idx = startIdx, endIdx do
        local entry = matches[idx]
        shown = shown + 1
        local row = self:EnsureRow(shown)
        row._entry = entry
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", self.host, "TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", self.host, "TOPRIGHT", 0, -y)

        local title = tostring(entry.title or entry.fish or entry.boss or entry.name or "항목")
        if type(entry.questID) == "number" and entry.questID > 0 then
            local comp = ns.Api.GameAdapters.IsQuestCompleted(entry.questID)
            local tag = (comp == true) and "[완료] " or ((comp == false) and "[미완료] " or "[확인 불가] ")
            title = tag .. title
        elseif type(entry.mapID) == "number" and type(entry.x) == "number" then
            title = "▸ " .. title
        end

        local qCol = QUALITY_COLORS[entry.quality or 1] or T.TEXT.PRIMARY
        row._left:SetText(title)
        row._left:SetTextColor(qCol[1], qCol[2], qCol[3], 1)

        local sub = tostring(entry.zone or entry.slot or entry.category or "")
        if type(entry.itemLevel) == "number" and entry.itemLevel > 0 and not string_find(sub, "iLvl", 1, true) then
            sub = sub .. (sub ~= "" and " · " or "") .. "iLvl " .. tostring(entry.itemLevel)
        end
        row._right:SetText(sub)
        row._right:SetTextColor(T.TEXT.SECONDARY[1], T.TEXT.SECONDARY[2], T.TEXT.SECONDARY[3], 1)
        row:Show()
        y = y + 26
    end
    self.visibleRows = shown

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
        parent:SetScript("OnMouseWheel", function(_, delta)
            CodexPage:StepPage((delta and delta > 0) and -1 or 1)
        end)
    end

    local hdr = W.SectionHeader(parent, "ForeverSuite 통합 도감 (6대 LoadOnDemand 풀 DB)")
    hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    local bar = W.PillBar(parent, TABS, self.activePack, function(v)
        CodexPage.activePack = v
        CodexPage.pageIndex = 1
        CodexPage:SyncSubFilters()
        CodexPage:EnsureDataLoaded(v)
        CodexPage:RenderPack(ns.UI.CommandHub.lastQuery or "")
        ns.UI.CommandHub:RefreshStatusBar()
    end)
    bar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -30)
    bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -30)

    -- KPI-4 contextual sub-filters (shown only on rewards / hunter_pets tabs)
    local rewBar = W.PillBar(parent, {
        { value = "all", label = "전체 보상", width = 76 },
        { value = "honor", label = "명예(PvP)", width = 82 },
        { value = "reputation", label = "평판", width = 56 },
        { value = "merchant", label = "상인 상자", width = 78 },
    }, self.rewardModeFilter, function(v)
        CodexPage.rewardModeFilter = v
        CodexPage.pageIndex = 1
        CodexPage:RenderPack(CodexPage.lastQuery)
    end)
    rewBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -58)
    rewBar:SetWidth(330)
    rewBar:Hide()

    local petRareTgl = W.Toggle(parent, "★ 희귀 야수만 보기 (클릭 시 다중 출현 좌표 순환 안내)", self.petRareOnly, function(v)
        CodexPage.petRareOnly = v
        CodexPage.pageIndex = 1
        CodexPage:RenderPack(CodexPage.lastQuery)
        return true
    end)
    petRareTgl:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -58)
    petRareTgl:SetWidth(380)
    petRareTgl:Hide()

    self.rewBar = rewBar
    self.petRareTgl = petRareTgl

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
end

function CodexPage:OnShow()
    self:SyncSubFilters()
    self:EnsureDataLoaded(self.activePack)
    self:RenderPack(ns.UI.CommandHub.lastQuery or "")
    ns.UI.CommandHub:RefreshStatusBar()
end

function CodexPage:OnSearch(query)
    self:RenderPack(query)
end
