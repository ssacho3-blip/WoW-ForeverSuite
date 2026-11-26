-- Module: Domain/PartyFinderModel.lua
-- Responsibility: Pure KPI-8 Party Finder chat message parser (25+ Classic/Forever dungeons + Tank/Heal/DPS roles)
--                 and bounded, sender-deduplicated, TTL-expiring listing board.
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local ipairs = ipairs
local tostring = tostring
local string_lower = string.lower
local string_find = string.find
local table_insert = table.insert
local table_remove = table.remove

local MAX_LISTINGS = 60
local TTL_SEC = 600

local DUNGEON_PATTERNS = {
    { id = "rfc", name = "성난불길 협곡", keys = { "성불", "성난불길", "rfc" } },
    { id = "dm", name = "죽음의 폐광", keys = { "죽폐", "폐광", "dm", "vc" } },
    { id = "wc", name = "통곡의 동굴", keys = { "통곡", "wc" } },
    { id = "sfk", name = "그림자송곳니 성채", keys = { "그송", "그림자송곳니", "sfk" } },
    { id = "bfd", name = "검은심연 나락", keys = { "검심", "검은심연", "bfd" } },
    { id = "stock", name = "스톰윈드 지하감옥", keys = { "지하감옥", "감옥", "스톰감옥" } },
    { id = "gnomer", name = "놈리건", keys = { "놈리건", "gnomer" } },
    { id = "rfk", name = "가시덩굴 우리", keys = { "가시덩굴 우리", "가우", "rfk" } },
    { id = "sm", name = "붉은십자군 수도원", keys = { "수도원", "붉십", "무기고", "도서관", "대성당", "묘지" } },
    { id = "rfd", name = "가시덩굴 구릉", keys = { "가시덩굴 구릉", "가구", "rfd" } },
    { id = "dalaran", name = "달라란 시", keys = { "달라란" } },
    { id = "drowned", name = "가라앉은 도시", keys = { "가라앉은", "가도" } },
    { id = "ulda", name = "울다만", keys = { "울다만", "ulda" } },
    { id = "kroldok", name = "크롤도크 보루", keys = { "크롤도크", "크롤" } },
    { id = "zf", name = "줄파락", keys = { "줄파", "줄파락", "zf" } },
    { id = "mara", name = "마라우돈", keys = { "마라", "마라우돈", "공주런" } },
    { id = "st", name = "가라앉은 사원", keys = { "학카르", "아탈학카르", "사원" } },
    { id = "brd", name = "검은바위 나락", keys = { "나락", "검바나락", "brd" } },
    { id = "brs", name = "검은바위 첨탑", keys = { "첨탑", "상층", "하층", "ubrs", "lbrs" } },
    { id = "dmt", name = "혈투의 전장", keys = { "혈장", "혈투", "공물", "북쪽", "동쪽", "서쪽" } },
    { id = "scholo", name = "스칼로맨스", keys = { "스칼", "스칼로", "scholo" } },
    { id = "strat", name = "스트라솔름", keys = { "스트라", "솔름", "남작", "정문", "후문", "strat" } },
    { id = "shapers", name = "구체자의 정원", keys = { "구체자", "정원" } },
    { id = "ony", name = "오닉시아의 둥지", keys = { "오닉", "오닉시아", "ony" } },
    { id = "mc", name = "화산 심장부", keys = { "화심", "화산", "라그", "mc" } },
    { id = "bwl", name = "검은날개 둥지", keys = { "검둥", "검은날개", "bwl" } },
    { id = "zg", name = "줄구룹", keys = { "줄구룹", "zg" } },
}

local PartyFinderModel = {
    MAX_LISTINGS = MAX_LISTINGS,
    TTL_SEC = TTL_SEC,
}
ns.Domain.PartyFinderModel = PartyFinderModel

function PartyFinderModel.ParseListing(rawMsg, sender, channel, now)
    if type(rawMsg) ~= "string" or rawMsg == "" or type(sender) ~= "string" or sender == "" then
        return nil
    end
    local lower = string_lower(rawMsg)
    -- Must look like LFG/LFM recruitment
    local isRecruit = string_find(lower, "구함", 1, true)
        or string_find(lower, "모집", 1, true)
        or string_find(lower, "가실", 1, true)
        or string_find(lower, "출발", 1, true)
        or string_find(lower, "파티", 1, true)
        or string_find(lower, "lfm", 1, true)
        or string_find(lower, "lfg", 1, true)
        or string_find(lower, "탱", 1, true)
        or string_find(lower, "힐", 1, true)
        or string_find(lower, "딜", 1, true)
    if not isRecruit then
        return nil
    end

    local matchedDungeon = nil
    for _, d in ipairs(DUNGEON_PATTERNS) do
        for _, kw in ipairs(d.keys) do
            if string_find(lower, kw, 1, true) then
                matchedDungeon = d
                break
            end
        end
        if matchedDungeon then break end
    end
    if not matchedDungeon then
        return nil
    end

    local needTank = string_find(lower, "탱", 1, true) ~= nil or string_find(lower, "tank", 1, true) ~= nil
    local needHeal = string_find(lower, "힐", 1, true) ~= nil or string_find(lower, "heal", 1, true) ~= nil
    local needDps = string_find(lower, "딜", 1, true) ~= nil or string_find(lower, "dps", 1, true) ~= nil or string_find(lower, "법사", 1, true) ~= nil

    local roleTags = {}
    if needTank then roleTags[#roleTags + 1] = "탱" end
    if needHeal then roleTags[#roleTags + 1] = "힐" end
    if needDps then roleTags[#roleTags + 1] = "딜" end

    return {
        dungeonID = matchedDungeon.id,
        dungeonName = matchedDungeon.name,
        sender = sender,
        channel = tostring(channel or "채널"),
        text = rawMsg,
        needTank = needTank,
        needHeal = needHeal,
        needDps = needDps,
        roleSummary = (#roleTags > 0) and table.concat(roleTags, "/") or "자유",
        updatedAt = (type(now) == "number") and now or 0,
    }
end

function PartyFinderModel.UpsertListing(board, listing, now)
    if type(board) ~= "table" or type(listing) ~= "table" then
        return false
    end
    local tNow = (type(now) == "number") and now or listing.updatedAt or 0
    -- Remove expired or prior entry from same sender
    for i = #board, 1, -1 do
        local e = board[i]
        if e.sender == listing.sender or (tNow > 0 and (tNow - (e.updatedAt or 0)) > TTL_SEC) then
            table_remove(board, i)
        end
    end
    table_insert(board, 1, listing)
    while #board > MAX_LISTINGS do
        table_remove(board)
    end
    return true
end

function PartyFinderModel.FilterBoard(board, roleFilter, query, now)
    local out = {}
    if type(board) ~= "table" then return out end
    local q = string_lower(tostring(query or ""))
    local tNow = (type(now) == "number" and now > 0) and now or nil
    for _, e in ipairs(board) do
        if type(e) == "table" then
            local expired = tNow and type(e.updatedAt) == "number" and e.updatedAt > 0 and ((tNow - e.updatedAt) > TTL_SEC)
            if not expired then
                local roleOk = (not roleFilter) or roleFilter == "all"
                    or (roleFilter == "tank" and e.needTank)
                    or (roleFilter == "heal" and e.needHeal)
                    or (roleFilter == "dps" and e.needDps)
                if roleOk then
                    if q == "" then
                        table_insert(out, e)
                    else
                        local hay = string_lower(tostring(e.dungeonName or "") .. " " .. tostring(e.sender or "") .. " " .. tostring(e.text or ""))
                        if string_find(hay, q, 1, true) then
                            table_insert(out, e)
                        end
                    end
                end
            end
        end
    end
    return out
end
