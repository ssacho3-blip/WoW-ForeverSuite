-- Module: Features/WorldMapOverlay.lua
-- Responsibility: Zero-Taint UIParent-owned WorldMap coordinate bar & current-zone Service NPC / Trainer / Dungeon Entrance quick launcher.
-- Layer: Features (uses UI/Widgets + Blizzard/WorldMapAdapter read-only hooks; ZERO SetScript/AddDataProvider/AcquirePin on WorldMapFrame).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs
local tostring = tostring
local type = type

local OVERLAY_WIDTH = 324
local MAX_POI_ROWS = 6
local MAX_CANVAS_PINS = 36

local WorldMapOverlay = {
    card = nil,
    pinLayer = nil,
    pinPool = {},
    revealTexPool = {},
    heatTexPool = {},
    coordLabel = nil,
    zoneLabel = nil,
    poiRows = {},
    ticker = nil,
    activeCategory = "all",
    showQuestPins = true,
    showFogReveal = false,
    showGatherHeatmap = false,
    collapsed = false,
    filterBar = nil,
    extraBar = nil,
    collapseBtn = nil,
    lastMapID = nil,
    lastCanvasSig = nil,
    lastPinsEnabled = nil,
    cachedPinKey = nil,
    cachedPinList = nil,
    initialized = false,
}
ns.Features.WorldMapOverlay = WorldMapOverlay

local function CollectCombinedPOIs()
    if not ns.Api.SafeAPI.InCombat() then
        ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_Atlas")
    end
    local atlasPack = _G.ForeverSuiteData and _G.ForeverSuiteData.packs and _G.ForeverSuiteData.packs.atlas_npcs
    if type(atlasPack) == "table" and type(atlasPack.entries) == "table" and #atlasPack.entries > 0 then
        local merged = {}
        local seen = {}
        for _, p in ipairs(ns.Domain.WorldMapModel.CORE_POIS) do
            merged[#merged + 1] = p
            seen[tostring(p.mapID) .. ":" .. tostring(p.name)] = true
        end
        for _, p in ipairs(atlasPack.entries) do
            local k = tostring(p.mapID) .. ":" .. tostring(p.name)
            if not seen[k] then
                merged[#merged + 1] = p
                seen[k] = true
            end
        end
        return merged
    end
    return ns.Domain.WorldMapModel.CORE_POIS
end

function WorldMapOverlay:EnsureCard()
    if self.card then
        return self.card
    end
    local card = W.Card(_G.UIParent, OVERLAY_WIDTH, 240, "ForeverSuiteWorldMapOverlay", T.ELEVATION.L2_HUB)
    card:SetPoint("BOTTOMLEFT", _G.UIParent, "BOTTOMLEFT", 24, 24)
    W.SetBorderColor(card, T.BORDER.GOLD_SOFT)

    local hdr = W.Label(card, "✦ 월드맵 좌표 · 안개 · 히트맵 · 위치", "heading", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    hdr:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -8)
    hdr:SetPoint("TOPRIGHT", card, "TOPRIGHT", -34, -8)

    local collapseBtn = W.MiniButton(card, "−", 22, 18, function()
        WorldMapOverlay:SetCollapsed(not WorldMapOverlay.collapsed)
    end, "좌표 바만 남기고 접기 / 펼치기")
    collapseBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", -8, -6)

    local coord = W.Label(card, "내 위치: —  |  커서: —", "mono", T.TEXT.PRIMARY, { justifyH = "LEFT", wordWrap = false })
    coord:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -28)
    coord:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -28)

    local zone = W.Label(card, "지도: —", "small", T.TEXT.SECONDARY, { justifyH = "LEFT", wordWrap = false })
    zone:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -46)
    zone:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -46)

    -- E6 & E7: Fog-of-War Reveal, Gather/Pet Heatmap, and Quick Cursor /way Gesture buttons
    local revealBtn = W.MiniButton(card, "안개밝힘", 66, 18, function(btn)
        WorldMapOverlay.showFogReveal = not WorldMapOverlay.showFogReveal
        btn:SetActive(WorldMapOverlay.showFogReveal)
        WorldMapOverlay.lastCanvasSig = nil
        WorldMapOverlay:Tick()
    end, "미탐험 지역 안개 밝히기 오버레이 토글 (Zero-Taint)")
    revealBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -64)

    local heatBtn = W.MiniButton(card, "채집히트맵", 72, 18, function(btn)
        WorldMapOverlay.showGatherHeatmap = not WorldMapOverlay.showGatherHeatmap
        btn:SetActive(WorldMapOverlay.showGatherHeatmap)
        WorldMapOverlay.lastCanvasSig = nil
        WorldMapOverlay:Tick()
    end, "현재 지역 약초·광맥 채집 밀도 히트맵 토글")
    heatBtn:SetPoint("LEFT", revealBtn, "RIGHT", 6, 0)

    local wayBtn = W.MiniButton(card, "커서 /way", 66, 18, function()
        WorldMapOverlay:PinCurrentCursorLocation()
    end, "현재 지도 커서 위치로 즉시 /way 화살표 설정")
    wayBtn:SetPoint("LEFT", heatBtn, "RIGHT", 6, 0)

    local filterBar = W.PillBar(card, {
        { value = "all", label = "전체", width = 44 },
        { value = "dungeon", label = "던전", width = 44 },
        { value = "trainer", label = "상급자", width = 52 },
        { value = "service", label = "서비스", width = 52 },
        { value = "transport", label = "교통편", width = 52 },
    }, self.activeCategory, function(cat)
        WorldMapOverlay.activeCategory = cat
        WorldMapOverlay.cachedPinKey = nil
        WorldMapOverlay:RefreshPOIs(WorldMapOverlay.lastMapID)
        local m = ns.Blizzard.WorldMapAdapter:GetCanvasMetrics()
        if WorldMapOverlay.lastMapID and m then
            WorldMapOverlay:RenderCanvasPins(WorldMapOverlay.lastMapID, m)
        end
    end)
    filterBar:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -88)
    filterBar:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -88)

    for i = 1, MAX_POI_ROWS do
        local row = W.ListRow(card, 20, function(btn, mouseBtn)
            if mouseBtn and mouseBtn ~= "LeftButton" then return end
            local p = btn._poi
            if type(p) ~= "table" or type(p.mapID) ~= "number" then return end
            local title = tostring(p.name or "목적지")
            local ok, status
            if ns.Features.NavigationHud then
                ok, status = ns.Features.NavigationHud:SetTarget(p.mapID, p.x, p.y, title)
            else
                ok, status = ns.Api.NavPort.SetWaypoint(p.mapID, p.x, p.y)
            end
            if status == "ARRIVED" then
                ns.Api.SafeAPI.Print("이미 목적지 근처입니다: " .. title)
            elseif ok and status == "APPLIED" then
                ns.Api.SafeAPI.Print("지도 목적지 연결: " .. title .. " (" .. ns.Domain.WorldMapModel.FormatCoordPair(p.x, p.y) .. ")")
            elseif status == "DEFERRED" then
                ns.Api.SafeAPI.Print("화살표 활성화 (기본 핀은 지도/전투 종료 후 적용): " .. title)
            else
                ns.Api.SafeAPI.Print("화살표 안내 시작 (기본 핀 미지원 지역): " .. title)
            end
        end)
        row:SetPoint("TOPLEFT", card, "TOPLEFT", 6, -(116 + (i - 1) * 20))
        row:SetPoint("TOPRIGHT", card, "TOPRIGHT", -6, -(116 + (i - 1) * 20))
        row:Hide()
        self.poiRows[i] = row
    end

    card:Hide()
    self.card = card
    self.coordLabel = coord
    self.zoneLabel = zone
    self.filterBar = filterBar
    self.revealBtn = revealBtn
    self.heatBtn = heatBtn
    self.wayBtn = wayBtn
    self.collapseBtn = collapseBtn
    return card
end

function WorldMapOverlay:SetCollapsed(flag)
    self.collapsed = flag and true or false
    if not self.card then return end
    if self.collapseBtn then
        self.collapseBtn:SetLabel(self.collapsed and "+" or "−")
        self.collapseBtn:SetActive(self.collapsed)
    end
    if self.collapsed then
        self.card:SetHeight(50)
        if self.zoneLabel then self.zoneLabel:Hide() end
        if self.filterBar then self.filterBar:Hide() end
        for i = 1, MAX_POI_ROWS do
            if self.poiRows[i] then self.poiRows[i]:Hide() end
        end
    else
        self.card:SetHeight(214)
        if self.zoneLabel then self.zoneLabel:Show() end
        if self.filterBar then self.filterBar:Show() end
        self:RefreshPOIs(self.lastMapID)
    end
end

function WorldMapOverlay:RefreshPOIs(mapID)
    if not self.card or self.collapsed then return end
    local pois = ns.Domain.WorldMapModel.FilterPOIs(CollectCombinedPOIs(), mapID, self.activeCategory, "", MAX_POI_ROWS)
    for i = 1, MAX_POI_ROWS do
        local row = self.poiRows[i]
        local p = pois[i]
        if p then
            row._poi = p
            row._left:SetText(tostring(p.name or "NPC"))
            row._right:SetText(ns.Domain.WorldMapModel.FormatCoordPair(p.x, p.y))
            row:Show()
        else
            row._poi = nil
            row:Hide()
        end
    end
end

function WorldMapOverlay:EnsurePinLayer()
    if self.pinLayer then
        return self.pinLayer
    end
    -- Zero-Taint UIParent-owned pin overlay (NEVER AddDataProvider / AcquirePin / child of WorldMapFrame!)
    local layer = W.HudContainer("ForeverSuiteWorldMapPinLayer", 1, 1)
    layer:SetFrameStrata(T.ELEVATION.L2_HUB)
    layer:EnableMouse(false)
    layer:Hide()
    self.pinLayer = layer
    return layer
end

function WorldMapOverlay:EnsureCanvasPin(idx)
    if self.pinPool[idx] then
        return self.pinPool[idx]
    end
    local layer = self:EnsurePinLayer()
    local pin = W.MiniButton(layer, "!", 20, 20, function(btn)
        local p = btn._pinData
        if type(p) ~= "table" or type(p.mapID) ~= "number" then return end
        local title = tostring(p.label or p.name or ("퀘스트 #" .. tostring(p.questID or "")))
        if ns.Features.NavigationHud then
            ns.Features.NavigationHud:SetTarget(p.mapID, p.x, p.y, title)
        else
            ns.Api.NavPort.SetWaypoint(p.mapID, p.x, p.y)
        end
        ns.Api.SafeAPI.Print("월드맵 핀 내비게이션: " .. title .. " (" .. ns.Domain.WorldMapModel.FormatCoordPair(p.x, p.y) .. ")")
    end, "클릭하여 /way 안내")
    local ico = W.IconFrame(pin, 18)
    ico:SetPoint("CENTER", pin, "CENTER", 0, 0)
    if type(ico.EnableMouse) == "function" then ico:EnableMouse(false) end
    pin._icon = ico
    pin:Hide()
    self.pinPool[idx] = pin
    return pin
end

function WorldMapOverlay:HideCanvasPins()
    for i = 1, #self.pinPool do
        self.pinPool[i]:Hide()
    end
    for i = 1, #self.revealTexPool do
        self.revealTexPool[i]:Hide()
    end
    for i = 1, #self.heatTexPool do
        self.heatTexPool[i]:Hide()
    end
    if self.pinLayer then
        self.pinLayer:Hide()
    end
end

-- E6: Quick map gesture — set /way to current WorldMap cursor position
function WorldMapOverlay:PinCurrentCursorLocation()
    local mapID = ns.Blizzard.WorldMapAdapter:GetViewingMapID()
    local cx, cy = ns.Api.GameAdapters.GetCursorScreenPosition()
    local metrics = ns.Blizzard.WorldMapAdapter:GetCanvasMetrics()
    if not (mapID and cx and cy and metrics) then return false end
    local nx, ny = ns.Domain.WorldMapModel.ComputeCursorCoords(cx, cy, metrics.scale, metrics.left, metrics.bottom, metrics.width, metrics.height)
    if not (nx and ny) then return false end
    local mName = ns.Api.GameAdapters.GetMapName(mapID) or ("Map #" .. tostring(mapID))
    local label = mName .. " " .. ns.Domain.WorldMapModel.FormatCoordPair(nx, ny)
    if ns.Features.NavigationHud then
        ns.Features.NavigationHud:SetTarget(mapID, nx, ny, label)
    end
    ns.Api.SafeAPI.Print("지도 커서 /way 설정: " .. label)
    return true
end

-- E6 & E7: Render Zero-Taint Fog-of-War Reveal tiles + Gather Heatmap overlays inside UIParent pinLayer
function WorldMapOverlay:RenderMapExtras(mapID, metrics)
    for i = 1, #self.revealTexPool do self.revealTexPool[i]:Hide() end
    for i = 1, #self.heatTexPool do self.heatTexPool[i]:Hide() end
    if not (mapID and metrics) then return 0, 0 end
    local wantReveal = self.showFogReveal or (ns.Api.ProfileStore:Get("ui", "worldMapReveal") == true)
    local wantHeat = self.showGatherHeatmap or (ns.Api.ProfileStore:Get("ui", "worldMapHeatmap") == true)
    if not (wantReveal or wantHeat) then return 0, 0 end

    if not ns.Api.SafeAPI.InCombat() then
        ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_MapExtra")
        if wantHeat then ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Media_Assets") end
    end
    local layer = self:EnsurePinLayer()
    layer:Show()
    local packs = (_G.ForeverSuiteData and _G.ForeverSuiteData.packs) or {}
    local revCount, heatCount = 0, 0

    if wantReveal and packs.map_reveal and type(packs.map_reveal.entries) == "table" then
        local tiles = ns.Domain.WorldMapModel.FilterRevealTiles(packs.map_reveal.entries, mapID)
        for _, tile in ipairs(tiles) do
            local firstId = tonumber(string.match(tile.filesCsv, "(%d+)"))
            if firstId and revCount < 24 then
                revCount = revCount + 1
                local tx = self.revealTexPool[revCount]
                if not tx then
                    tx = layer:CreateTexture(nil, "BACKGROUND")
                    self.revealTexPool[revCount] = tx
                end
                local sx = metrics.left + ((tile.x / 1002.0) * metrics.width)
                local sy = metrics.bottom + ((1 - (tile.y / 668.0)) * metrics.height)
                tx:SetTexture(firstId)
                tx:SetAlpha(0.55)
                tx:SetSize((tile.w / 1002.0) * metrics.width, (tile.h / 668.0) * metrics.height)
                tx:ClearAllPoints()
                tx:SetPoint("TOPLEFT", _G.UIParent, "BOTTOMLEFT", sx, sy)
                tx:Show()
            end
        end
    end

    if wantHeat and packs.gather_heatmap and type(packs.gather_heatmap.entries) == "table" then
        local heats = ns.Domain.WorldMapModel.FilterGatherHeatmaps(packs.gather_heatmap.entries, mapID, 4)
        for _, h in ipairs(heats) do
            heatCount = heatCount + 1
            local tx = self.heatTexPool[heatCount]
            if not tx then
                tx = layer:CreateTexture(nil, "ARTWORK")
                self.heatTexPool[heatCount] = tx
            end
            tx:SetTexture(h.file)
            if type(tx.SetTexCoord) == "function" then
                tx:SetTexCoord(h.u1 or 0, h.u2 or 1, h.v1 or 0, h.v2 or 1)
            end
            tx:SetAlpha(0.45)
            tx:SetSize(metrics.width, metrics.height)
            tx:ClearAllPoints()
            tx:SetPoint("BOTTOMLEFT", _G.UIParent, "BOTTOMLEFT", metrics.left, metrics.bottom)
            tx:Show()
        end
    end
    return revCount, heatCount
end

local PIN_ICON_BY_KIND = {
    quest = "Interface\\GossipFrame\\AvailableQuestIcon",
    dungeon = "Interface\\Icons\\INV_Misc_Map_01",
    trainer = "Interface\\Icons\\Trade_BlackSmithing",
    transport = "Interface\\Icons\\Ability_Mount_Gryphon_01",
    service = "Interface\\Icons\\INV_Misc_Coin_01",
}

function WorldMapOverlay:InvalidatePinCache()
    self.cachedPinKey = nil
    self.cachedPinList = nil
end

function WorldMapOverlay:BuildPinListForMap(mapID)
    if self.showQuestPins and not ns.Api.SafeAPI.InCombat() then
        ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_MapPins")
    end
    if not ns.Api.SafeAPI.InCombat() then
        ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_Atlas")
    end
    local qPack = _G.ForeverSuiteData and _G.ForeverSuiteData.packs and _G.ForeverSuiteData.packs.map_quest_starts
    local atlasPack = _G.ForeverSuiteData and _G.ForeverSuiteData.packs and _G.ForeverSuiteData.packs.atlas_npcs
    local qReady = (not self.showQuestPins) or (type(qPack) == "table" and type(qPack.entries) == "table")
    local atlasReady = (type(atlasPack) == "table" and type(atlasPack.entries) == "table")
    local cacheKey = tostring(mapID) .. "|" .. tostring(self.activeCategory) .. "|" .. tostring(self.showQuestPins) .. "|" .. tostring(qReady) .. "|" .. tostring(atlasReady)
    if qReady and self.cachedPinKey == cacheKey and type(self.cachedPinList) == "table" then
        return self.cachedPinList
    end

    local combined = {}
    -- 1. Unaccepted Quest Start `!` pins from ForeverSuite_Data_MapPins (3,609 real Forever pins!)
    if self.showQuestPins and type(qPack) == "table" and type(qPack.entries) == "table" then
        local compSet, logSet = {}, {}
        for _, qp in ipairs(qPack.entries) do
            if qp.mapID == mapID and type(qp.questID) == "number" then
                compSet[qp.questID] = ns.Api.GameAdapters.IsQuestCompleted(qp.questID)
                logSet[qp.questID] = ns.Api.SafeAPI.IsQuestInLog(qp.questID)
                if type(qp.prereqID) == "number" and qp.prereqID > 0 then
                    compSet[qp.prereqID] = ns.Api.GameAdapters.IsQuestCompleted(qp.prereqID)
                end
            end
        end
        local qPins = ns.Domain.WorldMapModel.FilterQuestPins(qPack.entries, mapID, {
            faction = ns.Api.GameAdapters.GetPlayerFaction(),
            completedSet = compSet,
            inLogSet = logSet,
            limit = 26,
        })
        for _, qp in ipairs(qPins) do
            combined[#combined + 1] = {
                mapID = qp.mapID,
                x = qp.x,
                y = qp.y,
                questID = qp.questID,
                kind = "quest",
                glyph = "!",
                icon = PIN_ICON_BY_KIND.quest,
                borderCol = T.BORDER.GOLD,
                active = true,
                label = "퀘스트 #" .. tostring(qp.questID) .. " (" .. tostring(qp.npc or "") .. " · " .. ((type(qp.level) == "number" and qp.level > 0) and ("Lv." .. tostring(qp.level)) or "Lv.—") .. ")",
            }
        end
    end

    -- 2. Service NPC / Trainer / Dungeon Entrance / Transport Dock pins on this map
    local pois = ns.Domain.WorldMapModel.FilterPOIs(CollectCombinedPOIs(), mapID, self.activeCategory, "", 10)
    for _, p in ipairs(pois) do
        local cat = p.category or "service"
        local g = (cat == "dungeon") and "D"
            or ((cat == "trainer") and "T"
            or ((cat == "transport") and "B" or "S"))
        combined[#combined + 1] = {
            mapID = p.mapID,
            x = p.x,
            y = p.y,
            kind = cat,
            glyph = g,
            icon = PIN_ICON_BY_KIND[cat] or PIN_ICON_BY_KIND.service,
            borderCol = (cat == "dungeon" or cat == "transport") and T.BORDER.GOLD or T.SEMANTIC.INFO,
            active = (cat == "dungeon" or cat == "transport"),
            label = tostring(p.name or "NPC"),
        }
    end

    if qReady and atlasReady then
        self.cachedPinKey = cacheKey
        self.cachedPinList = combined
    end
    return combined
end

function WorldMapOverlay:RenderCanvasPins(mapID, metrics)
    if not (mapID and metrics) or ns.Api.ProfileStore:Get("ui", "showWorldMapPins") == false then
        self:HideCanvasPins()
        return 0
    end
    local layer = self:EnsurePinLayer()
    layer:Show()

    local combined = self:BuildPinListForMap(mapID)
    local shown = 0
    for i = 1, (#combined > MAX_CANVAS_PINS and MAX_CANVAS_PINS or #combined) do
        local item = combined[i]
        local sx, sy = ns.Domain.WorldMapModel.ProjectMapToScreen(item.x, item.y, metrics)
        if sx and sy then
            shown = shown + 1
            local pin = self:EnsureCanvasPin(shown)
            pin._pinData = item
            pin._tooltipText = item.label .. " · 클릭 /way"
            pin:SetLabel(item.glyph)
            pin:SetActive(item.active)
            if pin._icon then
                pin._icon:SetIcon(item.icon, item.borderCol, item.glyph)
                pin._icon:Show()
            end
            pin:ClearAllPoints()
            pin:SetPoint("CENTER", _G.UIParent, "BOTTOMLEFT", sx, sy)
            pin:Show()
        end
    end
    for i = shown + 1, #self.pinPool do
        self.pinPool[i]:Hide()
    end
    return shown
end

function WorldMapOverlay:Tick()
    if ns.Api.ProfileStore:Get("ui", "showWorldMapOverlay") == false then
        self:StopAndHide()
        return
    end
    if not ns.Api.SafeAPI.IsWorldMapShown() then
        self:StopAndHide()
        return
    end
    self:EnsureCard()

    local pos = ns.Api.GameAdapters.GetPlayerPosition()
    local playerTxt = pos and ns.Domain.WorldMapModel.FormatCoordPair(pos.x, pos.y) or "—"

    local cx, cy = ns.Api.GameAdapters.GetCursorScreenPosition()
    local metrics = ns.Blizzard.WorldMapAdapter:GetCanvasMetrics()
    local cursorTxt = "—"
    if cx and cy and metrics then
        local nx, ny = ns.Domain.WorldMapModel.ComputeCursorCoords(
            cx, cy, metrics.scale, metrics.left, metrics.bottom, metrics.width, metrics.height
        )
        cursorTxt = ns.Domain.WorldMapModel.FormatCoordPair(nx, ny)
    end

    self.coordLabel:SetText("내 위치: " .. playerTxt .. "  |  커서: " .. cursorTxt)

    local mapID = ns.Blizzard.WorldMapAdapter:GetViewingMapID()
    local pinsEnabled = (ns.Api.ProfileStore:Get("ui", "showWorldMapPins") ~= false)
    local canvasSig = metrics and (tostring(metrics.left) .. ":" .. tostring(metrics.bottom) .. ":" .. tostring(metrics.width) .. ":" .. tostring(metrics.height)) or ""
    if mapID ~= self.lastMapID or canvasSig ~= self.lastCanvasSig or pinsEnabled ~= self.lastPinsEnabled then
        local mapChanged = (mapID ~= self.lastMapID)
        self.lastMapID = mapID
        self.lastCanvasSig = canvasSig
        self.lastPinsEnabled = pinsEnabled
        if mapChanged then
            local mName = mapID and ns.Api.GameAdapters.GetMapName(mapID) or nil
            self.zoneLabel:SetText("지도: " .. (mName or (mapID and ("#" .. tostring(mapID)) or "—")))
            self:RefreshPOIs(mapID)
        end
        self:RenderCanvasPins(mapID, metrics)
        self:RenderMapExtras(mapID, metrics)
    end
end

function WorldMapOverlay:OnWorldMapShown()
    if ns.Api.ProfileStore:Get("ui", "showWorldMapOverlay") == false then
        return
    end
    local card = self:EnsureCard()
    card:Show()
    self.lastMapID = false
    self.lastCanvasSig = nil
    self.cachedPinKey = nil
    self:Tick()
    if not self.ticker then
        -- ≤10Hz (0.12s) ticker; cancelled immediately when WorldMap hides (Invariant I3)
        self.ticker = ns.Api.GameAdapters.StartTicker(0.12, function()
            WorldMapOverlay:Tick()
        end)
    end
end

function WorldMapOverlay:StopAndHide()
    if self.ticker then
        ns.Api.GameAdapters.CancelTicker(self.ticker)
        self.ticker = nil
    end
    self:HideCanvasPins()
    if self.card then
        self.card:Hide()
    end
end

function WorldMapOverlay:ApplyVisibility()
    if ns.Api.ProfileStore:Get("ui", "showWorldMapOverlay") == false then
        self:StopAndHide()
    elseif ns.Api.SafeAPI.IsWorldMapShown() then
        self:OnWorldMapShown()
    end
end

function WorldMapOverlay:Init()
    if self.initialized then
        return true
    end
    ns.Blizzard.WorldMapAdapter:RegisterCallbacks(
        function() WorldMapOverlay:OnWorldMapShown() end,
        function() WorldMapOverlay:StopAndHide() end
    )
    self.initialized = true
    return true
end
