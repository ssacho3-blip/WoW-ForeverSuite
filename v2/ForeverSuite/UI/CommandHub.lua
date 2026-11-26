-- Module: UI/CommandHub.lua
-- Responsibility: ForeverSuite v3.0 Unified L2 /fs Command Hub (960x640, 4-Group Left Rail,
--                 L3_OVERLAY Global Search Palette with inline setting toggles, persisted hub position,
--                 Profile Share Modal, and interactive Zero-Taint Status Bar).
-- Layer: UI
local _, ns = ...
ns.UI = ns.UI or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local table_insert = table.insert

local HUB_WIDTH = 960
local HUB_HEIGHT = 640
local RAIL_WIDTH = 168
local PALETTE_MAX_ROWS = 10

local GROUP_META = {
    { key = "now",    title = "지금 할 일" },
    { key = "combat", title = "던전 · 장비" },
    { key = "life",   title = "생활 · 경제" },
    { key = "system", title = "환경 설정" },
}

local DEFAULT_GROUP_BY_ID = {
    home        = "now",
    partyfinder = "now",
    questguide  = "now",
    dungeons    = "combat",
    bis         = "combat",
    codex       = "combat",
    professions = "life",
    utilities   = "life",
    ledger      = "life",
    settings    = "system",
    fonts       = "system",
    diagnostics = "system",
}

local CommandHub = {
    window = nil,
    rail = nil,
    contentHost = nil,
    statusLabel = nil,
    searchBox = nil,
    searchPalette = nil,
    paletteRows = {},
    paletteItems = {},
    pages = {},
    pageDefs = {},
    activePageId = nil,
    lastQuery = "",
}
ns.UI.CommandHub = CommandHub

function CommandHub:RegisterPage(def)
    if type(def) ~= "table" or type(def.id) ~= "string" then
        return false
    end
    table_insert(self.pageDefs, def)
    self.pages[def.id] = def
    return true
end

function CommandHub:BuildGroupedRailSpec()
    local buckets = { now = {}, combat = {}, life = {}, system = {} }
    for _, def in ipairs(self.pageDefs) do
        local g = def.group or DEFAULT_GROUP_BY_ID[def.id] or "system"
        if not buckets[g] then buckets[g] = {} end
        table_insert(buckets[g], def)
    end
    local groups = {}
    for _, gm in ipairs(GROUP_META) do
        local list = buckets[gm.key]
        if list and #list > 0 then
            table_insert(groups, { key = gm.key, title = gm.title, items = list })
        end
    end
    return groups
end

function CommandHub:CloseSearchPalette()
    if self.searchPalette then
        self.searchPalette:Hide()
    end
end

function CommandHub:EnsureSearchPalette()
    if self.searchPalette then
        return self.searchPalette
    end
    if not (self.window and self.searchBox) then
        return nil
    end

    local pal = W.Card(_G.UIParent, 410, 340, "ForeverSuiteV3GlobalSearchPalette", T.ELEVATION.L3_OVERLAY)
    pal:SetPoint("TOPRIGHT", self.searchBox, "BOTTOMRIGHT", 0, -4)
    W.SetBorderColor(pal, T.BORDER.GOLD)

    local hdr = W.Label(pal, "전역 검색 결과 (클릭 즉시 이동 · 설정 바로 토글)", "small", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    hdr:SetPoint("TOPLEFT", pal, "TOPLEFT", 10, -8)
    hdr:SetPoint("TOPRIGHT", pal, "TOPRIGHT", -34, -8)

    local closeBtn = W.MiniButton(pal, "×", 22, 18, function()
        CommandHub:CloseSearchPalette()
    end, "검색 결과 닫기")
    closeBtn:SetPoint("TOPRIGHT", pal, "TOPRIGHT", -6, -6)

    self.paletteRows = {}
    for i = 1, PALETTE_MAX_ROWS do
        local row = W.IconRow(pal, 30, function(r)
            local item = r._payload
            if not item then return end
            if item.kind == "setting" and item.settingType == "boolean" then
                local cur = ns.Api.ProfileStore:Get(item.section, item.key) == true
                local ok = ns.Api.ProfileStore:Set(item.section, item.key, not cur)
                if ok then
                    CommandHub:UpdateSearchPalette(CommandHub.lastQuery)
                end
                return
            end
            CommandHub:CloseSearchPalette()
            if CommandHub.searchBox then
                CommandHub.searchBox:ClearFocus()
            end
            if item.kind == "feature" then
                CommandHub:JumpTo(item.pageId, { subTab = item.subTab })
            elseif item.kind == "setting" then
                CommandHub:JumpTo("settings", { searchQuery = item.title })
            elseif item.kind == "codex" then
                CommandHub:JumpTo(item.pageId, { searchQuery = item.query, packId = item.packId })
            end
        end)
        row:SetPoint("TOPLEFT", pal, "TOPLEFT", 6, -(28 + (i - 1) * 31))
        row:SetPoint("TOPRIGHT", pal, "TOPRIGHT", -6, -(28 + (i - 1) * 31))
        row:Hide()
        self.paletteRows[i] = row
    end

    local emptyLbl = W.Label(pal, "일치하는 기능·설정·로드된 도감 항목이 없습니다.", "small", T.TEXT.MUTED, { justifyH = "CENTER", wordWrap = false })
    emptyLbl:SetPoint("CENTER", pal, "CENTER", 0, -6)
    emptyLbl:Hide()

    pal._headerLbl = hdr
    pal._emptyLbl = emptyLbl
    pal:Hide()
    self.searchPalette = pal
    return pal
end

function CommandHub:UpdateSearchPalette(query)
    local q = tostring(query or "")
    self.lastQuery = q
    -- Always keep active page's local search live-filtered alongside global palette
    local curPage = self.activePageId and self.pages[self.activePageId] or nil
    if curPage and type(curPage.OnSearch) == "function" then
        curPage:OnSearch(q)
    end
    local trimmed = string.match(q, "^%s*(.-)%s*$") or ""
    if trimmed == "" then
        self:CloseSearchPalette()
        self.paletteItems = {}
        return
    end
    if not (ns.Domain and ns.Domain.GlobalSearchModel) then
        return
    end
    local pal = self:EnsureSearchPalette()
    if not pal then return end

    local schemas = ns.Api.ProfileStore and ns.Api.ProfileStore.schemas or {}
    local loadedPacks = (type(_G.ForeverSuiteData) == "table") and _G.ForeverSuiteData.packs or nil
    local res = ns.Domain.GlobalSearchModel.Search(trimmed, schemas, loadedPacks, { features = 3, settings = 3, codex = 4 })

    local flat = {}
    for _, f in ipairs(res.features) do flat[#flat + 1] = f end
    for _, s in ipairs(res.settings) do flat[#flat + 1] = s end
    for _, c in ipairs(res.codex) do flat[#flat + 1] = c end
    self.paletteItems = flat

    local count = #flat
    if count == 0 then
        for i = 1, PALETTE_MAX_ROWS do self.paletteRows[i]:Hide() end
        pal._emptyLbl:Show()
        pal:SetHeight(86)
        pal:Show()
        return
    end

    pal._emptyLbl:Hide()
    local shown = (count > PALETTE_MAX_ROWS) and PALETTE_MAX_ROWS or count
    for i = 1, PALETTE_MAX_ROWS do
        local row = self.paletteRows[i]
        local item = flat[i]
        if item and i <= shown then
            local iconTex, glyph, rightText, rightCol, borderCol
            if item.kind == "feature" then
                glyph = "→"
                borderCol = T.BORDER.GOLD
                rightText = "바로가기"
                rightCol = T.TEXT.GOLD
            elseif item.kind == "setting" then
                glyph = "⚙"
                borderCol = T.SEMANTIC.INFO
                if item.settingType == "boolean" then
                    local on = ns.Api.ProfileStore:Get(item.section, item.key) == true
                    rightText = on and "[ON]" or "[OFF]"
                    rightCol = on and T.SEMANTIC.SUCCESS or T.TEXT.MUTED
                else
                    rightText = "설정 이동"
                    rightCol = T.SEMANTIC.INFO
                end
            else
                iconTex = item.itemID and ns.Api.GameAdapters and ns.Api.GameAdapters.GetItemIconSafe(item.itemID) or nil
                glyph = "◈"
                borderCol = T.BORDER.GOLD_SOFT
                rightText = item.packTitle or "도감"
                rightCol = T.TEXT.SECONDARY
            end
            row:SetData({
                icon = iconTex,
                fallbackGlyph = glyph,
                borderCol = borderCol,
                title = item.title,
                subtitle = item.sub,
                rightText = rightText,
                rightCol = rightCol,
                sepCol = T.BORDER.SUBTLE,
                payload = item,
            })
            row:Show()
        else
            row:Hide()
        end
    end
    pal:SetHeight(36 + shown * 31)
    pal:Show()
end

function CommandHub:OpenProfileShareModal(initialMode)
    local modal = W.CopyPasteModal()
    if initialMode == "import" then
        modal:OpenImport(
            "프로필 가져오기 (복원)",
            "백업해 둔 FS2: 문자열을 붙여넣고 [가져오기 적용]을 누르세요.",
            function(raw)
                local ok, res = ns.Features.UtilitiesPage:HandleProfileCommand("import " .. tostring(raw or ""))
                if ok then
                    if ns.Features.SettingsPage and ns.Features.SettingsPage.SyncControlsFromStore then
                        ns.Features.SettingsPage:SyncControlsFromStore()
                    end
                    return true, "프로필 복원 완료 (" .. tostring(res) .. "개 설정 적용)"
                end
                return false, "가져오기 실패: " .. tostring(res or "형식 오류")
            end
        )
        return modal
    end
    local exported = ns.Features.UtilitiesPage and ns.Features.UtilitiesPage:HandleProfileCommand("export") or ""
    if type(exported) ~= "string" or string.sub(exported, 1, 4) ~= "FS2:" then
        modal:OpenExport(
            "프로필 백업 불가",
            "현재 프로필 문자열을 생성할 수 없습니다 (SavedVariables 미초기화 또는 읽기 전용).",
            ""
        )
        return modal
    end
    local _, entryCount = ns.Domain.PowerQoLModel.DeserializeProfile(exported)
    local cntTxt = (type(entryCount) == "number") and (tostring(entryCount) .. "개 설정") or "현재 설정"
    modal:OpenExport(
        "프로필 백업 · 내보내기",
        cntTxt .. "이 아래 문자열로 직렬화되었습니다. Ctrl+C (Cmd+C) 로 복사해 보관하세요.",
        exported
    )
    return modal
end

function CommandHub:EnsureWindow()
    if self.window then
        return self.window
    end
    local win = W.Window("ForeverSuiteV2CommandHub", HUB_WIDTH, HUB_HEIGHT, "✦ ForeverSuite")
    local savedPos = ns.Api and ns.Api.ProfileStore and ns.Api.ProfileStore:GetLayout("commandHub")
    if type(savedPos) == "table" and type(savedPos.point) == "string" then
        win:ClearAllPoints()
        win:SetPoint(savedPos.point, _G.UIParent, savedPos.relPoint or savedPos.point, savedPos.x or 0, savedPos.y or 0)
    else
        win:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 12)
    end
    win:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if ns.Api and ns.Api.ProfileStore and type(self.GetPoint) == "function" then
            local p, _, rp, x, y = self:GetPoint(1)
            if p then
                ns.Api.ProfileStore:SetLayout("commandHub", {
                    point = p,
                    relPoint = rp or p,
                    x = math.floor((x or 0) + 0.5),
                    y = math.floor((y or 0) + 0.5),
                })
            end
        end
    end)
    win:HookScript("OnHide", function()
        CommandHub:CloseSearchPalette()
    end)
    win:SetScript("OnMouseDown", function()
        CommandHub:CloseSearchPalette()
    end)

    local moveBtn = W.Button(win._header, "HUD 이동", 76, 24, function()
        local unlocked, reason = ns.UI.HudLayout:ToggleUnlock()
        if reason == "IN_COMBAT" then
            ns.Api.SafeAPI.Print("전투 중에는 HUD 배치 편집 모드를 켤 수 없습니다.")
        else
            ns.Api.SafeAPI.Print(unlocked and "HUD 배치 편집 모드 활성화" or "HUD 위치 잠금 완료")
        end
    end, true)
    moveBtn:SetPoint("RIGHT", win._closeBtn, "LEFT", -T.SPACE.SM, 0)

    local shareBtn = W.Button(win._header, "프로필 공유", 82, 24, function(_, mouseBtn)
        CommandHub:OpenProfileShareModal(mouseBtn == "RightButton" and "import" or "export")
    end)
    shareBtn:SetPoint("RIGHT", moveBtn, "LEFT", -6, 0)

    local search = W.SearchBox(win._header, 248, "기능 · 설정 · 도감 통합 검색...", function(q)
        if CommandHub._suppressPalette then
            CommandHub.lastQuery = tostring(q or "")
            return
        end
        CommandHub:UpdateSearchPalette(q)
    end)
    search:SetPoint("RIGHT", shareBtn, "LEFT", -10, 0)
    search:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        CommandHub:CloseSearchPalette()
    end)

    -- Window scale & center reset stepper (- / 100% / +) right beside search box
    local scalePlus = W.MiniButton(win._header, "+", 20, 22, function()
        CommandHub:AdjustUserScale(0.05)
    end, "창 크기 +5% 확대")
    scalePlus:SetPoint("RIGHT", search, "LEFT", -8, 0)

    local scaleValBtn = W.MiniButton(win._header, "100%", 42, 22, function(_, mouseBtn)
        if mouseBtn == "RightButton" then
            CommandHub:ResetWindowTransform()
        else
            CommandHub:SetUserScale(1.0)
        end
    end, "좌클릭: 크기 100% 초기화 · 우클릭: 창 위치·크기 중앙 복원")
    scaleValBtn:SetPoint("RIGHT", scalePlus, "LEFT", -2, 0)

    local scaleMinus = W.MiniButton(win._header, "−", 20, 22, function()
        CommandHub:AdjustUserScale(-0.05)
    end, "창 크기 -5% 축소")
    scaleMinus:SetPoint("RIGHT", scaleValBtn, "LEFT", -2, 0)
    self.scaleValBtn = scaleValBtn

    local groups = self:BuildGroupedRailSpec()
    local rail = W.GroupedTabRail(win, RAIL_WIDTH, groups, function(pageId)
        CommandHub:CloseSearchPalette()
        if CommandHub.searchBox and (CommandHub.searchBox:GetText() or "") ~= "" then
            CommandHub._suppressPalette = true
            CommandHub.lastQuery = ""
            CommandHub.searchBox:SetText("")
            CommandHub._suppressPalette = false
        end
        CommandHub:SelectPage(pageId)
    end)
    rail:SetPoint("TOPLEFT", win, "TOPLEFT", 1, -41)
    rail:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 1, 28)

    local host = CreateFrame("Frame", nil, win)
    host:SetPoint("TOPLEFT", rail, "TOPRIGHT", T.SPACE.MD, -10)
    host:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -T.SPACE.MD, 32)

    local footer = CreateFrame("Frame", nil, win)
    footer:SetHeight(27)
    footer:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 1, 1)
    footer:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -1, 1)

    local status = W.Label(footer, "", "small", T.TEXT.MUTED, { justifyH = "LEFT", wordWrap = false })
    status:SetPoint("LEFT", footer, "LEFT", T.SPACE.MD, 0)

    local diagMini = W.MiniButton(footer, "진단", 48, 19, function()
        CommandHub:SelectPage("diagnostics")
    end, "Zero-Taint 진단 · LoD 팩 관리")
    diagMini:SetPoint("RIGHT", footer, "RIGHT", -8, 0)

    local favMini = W.MiniButton(footer, "★위치저장", 76, 19, function()
        if ns.Features.UtilitiesPage and ns.Features.UtilitiesPage.QuickSaveCurrentLocation then
            ns.Features.UtilitiesPage:QuickSaveCurrentLocation()
        else
            CommandHub:JumpTo("utilities", { subTab = "bookmarks" })
        end
    end, "현재 캐릭터 좌표를 즐겨찾기 /way 북마크에 저장")
    favMini:SetPoint("RIGHT", diagMini, "LEFT", -6, 0)
    status:SetPoint("RIGHT", favMini, "LEFT", -8, 0)

    self.window = win
    self.rail = rail
    self.contentHost = host
    self.statusLabel = status
    self.searchBox = search

    if self.pageDefs[1] then
        self:SelectPage(self.pageDefs[1].id)
    end
    self:RefreshStatusBar()
    return win
end

function CommandHub:SelectPage(pageId, skipSearchSync)
    local def = self.pages[pageId]
    if not def then
        return false
    end
    local prevId = self.activePageId
    self.activePageId = pageId
    if (not skipSearchSync) and prevId and prevId ~= pageId and self.searchBox and (self.searchBox:GetText() or "") ~= "" then
        self._suppressPalette = true
        self.lastQuery = ""
        self.searchBox:SetText("")
        self._suppressPalette = false
        self:CloseSearchPalette()
    end
    if self.rail then
        self.rail:SetActive(pageId)
    end
    for id, page in pairs(self.pages) do
        if page._frame then
            if id == pageId then
                page._frame:Show()
            else
                page._frame:Hide()
            end
        end
    end
    if not def._frame and self.contentHost then
        local f = CreateFrame("Frame", nil, self.contentHost)
        f:SetAllPoints(self.contentHost)
        def._frame = f
        if type(def.Build) == "function" then
            def:Build(f)
        end
    end
    if def._frame then
        def._frame:Show()
    end
    if type(def.OnShow) == "function" then
        def:OnShow()
    end
    -- Keep active page filter synchronized with whatever text is currently visible in searchBox
    if not skipSearchSync then
        local visibleQ = (self.searchBox and (self.searchBox:GetText() or "")) or ""
        if visibleQ ~= "" and type(def.OnSearch) == "function" then
            def:OnSearch(visibleQ)
        end
    end
    self:RefreshStatusBar()
    return true
end

function CommandHub:GetUserScale()
    local saved = ns.Api and ns.Api.ProfileStore and ns.Api.ProfileStore:GetState("hubScale")
    local n = tonumber(saved) or 1.0
    if n < 0.75 then n = 0.75 end
    if n > 1.25 then n = 1.25 end
    return math.floor(n * 100 + 0.5) / 100
end

function CommandHub:SetUserScale(scale)
    local n = tonumber(scale) or 1.0
    if n < 0.75 then n = 0.75 end
    if n > 1.25 then n = 1.25 end
    n = math.floor(n * 100 + 0.5) / 100
    if ns.Api and ns.Api.ProfileStore then
        ns.Api.ProfileStore:SetState("hubScale", n)
    end
    return self:FitScaleToViewport(self.window)
end

function CommandHub:AdjustUserScale(delta)
    local d = tonumber(delta) or 0
    local base = self:GetUserScale()
    if d < 0 and self.window and type(self.window._fsAppliedScale) == "number" and self.window._fsAppliedScale < base then
        base = self.window._fsAppliedScale
    end
    return self:SetUserScale(base + d)
end

function CommandHub:ResetWindowTransform()
    if ns.Api and ns.Api.ProfileStore then
        ns.Api.ProfileStore:SetState("hubScale", 1.0)
        ns.Api.ProfileStore:SetLayout("commandHub", { point = "CENTER", relPoint = "CENTER", x = 0, y = 12 })
    end
    if self.window then
        self.window:ClearAllPoints()
        self.window:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 12)
        self:FitScaleToViewport(self.window)
    end
    ns.Api.SafeAPI.Print("CommandHub 창 위치와 크기를 기본값(중앙 · 100%)으로 복원했습니다.")
    return true
end

function CommandHub:FitScaleToViewport(win)
    win = win or self.window
    if not (win and _G.UIParent) then
        return 1.0
    end
    if ns.Api and ns.Api.SafeAPI and ns.Api.SafeAPI.InCombat() then
        return win._fsAppliedScale or 1.0
    end
    local pw = (type(_G.UIParent.GetWidth) == "function") and _G.UIParent:GetWidth() or nil
    local ph = (type(_G.UIParent.GetHeight) == "function") and _G.UIParent:GetHeight() or nil
    if type(pw) ~= "number" or type(ph) ~= "number" or pw <= 0 or ph <= 0 then
        return 1.0
    end
    local desired = self:GetUserScale()
    local maxFitX = (pw * 0.90) / HUB_WIDTH
    local maxFitY = (ph * 0.88) / HUB_HEIGHT
    local maxFit = (maxFitX < maxFitY) and maxFitX or maxFitY
    local scale = (desired < maxFit) and desired or maxFit
    if scale < 0.70 then scale = 0.70 end
    if scale > 1.25 then scale = 1.25 end
    scale = math.floor(scale * 100 + 0.5) / 100
    local prevScale = win._fsAppliedScale or 1.0
    if type(win.SetScale) == "function" then
        pcall(win.SetScale, win, scale)
    end
    -- Re-center if viewport shrank below desired scale so a previously dragged offset never clips offscreen
    if scale < desired and math.abs(scale - prevScale) > 0.001 then
        win:ClearAllPoints()
        win:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 0)
    end
    win._fsAppliedScale = scale
    if self.scaleValBtn and type(self.scaleValBtn.SetLabel) == "function" then
        self.scaleValBtn:SetLabel(tostring(math.floor(scale * 100 + 0.5)) .. "%")
    end
    return scale
end

function CommandHub:JumpTo(pageId, opts)
    local win = self:EnsureWindow()
    self:FitScaleToViewport(win)
    win:Show()
    local targetQ = (type(opts) == "table" and type(opts.searchQuery) == "string") and opts.searchQuery or ""
    if self.searchBox then
        self._suppressPalette = true
        self.lastQuery = targetQ
        self.searchBox:SetText(targetQ)
        self._suppressPalette = false
        self:CloseSearchPalette()
    end
    local ok = self:SelectPage(pageId, true)
    if not ok then return false end
    local def = self.pages[pageId]
    if type(opts) == "table" and def then
        if opts.packId and type(def.SelectPack) == "function" then
            def:SelectPack(opts.packId)
        end
        if opts.subTab and type(def.SelectSubTab) == "function" then
            def:SelectSubTab(opts.subTab)
        end
        if targetQ ~= "" and type(def.OnSearch) == "function" then
            def:OnSearch(targetQ)
        end
    end
    return true
end

function CommandHub:SetNavBadge(pageId, count)
    if self.rail and type(self.rail.SetBadge) == "function" then
        self.rail:SetBadge(pageId, count)
    end
end

local LOD_ADDONS = {
    "ForeverSuite_Data",
    "ForeverSuite_Data_Dungeon",
    "ForeverSuite_Data_BiS",
    "ForeverSuite_Data_Profession",
    "ForeverSuite_Data_Reward",
    "ForeverSuite_Data_Pet",
    "ForeverSuite_Data_Atlas",
    "ForeverSuite_Data_MapPins",
    "ForeverSuite_Data_Items",
    "ForeverSuite_Data_QuestExtra",
    "ForeverSuite_Data_MapExtra",
    "ForeverSuite_Media_Assets",
}

function CommandHub:RefreshStatusBar()
    if not self.statusLabel then
        return
    end
    local loadedCnt = 0
    for i = 1, #LOD_ADDONS do
        if ns.Api.SafeAPI.GetAddOnLoadedState(LOD_ADDONS[i]) == true then
            loadedCnt = loadedCnt + 1
        end
    end
    if loadedCnt == 0 and type(_G.ForeverSuiteData) == "table" and type(_G.ForeverSuiteData.packs) == "table" then
        for _ in pairs(_G.ForeverSuiteData.packs) do
            loadedCnt = 1
            break
        end
    end
    local realm = ns.Api.SafeAPI.GetCanonicalRealm()
    local taintText = "집계 없음"
    if ns.Api.ProfileStore.readOnly then
        taintText = "집계 없음 (읽기 전용)"
    elseif ns.Api.ProfileStore.db and ns.Api.ProfileStore.db.v2 and ns.Api.ProfileStore.db.v2.diagnostics then
        local blocked = ns.Api.ProfileStore.db.v2.diagnostics.taintTotal
        if type(blocked) == "number" then
            taintText = "Blocked " .. tostring(blocked) .. "건"
        end
    end
    local lodText = (loadedCnt > 0) and (tostring(loadedCnt) .. "/" .. tostring(#LOD_ADDONS) .. "팩 로드됨") or "미로드(0MB)"
    self.statusLabel:SetText(
        "상태: " .. taintText .. " · LoD " .. lodText .. " · 렐름: " .. realm
    )
end

function CommandHub:Toggle()
    local win = self:EnsureWindow()
    if win:IsShown() then
        win:Hide()
    else
        self:FitScaleToViewport(win)
        win:Show()
        local active = self.activePageId and self.pages[self.activePageId] or nil
        if active and type(active.OnShow) == "function" then
            active:OnShow()
        end
        local visibleQ = (self.searchBox and (self.searchBox:GetText() or "")) or ""
        if visibleQ ~= "" and active and type(active.OnSearch) == "function" then
            active:OnSearch(visibleQ)
        end
        self:RefreshStatusBar()
    end
end
