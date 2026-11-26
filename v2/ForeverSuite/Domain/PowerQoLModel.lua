-- Module: Domain/PowerQoLModel.lua
-- Responsibility: Pure KPI-12 models (Extended Character Stats formatter, Safe Trade History & Gold Farm GPH,
--                 Favorite /way Bookmarks, and Deterministic Profile Export/Import codec).
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local tonumber = tonumber
local math_floor = math.floor
local string_format = string.format
local string_gmatch = string.gmatch
local string_match = string.match
local table_insert = table.insert
local table_remove = table.remove
local table_sort = table.sort
local table_concat = table.concat

local MAX_TRADES = 50
local MAX_BOOKMARKS = 30

local PowerQoLModel = {
    MAX_TRADES = MAX_TRADES,
    MAX_BOOKMARKS = MAX_BOOKMARKS,
}
ns.Domain.PowerQoLModel = PowerQoLModel

local function FmtNum(v, suffix)
    if type(v) ~= "number" or v ~= v then return "—" end
    return string_format("%.1f%s", v, suffix or "")
end

local function FmtInt(v)
    if type(v) ~= "number" or v ~= v then return "—" end
    return tostring(math_floor(v))
end

function PowerQoLModel.FormatExtendedStatsLines(st)
    if type(st) ~= "table" then return {} end
    local spdTxt = (type(st.moveSpeedPct) == "number" and st.moveSpeedPct == st.moveSpeedPct)
        and (tostring(math_floor(st.moveSpeedPct)) .. "%")
        or "—"
    return {
        { left = "전투력 / 주문력", right = "AP " .. FmtInt(st.attackPower) .. " · SP " .. FmtInt(st.spellPower) },
        { left = "치명타 / 주문 극대화", right = FmtNum(st.meleeCrit, "%") .. " / " .. FmtNum(st.spellCrit, "%") },
        { left = "방어도 / 방어 회피", right = "방어 " .. FmtInt(st.armor) .. " · 회피 " .. FmtNum(st.dodge, "%") .. " · 무기막기 " .. FmtNum(st.parry, "%") },
        { left = "방패 막기 / 이동 속도", right = "방막 " .. FmtNum(st.block, "%") .. " · 이속 " .. spdTxt },
    }
end

function PowerQoLModel.RecordTrade(log, rec)
    if type(log) ~= "table" or type(rec) ~= "table" then return false end
    local partner = (type(rec.partner) == "string" and rec.partner ~= "") and rec.partner or "상대방"
    local given = (type(rec.givenCopper) == "number" and rec.givenCopper >= 0) and math_floor(rec.givenCopper) or 0
    local recv = (type(rec.receivedCopper) == "number" and rec.receivedCopper >= 0) and math_floor(rec.receivedCopper) or 0
    local givenItems = type(rec.givenItems) == "string" and rec.givenItems or ""
    local recvItems = type(rec.receivedItems) == "string" and rec.receivedItems or ""
    if given == 0 and recv == 0 and givenItems == "" and recvItems == "" then
        return false
    end
    table_insert(log, 1, {
        partner = partner,
        givenCopper = given,
        receivedCopper = recv,
        givenItems = givenItems,
        receivedItems = recvItems,
        timestamp = (type(rec.timestamp) == "number") and math_floor(rec.timestamp) or 0,
    })
    while #log > MAX_TRADES do
        table_remove(log)
    end
    return true
end

function PowerQoLModel.ComputeFarmGph(deltaCopper, elapsedSec)
    if type(deltaCopper) ~= "number" or deltaCopper ~= deltaCopper
        or type(elapsedSec) ~= "number" or elapsedSec ~= elapsedSec or elapsedSec < 1
    then
        return nil
    end
    return math_floor((deltaCopper / elapsedSec) * 3600)
end

function PowerQoLModel.AddBookmark(list, label, mapID, x, y)
    if type(list) ~= "table" then return false, "INVALID_LIST" end
    if type(label) ~= "string" or label == "" then return false, "INVALID_LABEL" end
    if type(mapID) ~= "number" or mapID <= 0 or type(x) ~= "number" or type(y) ~= "number" then
        return false, "INVALID_COORDS"
    end
    if x ~= x or y ~= y or x < 0 or x > 1 or y < 0 or y > 1 then
        return false, "OUT_OF_RANGE"
    end
    if #list >= MAX_BOOKMARKS then
        return false, "FULL"
    end
    table_insert(list, {
        label = label,
        mapID = math_floor(mapID),
        x = x,
        y = y,
    })
    return true, "ADDED"
end

function PowerQoLModel.RemoveBookmark(list, index)
    if type(list) ~= "table" or type(index) ~= "number" then return false end
    local idx = math_floor(index)
    if idx < 1 or idx > #list then return false end
    table_remove(list, idx)
    return true
end

-- Deterministic Profile Export/Import: "FS2:sec.key=val;sec.key=val" (ASCII identifier keys only)
function PowerQoLModel.SerializeProfile(settingsBySection)
    if type(settingsBySection) ~= "table" then return "FS2:" end
    local pairsOut = {}
    for sec, tbl in pairs(settingsBySection) do
        if type(sec) == "string" and string_match(sec, "^[%a%d_]+$") and type(tbl) == "table" then
            for k, v in pairs(tbl) do
                if type(k) == "string" and string_match(k, "^[%a%d_]+$")
                    and (type(v) == "boolean" or type(v) == "string" or type(v) == "number")
                then
                    local encoded
                    if type(v) == "boolean" then
                        encoded = v and "b:1" or "b:0"
                    elseif type(v) == "number" then
                        encoded = "n:" .. tostring(v)
                    else
                        -- Strip delimiter characters so token framing stays unambiguous
                        local clean = string.gsub(v, "[;=:]", "")
                        encoded = "s:" .. clean
                    end
                    table_insert(pairsOut, sec .. "." .. k .. "=" .. encoded)
                end
            end
        end
    end
    table_sort(pairsOut)
    return "FS2:" .. table_concat(pairsOut, ";")
end

function PowerQoLModel.DeserializeProfile(raw)
    if type(raw) ~= "string" then return nil, "INVALID_TYPE" end
    local body = string_match(raw, "^%s*FS2:(.-)%s*$")
    if not body then return nil, "INVALID_HEADER" end
    local out = {}
    local count = 0
    for token in string_gmatch(body, "[^;]+") do
        local sec, key, typ, valStr = string_match(token, "^([%a%d_]+)%.([%a%d_]+)=([bns]):(.*)$")
        if not sec then
            return nil, "MALFORMED_TOKEN"
        end
        local val
        if typ == "b" then
            if valStr == "1" then val = true elseif valStr == "0" then val = false else return nil, "BAD_BOOL" end
        elseif typ == "n" then
            val = tonumber(valStr)
            if not val then return nil, "BAD_NUM" end
        else
            val = valStr
        end
        out[sec] = out[sec] or {}
        out[sec][key] = val
        count = count + 1
    end
    return out, count
end
