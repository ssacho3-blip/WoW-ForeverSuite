-- Module: Domain/DungeonBrowserModel.lua
-- Responsibility: Pure 2-pane Dungeon Browser model (dungeon filter, boss->drop join, quest readiness checklist,
--                 and dungeon run report summary).
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
local math_floor = math.floor
local string_lower = string.lower
local string_find = string.find
local string_gmatch = string.gmatch
local string_format = string.format
local table_insert = table.insert

local DungeonBrowserModel = {}
ns.Domain.DungeonBrowserModel = DungeonBrowserModel

function DungeonBrowserModel.ParseIdCsv(csv)
    local out = {}
    if type(csv) ~= "string" or csv == "" then
        return out
    end
    for tok in string_gmatch(csv, "%d+") do
        local n = tonumber(tok)
        if n and n > 0 then
            table_insert(out, n)
        end
    end
    return out
end

function DungeonBrowserModel.FilterDungeons(dungeons, query, raidFilter)
    local out = {}
    if type(dungeons) ~= "table" then return out end
    local q = string_lower(tostring(query or ""))
    for _, d in ipairs(dungeons) do
        if type(d) == "table" and type(d.title) == "string" then
            local modeOk = true
            if raidFilter == "dungeon" then
                modeOk = (d.isRaid ~= true)
            elseif raidFilter == "raid" then
                modeOk = (d.isRaid == true)
            end
            if modeOk then
                if q == "" then
                    table_insert(out, d)
                else
                    local hay = string_lower(d.title .. " " .. tostring(d.zone or "") .. " " .. tostring(d.levels or ""))
                    if string_find(hay, q, 1, true) then
                        table_insert(out, d)
                    end
                end
            end
        end
    end
    return out
end

function DungeonBrowserModel.GetBossesForDungeon(allBosses, dungeon)
    local out = {}
    if type(dungeon) ~= "table" then
        return out
    end
    local dKey = tostring(dungeon.id or "")
    local dName = tostring(dungeon.title or "")
    local dInst = (type(dungeon.instance) == "number" and dungeon.instance > 0) and dungeon.instance or nil
    for _, b in ipairs(allBosses or {}) do
        if type(b) == "table" then
            local match = (dInst and b.instance == dInst)
                or (dKey ~= "" and b.dungeonKey == dKey)
                or (dName ~= "" and b.dungeonName == dName)
            if match then
                table_insert(out, b)
            end
        end
    end
    return out
end

function DungeonBrowserModel.IndexLootByItemID(allLoot)
    local idx = {}
    for _, it in ipairs(allLoot or {}) do
        if type(it) == "table" and type(it.itemID) == "number" and it.itemID > 0 then
            idx[it.itemID] = it
        end
    end
    return idx
end

function DungeonBrowserModel.GetDropsForBoss(boss, lootByID)
    local out = {}
    if type(boss) ~= "table" then
        return out
    end
    local ids = DungeonBrowserModel.ParseIdCsv(boss.itemsCsv)
    local map = type(lootByID) == "table" and lootByID or {}
    for _, iid in ipairs(ids) do
        local it = map[iid]
        if it then
            table_insert(out, it)
        else
            table_insert(out, {
                itemID = iid,
                title = "아이템 #" .. tostring(iid),
                quality = nil,
                placeholder = true,
                itemLevel = 0,
                slot = "",
                zone = boss.title or "보스 드랍",
            })
        end
    end
    return out
end

-- Evaluates live quest preparation checklist for a dungeon.
-- statusMap: { completed = { [qid]=true|false|nil }, inLog = { [qid]=true } }
function DungeonBrowserModel.BuildQuestReadiness(allQuests, dungeon, statusMap)
    local rows = {}
    local counts = { total = 0, completed = 0, inLog = 0, available = 0, prereq = 0 }
    if type(dungeon) ~= "table" then
        return rows, counts
    end
    local dKey = tostring(dungeon.id or "")
    local dName = tostring(dungeon.title or "")
    local st = type(statusMap) == "table" and statusMap or {}
    local comp = type(st.completed) == "table" and st.completed or {}
    local inLog = type(st.inLog) == "table" and st.inLog or {}

    for _, q in ipairs(allQuests or {}) do
        if type(q) == "table" and (q.dungeonKey == dKey or q.dungeonName == dName) then
            local qid = q.questID
            local state = "AVAILABLE"
            if comp[qid] == true then
                state = "COMPLETED"
                counts.completed = counts.completed + 1
            elseif inLog[qid] == true then
                state = "IN_LOG"
                counts.inLog = counts.inLog + 1
            elseif type(q.prereqID) == "number" and q.prereqID > 0 and comp[q.prereqID] == false then
                state = "PREREQ_NEEDED"
                counts.prereq = counts.prereq + 1
            else
                counts.available = counts.available + 1
            end
            counts.total = counts.total + 1
            table_insert(rows, {
                quest = q,
                state = state,
            })
        end
    end
    return rows, counts
end

function DungeonBrowserModel.FormatDuration(sec)
    if type(sec) ~= "number" or sec < 0 or sec ~= sec then
        return "00:00"
    end
    local s = math_floor(sec)
    local m = math_floor(s / 60)
    local r = s - m * 60
    return string_format("%02d:%02d", m, r)
end

-- B5: Resolve interior map pages & boss pins for a dungeon (from dungeon_map_meta pack)
function DungeonBrowserModel.GetMapPagesForDungeon(metaRows, dungeon)
    local pages, notes = {}, {}
    if type(dungeon) ~= "table" or type(metaRows) ~= "table" then
        return pages, notes
    end
    local dInst = (type(dungeon.instance) == "number" and dungeon.instance > 0) and dungeon.instance or nil
    local dName = tostring(dungeon.title or "")
    for _, m in ipairs(metaRows) do
        if type(m) == "table" then
            local instMatch = dInst and m.instance == dInst
            local nameMatch = (not instMatch) and dName ~= "" and type(m.title) == "string" and string_find(m.title, dName, 1, true)
            if instMatch or nameMatch then
                if m.pageIndex == 99 then
                    table_insert(notes, m)
                elseif type(m.texture) == "string" and m.texture ~= "" then
                    table_insert(pages, m)
                end
            end
        end
    end
    return pages, notes
end

-- B5: Parse "1:280:38|2:252:22|C:254:157" into pixel pin list on 512x512 artwork
function DungeonBrowserModel.ParseBossPins(csv)
    local pins = {}
    if type(csv) ~= "string" or csv == "" then return pins end
    for entry in string_gmatch(csv, "[^|]+") do
        local label, xs, ys = string.match(entry, "^([^:]+):([%d%.%-]+):([%d%.%-]+)$")
        local x, y = tonumber(xs), tonumber(ys)
        if label and x and y then
            table_insert(pins, {
                label = label,
                px = x,
                py = y,
                nx = x / 512.0,
                ny = y / 512.0,
            })
        end
    end
    return pins
end

function DungeonBrowserModel.ResolveMapTexturePath(page)
    if type(page) ~= "table" or type(page.texture) ~= "string" or page.texture == "" then
        return nil
    end
    local tex = page.texture
    local ext = (type(page.extension) == "string" and page.extension ~= "") and page.extension or "tga"
    if string_find(tex, "^Dungeon%d+$") then
        return "Interface\\AddOns\\ForeverSuite_Media_Assets\\Dungeon4130\\" .. tex .. "." .. ext
    end
    return "Interface\\AddOns\\ForeverSuite_Media_Assets\\Maps\\" .. tex .. "." .. ext
end

-- B6: Filter verified step-by-step dungeon quest checklists for a dungeon
function DungeonBrowserModel.FilterStepsForDungeon(stepRows, dungeon, dungeonQuestSet, completedSet)
    local out = {}
    if type(stepRows) ~= "table" or type(dungeon) ~= "table" then return out end
    local dName = tostring(dungeon.title or "")
    local qSet = type(dungeonQuestSet) == "table" and dungeonQuestSet or {}
    local comp = type(completedSet) == "table" and completedSet or {}
    for _, st in ipairs(stepRows) do
        if type(st) == "table" and type(st.questID) == "number" then
            local match = qSet[st.questID] == true
                or (dName ~= "" and type(st.dungeon) == "string" and st.dungeon == dName)
                or (dName ~= "" and type(st.source) == "string" and string_find(st.source, dName, 1, true) ~= nil)
            if match then
                local done = comp[st.questID] == true
                table_insert(out, {
                    step = st,
                    done = done,
                })
            end
        end
    end
    return out
end

-- B6: Lookup creature portrait displayID / fileDataID by npcID
function DungeonBrowserModel.IndexPortraitsByNpcID(rows)
    local map = {}
    for _, r in ipairs(rows or {}) do
        if type(r) == "table" and type(r.npcID) == "number" and r.npcID > 0 then
            map[r.npcID] = r
        end
    end
    return map
end

-- B4: Compute dungeon XP/hour (nil if elapsed < 10s or xp <= 0 — zero fabrication)
function DungeonBrowserModel.ComputeXpPerHour(xpGained, elapsedSec)
    if type(xpGained) ~= "number" or xpGained <= 0 or type(elapsedSec) ~= "number" or elapsedSec < 10 then
        return nil
    end
    return math_floor((xpGained * 3600) / elapsedSec + 0.5)
end

-- B7: Evaluate loot roll item vs equipped slot & BiS catalog
function DungeonBrowserModel.EvaluateRollItem(itemID, itemLevel, equipSlot, equippedMap, bisSet)
    if type(itemID) ~= "number" or itemID <= 0 then return nil end
    local isBiS = (type(bisSet) == "table" and bisSet[itemID] == true)
    local eqIlvl = (type(equippedMap) == "table" and type(equipSlot) == "number" and equipSlot > 0) and equippedMap[equipSlot] or nil
    local delta = (type(itemLevel) == "number" and itemLevel > 0 and type(eqIlvl) == "number" and eqIlvl > 0)
        and (math_floor(itemLevel) - math_floor(eqIlvl)) or nil
    local verdict = "참고"
    local tone = "SECONDARY"
    if isBiS then
        verdict = (delta and delta > 0) and ("★ BiS (+" .. tostring(delta) .. ")") or "★ BiS 추천"
        tone = "GOLD"
    elseif delta and delta > 0 then
        verdict = "+" .. tostring(delta) .. " 업그레이드"
        tone = "SUCCESS"
    elseif delta and delta == 0 then
        verdict = "동급"
        tone = "SECONDARY"
    elseif delta and delta < 0 then
        verdict = tostring(delta) .. " 하위"
        tone = "DANGER"
    end
    return {
        itemID = itemID,
        isBiS = isBiS,
        delta = delta,
        verdict = verdict,
        tone = tone,
    }
end
