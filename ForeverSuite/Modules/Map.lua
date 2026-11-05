local _, ns = ...

local type = type
local tonumber = tonumber
local tostring = tostring
local string_format = string.format
local string_match = string.match

local Map = {
    title = "지도 좌표 및 경로 안내 (Map)",
    priority = "P1",
    description = "월드맵 열림 전용 0.15s 좌표 Ticker, /way <x> <y> 네이티브 3D 화살표 연동",
    yieldTo = { "TomTom" },
    coordLabel = nil,
    coordTicker = nil,
    mapHooked = false,
    active = false,
    lastCoordText = "플레이어: —",
}

function Map:FormatPlayerCoordinateText()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then
        return "플레이어: —"
    end
    local uiMapID = C_Map.GetBestMapForUnit("player")
    if not uiMapID or ns.IsSecret(uiMapID) then
        return "플레이어: —"
    end
    local pos = C_Map.GetPlayerMapPosition(uiMapID, "player")
    if not pos then
        return "플레이어: —"
    end
    local x, y
    if type(pos.GetXY) == "function" then
        x, y = pos:GetXY()
    else
        x, y = pos.x, pos.y
    end
    if type(x) ~= "number" or type(y) ~= "number" or ns.IsSecret(x) or ns.IsSecret(y) then
        return "플레이어: —"
    end
    if x <= 0 and y <= 0 then
        return "플레이어: —"
    end
    return string_format("플레이어: %.1f, %.1f", x * 100, y * 100)
end

function Map:RefreshCoords()
    if not self.active then
        return
    end
    local text = self:FormatPlayerCoordinateText()
    self.lastCoordText = text
    if self.coordLabel then
        self.coordLabel:SetText(text)
    end
end

function Map:StartMapTicker(ctx)
    if self.coordTicker and self.coordTicker:IsActive() then
        return
    end
    if not ns.ProfileManager:Get("map", "showCoordsOnWorldMap") then
        return
    end
    self:RefreshCoords()
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
    if not self.active then
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

function Map:OnEnable(ctx)
    self.active = true

    if _G.WorldMapFrame then
        local holder = ctx:CreateFrame("Frame", "ForeverSuiteMapCoordHolder", _G.WorldMapFrame)
        if holder then
            if not holder._fsInitialized then
                holder._fsInitialized = true
                holder:SetSize(200, 20)
                holder:SetPoint("BOTTOMLEFT", _G.WorldMapFrame, "BOTTOMLEFT", 16, 8)
                local lbl = ns.UI.CreateLabel(holder, "플레이어: —", "GameFontHighlightSmall", ns.UI.COLORS.ACCENT)
                if lbl then
                    lbl:SetPoint("LEFT", holder, "LEFT", 0, 0)
                    holder._fsCoordLabel = lbl
                end
            end
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

        if _G.WorldMapFrame.IsShown and _G.WorldMapFrame:IsShown() then
            self:StartMapTicker(ctx)
        end
    end

    if ns.ProfileManager:Get("map", "enableWaySlash") then
        local hasExtWay, extWayOwner = ns.HasExternalWayCommand()
        if hasExtWay then
            ns.SetFeatureYield("way", true, extWayOwner)
        else
            ns.SetFeatureYield("way", false, nil)
            _G.SLASH_FOREVERSUITEWAY1 = "/way"
            if type(_G.SlashCmdList) == "table" then
                _G.SlashCmdList["FOREVERSUITEWAY"] = function(msg)
                    Map:SetWaypointFromSlash(msg)
                end
            end
            ctx:AddCleanup(function()
                if type(_G.SlashCmdList) == "table" then
                    _G.SlashCmdList["FOREVERSUITEWAY"] = nil
                end
                _G.SLASH_FOREVERSUITEWAY1 = nil
            end)
        end
    end
end

function Map:OnDisable()
    self.active = false
    self:StopMapTicker()
    self.coordLabel = nil
end

ns.ModuleManager:Register("Map", Map)
