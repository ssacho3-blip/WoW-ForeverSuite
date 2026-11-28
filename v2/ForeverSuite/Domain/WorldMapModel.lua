-- Module: Domain/WorldMapModel.lua
-- Responsibility: Pure WorldMap cursor/player coordinate math, formatter (zero-fabrication "-"), and Service NPC/Entrance POI filter.
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
        return "-"
    end
    if x < 0 or x > 1 or y < 0 or y > 1 then
        return "-"
    end
    return string_format("%.1f, %.1f", x * 100, y * 100)
end

-- Projects normalized map coordinates (0..1, top-left origin) to UIParent screen coordinates given read-only canvas metrics.
-- When metrics.clip is provided (ScrollContainer visible viewport), points outside the visible viewport return nil, nil
-- so zoomed/panned pins NEVER leak outside the WorldMap frame.
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
    local clip = metrics.clip
    if type(clip) == "table" and type(clip.left) == "number" and type(clip.right) == "number"
        and type(clip.bottom) == "number" and type(clip.top) == "number"
    then
        if sx < clip.left or sx > clip.right or sy < clip.bottom or sy > clip.top then
            return nil, nil
        end
    end
    return sx, sy
end

-- Clips a UIParent-space rectangle (left, bottom, right, top) and its UV range (u1, u2, v1, v2) against metrics.clip.
-- Returns nil when completely outside the visible WorldMap viewport.
function WorldMapModel.ClipOverlayRect(left, bottom, right, top, u1, u2, v1, v2, clip)
    if type(left) ~= "number" or type(bottom) ~= "number" or type(right) ~= "number" or type(top) ~= "number" then
        return nil
    end
    if right <= left or top <= bottom then
        return nil
    end
    local cu1, cu2, cv1, cv2 = u1 or 0, u2 or 1, v1 or 0, v2 or 1
    if type(clip) ~= "table" or type(clip.left) ~= "number" or type(clip.right) ~= "number"
        or type(clip.bottom) ~= "number" or type(clip.top) ~= "number"
    then
        return left, bottom, right - left, top - bottom, cu1, cu2, cv1, cv2
    end
    local nl = (left > clip.left) and left or clip.left
    local nr = (right < clip.right) and right or clip.right
    local nb = (bottom > clip.bottom) and bottom or clip.bottom
    local nt = (top < clip.top) and top or clip.top
    if nr <= nl or nt <= nb then
        return nil
    end
    local w = right - left
    local h = top - bottom
    local du = cu2 - cu1
    local dv = cv2 - cv1
    local nu1 = cu1 + ((nl - left) / w) * du
    local nu2 = cu1 + ((nr - left) / w) * du
    -- WoW texture V=0 is TOP, V=1 is BOTTOM
    local nv1 = cv1 + ((top - nt) / h) * dv
    local nv2 = cv1 + ((top - nb) / h) * dv
    return nl, nb, nr - nl, nt - nb, nu1, nu2, nv1, nv2
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

local tonumber = tonumber
local math_ceil = math.ceil
local math_min = math.min
local string_gmatch = string.gmatch

-- E6: Filter WorldMap Fog-of-War reveal tiles for a mapID
function WorldMapModel.FilterRevealTiles(revealRows, mapID)
    local out = {}
    if type(mapID) ~= "number" or mapID <= 0 or type(revealRows) ~= "table" then return out end
    for _, r in ipairs(revealRows) do
        if type(r) == "table" and r.mapID == mapID and type(r.filesCsv) == "string" and r.filesCsv ~= "" then
            table_insert(out, r)
        end
    end
    return out
end

-- E6: Decompose multi-file WorldMapOverlay tile (e.g. 512x256 -> 2 x 256x256 sub-tiles) accurately
function WorldMapModel.ExpandRevealSubTiles(tile, exploredSet)
    local out = {}
    if type(tile) ~= "table" or type(tile.filesCsv) ~= "string" then return out end
    local ids = {}
    for tok in string_gmatch(tile.filesCsv, "%d+") do
        local fid = tonumber(tok)
        if fid and fid > 0 then ids[#ids + 1] = fid end
    end
    if #ids == 0 then return out end
    local exp = type(exploredSet) == "table" and exploredSet or {}
    local tw = (type(tile.w) == "number" and tile.w > 0) and tile.w or 256
    local th = (type(tile.h) == "number" and tile.h > 0) and tile.h or 256
    local ox = (type(tile.x) == "number") and tile.x or 0
    local oy = (type(tile.y) == "number") and tile.y or 0
    local cols = math_ceil(tw / 256)
    if cols < 1 then cols = 1 end
    for idx, fid in ipairs(ids) do
        if not exp[fid] then
            local c = (idx - 1) % cols
            local r = (idx - 1 - c) / cols
            local sx = ox + c * 256
            local sy = oy + r * 256
            local sw = math_min(256, tw - c * 256)
            local sh = math_min(256, th - r * 256)
            if sw > 0 and sh > 0 then
                local fw, fh = 16, 16
                while fw < sw do fw = fw * 2 end
                while fh < sh do fh = fh * 2 end
                table_insert(out, {
                    fileID = fid,
                    x = sx,
                    y = sy,
                    w = sw,
                    h = sh,
                    u2 = sw / fw,
                    v2 = sh / fh,
                })
            end
        end
    end
    return out
end

-- E7: Filter Gather Heatmap sprites for a mapID
function WorldMapModel.FilterGatherHeatmaps(rows, mapID, limit)
    local out = {}
    if type(mapID) ~= "number" or mapID <= 0 or type(rows) ~= "table" then return out end
    local cap = (type(limit) == "number" and limit > 0) and limit or 6
    for _, r in ipairs(rows) do
        if type(r) == "table" and r.mapID == mapID and type(r.file) == "string" and r.file ~= "" then
            table_insert(out, r)
            if #out >= cap then break end
        end
    end
    return out
end

-- E7: Filter Hunter Pet Density Heatmap sprites for a mapID (with exact source rect x0,x1,y0,y1)
function WorldMapModel.FilterPetHeatmaps(rows, mapID, limit)
    local out = {}
    if type(mapID) ~= "number" or mapID <= 0 or type(rows) ~= "table" then return out end
    local cap = (type(limit) == "number" and limit > 0) and limit or 12
    for _, r in ipairs(rows) do
        if type(r) == "table" and r.mapID == mapID and type(r.file) == "string" and r.file ~= "" then
            table_insert(out, r)
            if #out >= cap then break end
        end
    end
    return out
end

-- E3: Selectable Navigation Arrow Styles (GodJohnson Gold-Border 3-layer procedural + ForeverSuite_Media_Assets/Arrows/)
WorldMapModel.ARROW_STYLES = {
    { id = "gold_classic", label = "갓존스 황금 화살표", texture = nil, procedural = true },
    { id = "minimal", label = "심플 화살표",     texture = nil },
    { id = "classic", label = "클래식 라운드",   texture = "Interface\\AddOns\\ForeverSuite_Media_Assets\\Arrows\\Rounded418\\roundedClassic-face.tga" },
    { id = "compass", label = "나침반 링",       texture = "Interface\\AddOns\\ForeverSuite_Media_Assets\\Arrows\\CompassRim.tga" },
    { id = "wedge",   label = "쐐기 3D",         texture = "Interface\\AddOns\\ForeverSuite_Media_Assets\\Arrows\\Rounded418\\roundedWedge-face.tga" },
    { id = "crest",   label = "문장 장식",       texture = "Interface\\AddOns\\ForeverSuite_Media_Assets\\Arrows\\CrestRim.tga" },
    { id = "spear",   label = "창날 화살표",     texture = "Interface\\AddOns\\ForeverSuite_Media_Assets\\Arrows\\SpearRim.tga" },
}

function WorldMapModel.ResolveArrowTexture(styleId)
    for _, st in ipairs(WorldMapModel.ARROW_STYLES) do
        if st.id == styleId then return st.texture end
    end
    return nil
end
