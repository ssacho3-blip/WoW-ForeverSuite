-- Module: Features/ChatToolsModule.lua
-- Responsibility: Zero-Taint Chat History ring buffer, URL extractor, Keyword Alert Toast,
--                 G4 Compact Chat Quick-Channel Button Bar & Chat Font Size, G5 Channel Join Link Helper & Party Class-Colored Names.
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local type = type

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

local QUICK_CHANNELS = {
    { label = "일반", prefix = "/s " },
    { label = "파티", prefix = "/p " },
    { label = "공대", prefix = "/ra " },
    { label = "길드", prefix = "/g " },
    { label = "파찾", join = "파티찾기", prefix = "/4 " },
}

local ChatToolsModule = {
    history = {},
    alertsTriggered = 0,
    channelBar = nil,
    initialized = false,
}
ns.Features.ChatToolsModule = ChatToolsModule

function ChatToolsModule:EnsureChannelBar()
    if self.channelBar then return self.channelBar end
    local bar = W.Card(_G.UIParent, 232, 24, "ForeverSuiteChatQuickBar", T.ELEVATION.L0_HUD)
    W.SetBorderColor(bar, T.BORDER.SUBTLE)
    local x = 4
    for _, spec in ipairs(QUICK_CHANNELS) do
        local captured = spec
        local b = W.MiniButton(bar, spec.label, 42, 18, function()
            local prefix = captured.prefix
            if captured.join then
                ns.Api.GameAdapters.JoinChannelSafe(captured.join)
                local dynIdx = ns.Api.GameAdapters.GetChannelIndexByNameSafe(captured.join)
                if dynIdx then
                    prefix = "/" .. tostring(dynIdx) .. " "
                end
            end
            if type(_G.ChatFrame_OpenChat) == "function" then
                pcall(_G.ChatFrame_OpenChat, prefix)
            end
        end, captured.label .. " 채널 바로 열기 (" .. captured.prefix .. ")")
        b:SetPoint("LEFT", bar, "LEFT", x, 0)
        x = x + 45
    end
    ns.UI.HudLayout:Register("chatQuickBar", bar, {
        point = "BOTTOMLEFT",
        relPoint = "BOTTOMLEFT",
        x = 24,
        y = 224,
    }, "채팅 빠른 채널 바")
    bar:Hide()
    self.channelBar = bar
    return bar
end

function ChatToolsModule:RefreshChannelBar()
    local bar = self:EnsureChannelBar()
    if ns.UI.HudLayout and ns.UI.HudLayout:IsUnlocked() then return end
    if ns.Api.ProfileStore:Get("social", "showChatButtons") == true then
        bar:Show()
    else
        bar:Hide()
    end
end

-- G4: Apply chat window font size OOC
function ChatToolsModule:ApplyChatFontSize(size)
    local sz = tonumber(size) or (ns.Api.ProfileStore and ns.Api.ProfileStore:GetState("chatFontSize"))
    if type(sz) == "number" and sz >= 10 and sz <= 24 then
        return ns.Api.GameAdapters.SetChatFontSizeSafe(sz)
    end
    return false, "UNSET"
end

-- G5: Join custom channel safely
function ChatToolsModule:JoinChannel(name)
    local ok = ns.Api.GameAdapters.JoinChannelSafe(name)
    if ok then
        ns.Api.SafeAPI.Print("채널 참여 요청: " .. tostring(name))
    end
    return ok
end

-- G5: Format current party members with class-colored hex strings (zero enemy nameplate touch)
function ChatToolsModule:GetPartyClassColoredNames()
    local units, ok = ns.Api.GameAdapters.GetRosterUnitTokens()
    if not ok then return {} end
    local out = {}
    for _, u in ipairs(units) do
        local name, st = ns.Api.GameAdapters.GetUnitNameSafe(u)
        if st == "OK" and name then
            local cls = (u == "player") and ns.Api.GameAdapters.GetPlayerClass() or nil
            if (not cls) and type(_G.UnitClass) == "function" then
                local okC, _, eng = pcall(_G.UnitClass, u)
                if okC and (not ns.Api.SafeAPI.IsSecret(eng)) and type(eng) == "string" then cls = eng end
            end
            local col = (cls and T.CLASS_COLORS[cls]) or T.TEXT.PRIMARY
            local hex = string.format("%02x%02x%02x", math.floor(col[1] * 255), math.floor(col[2] * 255), math.floor(col[3] * 255))
            out[#out + 1] = {
                unit = u,
                name = name,
                class = cls,
                colored = "|cff" .. hex .. name .. "|r",
            }
        end
    end
    return out
end

function ChatToolsModule:PrintPartyClassRoster()
    local list = self:GetPartyClassColoredNames()
    if #list == 0 then
        ns.Api.SafeAPI.Print("현재 파티/공격대 구성원이 없습니다.")
        return false
    end
    local names = {}
    for _, m in ipairs(list) do
        names[#names + 1] = m.colored
    end
    ns.Api.SafeAPI.Print("파티원 직업 현황 (" .. tostring(#names) .. "명): " .. table.concat(names, ", "))
    return true
end

function ChatToolsModule:OnChatEvent(eventName, msg, sender, ...)
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
        local snd = ns.Api.ProfileStore:Get("ui", "alertSoundKey") or "dingdong"
        if snd ~= "none" then
            ns.Api.GameAdapters.PlayNotificationSound(snd, 75, "SFX")
        end
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
    self:RefreshChannelBar()
    for ev in pairs(CHAT_EVENTS) do
        ns.Api.EventBus:OnEvent("v2:chat:" .. ev, ev, function(_, ...)
            ChatToolsModule:OnChatEvent(ev, ...)
        end)
    end
end
