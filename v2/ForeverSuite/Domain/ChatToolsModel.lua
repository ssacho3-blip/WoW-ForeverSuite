-- Module: Domain/ChatToolsModel.lua
-- Responsibility: Pure Chat History ring buffer (bounded), URL extractor with pipe-escape sanitization,
--                 and keyword alert matcher (Invariant I4: never stores secret text).
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local ipairs = ipairs
local tostring = tostring
local math_floor = math.floor
local string_lower = string.lower
local string_find = string.find
local string_gmatch = string.gmatch
local string_gsub = string.gsub
local table_insert = table.insert
local table_remove = table.remove

local MAX_HISTORY = 100
local MAX_URL_LEN = 240

local ChatToolsModel = {
    MAX_HISTORY = MAX_HISTORY,
}
ns.Domain.ChatToolsModel = ChatToolsModel

function ChatToolsModel.SanitizeText(raw)
    if type(raw) ~= "string" then
        return ""
    end
    -- Escape WoW hyperlink/color control sequences so display/copy never injects malformed UI escapes
    return (string_gsub(raw, "|", "||"))
end

function ChatToolsModel.ExtractUrls(raw)
    local out = {}
    if type(raw) ~= "string" or raw == "" then
        return out
    end
    -- Strip WoW color/hyperlink wrappers before URL scanning
    local cleaned = string_gsub(raw, "|c%x%x%x%x%x%x%x%x", "")
    cleaned = string_gsub(cleaned, "|r", "")
    cleaned = string_gsub(cleaned, "|", "")
    for url in string_gmatch(cleaned, "https?://[%w%-%._~:/%?#%[%]@!$&'%(%)%*%+,;=%%]+") do
        if #url <= MAX_URL_LEN then
            table_insert(out, url)
        end
    end
    return out
end

function ChatToolsModel.ParseKeywords(rawCsv)
    local out = {}
    if type(rawCsv) ~= "string" or rawCsv == "" then
        return out
    end
    for tok in string_gmatch(rawCsv, "[^,]+") do
        local trimmed = string_gsub(tok, "^%s*(.-)%s*$", "%1")
        if trimmed ~= "" then
            table_insert(out, string_lower(trimmed))
        end
    end
    return out
end

function ChatToolsModel.MatchKeyword(rawMsg, keywords)
    if type(rawMsg) ~= "string" or rawMsg == "" or type(keywords) ~= "table" or #keywords == 0 then
        return nil
    end
    local lower = string_lower(rawMsg)
    for _, kw in ipairs(keywords) do
        if type(kw) == "string" and kw ~= "" and string_find(lower, kw, 1, true) then
            return kw
        end
    end
    return nil
end

-- Appends a sanitized chat record into bounded ring buffer (newest last; oldest evicted when > maxEntries).
function ChatToolsModel.AppendHistory(ring, entry, maxEntries)
    if type(ring) ~= "table" or type(entry) ~= "table" then
        return false
    end
    local cap = (type(maxEntries) == "number" and maxEntries >= 1) and math_floor(maxEntries) or MAX_HISTORY
    local cleanMsg = ChatToolsModel.SanitizeText(entry.text)
    local cleanSender = ChatToolsModel.SanitizeText(entry.sender)
    if cleanMsg == "" then
        return false
    end
    local urls = ChatToolsModel.ExtractUrls(entry.text)
    table_insert(ring, {
        timestamp = (type(entry.timestamp) == "number") and entry.timestamp or 0,
        channel = tostring(entry.channel or "SAY"),
        sender = cleanSender,
        text = cleanMsg,
        urls = urls,
        matchedKeyword = entry.matchedKeyword,
    })
    while #ring > cap do
        table_remove(ring, 1)
    end
    return true
end
