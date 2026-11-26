-- Module: Domain/WorldMapModel.lua
-- Responsibility: Pure WorldMap cursor/player coordinate math, formatter (zero-fabrication "—"), and Service NPC/Entrance POI filter.
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local ipairs = ipairs
local tostring = tostring
local string_format = string.format
local string_lower = string.lower
local string_find = string.find
local table_insert = table.insert

local WorldMapModel = {}
ns.Domain.WorldMapModel = WorldMapModel

-- Built-in essential capital / dungeon entrance fallback POIs (augmented automatically by ForeverSuite_Data_Atlas when loaded)
WorldMapModel.CORE_POIS = {
    { mapID = 1453, x = 0.5035, y = 0.6618, name = "스톰윈드 지하감옥 입구", category = "dungeon", faction = "A" },
    { mapID = 1453, x = 0.4956, y = 0.8580, name = "제니아 캐논 (마법사 상급자)", category = "trainer", class = "MAGE", faction = "A" },
    { mapID = 1453, x = 0.4843, y = 0.5022, name = "그레이슨 섀도브레이커 (성기사 상급자)", category = "trainer", class = "PALADIN", faction = "A" },
    { mapID = 1453, x = 0.4953, y = 0.4460, name = "대여사제 로레나 (사제 상급자)", category = "trainer", class = "PRIEST", faction = "A" },
    { mapID = 1453, x = 0.6735, y = 0.3625, name = "아인리스 브라이트스피어 (사냥꾼 상급자)", category = "trainer", class = "HUNTER", faction = "A" },
    { mapID = 1453, x = 0.7820, y = 0.5320, name = "스테판 라이백 (요리 상급자)", category = "service", faction = "A" },
    { mapID = 1454, x = 0.5250, y = 0.4950, name = "성난불길 협곡 입구", category = "dungeon", faction = "H" },
    { mapID = 1454, x = 0.3835, y = 0.8556, name = "페프레도 (마법사 상급자)", category = "trainer", class = "MAGE", faction = "H" },
    { mapID = 1454, x = 0.6605, y = 0.1853, name = "오르막 그림샷 (사냥꾼 상급자)", category = "trainer", class = "HUNTER", faction = "H" },
    { mapID = 1454, x = 0.3601, y = 0.8773, name = "시예라 (사제 상급자)", category = "trainer", class = "PRIEST", faction = "H" },
    { mapID = 1454, x = 0.5750, y = 0.5390, name = "잠자 (요리 상급자)", category = "service", faction = "H" },
    { mapID = 1436, x = 0.3816, y = 0.7748, name = "죽음의 폐광 입구", category = "dungeon", faction = "AH" },
    { mapID = 1413, x = 0.4769, y = 0.3498, name = "통곡의 동굴 입구", category = "dungeon", faction = "AH" },
    { mapID = 1421, x = 0.4472, y = 0.6777, name = "그림자송곳니 성채 입구", category = "dungeon", faction = "AH" },
    { mapID = 1420, x = 0.8508, y = 0.3138, name = "붉은십자군 수도원 입구", category = "dungeon", faction = "AH" },
    { mapID = 1446, x = 0.3873, y = 0.1990, name = "줄파락 입구", category = "dungeon", faction = "AH" },
    { mapID = 1427, x = 0.2715, y = 0.7248, name = "검은바위 나락 입구", category = "dungeon", faction = "AH" },
    { mapID = 1422, x = 0.6905, y = 0.7297, name = "스칼로맨스 입구", category = "dungeon", faction = "AH" },
    { mapID = 1423, x = 0.2609, y = 0.1044, name = "스트라솔름 입구", category = "dungeon", faction = "AH" },
}

-- Computes normalized WoW map coordinates (0..1, top-left origin) from raw screen cursor position and canvas metrics.
-- Returns nil, nil when cursor is outside the canvas or any metric is invalid/NaN.
function WorldMapModel.ComputeCursorCoords(cursorX, cursorY, effScale, left, bottom, width, height)
    if type(cursorX) ~= "number" or type(cursorY) ~= "number"
        or type(effScale) ~= "number" or effScale <= 0
        or type(left) ~= "number" or type(bottom) ~= "number"
        or type(width) ~= "number" or width <= 0
        or type(height) ~= "number" or height <= 0
    then
        return nil, nil
    end
    if cursorX ~= cursorX or cursorY ~= cursorY or effScale ~= effScale then
        return nil, nil
    end
    local sx = cursorX / effScale
    local sy = cursorY / effScale
    local nx = (sx - left) / width
    local ny = 1 - ((sy - bottom) / height)
    if nx < 0 or nx > 1 or ny < 0 or ny > 1 then
        return nil, nil
    end
    return nx, ny
end

-- Formats normalized (0..1) coords as "42.5, 66.1". Never fabricates 0.0 on nil/invalid input.
function WorldMapModel.FormatCoordPair(x, y)
    if type(x) ~= "number" or type(y) ~= "number" or x ~= x or y ~= y then
        return "—"
    end
    if x < 0 or x > 1 or y < 0 or y > 1 then
        return "—"
    end
    return string_format("%.1f, %.1f", x * 100, y * 100)
end

-- Projects normalized map coordinates (0..1, top-left origin) to UIParent screen coordinates given read-only canvas metrics.
function WorldMapModel.ProjectMapToScreen(nx, ny, metrics)
    if type(nx) ~= "number" or type(ny) ~= "number" or type(metrics) ~= "table" then
        return nil, nil
    end
    if nx ~= nx or ny ~= ny or nx < 0 or nx > 1 or ny < 0 or ny > 1 then
        return nil, nil
    end
    if type(metrics.left) ~= "number" or metrics.left ~= metrics.left
        or type(metrics.bottom) ~= "number" or metrics.bottom ~= metrics.bottom
        or type(metrics.width) ~= "number" or metrics.width ~= metrics.width or metrics.width <= 0
        or type(metrics.height) ~= "number" or metrics.height ~= metrics.height or metrics.height <= 0
    then
        return nil, nil
    end
    local sx = metrics.left + (nx * metrics.width)
    local sy = metrics.bottom + ((1 - ny) * metrics.height)
    return sx, sy
end

-- Filters WorldMap `!` quest start pins for a viewed mapID (excludes completed, in-log, wrong-faction, and unmet prereqs).
function WorldMapModel.FilterQuestPins(allPins, mapID, opts)
    local out = {}
    if type(mapID) ~= "number" or mapID <= 0 then
        return out
    end
    opts = type(opts) == "table" and opts or {}
    local faction = opts.faction
    local completedSet = type(opts.completedSet) == "table" and opts.completedSet or {}
    local inLogSet = type(opts.inLogSet) == "table" and opts.inLogSet or {}
    local cap = (type(opts.limit) == "number" and opts.limit > 0) and opts.limit or 36

    for _, p in ipairs(allPins or {}) do
        if type(p) == "table" and p.mapID == mapID and type(p.questID) == "number" then
            local fOk = (not faction) or p.faction == "Both" or p.faction == "" or p.faction == faction
            local notDone = (completedSet[p.questID] ~= true) and (inLogSet[p.questID] ~= true)
            local prereqOk = (type(p.prereqID) ~= "number") or (p.prereqID <= 0) or (completedSet[p.prereqID] ~= false)
            if fOk and notDone and prereqOk then
                table_insert(out, p)
                if #out >= cap then
                    break
                end
            end
        end
    end
    return out
end

function WorldMapModel.FilterPOIs(pois, mapID, category, query, limit)
    local out = {}
    if type(mapID) ~= "number" or mapID <= 0 then
        return out
    end
    local q = string_lower(tostring(query or ""))
    local maxN = (type(limit) == "number" and limit > 0) and limit or 12
    for _, p in ipairs(pois or {}) do
        if type(p) == "table" and p.mapID == mapID then
            local catOk = (not category) or category == "all" or p.category == category or p.kind == category
            if catOk then
                local name = tostring(p.name or "")
                local svc = tostring(p.service or "")
                local hay = string_lower(name .. " " .. svc)
                if q == "" or string_find(hay, q, 1, true) then
                    table_insert(out, p)
                    if #out >= maxN then
                        break
                    end
                end
            end
        end
    end
    return out
end
