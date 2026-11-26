-- Module: Features/BiSBrowserPage.lua
-- Responsibility: ForeverSuite v3.0 2-Pane BiS & Live 1:1 Equipped Gear Comparison Browser
--                 (unified W.FlowPillGroup fixing dual-PillBar highlight bug, W.IconRow w/ real built-in icons,
--                  W.ScrollBar, and Right 2-Pane Comparison Card: Equipped vs Selected BiS + Chat Link CTA).
-- Layer: Features (uses UI/Widgets + CompositeWidgets + Domain/BiSBrowserModel + Api/SafeAPI/GameAdapters).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local type = type
local math_max = math.max
local math_min = math.min

local VISIBLE_ROWS = 12

local BiSBrowserPage = {
    id = "bis",
    label = "BiS · 비교",
    group = "combat",
    host = nil,
    slotFilter = "all",
    selectedSpecId = nil,
    selectedSpecRole = nil,
    upgradeOnly = false,
    classOnly = false,
    scrollOffset = 0,
    lastQuery = "",
    slotPillGroup = nil,
    specPillBar = nil,
    rows = {},
    scrollBar = nil,
    emptyState = nil,
    selectedRec = nil,
    detailPanel = nil,
    equippedIcon = nil,
    equippedNameLbl = nil,
    equippedSubLbl = nil,
    linkBtn = nil,
    dungeonBtn = nil,
    matchedDungeonQuery = nil,
    statusLbl = nil,
}
ns.Features.BiSBrowserPage = BiSBrowserPage

local function QualityColor(q)
    return (type(q) == "number" and T.QUALITY[q]) or T.TEXT.PRIMARY
end

local function ToneColor(tone)
    if tone == "SUCCESS" then return T.SEMANTIC.SUCCESS end
    if tone == "GOLD" then return T.TEXT.GOLD end
    if tone == "DANGER" then return T.SEMANTIC.DANGER end
    if tone == "SECONDARY" then return T.TEXT.SECONDARY end
    return T.TEXT.MUTED
end

local function ShowBiSTooltip(btn)
    local rec = btn and btn._rec
    if type(rec) ~= "table" or not (_G.GameTooltip and type(_G.GameTooltip.SetOwner) == "function") then return end
    local it = rec.item
    pcall(function()
        _G.GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        _G.GameTooltip:ClearLines()
        if type(it.itemID) == "number" and it.itemID > 0 and type(_G.GameTooltip.SetHyperlink) == "function" then
            pcall(_G.GameTooltip.SetHyperlink, _G.GameTooltip, "item:" .. tostring(it.itemID))
        end
        local col = QualityColor(it.quality)
        _G.GameTooltip:AddLine(tostring(it.title), col[1], col[2], col[3])
        if rec.equippedIlvl then
            _G.GameTooltip:AddLine("착용 장비 비교: 내 iLvl " .. tostring(rec.equippedIlvl) .. " → " .. tostring(rec.badge), T.TEXT.GOLD[1], T.TEXT.GOLD[2], T.TEXT.GOLD[3])
        end
        if type(it.note) == "string" and it.note ~= "" then
            _G.GameTooltip:AddLine("능력치: " .. it.note, T.TEXT.PRIMARY[1], T.TEXT.PRIMARY[2], T.TEXT.PRIMARY[3])
        end
        if type(it.acq) == "string" and it.acq ~= "" then
            _G.GameTooltip:AddLine("획득처: " .. it.acq, T.SEMANTIC.SUCCESS[1], T.SEMANTIC.SUCCESS[2], T.SEMANTIC.SUCCESS[3])
        end
        _G.GameTooltip:Show()
    end)
end

local function HideBiSTooltip()
    if _G.GameTooltip and type(_G.GameTooltip.Hide) == "function" then
        pcall(_G.GameTooltip.Hide, _G.GameTooltip)
    end
end

function BiSBrowserPage:RenderDetail(equippedInfoMap)
    if not self.detailPanel then return end
    local rec = self.selectedRec
    if not rec or not rec.item then
        self.detailPanel:SetHeader("BiS 장비 비교 카드", "좌측 목록에서 아이템을 선택하세요", T.ICON.FALLBACK, T.BORDER.HAIRLINE)
        self.detailPanel:SetBodyText("아이템을 클릭하면 현재 착용 중인 동일 부위 장비와 아이템 레벨(iLvl), 능력치, 획득처를 나란히 비교합니다.")
        if self.equippedIcon then self.equippedIcon:SetIcon(T.ICON.FALLBACK, T.BORDER.SUBTLE) end
        if self.equippedNameLbl then self.equippedNameLbl:SetText("착용 장비 미선택") end
        if self.equippedSubLbl then self.equippedSubLbl:SetText("좌측 BiS 후보를 클릭하세요") end
        if self.linkBtn then self.linkBtn:Hide() end
        return
    end

    local it = rec.item
    local qCol = QualityColor(it.quality)
    local iconTex = (type(it.itemID) == "number") and ns.Api.GameAdapters.GetItemIconSafe(it.itemID) or nil
    local subTxt = "[" .. tostring(it.slot or "장비") .. "]  " .. tostring(rec.badge or "")
    self.detailPanel:SetHeader(tostring(it.title), subTxt, iconTex, qCol, "★")

    -- Compare against currently equipped slot item (normalize paired ring 12->11 and trinket 14->13)
    local eqInfo = nil
    local slotNum = ns.Domain.BiSBrowserModel.ResolveEquipSlot(it)
    if type(equippedInfoMap) == "table" and type(slotNum) == "number" then
        eqInfo = equippedInfoMap[slotNum]
    end
    if self.equippedIcon then
        if eqInfo then
            self.equippedIcon:SetIcon(eqInfo.icon, QualityColor(eqInfo.quality), "✓")
            self.equippedNameLbl:SetText("현재 착용: " .. tostring(eqInfo.name))
            local eqCol = QualityColor(eqInfo.quality)
            self.equippedNameLbl:SetTextColor(eqCol[1], eqCol[2], eqCol[3], 1)
            local ilvlStr = (type(eqInfo.ilvl) == "number") and ("iLvl " .. tostring(eqInfo.ilvl)) or "iLvl 미집계"
            self.equippedSubLbl:SetText(ilvlStr .. "  →  " .. tostring(rec.badge or ""))
        elseif type(rec.equippedIlvl) == "number" then
            self.equippedIcon:SetIcon(T.ICON.FALLBACK, T.BORDER.GOLD_SOFT, "✓")
            self.equippedNameLbl:SetText("현재 착용 슬롯 (iLvl " .. tostring(rec.equippedIlvl) .. ")")
            self.equippedNameLbl:SetTextColor(T.TEXT.PRIMARY[1], T.TEXT.PRIMARY[2], T.TEXT.PRIMARY[3], 1)
            self.equippedSubLbl:SetText("비교 결과: " .. tostring(rec.badge or ""))
        else
            self.equippedIcon:SetIcon(T.ICON.FALLBACK, T.BORDER.SUBTLE, "—")
            self.equippedNameLbl:SetText("현재 착용 장비 미집계 / 비어 있음")
            self.equippedNameLbl:SetTextColor(T.TEXT.MUTED[1], T.TEXT.MUTED[2], T.TEXT.MUTED[3], 1)
            self.equippedSubLbl:SetText("비교 대상 iLvl 정보 없음")
        end
    end

    local lines = {}
    lines[#lines + 1] = "■ 아이템 레벨: " .. ((type(it.itemLevel) == "number" and it.itemLevel > 0) and tostring(it.itemLevel) or "정보 없음")
    if type(rec.specScore) == "number" and rec.specScore > 0 then
        lines[#lines + 1] = "■ 전문화 가중치 평가: [" .. tostring(rec.specGrade or "C") .. "등급 · " .. tostring(rec.specScore) .. "점]"
    end
    if type(it.itemID) == "number" and it.itemID > 0 then
        lines[#lines + 1] = "■ 아이템 ID: #" .. tostring(it.itemID)
    end
    if type(it.note) == "string" and it.note ~= "" then
        lines[#lines + 1] = "\n■ 핵심 능력치 · 메모\n" .. it.note
    end
    if type(it.acq) == "string" and it.acq ~= "" then
        lines[#lines + 1] = "\n■ 획득처 (Acquisitions)\n" .. it.acq
    end
    local evPack = _G.ForeverSuiteData and _G.ForeverSuiteData.packs and _G.ForeverSuiteData.packs.bis_evidence
    local cls = ns.Api.GameAdapters.GetPlayerClass()
    if type(evPack) == "table" and type(evPack.entries) == "table" and cls then
        local ev = ns.Domain.BiSBrowserModel.FindEvidence(evPack.entries, cls, self.selectedSpecId)
        if ev then
            lines[#lines + 1] = "\n■ 전문화 우선순위 (" .. tostring(ev.title or "") .. ")\n" .. tostring(ev.summary or "")
            if type(ev.priorities) == "string" and ev.priorities ~= "" then
                lines[#lines + 1] = "우선 확인: " .. ev.priorities
            end
        end
    end
    self.detailPanel:SetBodyText(table.concat(lines, "\n"))
    if self.linkBtn then
        if type(it.itemID) == "number" and it.itemID > 0 then
            self.linkBtn:Show()
        else
            self.linkBtn:Hide()
        end
    end
    self.matchedDungeonQuery = nil
    if self.dungeonBtn then
        local acqText = tostring(it.acq or "")
        local matched = nil
        if acqText ~= "" then
            local dPack = _G.ForeverSuiteData and _G.ForeverSuiteData.packs and _G.ForeverSuiteData.packs.dungeons
            if type(dPack) == "table" and type(dPack.entries) == "table" then
                for _, d in ipairs(dPack.entries) do
                    if type(d.title) == "string" and d.title ~= "" and string.find(acqText, d.title, 1, true) then
                        matched = d.title
                        break
                    end
                end
            end
            if not matched then
                local known = { "화산 심장부", "검은날개 둥지", "오닉시아", "안퀴라즈", "낙스라마스", "줄구룹", "스트라솔름", "스칼로맨스", "검은바위 나락", "검은바위 첨탑", "혈투의 전장", "마라우돈", "줄파락", "가라앉은 사원" }
                for _, kw in ipairs(known) do
                    if string.find(acqText, kw, 1, true) then
                        matched = kw
                        break
                    end
                end
            end
        end
        if matched then
            self.matchedDungeonQuery = matched
            self.dungeonBtn:Show()
        else
            self.dungeonBtn:Hide()
        end
    end
end

function BiSBrowserPage:Render(query)
    if not (self.host and self.rows[1]) then return end
    self.lastQuery = query or ""
    local ok, st = ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_BiS")
    local pack = _G.ForeverSuiteData and _G.ForeverSuiteData.packs and _G.ForeverSuiteData.packs.bis
    if not (ok and type(pack) == "table" and type(pack.entries) == "table") then
        for i = 1, VISIBLE_ROWS do
            self.rows[i]._rec = nil
            self.rows[i]:Hide()
        end
        if self.scrollBar then self.scrollBar:SetMetrics(0, VISIBLE_ROWS, 0) end
        self.selectedRec = nil
        self:RenderDetail(nil)
        if self.emptyState then
            self.emptyState:SetMessage("BiS 데이터팩 미로드", "상태: " .. tostring(st))
            self.emptyState:Show()
        end
        if self.statusLbl then self.statusLbl:SetText("BiS 데이터팩을 불러오지 못했습니다 (" .. tostring(st) .. ").") end
        return
    end

    -- Single normalized snapshot for BOTH badge delta & right-hand detail card
    local equippedInfo = ns.Api.GameAdapters.GetEquippedItemInfoMap()
    local equippedLevels = {}
    for slotKey, info in pairs(equippedInfo) do
        if type(info.ilvl) == "number" and info.ilvl > 0 then
            equippedLevels[slotKey] = info.ilvl
        end
    end
    local list = ns.Domain.BiSBrowserModel.FilterAndCompare(pack.entries, {
        slotFilter = self.slotFilter,
        upgradeOnly = self.upgradeOnly,
        classOnly = self.classOnly,
        playerClass = ns.Api.GameAdapters.GetPlayerClass(),
        specRole = self.selectedSpecRole,
        query = self.lastQuery,
        equippedBySlot = equippedLevels,
    })

    local total = #list
    local maxOff = math_max(0, total - VISIBLE_ROWS)
    self.scrollOffset = math_max(0, math_min(maxOff, self.scrollOffset))

    if total == 0 then
        for i = 1, VISIBLE_ROWS do
            self.rows[i]._rec = nil
            self.rows[i]:Hide()
        end
        if self.scrollBar then self.scrollBar:SetMetrics(0, VISIBLE_ROWS, 0) end
        if self.emptyState then
            self.emptyState:SetMessage("조건에 맞는 BiS 장비가 없습니다", "필터를 '전체'로 바꾸거나 업그레이드 전용 옵션을 해제해 보세요.")
            self.emptyState:Show()
        end
        self.selectedRec = nil
        self:RenderDetail(equippedInfo)
    else
        if self.emptyState then self.emptyState:Hide() end
        -- Always re-resolve selectedRec against the fresh filtered list so filtered-out or stale deltas are never retained
        local resolved = nil
        if self.selectedRec and self.selectedRec.item then
            local prevID = self.selectedRec.item.itemID
            local prevTitle = self.selectedRec.item.title
            local prevSlot = self.selectedRec.item.slot
            for _, rec in ipairs(list) do
                if prevID ~= nil then
                    if rec.item.itemID == prevID then
                        resolved = rec
                        break
                    end
                elseif rec.item.title == prevTitle and rec.item.slot == prevSlot then
                    resolved = rec
                    break
                end
            end
        end
        self.selectedRec = resolved or list[1]
        for i = 1, VISIBLE_ROWS do
            local row = self.rows[i]
            local rec = list[self.scrollOffset + i]
            if rec then
                local it = rec.item
                row._rec = rec
                local qCol = QualityColor(it.quality)
                local bCol = ToneColor(rec.tone)
                local iconTex = (type(it.itemID) == "number") and ns.Api.GameAdapters.GetItemIconSafe(it.itemID) or nil
                local isSel = (self.selectedRec and self.selectedRec.item == it)
                row:SetData({
                    icon = iconTex,
                    borderCol = qCol,
                    title = tostring(it.title),
                    subtitle = "[" .. tostring(it.slot or "장비") .. "]" .. ((type(it.acq) == "string" and it.acq ~= "") and (" · " .. it.acq) or ""),
                    titleCol = qCol,
                    rightText = (rec.specGrade and ("[" .. rec.specGrade .. "] ") or "") .. tostring(rec.badge or ""),
                    rightCol = bCol,
                    selected = isSel,
                    sepCol = T.BORDER.SUBTLE,
                })
                row:Show()
            else
                row._rec = nil
                row:Hide()
            end
        end
        if self.scrollBar then
            self.scrollBar:SetMetrics(self.scrollOffset, VISIBLE_ROWS, total)
        end
        self:RenderDetail(equippedInfo)
    end

    if self.statusLbl then
        self.statusLbl:SetText(
            "BiS 후보 " .. tostring(total) .. "건 (부위: " .. tostring(self.slotFilter)
            .. (self.upgradeOnly and " · 업그레이드 전용" or "") .. " · Shift+클릭 채팅 링크)"
        )
    end
end

function BiSBrowserPage:Build(parent)
    self.host = parent
    local hdr = W.SectionHeader(parent, "BiS 추천 장비 · 착용 장비 2-Pane 실시간 비교")
    hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    -- Bug #4 Fix: Single unified W.FlowPillGroup (never leaves dual gold pills active!)
    local slotGroup = W.FlowPillGroup(parent, ns.Domain.BiSBrowserModel.SLOT_FILTERS, self.slotFilter, 550, function(v)
        BiSBrowserPage.slotFilter = v
        BiSBrowserPage.scrollOffset = 0
        BiSBrowserPage.selectedRec = nil
        BiSBrowserPage:Render(BiSBrowserPage.lastQuery)
    end)
    slotGroup:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -28)
    self.slotPillGroup = slotGroup

    local upgToggle = W.Toggle(parent, "업그레이드만 보기", self.upgradeOnly, function(v)
        BiSBrowserPage.upgradeOnly = v
        BiSBrowserPage.scrollOffset = 0
        BiSBrowserPage.selectedRec = nil
        BiSBrowserPage:Render(BiSBrowserPage.lastQuery)
        return true
    end)
    upgToggle:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -2, -26)
    upgToggle:SetWidth(190)

    local clsToggle = W.Toggle(parent, "내 직업 착용 가능만", self.classOnly, function(v)
        BiSBrowserPage.classOnly = v
        BiSBrowserPage.scrollOffset = 0
        BiSBrowserPage.selectedRec = nil
        BiSBrowserPage:Render(BiSBrowserPage.lastQuery)
        return true
    end)
    clsToggle:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -2, -52)
    clsToggle:SetWidth(190)

    local specs = ns.Domain.BiSBrowserModel.GetSpecsForClass(ns.Api.GameAdapters.GetPlayerClass())
    local specOpts = { { value = "all", label = "기본(iLvl)", width = 76 } }
    for _, sp in ipairs(specs) do
        specOpts[#specOpts + 1] = { value = sp.id, label = sp.label, width = 58 }
    end
    local specBar = W.PillBar(parent, specOpts, self.selectedSpecId or "all", function(v)
        if v == "all" then
            BiSBrowserPage.selectedSpecId = nil
            BiSBrowserPage.selectedSpecRole = nil
        else
            BiSBrowserPage.selectedSpecId = v
            for _, sp in ipairs(specs) do
                if sp.id == v then BiSBrowserPage.selectedSpecRole = sp.role; break end
            end
        end
        BiSBrowserPage.scrollOffset = 0
        BiSBrowserPage:Render(BiSBrowserPage.lastQuery)
    end)
    local specY = 28 + (slotGroup._totalHeight or 50) + 6
    specBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -specY)
    specBar:SetWidth(300)
    self.specPillBar = specBar

    local listTopY = specY + 30
    local leftPane = W.Card(parent, 424, 419)
    leftPane:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -listTopY)
    leftPane:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 24)
    if type(leftPane.EnableMouseWheel) == "function" then
        leftPane:EnableMouseWheel(true)
        leftPane:SetScript("OnMouseWheel", function(_, delta)
            if not delta or delta == 0 then return end
            BiSBrowserPage.scrollOffset = BiSBrowserPage.scrollOffset + (delta > 0 and -3 or 3)
            BiSBrowserPage:Render(BiSBrowserPage.lastQuery)
        end)
    end

    for i = 1, VISIBLE_ROWS do
        local row = W.IconRow(leftPane, 32, function(btn)
            local rec = btn._rec
            if not (rec and rec.item) then return end
            if ns.Api.GameAdapters.IsShiftDown() and type(rec.item.itemID) == "number" then
                ns.Api.GameAdapters.InsertItemChatLink(rec.item.itemID, rec.item.title)
                return
            end
            BiSBrowserPage.selectedRec = rec
            BiSBrowserPage:Render(BiSBrowserPage.lastQuery)
        end)
        row:SetTooltipHandler(ShowBiSTooltip, HideBiSTooltip)
        row:SetPoint("TOPLEFT", leftPane, "TOPLEFT", 4, -(6 + (i - 1) * 34))
        row:SetPoint("TOPRIGHT", leftPane, "TOPRIGHT", -14, -(6 + (i - 1) * 34))
        self.rows[i] = row
    end

    local sb = W.ScrollBar(leftPane, 404, function(newOff)
        BiSBrowserPage.scrollOffset = newOff
        BiSBrowserPage:Render(BiSBrowserPage.lastQuery)
    end)
    sb:SetPoint("TOPRIGHT", leftPane, "TOPRIGHT", -3, -6)
    sb:SetPoint("BOTTOMRIGHT", leftPane, "BOTTOMRIGHT", -3, 6)
    self.scrollBar = sb

    local empty = W.EmptyState(leftPane, { title = "BiS 장비 없음", desc = "" })
    empty:SetAllPoints(leftPane)
    self.emptyState = empty

    -- Right Pane: Top Equipped Comparison Banner (54px) + DetailPanel below
    local eqCard = W.Card(parent, 334, 54)
    eqCard:SetPoint("TOPLEFT", leftPane, "TOPRIGHT", 10, 0)
    eqCard:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -listTopY)
    W.SetBorderColor(eqCard, T.BORDER.GOLD_SOFT)

    local eqIcon = W.IconFrame(eqCard, T.ICON.MD)
    eqIcon:SetPoint("LEFT", eqCard, "LEFT", 10, 0)
    local eqName = W.Label(eqCard, "현재 착용 장비", "body", T.TEXT.PRIMARY, { justifyH = "LEFT", wordWrap = false })
    eqName:SetPoint("TOPLEFT", eqCard, "TOPLEFT", 10 + T.ICON.MD + 8, -9)
    eqName:SetPoint("TOPRIGHT", eqCard, "TOPRIGHT", -8, -9)
    local eqSub = W.Label(eqCard, "", "small", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    eqSub:SetPoint("TOPLEFT", eqCard, "TOPLEFT", 10 + T.ICON.MD + 8, -29)
    eqSub:SetPoint("TOPRIGHT", eqCard, "TOPRIGHT", -8, -29)
    self.equippedIcon = eqIcon
    self.equippedNameLbl = eqName
    self.equippedSubLbl = eqSub

    local detail = W.DetailPanel(parent, 334, 357, { hasFooter = true })
    detail:SetPoint("TOPLEFT", eqCard, "BOTTOMLEFT", 0, -8)
    detail:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 24)
    self.detailPanel = detail

    local linkBtn = W.Button(detail._footer, "채팅 아이템 링크", 136, 24, function()
        local rec = BiSBrowserPage.selectedRec
        if rec and rec.item and type(rec.item.itemID) == "number" then
            if not ns.Api.GameAdapters.InsertItemChatLink(rec.item.itemID, rec.item.title) then
                ns.Api.SafeAPI.Print("[BiS] " .. tostring(rec.item.title) .. " (#" .. tostring(rec.item.itemID) .. ")")
            end
        end
    end, true)
    linkBtn:SetPoint("LEFT", detail._footer, "LEFT", 0, 0)
    linkBtn:Hide()
    self.linkBtn = linkBtn

    local dungBtn = W.Button(detail._footer, "던전 보스 보기", 118, 24, function()
        if BiSBrowserPage.matchedDungeonQuery then
            ns.UI.CommandHub:JumpTo("dungeons", { searchQuery = BiSBrowserPage.matchedDungeonQuery })
        end
    end)
    dungBtn:SetPoint("LEFT", linkBtn, "RIGHT", 8, 0)
    dungBtn:Hide()
    self.dungeonBtn = dungBtn

    self.statusLbl = W.Label(parent, "", "small", T.TEXT.MUTED)
    self.statusLbl:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 4)
end

function BiSBrowserPage:OnShow()
    self:Render("")
    ns.UI.CommandHub:RefreshStatusBar()
end

function BiSBrowserPage:OnSearch(query)
    self.scrollOffset = 0
    self:Render(query)
end
