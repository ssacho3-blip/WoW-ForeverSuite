-- Module: Modules/Map.lua
-- Responsibility: WorldMap open-only 0.15s player & cursor coordinate display and /way native SuperTrack pin integration.
-- Dependencies: Core/Init.lua, Core/ProfileManager.lua, Core/ModuleManager.lua, UI/Framework.lua.
-- Public API: Map (QueryPlayerCoords, QueryCursorCoords, FormatPlayerCoordinateText, RefreshCoords, SetWaypointFromSlash).
-- Combat/Secret Safety: Cancels ticker immediately when WorldMapFrame hides (0 idle tickers); guards secret map/cursor coords.
local _, ns = ...

local type = type
local pcall = pcall
local tonumber = tonumber
local tostring = tostring
local string_format = string.format
local string_match = string.match

local Map = {
    title = "지도 좌표 및 경로 안내 (Map)",
    priority = "P1",
    description = "월드맵 열림 전용 0.15s 플레이어·커서 좌표, /way 네이티브 3D 화살표 연동",
    yieldTo = { "TomTom" },
    coordLabel = nil,
    coordTicker = nil,
    mapHooked = false,
    active = false,
    lastCoordText = "플레이어: —",
}

function Map:QueryPlayerCoords()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then
        return nil, nil
    end
    local uiMapID = C_Map.GetBestMapForUnit("player")
    if not uiMapID or ns.IsSecret(uiMapID) then
        return nil, nil
    end
    local pos = C_Map.GetPlayerMapPosition(uiMapID, "player")
    if not pos or ns.IsSecret(pos) then
        return nil, nil
    end
    local x, y
    if type(pos.GetXY) == "function" then
        x, y = pos:GetXY()
    else
        x, y = pos.x, pos.y
    end
    if type(x) ~= "number" or type(y) ~= "number" or ns.IsSecret(x) or ns.IsSecret(y) then
        return nil, nil
    end
    if x ~= x or y ~= y or x < 0 or x > 1 or y < 0 or y > 1 or (x == 0 and y == 0) then
        return nil, nil
    end
    return x * 100, y * 100
end

function Map:QueryCursorCoords()
    local wmf = _G.WorldMapFrame
    if type(wmf) ~= "table" or ns.IsSecret(wmf) then
        return nil, nil
    end
    local ok, cx, cy = false, nil, nil
    local sc = wmf.ScrollContainer
    if type(sc) == "table" and not ns.IsSecret(sc) and type(sc.GetNormalizedCursorPosition) == "function" then
        ok, cx, cy = pcall(sc.GetNormalizedCursorPosition, sc)
    elseif type(wmf.GetNormalizedCursorPosition) == "function" then
        ok, cx, cy = pcall(wmf.GetNormalizedCursorPosition, wmf)
    end
    if not ok or ns.IsSecret(cx) or ns.IsSecret(cy) or type(cx) ~= "number" or type(cy) ~= "number" then
        return nil, nil
    end
    if cx ~= cx or cy ~= cy or cx < 0 or cx > 1 or cy < 0 or cy > 1 then
        return nil, nil
    end
    return cx * 100, cy * 100
end

function Map:FormatPlayerCoordinateText()
    local px, py = self:QueryPlayerCoords()
    local cx, cy = self:QueryCursorCoords()
    if px and py and cx and cy then
        return string_format("플레이어: %.1f, %.1f  |  커서: %.1f, %.1f", px, py, cx, cy)
    elseif px and py then
        return string_format("플레이어: %.1f, %.1f", px, py)
    elseif cx and cy then
        return string_format("플레이어: —  |  커서: %.1f, %.1f", cx, cy)
    end
    return "플레이어: —"
end

function Map:RefreshCoords()
    if not self.active or not ns.ProfileManager:Get("map", "showCoordsOnWorldMap") then
        self:StopMapTicker()
        if self.coordHolder and self.coordHolder.Hide then
            self.coordHolder:Hide()
        end
        return
    end
    if self.coordHolder and self.coordHolder.Show then
        self.coordHolder:Show()
    end
    local text = self:FormatPlayerCoordinateText()
    self.lastCoordText = text
    if self.coordLabel then
        self.coordLabel:SetText(text)
    end
end

function Map:StartMapTicker(ctx)
    if not ns.ProfileManager:Get("map", "showCoordsOnWorldMap") then
        self:StopMapTicker()
        if self.coordHolder and self.coordHolder.Hide then
            self.coordHolder:Hide()
        end
        return
    end
    if self.coordHolder and self.coordHolder.Show then
        self.coordHolder:Show()
    end
    self:RefreshCoords()
    if self.coordTicker and self.coordTicker:IsActive() then
        return
    end
    self.coordTicker = ctx:NewTicker(0.15, function()
        Map:RefreshCoords()
    end)
end

function Map:StopMapTicker()
    if self.coordTicker then
        self.coordTicker:Cancel()
        self.coordTicker = nil
    end
end

function Map:SetWaypointFromSlash(rawInput)
    if not self.active or not ns.ProfileManager:Get("map", "enableWaySlash") then
        return false
    end
    local clean = tostring(rawInput or "")
    if clean == "clear" or clean == "reset" then
        if C_Map and C_Map.ClearUserWaypoint then
            C_Map.ClearUserWaypoint()
            ns.Print("사용자 목표 지점 핀을 해제했습니다.")
        end
        return true
    end

    local sx, sy, note = string_match(clean, "^%s*([%d%.]+)[,%s]+([%d%.]+)%s*(.-)%s*$")
    local x = tonumber(sx)
    local y = tonumber(sy)
    if not x or not y or x < 0 or x > 100 or y < 0 or y > 100 then
        ns.Warn("사용법: /way <X 0~100> <Y 0~100> [메모]  또는  /way clear")
        return false
    end

    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.CanSetUserWaypointOnMap and C_Map.SetUserWaypoint) then
        ns.Warn("현재 클라이언트에서 사용자 웨이포인트 API를 사용할 수 없습니다.")
        return false
    end

    local uiMapID = nil
    if _G.WorldMapFrame and _G.WorldMapFrame.IsShown and _G.WorldMapFrame:IsShown() and _G.WorldMapFrame.GetMapID then
        uiMapID = _G.WorldMapFrame:GetMapID()
    end
    if not uiMapID then
        uiMapID = C_Map.GetBestMapForUnit("player")
    end

    if not uiMapID or not C_Map.CanSetUserWaypointOnMap(uiMapID) then
        ns.Warn("현재 지역(인스턴스/미지원 맵)에서는 웨이포인트를 설정할 수 없습니다.")
        return false
    end

    local nx = x / 100
    local ny = y / 100
    local mapPoint
    if _G.UiMapPoint and _G.UiMapPoint.CreateFromCoordinates then
        mapPoint = _G.UiMapPoint.CreateFromCoordinates(uiMapID, nx, ny)
    else
        mapPoint = { uiMapID = uiMapID, position = { x = nx, y = ny } }
    end

    C_Map.SetUserWaypoint(mapPoint)
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
        C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    end

    local label = (note and note ~= "") and (" (" .. note .. ")") or ""
    ns.Print(string_format("목표 지점 설정: %.1f, %.1f%s (단일 네이티브 SuperTrack 핀)", x, y, label))
    return true
end

function Map:UnregisterWaySlash()
    if self.wayOwned then
        if type(_G.SlashCmdList) == "table" then
            _G.SlashCmdList["FOREVERSUITEWAY"] = nil
        end
        _G.SLASH_FOREVERSUITEWAY1 = nil
        self.wayOwned = false
    end
    ns.SetFeatureYield("way", false, nil)
end

function Map:SyncWayCommand()
    if not self.active or not ns.ProfileManager:Get("map", "enableWaySlash") then
        self:UnregisterWaySlash()
        return
    end
    if self.wayOwned then
        return
    end
    local hasExtWay, extWayOwner = ns.HasExternalWayCommand()
    if hasExtWay then
        ns.SetFeatureYield("way", true, extWayOwner)
        return
    end
    ns.SetFeatureYield("way", false, nil)
    _G.SLASH_FOREVERSUITEWAY1 = "/way"
    if type(_G.SlashCmdList) == "table" then
        _G.SlashCmdList["FOREVERSUITEWAY"] = function(msg)
            Map:SetWaypointFromSlash(msg)
        end
    end
    self.wayOwned = true
end

function Map:SyncSettings(ctx)
    if not self.active or not ns.ProfileManager:Get("map", "showCoordsOnWorldMap") then
        self:StopMapTicker()
        if self.coordHolder and self.coordHolder.Hide then
            self.coordHolder:Hide()
        end
    else
        if self.coordHolder and self.coordHolder.Show then
            self.coordHolder:Show()
        end
        local effCtx = ctx or ((ns.ModuleManager:GetModule("Map") or {}).ctx)
        if _G.WorldMapFrame and _G.WorldMapFrame.IsShown and _G.WorldMapFrame:IsShown() and effCtx then
            self:StartMapTicker(effCtx)
        else
            self:RefreshCoords()
        end
    end
    self:SyncWayCommand()
end

function Map:OnInitialize()
    if not self.settingListenerBound then
        self.settingListenerBound = true
        ns.ProfileManager:OnSettingChanged(function(section)
            if section == "map" and Map.active then
                Map:SyncSettings()
            end
        end)
    end
end

function Map:OnEnable(ctx)
    self.active = true

    if _G.WorldMapFrame then
        local holder = ctx:CreateFrame("Frame", "ForeverSuiteMapCoordHolder", _G.WorldMapFrame)
        if holder then
            if not holder._fsInitialized then
                holder._fsInitialized = true
                holder:SetSize(340, 20)
                holder:SetPoint("BOTTOMLEFT", _G.WorldMapFrame, "BOTTOMLEFT", 16, 8)
                local lbl = ns.UI.CreateLabel(holder, "플레이어: —", "GameFontHighlightSmall", ns.UI.COLORS.ACCENT)
                if lbl then
                    lbl:SetPoint("LEFT", holder, "LEFT", 0, 0)
                    holder._fsCoordLabel = lbl
                end
            end
            self.coordHolder = holder
            self.coordLabel = holder._fsCoordLabel
        end

        if not self.mapHooked and _G.WorldMapFrame.HookScript then
            self.mapHooked = true
            _G.WorldMapFrame:HookScript("OnShow", function()
                if Map.active then
                    local rec = ns.ModuleManager:GetModule("Map")
                    if rec and rec.ctx then
                        Map:StartMapTicker(rec.ctx)
                    end
                end
            end)
            _G.WorldMapFrame:HookScript("OnHide", function()
                Map:StopMapTicker()
            end)
        end
    end

    ctx:AddCleanup(function()
        Map:UnregisterWaySlash()
    end)
    self:SyncSettings(ctx)
end

function Map:OnDisable()
    self.active = false
    self:StopMapTicker()
    self:UnregisterWaySlash()
    if self.coordHolder and self.coordHolder.Hide then
        self.coordHolder:Hide()
    end
    self.coordHolder = nil
    self.coordLabel = nil
end

ns.ModuleManager:Register("Map", Map)
