-- Module: Features/DungeonBrowserPage.lua
-- Responsibility: ForeverSuite v3.0 2-Pane Dungeon Browser (40 dungeons, 272 bosses -> IconRow drops w/ live +iLvl delta,
--                 432-quest live readiness checklist, W.ScrollText overview, W.ScrollBar on both panes, and Run Report).
-- Layer: Features (uses UI/Widgets + CompositeWidgets + Domain/DungeonBrowserModel + Api/SafeAPI/GameAdapters).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs
local tostring = tostring
local type = type
local math_max = math.max
local math_min = math.min

local LEFT_ROWS = 15
local RIGHT_ROWS = 11

local DungeonBrowserPage = {
    id = "dungeons",
    label = "던전 도감",
    group = "combat",
    host = nil,
    leftRows = {},
    rightRows = {},
    leftScrollBar = nil,
    rightScrollBar = nil,
    raidFilter = "all",
    activeTab = "overview", -- overview | map | bosses | quests | steps | report
    questFilter = "all", -- all | AVAILABLE | IN_LOG | COMPLETED
    selectedDungeon = nil,
    selectedBoss = nil,
    mapPageIdx = 1,
    leftOffset = 0,
    rightOffset = 0,
    lootByID = nil,
    portraitsByNpc = nil,
    lastQuery = "",
    lastLoadStatus = "LOADED",
    overviewMetaCard = nil,
    overviewMetaLabels = {},
    questFilterBar = nil,
    mapPanel = nil,
    mapTex = nil,
    mapTitleLbl = nil,
    mapNoteLbl = nil,
    mapPrevBtn = nil,
    mapNextBtn = nil,
    mapPinButtons = {},
    quickLootBtn = nil,
    quickLootPopup = nil,
    quickLootRows = {},
    rollPreviewCard = nil,
    rollPreviewTitle = nil,
    rollPreviewSub = nil,
    emptyState = nil,
    activeRun = nil,
    runHistory = {},
}
ns.Features.DungeonBrowserPage = DungeonBrowserPage

local function QualityColor(q)
    return (type(q) == "number" and T.QUALITY[q]) or T.TEXT.PRIMARY
end

local function LevelDifficultyColor(levelsStr, isRaid, playerLv)
    if isRaid then return T.SEMANTIC.WARN end
    if type(playerLv) ~= "number" or playerLv < 1 or type(levelsStr) ~= "string" then
        return T.SEMANTIC.INFO
    end
    local lo, hi = string.match(levelsStr, "(%d+)%D+(%d+)")
    local minL = tonumber(lo) or tonumber(string.match(levelsStr, "(%d+)"))
    local maxL = tonumber(hi) or minL
    if not minL then return T.SEMANTIC.INFO end
    if playerLv + 4 < minL then return T.SEMANTIC.DANGER end
    if playerLv <= maxL + 2 then return T.TEXT.GOLD end
    return T.SEMANTIC.SUCCESS
end

function DungeonBrowserPage:EnsureDataLoaded()
    local ok, st = ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_Dungeon")
    self.lastLoadStatus = st or (ok and "LOADED" or "LOAD_FAILED")
    local packs = _G.ForeverSuiteData and _G.ForeverSuiteData.packs
    if ok and type(packs) == "table" then
        if (not self.lootByID) and type(packs.dungeon_loot) == "table" and type(packs.dungeon_loot.entries) == "table" then
            self.lootByID = ns.Domain.DungeonBrowserModel.IndexLootByItemID(packs.dungeon_loot.entries)
        end
        if (not self.portraitsByNpc) and type(packs.dungeon_portraits) == "table" and type(packs.dungeon_portraits.entries) == "table" then
            self.portraitsByNpc = ns.Domain.DungeonBrowserModel.IndexPortraitsByNpcID(packs.dungeon_portraits.entries)
        end
    end
    return ok, st
end

function DungeonBrowserPage:EnsureQuickLootHud()
    if self.quickLootBtn then return self.quickLootBtn end
    local btn = W.Button(_G.UIParent, "★ 던전 빠른 드랍", 128, 24, function()
        DungeonBrowserPage:ToggleQuickLootPopup()
    end, true)
    btn:Hide()
    self.quickLootBtn = btn
    ns.UI.HudLayout:Register("dungeonQuickLoot", btn, {
        point = "TOPRIGHT",
        relPoint = "TOPRIGHT",
        x = -206,
        y = -208,
    }, "던전 빠른 드랍 버튼")

    local pop = W.Card(_G.UIParent, 340, 316, "ForeverSuiteQuickLootPopup", T.ELEVATION.L3_OVERLAY)
    pop:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -4)
    W.MakeDraggable(pop, "quickLootPopup", nil)
    W.SetBorderColor(pop, T.BORDER.GOLD)
    local pHdr = W.Label(pop, "던전 빠른 드랍 미리보기", "heading", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    pHdr:SetPoint("TOPLEFT", pop, "TOPLEFT", 10, -8)
    pHdr:SetPoint("TOPRIGHT", pop, "TOPRIGHT", -34, -8)
    local pClose = W.MiniButton(pop, "×", 20, 18, function() pop:Hide() end, "닫기")
    pClose:SetPoint("TOPRIGHT", pop, "TOPRIGHT", -6, -6)
    pop._hdr = pHdr
    self.quickLootRows = {}
    for i = 1, 8 do
        local r = W.IconRow(pop, 32, function(rowBtn)
            if rowBtn._item and type(rowBtn._item.itemID) == "number" and ns.Api.GameAdapters.IsShiftDown() then
                ns.Api.GameAdapters.InsertItemChatLink(rowBtn._item.itemID, rowBtn._item.title)
            end
        end)
        r:SetPoint("TOPLEFT", pop, "TOPLEFT", 6, -(32 + (i - 1) * 34))
        r:SetPoint("TOPRIGHT", pop, "TOPRIGHT", -6, -(32 + (i - 1) * 34))
        r:Hide()
        self.quickLootRows[i] = r
    end
    pop:Hide()
    self.quickLootPopup = pop
    return btn
end

function DungeonBrowserPage:ToggleQuickLootPopup()
    self:EnsureQuickLootHud()
    local pop = self.quickLootPopup
    if not pop then return false end
    if pop:IsShown() then
        pop:Hide()
        return false
    end
    self:EnsureDataLoaded()
    local instName = (self.activeRun and self.activeRun.name) or (self.selectedDungeon and self.selectedDungeon.title) or ""
    local packs = (_G.ForeverSuiteData and _G.ForeverSuiteData.packs) or {}
    local targetDungeon = self.selectedDungeon
    for _, d in ipairs((packs.dungeons and packs.dungeons.entries) or {}) do
        if instName ~= "" and (d.title == instName or string.find(instName, tostring(d.title or ""), 1, true)) then
            targetDungeon = d
            break
        end
    end
    pop._hdr:SetText("★ 빠른 드랍: " .. tostring((targetDungeon and targetDungeon.title) or (instName ~= "" and instName or "던전")))
    local bosses = targetDungeon and ns.Domain.DungeonBrowserModel.GetBossesForDungeon(packs.dungeon_bosses and packs.dungeon_bosses.entries or {}, targetDungeon) or {}
    local equipped = ns.Api.GameAdapters.GetEquippedItemLevelMap()
    local shown = 0
    for _, b in ipairs(bosses) do
        local drops = ns.Domain.DungeonBrowserModel.GetDropsForBoss(b, self.lootByID)
        for _, it in ipairs(drops) do
            if not it.placeholder and shown < 8 then
                shown = shown + 1
                local r = self.quickLootRows[shown]
                local slotNum = ns.Domain.BiSBrowserModel and ns.Domain.BiSBrowserModel.ResolveEquipSlot(it) or it.equipSlot
                local deltaTag = ""
                local rCol = T.TEXT.SECONDARY
                if type(slotNum) == "number" and type(it.itemLevel) == "number" and type(equipped[slotNum]) == "number" then
                    local diff = it.itemLevel - equipped[slotNum]
                    if diff > 0 then deltaTag = " (+" .. tostring(diff) .. "▲)"; rCol = T.SEMANTIC.SUCCESS end
                end
                r:SetData({
                    icon = ns.Api.GameAdapters.GetItemIconSafe(it.itemID),
                    borderCol = QualityColor(it.quality),
                    title = tostring(it.title),
                    subtitle = tostring(b.title or ""),
                    titleCol = QualityColor(it.quality),
                    rightText = (it.itemLevel and it.itemLevel > 0 and ("iLvl " .. tostring(it.itemLevel)) or "") .. deltaTag,
                    rightCol = rCol,
                })
                r._item = it
                r:Show()
            end
        end
    end
    for i = shown + 1, 8 do self.quickLootRows[i]:Hide() end
    pop:Show()
    return true
end

-- B7: Non-tainting Loot Roll Preview (START_LOOT_ROLL)
function DungeonBrowserPage:OnStartLootRoll(rollID)
    if ns.Api.ProfileStore:Get("ui", "showRollPreview") == false then return false end
    local info = ns.Api.GameAdapters.GetLootRollItemSafe(rollID)
    if not info then return false end
    local equipped = ns.Api.GameAdapters.GetEquippedItemLevelMap()
    local bisSet = {}
    local bisPack = _G.ForeverSuiteData and _G.ForeverSuiteData.packs and _G.ForeverSuiteData.packs.bis
    if type(bisPack) == "table" and type(bisPack.entries) == "table" then
        for _, b in ipairs(bisPack.entries) do
            if type(b.itemID) == "number" then bisSet[b.itemID] = true end
        end
    end
    local eqSlot = ns.Domain.BiSBrowserModel and ns.Domain.BiSBrowserModel.ResolveEquipSlot({ slot = info.equipLoc }) or nil
    local eval = ns.Domain.DungeonBrowserModel.EvaluateRollItem(info.itemID, info.itemLevel, eqSlot, equipped, bisSet)
    if not eval then return false end
    local body = tostring(info.name) .. (info.itemLevel and (" (iLvl " .. tostring(info.itemLevel) .. ")") or "") .. " - " .. tostring(eval.verdict)
    W.Toast("주사위 미리보기", body, (eval.tone == "GOLD" or eval.tone == "SUCCESS") and "SUCCESS" or "INFO", 5.0)
    return true, eval
end

function DungeonBrowserPage:OnInstanceChanged()
    local inInst, instType, instName = ns.Api.GameAdapters.GetInstanceContext()
    local now = ns.Api.GameAdapters.GetMonotonicTime() or 0
    local money = ns.Api.SafeAPI.GetPlayerMoney() or 0
    local xpSnap = ns.Api.GameAdapters.GetPlayerXPSnapshot()
    local curXp = xpSnap and xpSnap.xp or 0
    if inInst and (instType == "party" or instType == "raid") and instName ~= "" then
        if (not self.activeRun) or self.activeRun.name ~= instName then
            self.activeRun = {
                name = instName,
                instType = instType,
                startedAt = now,
                startMoney = money,
                startXp = curXp,
                xpGained = 0,
                bossesKilled = {},
                bossKillTimes = {},
            }
        end
        if ns.Api.ProfileStore:Get("ui", "showDungeonQuickLoot") ~= false then
            self:EnsureQuickLootHud():Show()
        end
    else
        if self.quickLootBtn and not (ns.UI.HudLayout and ns.UI.HudLayout:IsUnlocked()) then
            self.quickLootBtn:Hide()
        end
        if self.quickLootPopup then self.quickLootPopup:Hide() end
        if self.activeRun then
            local run = self.activeRun
            run.endedAt = now
            run.elapsed = math_max(0, now - (run.startedAt or now))
            run.goldDelta = money - (run.startMoney or money)
            if curXp >= (run.startXp or 0) then
                run.xpGained = math_max(run.xpGained or 0, curXp - (run.startXp or 0))
            end
            run.xpPerHour = ns.Domain.DungeonBrowserModel.ComputeXpPerHour(run.xpGained, run.elapsed)
            table.insert(self.runHistory, 1, run)
            if #self.runHistory > 15 then
                table.remove(self.runHistory)
            end
            self.activeRun = nil
        end
    end
end

function DungeonBrowserPage:OnBossKilled(encounterName, success)
    if ns.Api.SafeAPI.IsSecret(success) or ns.Api.SafeAPI.IsSecret(encounterName) then
        return
    end
    if success == 1 or success == true then
        if self.activeRun and type(encounterName) == "string" and encounterName ~= "" then
            local now = ns.Api.GameAdapters.GetMonotonicTime() or 0
            local stamp = ns.Domain.DungeonBrowserModel.FormatDuration(math_max(0, now - (self.activeRun.startedAt or now)))
            local idx = #self.activeRun.bossesKilled + 1
            self.activeRun.bossesKilled[idx] = encounterName
            self.activeRun.bossKillTimes = self.activeRun.bossKillTimes or {}
            self.activeRun.bossKillTimes[idx] = stamp
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
        local col = QualityColor(it.quality)
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
    if self.overviewMetaCard then self.overviewMetaCard:Hide() end
    if self.questFilterBar then self.questFilterBar:Hide() end
    if self.mapPanel then self.mapPanel:Hide() end
    if self.emptyState then self.emptyState:Hide() end
    self.entranceBtn:Hide()
    if self.rightScrollBar then self.rightScrollBar:SetMetrics(0, RIGHT_ROWS, 0) end

    local d = self.selectedDungeon
    if not d and self.activeTab ~= "report" then
        self.rightTitle:SetText("좌측 목록에서 던전을 선택하세요")
        self.rightSub:SetText("")
        local packsCheck = _G.ForeverSuiteData and _G.ForeverSuiteData.packs
        if (not packsCheck or not packsCheck.dungeons) and self.emptyState then
            self.emptyState:SetMessage("던전 데이터팩 미로드", "상태: " .. tostring(self.lastLoadStatus or "LOAD_FAILED") .. " (비전투 시 자동 로드)")
            self.emptyState:Show()
        end
        return
    end

    if d then
        self.rightTitle:SetText("★ " .. tostring(d.title) .. (d.levels and d.levels ~= "" and (" (" .. d.levels .. ")") or ""))
        self.rightSub:SetText(tostring(d.zone or ""))
    end

    if self.activeTab == "overview" then
        local bossTxt = (type(d.bossCount) == "number") and (tostring(d.bossCount) .. "명") or "정보 없음"
        local questTxt = (type(d.questCount) == "number") and (tostring(d.questCount) .. "개") or "정보 없음"
        local lvTxt = (d.levels and d.levels ~= "") and d.levels or (d.isRaid and "60 공대" or "정보 없음")
        if self.overviewMetaCard then
            if self.overviewMetaLabels[1] then self.overviewMetaLabels[1]:SetText("권장: " .. lvTxt .. " (" .. tostring(d.partySize or (d.isRaid and 40 or 5)) .. "인)") end
            if self.overviewMetaLabels[2] then self.overviewMetaLabels[2]:SetText("수록 보스: " .. bossTxt) end
            if self.overviewMetaLabels[3] then self.overviewMetaLabels[3]:SetText("던전 퀘스트: " .. questTxt) end
            self.overviewMetaCard:Show()
        end
        local routeText = (d.note and d.note ~= "") and d.note or "월드맵에서 입구 위치를 확인하세요."
        local showEnt = (d.entranceNote and d.entranceNote ~= "" and d.entranceNote ~= routeText and d.entranceNote ~= "던전 입구")
        local txt = "■ 위치 · 규모: " .. tostring(d.zone or "정보 없음")
            .. "\n\n■ 진입 루트 · 핵심 팁\n" .. routeText
            .. (showEnt and ("\n\n■ 입구 상세 안내\n" .. d.entranceNote) or "")
        self.overviewBody:SetText(txt)
        self.overviewBody:Show()
        if type(d.mapID) == "number" and type(d.x) == "number" and type(d.y) == "number" then
            self.entranceBtn:Show()
        end
        return
    end

    local packs = (_G.ForeverSuiteData and _G.ForeverSuiteData.packs) or {}

    if self.activeTab == "map" then
        if not ns.Api.SafeAPI.InCombat() then
            ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Media_Assets")
        end
        local pages, routeNotes = ns.Domain.DungeonBrowserModel.GetMapPagesForDungeon(
            packs.dungeon_map_meta and packs.dungeon_map_meta.entries or {}, d
        )
        if self.mapPanel then
            for i = 1, #self.mapPinButtons do self.mapPinButtons[i]:Hide() end
            if #pages == 0 then
                self.mapTitleLbl:SetText("등록된 내부 지도 없음 - 개요 탭에서 입구 /way 를 이용하세요")
                self.mapNoteLbl:SetText(tostring(d.note or ""))
                if self.mapTex then self.mapTex:Hide() end
                if self.mapPrevBtn then self.mapPrevBtn:Hide() end
                if self.mapNextBtn then self.mapNextBtn:Hide() end
            else
                if self.mapPageIdx < 1 then self.mapPageIdx = 1 end
                if self.mapPageIdx > #pages then self.mapPageIdx = #pages end
                local pg = pages[self.mapPageIdx]
                local texPath = ns.Domain.DungeonBrowserModel.ResolveMapTexturePath(pg)
                local cleanTitle = string.gsub(tostring(pg.title or d.title), "\n", " ")
                self.mapTitleLbl:SetText(
                    cleanTitle
                    .. ((pg.pageName and pg.pageName ~= "") and (" · " .. pg.pageName) or "")
                    .. " (" .. tostring(self.mapPageIdx) .. "/" .. tostring(#pages) .. ")"
                )
                local noteStr = tostring(pg.note or "")
                if #routeNotes > 0 then
                    noteStr = noteStr .. (noteStr ~= "" and " | " or "") .. tostring(routeNotes[1].title or "") .. ": " .. tostring(routeNotes[1].note or "")
                end
                self.mapNoteLbl:SetText(noteStr ~= "" and noteStr or "보스 핀 번호를 클릭하면 해당 보스 드랍으로 바로 이동합니다.")
                if self.mapTex and texPath then
                    self.mapTex:SetTexture(texPath)
                    self.mapTex:Show()
                end
                if self.mapPrevBtn then if #pages > 1 then self.mapPrevBtn:Show() else self.mapPrevBtn:Hide() end end
                if self.mapNextBtn then if #pages > 1 then self.mapNextBtn:Show() else self.mapNextBtn:Hide() end end
                local pins = ns.Domain.DungeonBrowserModel.ParseBossPins(pg.bossPinsCsv)
                local bosses = ns.Domain.DungeonBrowserModel.GetBossesForDungeon(packs.dungeon_bosses and packs.dungeon_bosses.entries or {}, d)
                local mapW, mapH = 340, 340
                for idx = 1, math_min(#pins, #self.mapPinButtons) do
                    local pin = pins[idx]
                    local btn = self.mapPinButtons[idx]
                    local bossIdx = tonumber(pin.label)
                    local bossRec = bossIdx and bosses[bossIdx] or nil
                    local lblStr = tostring(pin.label or "")
                    btn:SetLabel(lblStr)
                    if type(btn.SetWidth) == "function" then
                        local pinW = (#lblStr > 3) and math_min(92, math_max(28, math.floor(#lblStr * 4.5 + 10))) or 22
                        btn:SetWidth(pinW)
                    end
                    btn._tooltipText = bossRec and ("보스 #" .. lblStr .. ": " .. tostring(bossRec.title)) or ("위치 핀 #" .. lblStr)
                    btn._bossRec = bossRec
                    btn:ClearAllPoints()
                    btn:SetPoint("CENTER", self.mapTex, "TOPLEFT", pin.nx * mapW, -(pin.ny * mapH))
                    btn:Show()
                end
            end
            self.mapPanel:Show()
        end
        return
    end

    local rowsToShow = {}

    if self.activeTab == "bosses" then
        local bosses = ns.Domain.DungeonBrowserModel.GetBossesForDungeon(
            packs.dungeon_bosses and packs.dungeon_bosses.entries or {}, d
        )
        local equipped = ns.Api.GameAdapters.GetEquippedItemLevelMap()
        if not self.selectedBoss and bosses[1] then
            self.selectedBoss = bosses[1]
        end
        for _, b in ipairs(bosses) do
            local isSel = (self.selectedBoss and self.selectedBoss.title == b.title)
            local port = (self.portraitsByNpc and type(b.npcID) == "number" and b.npcID > 0) and self.portraitsByNpc[b.npcID] or nil
            local portIcon = (port and type(port.fileDataID) == "number" and port.fileDataID > 0) and port.fileDataID or nil
            rowsToShow[#rowsToShow + 1] = {
                title = (isSel and "▼ " or "▶ ") .. tostring(b.title),
                subtitle = (b.tip and b.tip ~= "") and b.tip or nil,
                right = (type(b.itemCount) == "number") and (tostring(b.itemCount) .. "종 드랍") or "드랍 정보",
                color = isSel and T.TEXT.GOLD or T.TEXT.PRIMARY,
                icon = portIcon,
                portraitDisplayID = (not portIcon and port and type(port.displayID) == "number" and port.displayID > 0) and port.displayID or nil,
                glyph = "★",
                borderCol = isSel and T.BORDER.GOLD or T.BORDER.SUBTLE,
                selected = isSel,
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
                    local qCol = it.placeholder and T.TEXT.MUTED or QualityColor(it.quality)
                    local iconTex = (type(it.itemID) == "number") and ns.Api.GameAdapters.GetItemIconSafe(it.itemID) or nil
                    local deltaTag = ""
                    local rightCol = T.TEXT.SECONDARY
                    local slotNum = ns.Domain.BiSBrowserModel and ns.Domain.BiSBrowserModel.ResolveEquipSlot(it)
                        or ((type(it.equipSlot) == "number" and it.equipSlot > 0) and it.equipSlot or it.invSlot)
                    if type(slotNum) == "number" and type(it.itemLevel) == "number" and type(equipped[slotNum]) == "number" then
                        local diff = it.itemLevel - equipped[slotNum]
                        if diff > 0 then
                            deltaTag = " (+" .. tostring(diff) .. "▲)"
                            rightCol = T.SEMANTIC.SUCCESS
                        elseif diff == 0 then
                            deltaTag = " (=)"
                        end
                    end
                    rowsToShow[#rowsToShow + 1] = {
                        title = tostring(it.title),
                        subtitle = (it.slot and it.slot ~= "") and it.slot or nil,
                        right = (it.itemLevel and it.itemLevel > 0 and ("iLvl " .. tostring(it.itemLevel)) or "") .. deltaTag,
                        color = qCol,
                        rightCol = rightCol,
                        icon = iconTex,
                        borderCol = qCol,
                        item = it,
                        onClick = (type(it.itemID) == "number") and function()
                            if ns.Api.GameAdapters.IsShiftDown() then
                                ns.Api.GameAdapters.InsertItemChatLink(it.itemID, it.title)
                            end
                        end or nil,
                    }
                end
            end
        end
        if #rowsToShow == 0 then
            rowsToShow[1] = { title = "등록된 보스 드랍 정보가 없습니다.", right = "", color = T.TEXT.MUTED, showIcon = false }
        end

    elseif self.activeTab == "quests" then
        if self.questFilterBar then self.questFilterBar:Show() end
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
        local qf = self.questFilter or "all"
        for _, qr in ipairs(qRows) do
            local pass = (qf == "all")
                or (qf == "AVAILABLE" and (qr.state == "AVAILABLE" or qr.state == "PREREQ_NEEDED"))
                or (qr.state == qf)
            if pass then
                local q = qr.quest
                local tag, col, glyph
                if qr.state == "COMPLETED" then tag, col, glyph = "[완료] ", T.SEMANTIC.SUCCESS, "V"
                elseif qr.state == "IN_LOG" then tag, col, glyph = "[진행] ", T.TEXT.GOLD, "?"
                elseif qr.state == "PREREQ_NEEDED" then tag, col, glyph = "[선행필요] ", T.SEMANTIC.DANGER, "×"
                else tag, col, glyph = "[미수락] ", T.TEXT.PRIMARY, "!" end
                rowsToShow[#rowsToShow + 1] = {
                    title = tag .. tostring(q.title) .. (q.inside and " (내부)" or ""),
                    subtitle = (q.npc and q.npc ~= "") and ("NPC: " .. tostring(q.npc)) or nil,
                    right = (q.level and q.level > 0 and ("Lv." .. tostring(q.level)) or "") .. (q.mapID and " · /way" or ""),
                    color = col,
                    glyph = glyph,
                    borderCol = col,
                    onClick = function()
                        if type(q.mapID) == "number" and type(q.x) == "number" and type(q.y) == "number" then
                            if ns.Features.NavigationHud then
                                ns.Features.NavigationHud:SetTarget(q.mapID, q.x, q.y, q.title)
                            end
                            ns.Api.SafeAPI.Print("던전 퀘스트 안내: " .. tostring(q.title) .. " - " .. tostring(q.npc or ""))
                        else
                            ns.Api.SafeAPI.Print(tostring(q.title) .. " (" .. tostring(q.npc or "") .. "): " .. tostring(q.objective or ""))
                        end
                    end,
                }
            end
        end
        if #rowsToShow == 0 then
            rowsToShow[1] = { title = "조건에 맞는 던전 퀘스트가 없습니다.", right = "", color = T.TEXT.MUTED, showIcon = false }
        end

    elseif self.activeTab == "steps" then
        local allQ = packs.dungeon_quests and packs.dungeon_quests.entries or {}
        local qSet, compSet = {}, {}
        for _, q in ipairs(allQ) do
            if q.dungeonKey == d.id or q.dungeonName == d.title then
                qSet[q.questID] = true
                compSet[q.questID] = ns.Api.GameAdapters.IsQuestCompleted(q.questID)
            end
        end
        local allSteps = packs.dungeon_steps and packs.dungeon_steps.entries or {}
        for _, st in ipairs(allSteps) do
            if qSet[st.questID] then compSet[st.questID] = ns.Api.GameAdapters.IsQuestCompleted(st.questID) end
        end
        local stepRows = ns.Domain.DungeonBrowserModel.FilterStepsForDungeon(allSteps, d, qSet, compSet)
        local doneCnt = 0
        for _, sr in ipairs(stepRows) do if sr.done then doneCnt = doneCnt + 1 end end
        self.rightSub:SetText("단계별 진행 체크리스트: " .. tostring(doneCnt) .. " / " .. tostring(#stepRows) .. " 완료 (클릭하여 NPC /way)")
        for idx, sr in ipairs(stepRows) do
            local st = sr.step
            rowsToShow[#rowsToShow + 1] = {
                title = (sr.done and "[V] " or ("[" .. tostring(idx) .. "] ")) .. tostring(st.title),
                subtitle = tostring(st.giver or "") .. ((st.source and st.source ~= "") and (" · " .. st.source) or ""),
                right = (st.questLevel and st.questLevel > 0 and ("Lv." .. tostring(st.questLevel)) or "") .. (st.mapID and " · /way" or ""),
                color = sr.done and T.SEMANTIC.SUCCESS or T.TEXT.PRIMARY,
                glyph = sr.done and "V" or "▶",
                borderCol = sr.done and T.SEMANTIC.SUCCESS or T.BORDER.GOLD_SOFT,
                onClick = function()
                    if type(st.mapID) == "number" and type(st.x) == "number" and type(st.y) == "number" then
                        if ns.Features.NavigationHud then
                            ns.Features.NavigationHud:SetTarget(st.mapID, st.x, st.y, tostring(st.giver or st.title))
                        end
                        ns.Api.SafeAPI.Print("단계 안내: " .. tostring(st.title) .. " - " .. tostring(st.source or st.giver or ""))
                    end
                end,
            }
        end
        if #rowsToShow == 0 then
            rowsToShow[1] = { title = "이 던전에 등록된 세부 진행 단계가 없습니다 (퀘스트 준비 탭을 확인하세요).", right = "", color = T.TEXT.MUTED, showIcon = false }
        end

    elseif self.activeTab == "report" then
        self.rightTitle:SetText("★ 던전 클리어 리포트 (시간 · XP/h · 보스 타임라인 · 골드)")
        self.rightSub:SetText("던전 입장·보스 처치 시각·경험치·골드 변화 자동 기록")
        local ledger = ns.Domain and ns.Domain.LedgerModel
        local fmtCopper = (ledger and type(ledger.FormatCopper) == "function")
            and ledger.FormatCopper
            or function(v) return tostring(v or 0) .. "c" end
        local function FormatBossTimeline(run)
            local list = run and run.bossesKilled or {}
            if #list == 0 then return "보스 0처치" end
            local times = run and run.bossKillTimes or {}
            local acc = {}
            for i = 1, #list do
                local t = times[i]
                acc[i] = t and ("[" .. tostring(t) .. "] " .. tostring(list[i])) or tostring(list[i])
            end
            return table.concat(acc, ", ")
        end
        if self.activeRun then
            local now = ns.Api.GameAdapters.GetMonotonicTime() or 0
            local elSec = math_max(0, now - (self.activeRun.startedAt or now))
            local el = ns.Domain.DungeonBrowserModel.FormatDuration(elSec)
            local xpSnap = ns.Api.GameAdapters.GetPlayerXPSnapshot()
            local gain = (xpSnap and xpSnap.xp >= (self.activeRun.startXp or 0)) and (xpSnap.xp - (self.activeRun.startXp or 0)) or (self.activeRun.xpGained or 0)
            local xph = ns.Domain.DungeonBrowserModel.ComputeXpPerHour(gain, elSec)
            local bossTxt = FormatBossTimeline(self.activeRun)
            rowsToShow[#rowsToShow + 1] = {
                title = "[진행중] " .. tostring(self.activeRun.name),
                subtitle = bossTxt .. (gain > 0 and (" · XP +" .. tostring(gain)) or "") .. (xph and (" (" .. tostring(xph) .. "/h)") or ""),
                right = el,
                color = T.TEXT.GOLD,
                icon = "Interface\\Icons\\INV_Misc_PocketWatch_01",
                glyph = "시간",
                borderCol = T.BORDER.GOLD,
            }
        end
        for _, r in ipairs(self.runHistory) do
            local bossTxt = FormatBossTimeline(r)
            local xpTxt = (r.xpGained and r.xpGained > 0) and (" · XP +" .. tostring(r.xpGained) .. (r.xpPerHour and (" (" .. tostring(r.xpPerHour) .. "/h)") or "")) or ""
            rowsToShow[#rowsToShow + 1] = {
                title = tostring(r.name),
                subtitle = bossTxt .. xpTxt,
                right = ns.Domain.DungeonBrowserModel.FormatDuration(r.elapsed or 0) .. " · " .. fmtCopper(r.goldDelta or 0),
                color = T.SEMANTIC.SUCCESS,
                glyph = "V",
                borderCol = T.SEMANTIC.SUCCESS,
            }
        end
        if #rowsToShow == 0 then
            rowsToShow[1] = { title = "던전 입장 시 경과 시간·보스 처치 시각·경험치(XP/h)·골드가 자동 기록됩니다.", right = "", color = T.TEXT.MUTED, showIcon = false }
        end
    end

    local visRows = (self.activeTab == "quests") and (RIGHT_ROWS - 1) or RIGHT_ROWS
    local rowStartY = (self.activeTab == "quests") and 84 or 52
    local total = #rowsToShow
    local maxOff = math_max(0, total - visRows)
    self.rightOffset = math_max(0, math_min(maxOff, self.rightOffset))
    for i = 1, RIGHT_ROWS do
        local row = self.rightRows[i]
        local data = (i <= visRows) and rowsToShow[self.rightOffset + i] or nil
        if data then
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", self.rightPane, "TOPLEFT", 6, -(rowStartY + (i - 1) * 36))
            row:SetPoint("TOPRIGHT", self.rightPane, "TOPRIGHT", -16, -(rowStartY + (i - 1) * 36))
            row:SetData({
                icon = data.icon,
                fallbackGlyph = data.glyph,
                showIcon = data.showIcon,
                borderCol = data.borderCol,
                title = data.title,
                subtitle = data.subtitle,
                titleCol = data.color,
                rightText = data.right,
                rightCol = data.rightCol or T.TEXT.SECONDARY,
                selected = data.selected,
                sepCol = T.BORDER.SUBTLE,
            })
            if data.portraitDisplayID and row._icon and row._icon._tex
                and type(_G.SetPortraitTextureFromCreatureDisplayID) == "function"
            then
                pcall(_G.SetPortraitTextureFromCreatureDisplayID, row._icon._tex, data.portraitDisplayID)
                row._icon._tex:Show()
                if row._icon._glyph then row._icon._glyph:Hide() end
            end
            row._item = data.item
            row._onActivate = data.onClick
            row:Show()
        else
            row._item = nil
            row._onActivate = nil
            row:Hide()
        end
    end
    if self.rightScrollBar then
        self.rightScrollBar:SetMetrics(self.rightOffset, visRows, total)
    end
end

function DungeonBrowserPage:RenderLeft(query)
    if not self.host then return end
    self.lastQuery = query or ""
    local packs = (_G.ForeverSuiteData and _G.ForeverSuiteData.packs) or {}
    local allD = packs.dungeons and packs.dungeons.entries or {}
    local filtered = ns.Domain.DungeonBrowserModel.FilterDungeons(allD, self.lastQuery, self.raidFilter)
    local pLv = ns.Api.GameAdapters.GetPlayerLevel()
    if (not self.selectedDungeon) and filtered[1] then
        self.selectedDungeon = filtered[1]
    end
    local total = #filtered
    local maxOff = math_max(0, total - LEFT_ROWS)
    self.leftOffset = math_max(0, math_min(maxOff, self.leftOffset))
    for i = 1, LEFT_ROWS do
        local row = self.leftRows[i]
        local d = filtered[self.leftOffset + i]
        if d then
            local sel = (self.selectedDungeon and self.selectedDungeon.id == d.id)
            row._dungeon = d
            row._left:SetText((sel and "▶ " or "") .. tostring(d.title))
            local c = sel and T.TEXT.GOLD or T.TEXT.PRIMARY
            row._left:SetTextColor(c[1], c[2], c[3], 1)
            local lvBadge = (d.levels and d.levels ~= "") and string.gsub(d.levels, "레벨", "") or (d.isRaid and "60 공대" or "5인")
            if d.isRaid then lvBadge = tostring(d.partySize or 40) .. "인 공대" end
            row._right:SetText(lvBadge)
            local rc = LevelDifficultyColor(d.levels, d.isRaid, pLv)
            row._right:SetTextColor(rc[1], rc[2], rc[3], 1)
            row:SetRowStyle(sel and T.SURFACE.GOLD_TINT or { 0, 0, 0, 0 }, sel and T.BORDER.GOLD or nil, 0, 2, nil, 6)
            row:Show()
        else
            row._dungeon = nil
            row:Hide()
        end
    end
    if self.leftScrollBar then
        self.leftScrollBar:SetMetrics(self.leftOffset, LEFT_ROWS, total)
    end
    self:RenderRight()
end

function DungeonBrowserPage:Build(parent)
    self.host = parent
    local hdr = W.SectionHeader(parent, "던전 통합 도감 (개요 · 보스·드랍 아이콘 · 퀘스트 준비 · 클리어 리포트)")
    hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    local filterBar = W.PillBar(parent, {
        { value = "all",     label = "전체",    width = 56 },
        { value = "dungeon", label = "5인 던전", width = 76 },
        { value = "raid",    label = "공격대",  width = 66 },
    }, self.raidFilter, function(v)
        DungeonBrowserPage.raidFilter = v
        DungeonBrowserPage.leftOffset = 0
        DungeonBrowserPage:RenderLeft(DungeonBrowserPage.lastQuery)
    end)
    filterBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -28)
    filterBar:SetWidth(220)

    local tabBar = W.PillBar(parent, {
        { value = "overview", label = "개요",      width = 56 },
        { value = "map",      label = "내부 지도",  width = 76 },
        { value = "bosses",   label = "보스·드랍",  width = 76 },
        { value = "quests",   label = "퀘스트",    width = 62 },
        { value = "steps",    label = "진행 단계",  width = 76 },
        { value = "report",   label = "리포트",    width = 62 },
    }, self.activeTab, function(v)
        DungeonBrowserPage.activeTab = v
        DungeonBrowserPage.rightOffset = 0
        DungeonBrowserPage.mapPageIdx = 1
        DungeonBrowserPage:RenderRight()
    end)
    tabBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 242, -28)
    tabBar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -28)

    local leftPane = W.Card(parent, 232, 470)
    leftPane:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -60)
    leftPane:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 14)
    if type(leftPane.EnableMouseWheel) == "function" then
        leftPane:EnableMouseWheel(true)
        leftPane:SetScript("OnMouseWheel", function(_, delta)
            if not delta or delta == 0 then return end
            DungeonBrowserPage.leftOffset = DungeonBrowserPage.leftOffset + (delta > 0 and -3 or 3)
            DungeonBrowserPage:RenderLeft(DungeonBrowserPage.lastQuery)
        end)
    end
    for i = 1, LEFT_ROWS do
        local row = W.ListRow(leftPane, 29, function(btn)
            if btn._dungeon then
                DungeonBrowserPage.selectedDungeon = btn._dungeon
                DungeonBrowserPage.selectedBoss = nil
                DungeonBrowserPage.rightOffset = 0
                DungeonBrowserPage:RenderLeft(DungeonBrowserPage.lastQuery)
            end
        end)
        row:SetPoint("TOPLEFT", leftPane, "TOPLEFT", 4, -(6 + (i - 1) * 30))
        row:SetPoint("TOPRIGHT", leftPane, "TOPRIGHT", -14, -(6 + (i - 1) * 30))
        self.leftRows[i] = row
    end
    local lsb = W.ScrollBar(leftPane, 456, function(newOff)
        DungeonBrowserPage.leftOffset = newOff
        DungeonBrowserPage:RenderLeft(DungeonBrowserPage.lastQuery)
    end)
    lsb:SetPoint("TOPRIGHT", leftPane, "TOPRIGHT", -3, -6)
    lsb:SetPoint("BOTTOMRIGHT", leftPane, "BOTTOMRIGHT", -3, 6)
    self.leftScrollBar = lsb

    local rightPane = W.Card(parent, 526, 470)
    rightPane:SetPoint("TOPLEFT", leftPane, "TOPRIGHT", 10, 0)
    rightPane:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 14)
    self.rightPane = rightPane
    if type(rightPane.EnableMouseWheel) == "function" then
        rightPane:EnableMouseWheel(true)
        rightPane:SetScript("OnMouseWheel", function(_, delta)
            if not delta or delta == 0 then return end
            DungeonBrowserPage.rightOffset = DungeonBrowserPage.rightOffset + (delta > 0 and -3 or 3)
            DungeonBrowserPage:RenderRight()
        end)
    end

    self.rightTitle = W.Label(rightPane, "", "heading", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    self.rightTitle:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 12, -10)
    self.rightTitle:SetPoint("TOPRIGHT", rightPane, "TOPRIGHT", -12, -10)

    self.rightSub = W.Label(rightPane, "", "small", T.TEXT.SECONDARY, { justifyH = "LEFT", wordWrap = false })
    self.rightSub:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 12, -30)
    self.rightSub:SetPoint("TOPRIGHT", rightPane, "TOPRIGHT", -12, -30)

    -- 3-metric overview strip
    local metaCard = W.Card(rightPane, 502, 34)
    metaCard:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 10, -50)
    metaCard:SetPoint("TOPRIGHT", rightPane, "TOPRIGHT", -10, -50)
    W.SetBorderColor(metaCard, T.BORDER.GOLD_SOFT)
    local m1 = W.Label(metaCard, "", "small", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    m1:SetPoint("LEFT", metaCard, "LEFT", 10, 0)
    local m2 = W.Label(metaCard, "", "small", T.TEXT.PRIMARY, { justifyH = "CENTER", wordWrap = false })
    m2:SetPoint("CENTER", metaCard, "CENTER", 0, 0)
    local m3 = W.Label(metaCard, "", "small", T.SEMANTIC.INFO, { justifyH = "RIGHT", wordWrap = false })
    m3:SetPoint("RIGHT", metaCard, "RIGHT", -10, 0)
    metaCard:Hide()
    self.overviewMetaCard = metaCard
    self.overviewMetaLabels = { m1, m2, m3 }

    -- Quests status filter pill bar
    local qfBar = W.PillBar(rightPane, {
        { value = "all",       label = "전체",  width = 50 },
        { value = "AVAILABLE", label = "미수락", width = 60 },
        { value = "IN_LOG",    label = "진행중", width = 60 },
        { value = "COMPLETED", label = "완료",  width = 50 },
    }, self.questFilter, function(v)
        DungeonBrowserPage.questFilter = v
        DungeonBrowserPage.rightOffset = 0
        DungeonBrowserPage:RenderRight()
    end)
    qfBar:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 10, -50)
    qfBar:SetWidth(260)
    qfBar:Hide()
    self.questFilterBar = qfBar

    self.overviewBody = W.ScrollText(rightPane, 502, 332, { lineHeight = 18 })
    self.overviewBody:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 10, -90)
    self.overviewBody:SetPoint("BOTTOMRIGHT", rightPane, "BOTTOMRIGHT", -10, 44)

    -- B5: Interior Map Viewer panel (renders ForeverSuite_Media_Assets dungeon artwork + interactive Boss Pins)
    local mapPanel = W.Card(rightPane, 506, 404)
    mapPanel:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 10, -52)
    mapPanel:SetPoint("BOTTOMRIGHT", rightPane, "BOTTOMRIGHT", -10, 10)
    W.SetBorderColor(mapPanel, T.BORDER.GOLD_SOFT)
    local mTitle = W.Label(mapPanel, "", "small", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    mTitle:SetPoint("TOPLEFT", mapPanel, "TOPLEFT", 10, -8)
    mTitle:SetPoint("TOPRIGHT", mapPanel, "TOPRIGHT", -124, -8)
    local mPrev = W.MiniButton(mapPanel, "◀ 이전", 54, 18, function()
        DungeonBrowserPage.mapPageIdx = DungeonBrowserPage.mapPageIdx - 1
        DungeonBrowserPage:RenderRight()
    end, "이전 층/구역 지도")
    mPrev:SetPoint("TOPRIGHT", mapPanel, "TOPRIGHT", -64, -6)
    local mNext = W.MiniButton(mapPanel, "다음 ▶", 54, 18, function()
        DungeonBrowserPage.mapPageIdx = DungeonBrowserPage.mapPageIdx + 1
        DungeonBrowserPage:RenderRight()
    end, "다음 층/구역 지도")
    mNext:SetPoint("TOPRIGHT", mapPanel, "TOPRIGHT", -6, -6)
    local mTex = mapPanel:CreateTexture(nil, "ARTWORK")
    mTex:SetSize(340, 340)
    mTex:SetPoint("TOP", mapPanel, "TOP", 0, -28)
    local mNote = W.Label(mapPanel, "", "small", T.TEXT.SECONDARY, { justifyH = "LEFT", wordWrap = false })
    mNote:SetPoint("BOTTOMLEFT", mapPanel, "BOTTOMLEFT", 10, 8)
    mNote:SetPoint("BOTTOMRIGHT", mapPanel, "BOTTOMRIGHT", -10, 8)
    self.mapPinButtons = {}
    for idx = 1, 16 do
        local pb = W.MiniButton(mapPanel, tostring(idx), 22, 20, function(btn)
            if btn._bossRec then
                DungeonBrowserPage.selectedBoss = btn._bossRec
                DungeonBrowserPage.activeTab = "bosses"
                DungeonBrowserPage.rightOffset = 0
                DungeonBrowserPage:RenderRight()
            end
        end, "보스 위치")
        pb:SetActive(true)
        pb:Hide()
        self.mapPinButtons[idx] = pb
    end
    mapPanel:Hide()
    self.mapPanel = mapPanel
    self.mapTex = mTex
    self.mapTitleLbl = mTitle
    self.mapNoteLbl = mNote
    self.mapPrevBtn = mPrev
    self.mapNextBtn = mNext

    local empty = W.EmptyState(rightPane, { title = "던전 데이터 없음", desc = "" })
    empty:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 10, -52)
    empty:SetPoint("BOTTOMRIGHT", rightPane, "BOTTOMRIGHT", -10, 12)
    self.emptyState = empty

    self.entranceBtn = W.Button(rightPane, "던전 입구 /way 안내 시작", 184, 26, function()
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
        local row = W.IconRow(rightPane, 34, function(btn)
            if type(btn._onActivate) == "function" then btn._onActivate() end
        end)
        row:SetTooltipHandler(ShowItemHover, HideHover)
        row:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 6, -(52 + (i - 1) * 36))
        row:SetPoint("TOPRIGHT", rightPane, "TOPRIGHT", -16, -(52 + (i - 1) * 36))
        row:Hide()
        self.rightRows[i] = row
    end

    local rsb = W.ScrollBar(rightPane, 404, function(newOff)
        DungeonBrowserPage.rightOffset = newOff
        DungeonBrowserPage:RenderRight()
    end)
    rsb:SetPoint("TOPRIGHT", rightPane, "TOPRIGHT", -3, -52)
    rsb:SetPoint("BOTTOMRIGHT", rightPane, "BOTTOMRIGHT", -3, 10)
    self.rightScrollBar = rsb
end

function DungeonBrowserPage:OnShow()
    self:EnsureDataLoaded()
    self:RenderLeft("")
    ns.UI.CommandHub:RefreshStatusBar()
end

function DungeonBrowserPage:OnSearch(query)
    self.leftOffset = 0
    self:RenderLeft(query)
end
