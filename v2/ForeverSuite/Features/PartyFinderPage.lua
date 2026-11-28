-- Module: Features/PartyFinderPage.lua
-- Responsibility: ForeverSuite v3.0 Safe Party Finder Monitor (role filter, dungeon search, snapshot-based Hover Freeze
--                 preventing row shifts on pointer transition or row click, live expiry revalidation before whisper,
--                 2-step Safe Whisper Draft + optional Quick Send, W.ScrollBar, and W.EmptyState).
-- Layer: Features (uses UI/Widgets + CompositeWidgets + Domain/PartyFinderModel + Api/SafeAPI/GameAdapters).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs
local tostring = tostring
local math_max = math.max
local math_min = math.min

local MAX_ROWS = 11

local PartyFinderPage = {
    id = "partyfinder",
    label = "파티 찾기",
    group = "now",
    host = nil,
    listBox = nil,
    board = {},
    roleFilter = "all",
    scrollOffset = 0,
    lastQuery = "",
    rows = {},
    scrollBar = nil,
    emptyState = nil,
    statusLbl = nil,
    freezeLbl = nil,
    selectedListing = nil,
    detailTitleLbl = nil,
    detailBodyLbl = nil,
    draftBtn = nil,
    quickSendBtn = nil,
    hoverFrozen = false,
    hoverToken = 0,
    nextUid = 0,
    frozenList = nil,
    lastDisplayedList = {},
    pendingUpdates = 0,
    expiryTicker = nil,
}
ns.Features.PartyFinderPage = PartyFinderPage

local function StopExpiryTicker()
    if PartyFinderPage.expiryTicker then
        ns.Api.GameAdapters.CancelTicker(PartyFinderPage.expiryTicker)
        PartyFinderPage.expiryTicker = nil
    end
end

local function SyncExpiryTicker(liveCount)
    if (liveCount or 0) > 0 then
        if not PartyFinderPage.expiryTicker then
            PartyFinderPage.expiryTicker = ns.Api.GameAdapters.StartTicker(30, function()
                PartyFinderPage:RefreshExpiry()
            end)
        end
    else
        StopExpiryTicker()
    end
end

function PartyFinderPage:RefreshExpiry()
    local now = ns.Api.GameAdapters.GetEpochTimestamp()
    if type(now) ~= "number" or now <= 0 then return end
    local live = ns.Domain.PartyFinderModel.FilterBoard(self.board, "all", "", now)
    if ns.UI.CommandHub and type(ns.UI.CommandHub.SetNavBadge) == "function" then
        ns.UI.CommandHub:SetNavBadge("partyfinder", #live)
    end
    SyncExpiryTicker(#live)
    if (not self.hoverFrozen) and self.host and self.host:IsShown() then
        self:Render(self.lastQuery)
    end
end

local function BuildApplyMessage(item)
    local lvl = ns.Api.GameAdapters.GetPlayerLevel() or ""
    local cls = ns.Api.GameAdapters.GetPlayerClassLocalized() or ""
    local prefix = (lvl ~= "" and (tostring(lvl) .. "렙 ") or "") .. (cls ~= "" and (tostring(cls) .. " ") or "")
    return "안녕하세요! " .. prefix .. tostring(item.dungeonName or "파티") .. " 지원합니다."
end

local function IsSameListing(a, b)
    if not (a and b) then return false end
    if a._fsUid ~= nil and b._fsUid ~= nil then
        return a._fsUid == b._fsUid
    end
    return a.sender == b.sender and a.text == b.text and a.dungeonName == b.dungeonName and a.updatedAt == b.updatedAt
end

-- Revalidates selected listing against live non-expired board entries before sending/drafting any whisper
function PartyFinderPage:ResolveLiveSelection()
    local sel = self.selectedListing
    if not sel then return nil end
    local now = ns.Api.GameAdapters.GetEpochTimestamp()
    if ns.Api.SafeAPI.IsSecret(now) or type(now) ~= "number" or now <= 0 then
        ns.Api.SafeAPI.Print("현재 시각을 확인할 수 없어 안전 귓말 지원을 중단했습니다.")
        return nil
    end
    local live = ns.Domain.PartyFinderModel.FilterBoard(self.board, "all", "", now)
    if ns.UI.CommandHub and type(ns.UI.CommandHub.SetNavBadge) == "function" then
        ns.UI.CommandHub:SetNavBadge("partyfinder", #live)
    end
    SyncExpiryTicker(#live)
    for _, item in ipairs(live) do
        if IsSameListing(sel, item) then
            self.selectedListing = item
            return item
        end
    end
    self.selectedListing = nil
    self:SelectListing(nil)
    ns.Api.SafeAPI.Print("선택한 파티 모집글이 만료되었거나 목록에서 제거되었습니다.")
    return nil
end

function PartyFinderPage:SetHoverFrozen(flag)
    local nextState = flag and true or false
    if self.hoverFrozen == nextState then return end
    self.hoverFrozen = nextState
    if self.hoverFrozen then
        local snap = {}
        for i = 1, #self.lastDisplayedList do
            snap[i] = self.lastDisplayedList[i]
        end
        self.frozenList = snap
        if self.freezeLbl then
            local extra = (self.pendingUpdates > 0) and (" (새 글 +" .. tostring(self.pendingUpdates) .. "건)") or ""
            self.freezeLbl:SetText("[일시정지] 읽는 중 목록 고정" .. extra)
            self.freezeLbl:Show()
        end
    else
        self.frozenList = nil
        self.pendingUpdates = 0
        if self.freezeLbl then self.freezeLbl:Hide() end
        if self._pendingSearchReset then
            self._pendingSearchReset = false
            self.scrollOffset = 0
        end
        -- Always refresh on unfreeze so listings that expired while hovering are purged immediately
        if self.host and self.host:IsShown() then
            self:Render(self.lastQuery)
        end
    end
end

function PartyFinderPage:OnPointerEnterList()
    self.hoverToken = self.hoverToken + 1
    self:SetHoverFrozen(true)
end

function PartyFinderPage:OnPointerLeaveList()
    local myToken = self.hoverToken
    local function CheckUnfreeze()
        if self.hoverToken == myToken then
            self:SetHoverFrozen(false)
        end
    end
    -- Defer unfreeze by 1 frame (0.01s) when C_Timer.After is available so moving Row1->Row2 never flickers/flushes!
    if ns.Api and ns.Api.GameAdapters and type(ns.Api.GameAdapters.RunAfter) == "function" then
        if not ns.Api.GameAdapters.RunAfter(0.01, CheckUnfreeze) then
            CheckUnfreeze()
        end
    else
        CheckUnfreeze()
    end
end

function PartyFinderPage:IngestChatMessage(cleanMsg, cleanSender, channel)
    if ns.Api.SafeAPI.IsSecret(cleanMsg) or ns.Api.SafeAPI.IsSecret(cleanSender) then
        return false
    end
    local now = ns.Api.GameAdapters.GetEpochTimestamp()
    local listing = ns.Domain.PartyFinderModel.ParseListing(cleanMsg, cleanSender, channel, now)
    if not listing then
        return false
    end
    self.nextUid = self.nextUid + 1
    listing._fsUid = self.nextUid
    ns.Domain.PartyFinderModel.UpsertListing(self.board, listing, now)
    local liveAll = ns.Domain.PartyFinderModel.FilterBoard(self.board, "all", "", now)
    if ns.UI.CommandHub and type(ns.UI.CommandHub.SetNavBadge) == "function" then
        ns.UI.CommandHub:SetNavBadge("partyfinder", #liveAll)
    end
    SyncExpiryTicker(#liveAll)
    -- G2: Watched-dungeon/keyword floating alert popup + sound even when /fs Hub is closed
    if ns.Api.ProfileStore:Get("social", "partyWatchAlerts") ~= false then
        local watchCsv = ns.Api.ProfileStore:GetState("partyWatchKeywords") or ""
        local words = ns.Domain.ChatToolsModel and ns.Domain.ChatToolsModel.ParseKeywords(watchCsv) or {}
        if #words > 0 then
            local hay = tostring(listing.dungeonName or "") .. " " .. tostring(listing.roleSummary or "") .. " " .. tostring(listing.text or "")
            local hit = ns.Domain.ChatToolsModel.MatchKeyword(hay, words)
            if hit then
                W.Toast(
                    "파티 찾기 알림 [" .. hit .. "]",
                    "[" .. tostring(listing.dungeonName or "파티") .. "] " .. tostring(listing.sender or "") .. ": " .. tostring(listing.text or ""),
                    "GOLD",
                    5.5
                )
                local snd = ns.Api.ProfileStore:Get("ui", "alertSoundKey") or "dingdong"
                if snd ~= "none" then
                    ns.Api.GameAdapters.PlayNotificationSound(snd, 75, "SFX")
                end
            end
        end
    end
    if self.host and self.host:IsShown() then
        if self.hoverFrozen then
            self.pendingUpdates = self.pendingUpdates + 1
            if self.freezeLbl then
                self.freezeLbl:SetText("[일시정지] 읽는 중 목록 고정 (새 글 +" .. tostring(self.pendingUpdates) .. "건)")
                self.freezeLbl:Show()
            end
        else
            self:Render(self.lastQuery)
        end
    end
    return true
end

function PartyFinderPage:SetWatchKeywords(rawCsv)
    if ns.Api.ProfileStore and ns.Api.ProfileStore:SetState("partyWatchKeywords", tostring(rawCsv or "")) then
        ns.Api.SafeAPI.Print("파티 찾기 알림 단어 설정됨: " .. tostring(rawCsv or "(없음)"))
        return true
    end
    return false
end

function PartyFinderPage:SelectListing(item)
    self.selectedListing = item
    if not self.detailTitleLbl then return end
    if not item then
        self.detailTitleLbl:SetText("파티를 클릭해 상세 내용 확인 및 안전 귓말 지원")
        self.detailBodyLbl:SetText("행 클릭 시 실수로 귓속말이 즉시 발송되지 않습니다. 아래 버튼으로 채팅창을 열어 확인 후 전송하세요.")
        if self.draftBtn then self.draftBtn:Hide() end
        if self.quickSendBtn then self.quickSendBtn:Hide() end
        return
    end
    self.detailTitleLbl:SetText(
        "[" .. tostring(item.dungeonName or "파티") .. " · " .. tostring(item.roleSummary or "") .. "] "
        .. tostring(item.sender or "")
    )
    self.detailBodyLbl:SetText(tostring(item.text or ""))
    if self.draftBtn then self.draftBtn:Show() end
    if self.quickSendBtn then self.quickSendBtn:Show() end
end

function PartyFinderPage:RenderRowsFromList(list)
    local total = #list
    local maxOff = math_max(0, total - MAX_ROWS)
    self.scrollOffset = math_max(0, math_min(maxOff, self.scrollOffset))

    if total == 0 then
        for i = 1, MAX_ROWS do
            self.rows[i]._listing = nil
            self.rows[i]:Hide()
        end
        if self.emptyState then self.emptyState:Show() end
        if self.scrollBar then self.scrollBar:SetMetrics(0, MAX_ROWS, 0) end
        self:SelectListing(nil)
    else
        if self.emptyState then self.emptyState:Hide() end
        local rightMargin = (total > MAX_ROWS) and -14 or 0
        for i = 1, MAX_ROWS do
            local row = self.rows[i]
            local item = list[self.scrollOffset + i]
            if item then
                row._listing = item
                local isSel = IsSameListing(self.selectedListing, item)
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", self.listBox, "TOPLEFT", 0, -((i - 1) * 33))
                row:SetPoint("TOPRIGHT", self.listBox, "TOPRIGHT", rightMargin, -((i - 1) * 33))
                row:SetData({
                    icon = T.ICON.CUSTOM.partyFinder,
                    borderCol = isSel and T.BORDER.GOLD or T.BORDER.HAIRLINE,
                    title = "[" .. tostring(item.dungeonName or "") .. " · " .. tostring(item.roleSummary or "") .. "] " .. tostring(item.sender or ""),
                    subtitle = tostring(item.text or ""),
                    rightText = isSel and "선택됨" or "상세 보기",
                    rightCol = isSel and T.SEMANTIC.SUCCESS or T.TEXT.GOLD,
                    selected = isSel,
                    sepCol = T.BORDER.SUBTLE,
                })
                row:Show()
            else
                row._listing = nil
                row:Hide()
            end
        end
        if self.scrollBar then
            self.scrollBar:SetMetrics(self.scrollOffset, MAX_ROWS, total)
        end
    end

    if self.statusLbl then
        self.statusLbl:SetText(
            "실시간 파티 모집 " .. tostring(total) .. "건 (공개/파티찾기 채널 자동 수집 · 10분 만료 · 마우스 올리면 목록 고정)"
        )
    end
end

function PartyFinderPage:Render(query)
    if not (self.host and self.rows[1]) then return end
    self.lastQuery = query or ""
    if self.hoverFrozen and type(self.frozenList) == "table" then
        self:RenderRowsFromList(self.frozenList)
        return
    end
    local now = ns.Api.GameAdapters.GetEpochTimestamp()
    local liveAll = ns.Domain.PartyFinderModel.FilterBoard(self.board, "all", "", now)
    if ns.UI.CommandHub and type(ns.UI.CommandHub.SetNavBadge) == "function" then
        ns.UI.CommandHub:SetNavBadge("partyfinder", #liveAll)
    end
    SyncExpiryTicker(#liveAll)
    local list = ns.Domain.PartyFinderModel.FilterBoard(self.board, self.roleFilter, self.lastQuery, now)
    self.lastDisplayedList = list
    self:RenderRowsFromList(list)
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

    local hdr = W.SectionHeader(parent, "실시간 파티 찾기 (안전 2단계 귓말 · 마우스 호버 고정)")
    hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    local bar = W.PillBar(parent, {
        { value = "all",  label = "전체",      width = 62 },
        { value = "tank", label = "탱커 구함", width = 84 },
        { value = "heal", label = "힐러 구함", width = 84 },
        { value = "dps",  label = "딜러 구함", width = 84 },
    }, self.roleFilter, function(v)
        PartyFinderPage.roleFilter = v
        PartyFinderPage.scrollOffset = 0
        PartyFinderPage:SetHoverFrozen(false)
        PartyFinderPage:Render(PartyFinderPage.lastQuery)
    end)
    bar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -28)
    bar:SetWidth(350)

    local freezeLbl = W.Label(parent, "", "small", T.SEMANTIC.WARN, { justifyH = "RIGHT", wordWrap = false })
    freezeLbl:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -94, -34)
    freezeLbl:Hide()
    self.freezeLbl = freezeLbl

    local clearBtn = W.MiniButton(parent, "목록 비우기", 84, 22, function()
        StopExpiryTicker()
        PartyFinderPage.board = {}
        PartyFinderPage.selectedListing = nil
        PartyFinderPage.hoverFrozen = false
        PartyFinderPage.frozenList = nil
        PartyFinderPage.pendingUpdates = 0
        if ns.UI.CommandHub and type(ns.UI.CommandHub.SetNavBadge) == "function" then
            ns.UI.CommandHub:SetNavBadge("partyfinder", 0)
        end
        PartyFinderPage:Render(PartyFinderPage.lastQuery)
    end, "수집된 파티 목록 초기화")
    clearBtn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -30)

    -- List container holding rows so pointer hover covers full list region cleanly
    local listBox = W.Card(parent, 760, 366)
    listBox:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -62)
    listBox:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -62)
    listBox:EnableMouse(true)
    listBox:SetScript("OnEnter", function() PartyFinderPage:OnPointerEnterList() end)
    listBox:SetScript("OnLeave", function() PartyFinderPage:OnPointerLeaveList() end)
    self.listBox = listBox

    for i = 1, MAX_ROWS do
        local row = W.IconRow(listBox, 32, function(btn)
            local item = btn._listing
            if not item then return end
            PartyFinderPage:SelectListing(item)
            -- Render against frozen snapshot if hovered so rows NEVER shift under the user's cursor on click!
            if PartyFinderPage.hoverFrozen and type(PartyFinderPage.frozenList) == "table" then
                PartyFinderPage:RenderRowsFromList(PartyFinderPage.frozenList)
            else
                PartyFinderPage:Render(PartyFinderPage.lastQuery)
            end
        end)
        row:SetTooltipHandler(
            function(btn)
                PartyFinderPage:OnPointerEnterList()
                local item = btn and btn._listing
                if type(item) == "table" and _G.GameTooltip and type(_G.GameTooltip.SetOwner) == "function" then
                    pcall(function()
                        _G.GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
                        _G.GameTooltip:ClearLines()
                        _G.GameTooltip:AddLine("[" .. tostring(item.dungeonName or "파티") .. " · " .. tostring(item.roleSummary or "") .. "] " .. tostring(item.sender or ""), T.TEXT.GOLD[1], T.TEXT.GOLD[2], T.TEXT.GOLD[3])
                        _G.GameTooltip:AddLine(tostring(item.text or ""), T.TEXT.PRIMARY[1], T.TEXT.PRIMARY[2], T.TEXT.PRIMARY[3], true)
                        _G.GameTooltip:AddLine("클릭하여 하단 카드에서 안전 귓말 지원", T.TEXT.MUTED[1], T.TEXT.MUTED[2], T.TEXT.MUTED[3])
                        _G.GameTooltip:Show()
                    end)
                end
            end,
            function()
                if _G.GameTooltip and type(_G.GameTooltip.Hide) == "function" then
                    pcall(_G.GameTooltip.Hide, _G.GameTooltip)
                end
                PartyFinderPage:OnPointerLeaveList()
            end
        )
        row:SetPoint("TOPLEFT", listBox, "TOPLEFT", 0, -((i - 1) * 33))
        row:SetPoint("TOPRIGHT", listBox, "TOPRIGHT", 0, -((i - 1) * 33))
        self.rows[i] = row
    end

    local sb = W.ScrollBar(listBox, 358, function(newOff)
        PartyFinderPage.scrollOffset = newOff
        PartyFinderPage:Render(PartyFinderPage.lastQuery)
    end)
    sb:SetPoint("TOPRIGHT", listBox, "TOPRIGHT", -2, -4)
    self.scrollBar = sb

    local empty = W.EmptyState(listBox, {
        icon = T.ICON.CUSTOM.partyFinder,
        title = "수집된 파티 모집글이 없습니다",
        desc = "파티찾기(/4) · 공개(/1) 채널에 모집글이 올라오면 던전과 역할별로 자동 분류됩니다.",
    })
    empty:SetAllPoints(listBox)
    self.emptyState = empty

    -- Bottom Safe Action Detail Bar (76px tall for 2-line wrapped recruitment message)
    local detailCard = W.Card(parent, 760, 76)
    detailCard:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 20)
    detailCard:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 20)
    W.SetBorderColor(detailCard, T.BORDER.GOLD_SOFT)

    local dTitle = W.Label(detailCard, "", "heading", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    dTitle:SetPoint("TOPLEFT", detailCard, "TOPLEFT", 12, -8)
    dTitle:SetPoint("TOPRIGHT", detailCard, "TOPRIGHT", -246, -8)
    self.detailTitleLbl = dTitle

    local dBody = W.Label(detailCard, "", "small", T.TEXT.SECONDARY, { justifyH = "LEFT", wordWrap = true })
    if type(dBody.SetJustifyV) == "function" then dBody:SetJustifyV("TOP") end
    dBody:SetPoint("TOPLEFT", detailCard, "TOPLEFT", 12, -28)
    dBody:SetPoint("BOTTOMRIGHT", detailCard, "BOTTOMRIGHT", -246, 6)
    self.detailBodyLbl = dBody

    local quickBtn = W.Button(detailCard, "즉시 지원", 86, 26, function()
        local item = PartyFinderPage:ResolveLiveSelection()
        if not item then return end
        local msg = BuildApplyMessage(item)
        local sent = ns.Api.GameAdapters.SendChatSafe(msg, "WHISPER", item.sender)
        if sent then
            ns.Api.SafeAPI.Print("지원 귓속말 발송 → " .. tostring(item.sender))
        else
            ns.Api.SafeAPI.Print("전투/잠금 상태: /w " .. tostring(item.sender) .. " " .. msg)
        end
    end)
    quickBtn:SetPoint("RIGHT", detailCard, "RIGHT", -10, 0)
    quickBtn:Hide()
    self.quickSendBtn = quickBtn

    local draftBtn = W.Button(detailCard, "귓말 입력창 열기", 132, 26, function()
        local item = PartyFinderPage:ResolveLiveSelection()
        if not item then return end
        local msg = BuildApplyMessage(item)
        local ok = ns.Api.GameAdapters.OpenWhisperDraftSafe(item.sender, msg)
        if not ok then
            W.CopyPasteModal():OpenExport(
                "귓속말 명령어 복사",
                "채팅창에 붙여넣어 전송하세요.",
                "/w " .. tostring(item.sender) .. " " .. msg
            )
        end
    end, true)
    draftBtn:SetPoint("RIGHT", quickBtn, "LEFT", -8, 0)
    draftBtn:Hide()
    self.draftBtn = draftBtn

    self.statusLbl = W.Label(parent, "", "small", T.TEXT.MUTED)
    self.statusLbl:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 4)

    self:SelectListing(nil)
end

function PartyFinderPage:OnShow()
    self.hoverToken = self.hoverToken + 1
    self.hoverFrozen = false
    self.frozenList = nil
    self.pendingUpdates = 0
    if self.freezeLbl then self.freezeLbl:Hide() end
    self:Render("")
end

function PartyFinderPage:OnSearch(query)
    self.lastQuery = query or ""
    if self.hoverFrozen then
        self._pendingSearchReset = true
        self.pendingUpdates = self.pendingUpdates + 1
        if self.freezeLbl then
            self.freezeLbl:SetText("[일시정지] 읽는 중 목록 고정 (검색 대기중)")
            self.freezeLbl:Show()
        end
        return
    end
    self.scrollOffset = 0
    self:Render(self.lastQuery)
end
