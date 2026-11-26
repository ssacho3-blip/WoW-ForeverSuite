-- Module: Features/PartyFinderPage.lua
-- Responsibility: Dedicated KPI-8 Party Finder Auto-Parser UI (role filter, dungeon search, live chat ingestion,
--                 and 1-click whisper assist).
-- Layer: Features (uses UI/Widgets + Domain/PartyFinderModel + Api/SafeAPI/GameAdapters).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs
local tostring = tostring
local math_max = math.max
local math_min = math.min

local MAX_ROWS = 12

local PartyFinderPage = {
    id = "partyfinder",
    label = "파티 찾기",
    host = nil,
    board = {},
    roleFilter = "all",
    scrollOffset = 0,
    lastQuery = "",
    rows = {},
    statusLbl = nil,
}
ns.Features.PartyFinderPage = PartyFinderPage

function PartyFinderPage:IngestChatMessage(cleanMsg, cleanSender, channel)
    if ns.Api.SafeAPI.IsSecret(cleanMsg) or ns.Api.SafeAPI.IsSecret(cleanSender) then
        return false
    end
    local now = ns.Api.GameAdapters.GetEpochTimestamp()
    local listing = ns.Domain.PartyFinderModel.ParseListing(cleanMsg, cleanSender, channel, now)
    if not listing then
        return false
    end
    ns.Domain.PartyFinderModel.UpsertListing(self.board, listing, now)
    if self.host and self.host:IsShown() then
        self:Render(self.lastQuery)
    end
    return true
end

function PartyFinderPage:Render(query)
    if not (self.host and self.rows[1]) then return end
    self.lastQuery = query or ""
    local now = ns.Api.GameAdapters.GetEpochTimestamp()
    local list = ns.Domain.PartyFinderModel.FilterBoard(self.board, self.roleFilter, self.lastQuery, now)
    local maxOff = math_max(0, #list - MAX_ROWS)
    self.scrollOffset = math_max(0, math_min(maxOff, self.scrollOffset))

    for i = 1, MAX_ROWS do
        local row = self.rows[i]
        local item = list[self.scrollOffset + i]
        if item then
            row._listing = item
            row._left:SetText("[" .. tostring(item.dungeonName or "") .. " · " .. tostring(item.roleSummary or "") .. "] " .. tostring(item.sender or "") .. ": " .. tostring(item.text or ""))
            row._left:SetTextColor(T.TEXT.PRIMARY[1], T.TEXT.PRIMARY[2], T.TEXT.PRIMARY[3], 1)
            row._right:SetText("클릭 귓속말")
            row._right:SetTextColor(T.TEXT.GOLD[1], T.TEXT.GOLD[2], T.TEXT.GOLD[3], 1)
            row:Show()
        else
            row._listing = nil
            row:Hide()
        end
    end

    if self.statusLbl then
        self.statusLbl:SetText(
            "실시간 파티 모집 " .. tostring(#list) .. "건 (공개/파티찾기 채널 자동 수집 · 10분 경과 자동 만료 · 휠 스크롤)"
        )
    end
end

function PartyFinderPage:Build(parent)
    self.host = parent
    if type(parent.EnableMouseWheel) == "function" then
        parent:EnableMouseWheel(true)
        local prevWheel = type(parent.GetScript) == "function" and parent:GetScript("OnMouseWheel") or nil
        parent:SetScript("OnMouseWheel", function(f, delta)
            if type(prevWheel) == "function" then pcall(prevWheel, f, delta) end
            if not delta or delta == 0 then return end
            PartyFinderPage.scrollOffset = PartyFinderPage.scrollOffset + (delta > 0 and -3 or 3)
            PartyFinderPage:Render(PartyFinderPage.lastQuery)
        end)
    end
    local hdr = W.SectionHeader(parent, "실시간 파티 찾기 도우미 (던전 자동 분류 · 역할 필터)")
    hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    local bar = W.PillBar(parent, {
        { value = "all", label = "전체", width = 62 },
        { value = "tank", label = "탱커 구함", width = 84 },
        { value = "heal", label = "힐러 구함", width = 84 },
        { value = "dps", label = "딜러 구함", width = 84 },
    }, self.roleFilter, function(v)
        PartyFinderPage.roleFilter = v
        PartyFinderPage.scrollOffset = 0
        PartyFinderPage:Render(PartyFinderPage.lastQuery)
    end)
    bar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -28)
    bar:SetWidth(350)

    local clearBtn = W.MiniButton(parent, "목록 비우기", 84, 22, function()
        PartyFinderPage.board = {}
        PartyFinderPage:Render(PartyFinderPage.lastQuery)
    end, "수집된 파티 목록 초기화")
    clearBtn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -30)

    for i = 1, MAX_ROWS do
        local row = W.ListRow(parent, 26, function(btn)
            local item = btn._listing
            if not item then return end
            local lvl = ns.Api.GameAdapters.GetPlayerLevel() or ""
            local cls = ns.Api.GameAdapters.GetPlayerClassLocalized() or ""
            local msg = "안녕하세요! " .. tostring(lvl) .. "렙 " .. tostring(cls) .. " " .. item.dungeonName .. " 지원합니다."
            local sent = ns.Api.GameAdapters.SendChatSafe(msg, "WHISPER", item.sender)
            if sent then
                ns.Api.SafeAPI.Print("지원 귓속말 발송 → " .. item.sender)
            else
                ns.Api.SafeAPI.Print("전투/잠금 상태로 직접 귓속말해 주세요: /w " .. item.sender .. " " .. msg)
            end
        end)
        row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(62 + (i - 1) * 28))
        row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(62 + (i - 1) * 28))
        self.rows[i] = row
    end

    self.statusLbl = W.Label(parent, "", "small", T.TEXT.MUTED)
    self.statusLbl:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 4)
end

function PartyFinderPage:OnShow()
    self:Render(ns.UI.CommandHub.lastQuery or "")
end

function PartyFinderPage:OnSearch(query)
    self.scrollOffset = 0
    self:Render(query)
end
