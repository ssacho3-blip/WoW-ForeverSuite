-- Module: Features/ChatToolsModule.lua
-- Responsibility: Zero-Taint Chat History ring buffer, URL extractor & Keyword Alert Toast via own event frame
--                 (Contract C1: zero mutation of Blizzard chat frames; Invariant I4: drops all secret payloads).
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets

local CHAT_EVENTS = {
    CHAT_MSG_SAY = "일반",
    CHAT_MSG_YELL = "외치기",
    CHAT_MSG_PARTY = "파티",
    CHAT_MSG_PARTY_LEADER = "파티",
    CHAT_MSG_RAID = "공격대",
    CHAT_MSG_RAID_LEADER = "공격대",
    CHAT_MSG_GUILD = "길드",
    CHAT_MSG_WHISPER = "귓속말",
    CHAT_MSG_CHANNEL = "채널",
}

local ChatToolsModule = {
    history = {},
    alertsTriggered = 0,
    initialized = false,
}
ns.Features.ChatToolsModule = ChatToolsModule

function ChatToolsModule:OnChatEvent(eventName, msg, sender, ...)
    -- Invariant I4: If text, sender, or GUID (arg 12 in Classic / arg 10 in compact payloads) is secret, drop immediately
    local arg10 = select(8, ...)
    local arg12 = select(10, ...)
    if ns.Api.SafeAPI.IsSecret(msg) or ns.Api.SafeAPI.IsSecret(sender)
        or ns.Api.SafeAPI.IsSecret(arg10) or ns.Api.SafeAPI.IsSecret(arg12)
    then
        return false, "SECRET"
    end
    if type(msg) ~= "string" or msg == "" then
        return false, "EMPTY"
    end

    local kwRaw = ns.Api.ProfileStore:GetState("chatAlertKeywords") or ""
    local keywords = ns.Domain.ChatToolsModel.ParseKeywords(kwRaw)
    local matched = nil
    if ns.Api.ProfileStore:Get("social", "chatKeywordAlerts") ~= false and #keywords > 0 then
        matched = ns.Domain.ChatToolsModel.MatchKeyword(msg, keywords)
    end

    local chan = CHAT_EVENTS[eventName] or "채팅"
    local safeSenderStr = type(sender) == "string" and sender or "익명"
    local ok = ns.Domain.ChatToolsModel.AppendHistory(self.history, {
        timestamp = ns.Api.GameAdapters.GetEpochTimestamp(),
        channel = chan,
        sender = safeSenderStr,
        text = msg,
        matchedKeyword = matched,
    })

    -- Feed sanitized non-secret messages into PartyFinder auto-parser & live GDKP auction bid engine (KPI-7/8)
    if ns.Features.PartyFinderPage and (eventName == "CHAT_MSG_CHANNEL" or eventName == "CHAT_MSG_SAY" or eventName == "CHAT_MSG_YELL") then
        ns.Features.PartyFinderPage:IngestChatMessage(ns.Domain.ChatToolsModel.SanitizeText(msg), ns.Domain.ChatToolsModel.SanitizeText(safeSenderStr), chan)
    end
    if ns.Features.UtilitiesPage and (eventName == "CHAT_MSG_RAID" or eventName == "CHAT_MSG_RAID_LEADER" or eventName == "CHAT_MSG_PARTY" or eventName == "CHAT_MSG_PARTY_LEADER" or eventName == "CHAT_MSG_WHISPER") then
        ns.Features.UtilitiesPage:OnIncomingChatBid(msg, safeSenderStr)
    end

    if matched then
        self.alertsTriggered = self.alertsTriggered + 1
        local safeSender = ns.Domain.ChatToolsModel.SanitizeText(type(sender) == "string" and sender or "")
        local safeMatch = ns.Domain.ChatToolsModel.SanitizeText(matched)
        local safeBody = ns.Domain.ChatToolsModel.SanitizeText(msg)
        W.Toast("채팅 키워드 알림 [" .. safeMatch .. "]", "[" .. chan .. "] " .. safeSender .. ": " .. safeBody, "WARN")
    end
    return ok, matched
end

function ChatToolsModule:SetKeywords(rawCsv)
    if ns.Api.ProfileStore:SetState("chatAlertKeywords", tostring(rawCsv or "")) then
        ns.Api.SafeAPI.Print("채팅 키워드 알림 설정됨: " .. tostring(rawCsv or "(없음)"))
        return true
    end
    return false
end

function ChatToolsModule:Init()
    if self.initialized then
        return
    end
    self.initialized = true
    for ev in pairs(CHAT_EVENTS) do
        ns.Api.EventBus:OnEvent("v2:chat:" .. ev, ev, function(_, ...)
            ChatToolsModule:OnChatEvent(ev, ...)
        end)
    end
end
