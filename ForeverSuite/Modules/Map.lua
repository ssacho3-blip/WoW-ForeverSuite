-- Module: Modules/Map.lua
-- Responsibility: WorldMap open-only 0.15s player & cursor coordinate display and /way native SuperTrack pin integration.
-- Dependencies: Core/Init.lua, Core/ProfileManager.lua, Core/ModuleManager.lua, UI/Framework.lua.
-- Public API: Map (QueryPlayerCoords, QueryCursorCoords, FormatPlayerCoordinateText, RefreshCoords, SetWaypointFromSlash, ExtractZoneLayerFromGUID, PrintLayerInfo).
-- Combat/Secret Safety: Cancels ticker immediately when WorldMapFrame hides (0 idle tickers); guards secret map/cursor coords.
local _, ns = ...

local type = type
local pcall = pcall
local ipairs = ipairs
local tonumber = tonumber
local tostring = tostring
local string_format = string.format
local string_lower = string.lower
local string_match = string.match

local Map = {
    title = "지도 좌표 및 경로 안내 (Map)",
    priority = "P1",
    description = "월드맵 열림 전용 0.15s 플레이어·커서 좌표, /way 네이티브 3D 화살표 연동",
    yieldTo = {},
    coordLabel = nil,
    coordTicker = nil,
    mapHooked = false,
    active = false,
    userWaypointActive = false,
    lastCoordText = "플레이어: —",
}
ns.Map = Map

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

function Map:CoordsAllowed()
    return self.active
        and ns.ProfileManager:Get("map", "showCoordsOnWorldMap")
        and (not ns.IsFeatureYielded("mapCoords"))
        and true
        or false
end

function Map:RefreshCoords()
    if not self:CoordsAllowed() then
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
    if not self:CoordsAllowed() then
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

function Map:SetWaypointAt(uiMapID, x, y, note)
    if not self.active or ns.IsFeatureYielded("way") then
        ns.Warn("지도 모듈이 비활성(또는 외부 애드온에 양보) 상태라 웨이포인트를 설정하지 않습니다.")
        return false
    end
    if ns.IsSecret(x) or ns.IsSecret(y) or type(x) ~= "number" or type(y) ~= "number" then
        return false
    end
    if x ~= x or y ~= y or x < 0 or x > 100 or y < 0 or y > 100 then
        return false
    end
    if not (C_Map and C_Map.CanSetUserWaypointOnMap and C_Map.SetUserWaypoint) then
        ns.Warn("현재 클라이언트에서 사용자 웨이포인트 API를 사용할 수 없습니다.")
        return false
    end
    local targetMapID = uiMapID
    if (ns.IsSecret(targetMapID) or not targetMapID) and C_Map.GetBestMapForUnit then
        local okMap, liveMap = pcall(C_Map.GetBestMapForUnit, "player")
        targetMapID = okMap and liveMap or nil
    end
    if ns.IsSecret(targetMapID) or type(targetMapID) ~= "number" or targetMapID <= 0 then
        ns.Warn("현재 지역(인스턴스/미지원 맵)에서는 웨이포인트를 설정할 수 없습니다.")
        return false
    end
    local okCan, canSet = pcall(C_Map.CanSetUserWaypointOnMap, targetMapID)
    if not okCan or ns.IsSecret(canSet) or canSet ~= true then
        ns.Warn("현재 지역(인스턴스/미지원 맵)에서는 웨이포인트를 설정할 수 없습니다.")
        return false
    end
    local nx = x / 100
    local ny = y / 100
    local mapPoint
    if _G.UiMapPoint and _G.UiMapPoint.CreateFromCoordinates then
        local okPt, pt = pcall(_G.UiMapPoint.CreateFromCoordinates, targetMapID, nx, ny)
        if not okPt or not pt then
            ns.Warn("웨이포인트 좌표 생성에 실패했습니다.")
            return false
        end
        mapPoint = pt
    else
        mapPoint = { uiMapID = targetMapID, position = { x = nx, y = ny } }
    end
    local okSet = pcall(C_Map.SetUserWaypoint, mapPoint)
    if not okSet then
        ns.Warn("웨이포인트 설정에 실패했습니다.")
        return false
    end
    self.userWaypointActive = true
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
        pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
    end
    local label = (not ns.IsSecret(note) and type(note) == "string" and note ~= "") and (" (" .. note .. ")") or ""
    ns.Print(string_format("목표 지점 설정: %.1f, %.1f%s (단일 네이티브 SuperTrack 핀)", x, y, label))
    return true
end

function Map:SetWaypointFromSlash(rawInput)
    if ns.IsFeatureYielded("way") or not self.active or not ns.ProfileManager:Get("map", "enableWaySlash") then
        return false
    end
    local rawTrim = string_match(tostring(rawInput or ""), "^%s*(.-)%s*$") or ""
    local cleanCmd = string_lower(rawTrim)
    if cleanCmd == "clear" or cleanCmd == "reset" then
        self.userWaypointActive = false
        if C_Map and C_Map.ClearUserWaypoint then
            C_Map.ClearUserWaypoint()
            ns.Print("사용자 목표 지점 핀을 해제했습니다.")
        end
        return true
    end

    local sx, sy, note = string_match(rawTrim, "^([%d%.]+)[,%s]+([%d%.]+)%s*(.-)%s*$")
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
        local shownMap = _G.WorldMapFrame:GetMapID()
        if shownMap and not ns.IsSecret(shownMap) and C_Map.CanSetUserWaypointOnMap(shownMap) then
            uiMapID = shownMap
        end
    end
    if not uiMapID then
        uiMapID = C_Map.GetBestMapForUnit("player")
    end
    return self:SetWaypointAt(uiMapID, x, y, note)
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
    local hasExtWay, extWayOwner = ns.HasExternalWayCommand()
    if hasExtWay then
        self:UnregisterWaySlash()
        ns.SetFeatureYield("way", true, extWayOwner)
        return
    end
    if self.wayOwned then
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
    if not self:CoordsAllowed() then
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
    self.userWaypointActive = false
    self:StopMapTicker()
    self:UnregisterWaySlash()
    if self.coordHolder and self.coordHolder.Hide then
        self.coordHolder:Hide()
    end
    self.coordHolder = nil
    self.coordLabel = nil
end

function Map.ExtractZoneLayerFromGUID(guid)
    if ns.IsSecret(guid) or type(guid) ~= "string" or guid == "" then
        return nil, nil, nil
    end
    local unitKind, _, serverID, instanceID, zoneUID = string_match(
        guid,
        "^([A-Za-z]+)%-(%d+)%-(%d+)%-(%d+)%-(%d+)%-%d+%-[0-9A-Fa-f]+$"
    )
    if not zoneUID then
        return nil, nil, nil
    end
    if unitKind ~= "Creature" and unitKind ~= "Vehicle" and unitKind ~= "GameObject" and unitKind ~= "Pet" then
        return nil, nil, nil
    end
    return zoneUID, instanceID, serverID
end

function Map:PrintLayerInfo()
    local zoneName = (_G.GetRealZoneText and _G.GetRealZoneText()) or (_G.GetZoneText and _G.GetZoneText()) or "알 수 없음"
    if ns.IsSecret(zoneName) then
        zoneName = "비밀 값(전투 중)"
    end
    local instName, instType = "야외", "none"
    if type(_G.GetInstanceInfo) == "function" then
        local okInst, iName, iType = pcall(_G.GetInstanceInfo)
        if okInst and not ns.IsSecret(iName) and type(iName) == "string" and iName ~= "" then
            instName = iName
        end
        if okInst and not ns.IsSecret(iType) and type(iType) == "string" and iType ~= "" then
            instType = iType
        end
    end
    local zoneUID, instID, srvID, sourceUnit = nil, nil, nil, nil
    if type(_G.UnitGUID) == "function" then
        for _, unit in ipairs({ "target", "mouseover", "npc" }) do
            local okG, guid = pcall(_G.UnitGUID, unit)
            if okG then
                local z, i, s = Map.ExtractZoneLayerFromGUID(guid)
                if z then
                    zoneUID, instID, srvID, sourceUnit = z, i, s, unit
                    break
                end
            end
        end
    end
    if zoneUID then
        ns.Print(string_format(
            "현재 위상/존 진단: 지역=%s (%s:%s) | ZoneUID=%s · Instance=%s · Server=%s (기준: %s)",
            tostring(zoneName), tostring(instName), tostring(instType),
            tostring(zoneUID), tostring(instID), tostring(srvID), tostring(sourceUnit)
        ))
    else
        ns.Print(string_format(
            "현재 위상/존 진단: 지역=%s (%s:%s) | NPC/몬스터에 마우스를 올리거나 대상으로 잡은 뒤 /fs layer 를 실행하면 ZoneUID(위상)를 표시합니다.",
            tostring(zoneName), tostring(instName), tostring(instType)
        ))
    end
    return zoneUID
end

ns.ModuleManager:Register("Map", Map)
