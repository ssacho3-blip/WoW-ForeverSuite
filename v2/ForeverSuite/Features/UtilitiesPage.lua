-- Module: Features/UtilitiesPage.lua
-- Responsibility: ForeverSuite v3.0 Zero-Slash Utilities Suite (Chat/URL + CopyPasteModal, Alt Ledger w/ Class Icons,
--                 Full GUI GDKP Auction & Split Calculator, Extended Stats/Skills, Trade/Farm GPH, and /way Bookmarks).
--                 All 6 sub-tabs feature W.ScrollBar + mousewheel (zero 12-row truncation!).
-- Layer: Features (uses UI/Widgets + CompositeWidgets only; zero raw CreateFrame).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local tonumber = tonumber
local type = type
local math_max = math.max
local math_min = math.min
local math_floor = math.floor

local VISIBLE_ROWS = 10

local UtilitiesPage = {
    id = "utilities",
    label = "유틸 · 골드팟",
    group = "life",
    host = nil,
    activeSub = "gdkp",
    subBar = nil,
    rowPool = {},
    scrollBar = nil,
    scrollOffset = 0,
    emptyState = nil,
    summaryLbl = nil,
    subPanels = {},
    gdkpSales = {},
    gdkpPayouts = {},
    gdkpMembers = 10,
    gdkpCutPct = 0,
    activeAuction = nil,
    lootArchive = {},
    bookmarks = {},
    lastQuery = "",
}
ns.Features.UtilitiesPage = UtilitiesPage

function UtilitiesPage:LoadSavedBookmarks()
    local saved = ns.Api.ProfileStore and ns.Api.ProfileStore:GetState("wayBookmarks")
    if type(saved) == "table" then
        local clean = {}
        for _, b in ipairs(saved) do
            if type(b) == "table" and type(b.label) == "string" and b.label ~= ""
                and type(b.mapID) == "number" and type(b.x) == "number" and type(b.y) == "number"
            then
                clean[#clean + 1] = { label = b.label, mapID = b.mapID, x = b.x, y = b.y }
            end
        end
        self.bookmarks = clean
    end
end

function UtilitiesPage:SaveBookmarks(candidate)
    if ns.Api.ProfileStore and ns.Api.ProfileStore:CanWrite() then
        return ns.Api.ProfileStore:SetState("wayBookmarks", candidate or self.bookmarks) == true
    end
    return false
end

function UtilitiesPage:QuickSaveCurrentLocation(customLabel)
    local pos = ns.Api.GameAdapters.GetPlayerPosition()
    if not pos then
        ns.Api.SafeAPI.Print("현재 위치 좌표를 읽을 수 없습니다.")
        return false
    end
    local label = string.match(tostring(customLabel or ""), "^%s*(.-)%s*$") or ""
    if label == "" then
        local zone = ns.Api.GameAdapters.GetPlayerZoneText()
        label = (zone ~= "" and zone or ("Map #" .. tostring(pos.mapID))) .. " " .. ns.Domain.WorldMapModel.FormatCoordPair(pos.x, pos.y)
    end
    local candidate = {}
    for i = 1, #self.bookmarks do candidate[i] = self.bookmarks[i] end
    local ok, st = ns.Domain.PowerQoLModel.AddBookmark(candidate, label, pos.mapID, pos.x, pos.y)
    if not ok then
        ns.Api.SafeAPI.Print("즐겨찾기 저장 실패: " .. tostring(st))
        return false
    end
    if not self:SaveBookmarks(candidate) then
        ns.Api.SafeAPI.Print("즐겨찾기 저장 실패: 프로필이 읽기 전용입니다.")
        return false
    end
    self.bookmarks = candidate
    ns.Api.SafeAPI.Print("즐겨찾기 저장: " .. label)
    W.Toast("북마크 저장 완료", label, "SUCCESS", 3.0)
    if self.host and self.host:IsShown() and self.activeSub == "bookmarks" then
        self:Render(self.lastQuery)
    end
    return true
end

function UtilitiesPage:HandleFavCommand(raw)
    local sub, rest = string.match(tostring(raw or ""), "^(%S+)%s*(.*)$")
    sub = sub and string.lower(sub) or ""
    if sub == "add" then
        local label = string.match(rest or "", "^%s*(.-)%s*$") or ""
        local pos = ns.Api.GameAdapters.GetPlayerPosition()
        if not pos then
            ns.Api.SafeAPI.Print("현재 위치 좌표를 읽을 수 없습니다.")
            return false
        end
        local candidate = {}
        for i = 1, #self.bookmarks do candidate[i] = self.bookmarks[i] end
        local ok, st = ns.Domain.PowerQoLModel.AddBookmark(candidate, label, pos.mapID, pos.x, pos.y)
        if not ok then
            ns.Api.SafeAPI.Print("즐겨찾기 저장 실패(" .. tostring(st) .. "): /fs fav add <이름>")
            return false
        end
        if not self:SaveBookmarks(candidate) then
            ns.Api.SafeAPI.Print("즐겨찾기 저장 실패: 프로필이 읽기 전용입니다.")
            return false
        end
        self.bookmarks = candidate
        ns.Api.SafeAPI.Print("즐겨찾기 저장: " .. label .. " (" .. ns.Domain.WorldMapModel.FormatCoordPair(pos.x, pos.y) .. ")")
        if self.host and self.host:IsShown() and self.activeSub == "bookmarks" then
            self:Render(self.lastQuery)
        end
        return true
    elseif sub == "del" then
        local idx = tonumber(rest)
        local candidate = {}
        for i = 1, #self.bookmarks do candidate[i] = self.bookmarks[i] end
        if idx and ns.Domain.PowerQoLModel.RemoveBookmark(candidate, idx) then
            if not self:SaveBookmarks(candidate) then
                ns.Api.SafeAPI.Print("즐겨찾기 삭제 실패: 프로필이 읽기 전용입니다.")
                return false
            end
            self.bookmarks = candidate
            ns.Api.SafeAPI.Print("즐겨찾기 #" .. tostring(math_floor(idx)) .. " 삭제됨")
            if self.host and self.host:IsShown() and self.activeSub == "bookmarks" then
                self:Render(self.lastQuery)
            end
            return true
        end
        ns.Api.SafeAPI.Print("사용법: /fs fav del <번호>")
        return false
    end
    ns.Api.SafeAPI.Print("즐겨찾기 " .. tostring(#self.bookmarks) .. "개 · /fs fav add <이름> · /fs fav del <번호>")
    return true
end

function UtilitiesPage:HandleProfileCommand(raw)
    local sub, rest = string.match(tostring(raw or ""), "^(%S+)%s*(.*)$")
    sub = sub and string.lower(sub) or ""
    if sub == "export" then
        local prof = ns.Api.ProfileStore and ns.Api.ProfileStore.db and ns.Api.ProfileStore.db.v2
            and ns.Api.ProfileStore.db.v2.settings
        local str = ns.Domain.PowerQoLModel.SerializeProfile(prof)
        ns.Api.SafeAPI.Print("프로필 내보내기: " .. str)
        return str
    elseif sub == "import" then
        local parsed, cntOrErr = ns.Domain.PowerQoLModel.DeserializeProfile(rest)
        if not parsed then
            ns.Api.SafeAPI.Print("프로필 불러오기 실패(" .. tostring(cntOrErr) .. "): FS2:... 형식이 아닙니다.")
            return false, cntOrErr
        end
        local schemaMap = {}
        for _, sc in ipairs((ns.Api.ProfileStore and ns.Api.ProfileStore.schemas) or {}) do
            schemaMap[sc.section .. "." .. sc.key] = sc
        end
        local applied = 0
        for sec, tbl in pairs(parsed) do
            for k, v in pairs(tbl) do
                local sc = schemaMap[sec .. "." .. k]
                if sc then
                    local okVal = false
                    if sc.type == "boolean" and type(v) == "boolean" then
                        okVal = true
                    elseif sc.type == "enum" and type(v) == "string" then
                        for _, opt in ipairs(sc.options or {}) do
                            if opt.value == v then okVal = true; break end
                        end
                    end
                    if okVal and (sc.combatSafe or not ns.Api.SafeAPI.InCombat()) then
                        if ns.Api.ProfileStore:Set(sec, k, v) then
                            applied = applied + 1
                        end
                    end
                end
            end
        end
        ns.Api.SafeAPI.Print("프로필 불러오기 완료: " .. tostring(applied) .. "개 설정 적용됨")
        return true, applied
    end
    ns.Api.SafeAPI.Print("사용법: /fs profile export | /fs profile import <FS2:...>")
    return false
end

function UtilitiesPage:LoadSavedGdkp()
    local saved = ns.Api.ProfileStore and ns.Api.ProfileStore:GetState("gdkpLedger")
    if type(saved) == "table" then
        if type(saved.sales) == "table" then
            local clean = {}
            for _, s in ipairs(saved.sales) do
                if type(s) == "table" and type(s.item) == "string" and s.item ~= ""
                    and type(s.copper) == "number" and s.copper > 0 and s.copper == math_floor(s.copper)
                then
                    clean[#clean + 1] = {
                        item = s.item,
                        buyer = (type(s.buyer) == "string" and s.buyer ~= "") and s.buyer or "미상",
                        copper = s.copper,
                        paid = s.paid == true,
                    }
                end
            end
            self.gdkpSales = clean
        end
        if type(saved.payouts) == "table" then
            self.gdkpPayouts = saved.payouts
        end
        if type(saved.members) == "number" and saved.members >= 1 and saved.members <= ns.Domain.GdkpModel.MAX_MEMBERS then
            self.gdkpMembers = math_floor(saved.members)
        end
        if type(saved.cutPct) == "number" and saved.cutPct >= 0 and saved.cutPct <= ns.Domain.GdkpModel.MAX_CUT_PCT then
            self.gdkpCutPct = math_floor(saved.cutPct)
        end
    end
    local arch = ns.Api.ProfileStore and ns.Api.ProfileStore:GetState("lootArchive")
    if type(arch) == "table" then self.lootArchive = arch end
end

function UtilitiesPage:SaveGdkp(candidateSales, candidateMembers, candidateCutPct, candidatePayouts)
    if ns.Api.ProfileStore and ns.Api.ProfileStore:CanWrite() then
        return ns.Api.ProfileStore:SetState("gdkpLedger", {
            sales = candidateSales or self.gdkpSales,
            payouts = candidatePayouts or self.gdkpPayouts,
            members = candidateMembers or self.gdkpMembers,
            cutPct = (candidateCutPct ~= nil) and candidateCutPct or self.gdkpCutPct,
        }) == true
    end
    return false
end

-- H2: Auto-match completed trades to GDKP buyer payments & raid member payouts
function UtilitiesPage:OnCompletedTradeForGdkp(partner, receivedCopper, givenCopper)
    if type(partner) ~= "string" or partner == "" then return false end
    local changed = false
    if type(receivedCopper) == "number" and receivedCopper > 0 then
        local cnt, copper = ns.Domain.GdkpModel.MatchBuyerTradePayment(self.gdkpSales, partner, receivedCopper)
        if cnt > 0 then
            changed = true
            ns.Api.SafeAPI.Print("[골팟 자동정산] " .. partner .. " 입금 확인 (" .. tostring(cnt) .. "건 · " .. ns.Domain.LedgerModel.FormatCopper(copper) .. ")")
            W.Toast("골팟 입금 자동 확인", partner .. " · " .. ns.Domain.LedgerModel.FormatCopper(copper), "SUCCESS", 4.0)
        end
    end
    if type(givenCopper) == "number" and givenCopper > 0 then
        local split = ns.Domain.GdkpModel.ComputeSplit(self.gdkpSales, self.gdkpMembers, self.gdkpCutPct)
        local perMem = split and split.perMember or 0
        if perMem > 0 and ns.Domain.GdkpModel.MarkMemberPayout(self.gdkpPayouts, partner, givenCopper, perMem) then
            changed = true
            ns.Api.SafeAPI.Print("[골팟 분배 체크] " .. partner .. " 분배금 지급 완료 (" .. ns.Domain.LedgerModel.FormatCopper(givenCopper) .. ")")
        end
    end
    if changed then
        self:SaveGdkp()
        if self.host and self.host:IsShown() and self.activeSub == "gdkp" then
            self:Render(self.lastQuery)
        end
    end
    return changed
end

function UtilitiesPage:ArchiveCurrentGdkpRun(label)
    if #self.gdkpSales == 0 then return false, "EMPTY" end
    local split = ns.Domain.GdkpModel.ComputeSplit(self.gdkpSales, self.gdkpMembers, self.gdkpCutPct)
    local rec = {
        label = (type(label) == "string" and label ~= "") and label or (ns.Api.GameAdapters.GetPlayerZoneText() ~= "" and ns.Api.GameAdapters.GetPlayerZoneText() or "골드팟 기록"),
        archivedAt = ns.Api.GameAdapters.GetEpochTimestamp(),
        totalPot = split and split.totalPot or 0,
        perMember = split and split.perMember or 0,
        memberCount = self.gdkpMembers,
        saleCount = #self.gdkpSales,
    }
    table.insert(self.lootArchive, 1, rec)
    if #self.lootArchive > 30 then table.remove(self.lootArchive) end
    if ns.Api.ProfileStore and ns.Api.ProfileStore:CanWrite() then
        ns.Api.ProfileStore:SetState("lootArchive", self.lootArchive)
    end
    ns.Api.SafeAPI.Print("골팟 전리품 장부 아카이브 저장: " .. rec.label .. " (" .. ns.Domain.LedgerModel.FormatCopper(rec.totalPot) .. ")")
    return true, rec
end

function UtilitiesPage:OnIncomingChatBid(cleanMsg, cleanSender)
    if ns.Api.SafeAPI.IsSecret(cleanMsg) or ns.Api.SafeAPI.IsSecret(cleanSender) then
        return false, "SECRET"
    end
    if not (self.activeAuction and self.activeAuction.status == "OPEN") then
        return false
    end
    local copper = ns.Domain.GdkpModel.ParseChatBidCopper(cleanMsg)
    if not copper then
        return false
    end
    local now = ns.Api.GameAdapters.GetMonotonicTime() or 0
    local ok, st = ns.Domain.GdkpModel.SubmitBid(self.activeAuction, cleanSender, copper, now)
    if ok then
        ns.Api.SafeAPI.Print(
            "[골팟 최고가] " .. tostring(self.activeAuction.item) .. " - "
            .. cleanSender .. " " .. ns.Domain.LedgerModel.FormatCopper(copper)
        )
        if self.host and self.host:IsShown() and self.activeSub == "gdkp" then
            self:Render(self.lastQuery)
        end
    end
    return ok, st
end

function UtilitiesPage:RecordCurrentCharacter()
    if not (ns.Api.ProfileStore and ns.Api.ProfileStore:CanWrite()) then
        return false
    end
    local name = ns.Api.GameAdapters.GetPlayerName()
    if not name then
        return false
    end
    local store = ns.Api.ProfileStore:GetState("altLedger")
    if type(store) ~= "table" then
        store = {}
    end
    local hasSyndicator = ns.Api.SafeAPI.IsAddOnLoadedByName("Syndicator") or ns.Api.SafeAPI.IsAddOnLoadedByName("Baganator")
    local snap = {
        name = name,
        realm = ns.Api.SafeAPI.GetCanonicalRealm(),
        class = ns.Api.GameAdapters.GetPlayerClass(),
        level = ns.Api.GameAdapters.GetPlayerLevel(),
        gold = ns.Api.SafeAPI.GetPlayerMoney(),
        zone = ns.Api.GameAdapters.GetPlayerZoneText(),
        updatedAt = ns.Api.GameAdapters.GetEpochTimestamp(),
        bagFree = (not hasSyndicator) and ns.Api.SafeAPI.GetBagFreeSlots() or nil,
    }
    ns.Domain.AltInventoryModel.RecordSnapshot(store, snap)
    return ns.Api.ProfileStore:SetState("altLedger", store)
end

function UtilitiesPage:AddGdkpSaleDirect(item, buyer, goldInt)
    local cleanItem = string.match(tostring(item or ""), "^%s*(.-)%s*$") or ""
    local cleanBuyer = string.match(tostring(buyer or ""), "^%s*(.-)%s*$") or ""
    local g = tonumber(goldInt)
    if cleanItem == "" then
        ns.Api.SafeAPI.Print("아이템명을 입력하세요.")
        return false, "INVALID_ITEM"
    end
    if cleanBuyer == "" or string.find(cleanBuyer, "%s") then
        ns.Api.SafeAPI.Print("낙찰자 이름은 공백 없는 캐릭터명으로 입력하세요.")
        return false, "INVALID_BUYER"
    end
    if not (g and g > 0 and g == math_floor(g)) then
        ns.Api.SafeAPI.Print("골드는 양의 정수로 입력하세요.")
        return false, "INVALID_GOLD"
    end
    local candidate = {}
    for i = 1, #self.gdkpSales do candidate[i] = self.gdkpSales[i] end
    local ok, st = ns.Domain.GdkpModel.AddSale(candidate, cleanItem, cleanBuyer, g * 10000)
    if not ok then
        ns.Api.SafeAPI.Print("골팟 등록 실패: " .. tostring(st))
        return false, st
    end
    if not self:SaveGdkp(candidate) then
        ns.Api.SafeAPI.Print("골팟 등록 실패: 프로필이 읽기 전용입니다.")
        return false, "READ_ONLY"
    end
    self.gdkpSales = candidate
    ns.Api.SafeAPI.Print("골팟 등록: " .. cleanItem .. " (" .. cleanBuyer .. ", " .. tostring(g) .. "g)")
    self:Render(self.lastQuery)
    return true, st
end

function UtilitiesPage:StartGdkpAuctionDirect(item, startGold, incGold, durationSec)
    if self.activeAuction and self.activeAuction.status == "OPEN" then
        ns.Api.SafeAPI.Print("진행 중인 경매(" .. tostring(self.activeAuction.item) .. ")를 먼저 낙찰 마감하거나 유찰하세요.")
        return false, "AUCTION_OPEN"
    end
    local cleanItem = string.match(tostring(item or ""), "^%s*(.-)%s*$") or ""
    local sGold = tonumber(startGold)
    if cleanItem == "" or not (sGold and sGold > 0 and sGold == math_floor(sGold)) then
        ns.Api.SafeAPI.Print("아이템명과 시작가(양의 정수 골드)를 입력하세요.")
        return false, "INVALID_ARGS"
    end
    local now = ns.Api.GameAdapters.GetMonotonicTime()
    if type(now) ~= "number" then
        ns.Api.SafeAPI.Print("경매 시작 실패: 클라이언트 타이머를 읽을 수 없습니다.")
        return false, "CLOCK_UNAVAILABLE"
    end
    local iGold = tonumber(incGold) or 10
    local dur = tonumber(durationSec) or 20
    local auc, st = ns.Domain.GdkpModel.StartAuction(cleanItem, sGold, iGold, dur, now)
    if auc then
        self.activeAuction = auc
        local ch = ns.Api.GameAdapters.IsInRaidSafe() and "RAID" or (ns.Api.GameAdapters.IsInGroupSafe() and "PARTY" or nil)
        local msg = "[골팟 경매 시작] " .. cleanItem .. " · 시작가 " .. tostring(sGold) .. "g (최소 단위 " .. tostring(iGold) .. "g · " .. tostring(dur) .. "초)"
        if ch then ns.Api.GameAdapters.SendChatSafe(msg, ch) end
        ns.Api.SafeAPI.Print(msg)
        self:Render(self.lastQuery)
        return true, st
    end
    ns.Api.SafeAPI.Print("경매 시작 실패(" .. tostring(st) .. ")")
    return false, st
end

function UtilitiesPage:HandleGdkpCommand(raw)
    local sub, rest = string.match(tostring(raw or ""), "^(%S+)%s*(.*)$")
    sub = sub and string.lower(sub) or ""
    if sub == "start" then
        local trimmed = string.match(rest or "", "^%s*(.-)%s*$") or ""
        local item, startStr, incStr, durStr = string.match(trimmed, "^(.-)%s+(%d+)%s+(%d+)%s+(%d+)$")
        if not item then
            item, startStr, incStr = string.match(trimmed, "^(.-)%s+(%d+)%s+(%d+)$")
        end
        if not item then
            item, startStr = string.match(trimmed, "^(.-)%s+(%d+)$")
        end
        local ok = self:StartGdkpAuctionDirect(item, startStr, incStr, durStr)
        return ok
    elseif sub == "close" then
        if not self.activeAuction then
            ns.Api.SafeAPI.Print("진행 중인 경매가 없습니다.")
            return false
        end
        if not (ns.Api.ProfileStore and ns.Api.ProfileStore:CanWrite()) then
            ns.Api.SafeAPI.Print("골팟 낙찰 저장 실패: 프로필이 읽기 전용입니다. 공지를 취소했습니다.")
            return false
        end
        local auc = self.activeAuction
        local candidate = {}
        for i = 1, #self.gdkpSales do candidate[i] = self.gdkpSales[i] end
        local ok, st = ns.Domain.GdkpModel.CloseAuction(auc, candidate)
        if st ~= "SOLD" and st ~= "UNSOLD" then
            ns.Api.SafeAPI.Print("경매 마감 불가 상태: " .. tostring(st))
            return false
        end
        if st == "SOLD" then
            if not self:SaveGdkp(candidate) then
                ns.Api.SafeAPI.Print("골팟 낙찰 저장 실패: 공지를 취소했습니다.")
                return false
            end
            self.gdkpSales = candidate
        end
        self.activeAuction = nil
        local ch = ns.Api.GameAdapters.IsInRaidSafe() and "RAID" or (ns.Api.GameAdapters.IsInGroupSafe() and "PARTY" or nil)
        local msg = (st == "SOLD")
            and ("[골팟 낙찰] " .. auc.item .. " → " .. tostring(auc.highBidder) .. " (" .. ns.Domain.LedgerModel.FormatCopper(auc.highBidCopper) .. ")")
            or ("[골팟 유찰] " .. auc.item)
        if ch then ns.Api.GameAdapters.SendChatSafe(msg, ch) end
        ns.Api.SafeAPI.Print(msg)
        self:Render(self.lastQuery)
        return ok
    elseif sub == "cancel" then
        if not self.activeAuction then return false end
        local itemName = tostring(self.activeAuction.item or "")
        self.activeAuction = nil
        ns.Api.SafeAPI.Print("[골팟 유찰 취소] " .. itemName)
        self:Render(self.lastQuery)
        return true
    elseif sub == "announce" then
        local split = ns.Domain.GdkpModel.ComputeSplit(self.gdkpSales, self.gdkpMembers, self.gdkpCutPct)
        if split then
            local msg = "[골팟 정산] 총액 " .. ns.Domain.LedgerModel.FormatCopper(split.totalPot)
                .. " · " .. tostring(split.memberCount) .. "명 1인당 " .. ns.Domain.LedgerModel.FormatCopper(split.perMember)
                .. " (진행 " .. tostring(split.organizerCutPct) .. "%, 잔여 " .. ns.Domain.LedgerModel.FormatCopper(split.remainder) .. ")"
            local ch = ns.Api.GameAdapters.IsInRaidSafe() and "RAID" or (ns.Api.GameAdapters.IsInGroupSafe() and "PARTY" or nil)
            if ch then ns.Api.GameAdapters.SendChatSafe(msg, ch) end
            ns.Api.SafeAPI.Print(msg)
            return true
        end
        return false
    elseif sub == "add" then
        local item, buyer, goldStr = string.match(rest or "", "^(.-)%s+(%S+)%s+(%d+)$")
        if item and buyer and goldStr then
            local ok = self:AddGdkpSaleDirect(item, buyer, tonumber(goldStr))
            return ok
        end
        ns.Api.SafeAPI.Print("사용법: /fs gdkp add <아이템명> <낙찰자> <골드정수>")
        return false
    elseif sub == "members" then
        local n = tonumber(rest)
        if n and n == math_floor(n) and n >= 1 and n <= ns.Domain.GdkpModel.MAX_MEMBERS then
            if not self:SaveGdkp(self.gdkpSales, n, self.gdkpCutPct) then
                ns.Api.SafeAPI.Print("분배 인원 저장 실패: 프로필이 읽기 전용입니다.")
                return false
            end
            self.gdkpMembers = n
            ns.Api.SafeAPI.Print("골팟 분배 인원: " .. tostring(self.gdkpMembers) .. "명")
            self:Render(self.lastQuery)
            return true
        end
        ns.Api.SafeAPI.Print("분배 인원은 1~40 사이 정수여야 합니다.")
        return false
    elseif sub == "cut" then
        local p = tonumber(rest)
        if p and p == math_floor(p) and p >= 0 and p <= ns.Domain.GdkpModel.MAX_CUT_PCT then
            if not self:SaveGdkp(self.gdkpSales, self.gdkpMembers, p) then
                ns.Api.SafeAPI.Print("진행 몫 저장 실패: 프로필이 읽기 전용입니다.")
                return false
            end
            self.gdkpCutPct = p
            ns.Api.SafeAPI.Print("골팟 공대장/진행 몫: " .. tostring(self.gdkpCutPct) .. "%")
            self:Render(self.lastQuery)
            return true
        end
        ns.Api.SafeAPI.Print("진행 몫은 0~50% 정수여야 합니다.")
        return false
    elseif sub == "archive" then
        local ok = self:ArchiveCurrentGdkpRun(rest)
        if not ok then
            ns.Api.SafeAPI.Print("보관할 골팟 판매 내역이 없습니다.")
        else
            self:Render(self.lastQuery)
        end
        return ok
    elseif sub == "reset" then
        if not self:SaveGdkp({}, self.gdkpMembers, self.gdkpCutPct) then
            ns.Api.SafeAPI.Print("골팟 장부 초기화 실패: 프로필이 읽기 전용입니다.")
            return false
        end
        self.gdkpSales = {}
        self.activeAuction = nil
        ns.Api.SafeAPI.Print("골팟 장부를 초기화했습니다.")
        self:Render(self.lastQuery)
        return true
    end
    local split, st = ns.Domain.GdkpModel.ComputeSplit(self.gdkpSales, self.gdkpMembers, self.gdkpCutPct)
    if split then
        ns.Api.SafeAPI.Print(
            "골팟 합계 " .. ns.Domain.LedgerModel.FormatCopper(split.totalPot)
            .. " · " .. tostring(split.memberCount) .. "명 1인당 "
            .. ns.Domain.LedgerModel.FormatCopper(split.perMember)
            .. " (잔여 " .. ns.Domain.LedgerModel.FormatCopper(split.remainder) .. ")"
        )
    else
        ns.Api.SafeAPI.Print("골팟 계산 불가: " .. tostring(st))
    end
    return split ~= nil
end

function UtilitiesPage:SelectSubTab(sub)
    if sub == "stats" then sub = "character" end
    self.activeSub = sub
    self.scrollOffset = 0
    if self.subBar and type(self.subBar.SetValue) == "function" then
        self.subBar:SetValue(sub, true)
    end
    self:Render(self.lastQuery)
end

function UtilitiesPage:EnsureRow(idx)
    if self.rowPool[idx] then
        return self.rowPool[idx]
    end
    local row = W.IconRow(self.host, 32, function(btn, mouseBtn)
        if mouseBtn == "RightButton" and type(btn._onRightClick) == "function" then
            btn._onRightClick()
            return
        end
        if type(btn._onActivate) == "function" then
            btn._onActivate()
        end
    end)
    self.rowPool[idx] = row
    return row
end

function UtilitiesPage:SyncSubPanels()
    for k, panel in pairs(self.subPanels) do
        if k == self.activeSub then
            panel:Show()
        else
            panel:Hide()
        end
    end
    if self.activeSub == "gdkp" and self.gdkpMeta then
        local split = ns.Domain.GdkpModel.ComputeSplit(self.gdkpSales, self.gdkpMembers, self.gdkpCutPct)
        self.gdkpMeta.memLbl:SetText(tostring(self.gdkpMembers) .. "명")
        self.gdkpMeta.cutLbl:SetText("진행 " .. tostring(self.gdkpCutPct) .. "%")
        if split then
            self.gdkpMeta.potLbl:SetText(
                "총액 " .. ns.Domain.LedgerModel.FormatCopper(split.totalPot)
                .. "  |  1인당 " .. ns.Domain.LedgerModel.FormatCopper(split.perMember)
            )
        end
        if self.activeAuction and self.activeAuction.status == "OPEN" then
            local auc = self.activeAuction
            local bidTxt = auc.highBidder
                and (auc.highBidder .. " · " .. ns.Domain.LedgerModel.FormatCopper(auc.highBidCopper))
                or ("시작가 " .. ns.Domain.LedgerModel.FormatCopper(auc.startCopper))
            self.gdkpMeta.bannerLbl:SetText("★ 경매중: " .. tostring(auc.item) .. "  (" .. bidTxt .. ")")
            self.gdkpMeta.banner:Show()
        else
            self.gdkpMeta.banner:Hide()
        end
    elseif self.gdkpMeta and self.gdkpMeta.banner then
        self.gdkpMeta.banner:Hide()
    end
end

function UtilitiesPage:Render(query)
    if not self.host then return end
    self.lastQuery = query or ""
    self:SyncSubPanels()

    local lines = {}
    local summary = ""
    local q = string.lower(tostring(self.lastQuery))
    local emptyTitle, emptyDesc = "표시할 항목이 없습니다", ""

    if self.activeSub == "chat" then
        local hist = (ns.Features.ChatToolsModule and ns.Features.ChatToolsModule.history) or {}
        for i = #hist, 1, -1 do
            local h = hist[i]
            local left = "[" .. h.channel .. "] " .. h.sender .. ": " .. h.text
            local hasUrl = #(h.urls or {}) > 0
            local right = hasUrl and "URL 복사 ↗" or (h.matchedKeyword and ("★ " .. h.matchedKeyword) or "")
            if q == "" or string.find(string.lower(left), q, 1, true) then
                lines[#lines + 1] = {
                    title = left,
                    right = right,
                    color = h.matchedKeyword and T.SEMANTIC.WARN or T.TEXT.PRIMARY,
                    rightCol = hasUrl and T.TEXT.GOLD or T.SEMANTIC.WARN,
                    icon = hasUrl and "Interface\\Icons\\INV_Misc_Note_01" or "Interface\\Icons\\UI_Chat",
                    glyph = hasUrl and "↗" or "말",
                    onClick = hasUrl and function()
                        W.CopyPasteModal():OpenExport(
                            "채팅 URL 복사",
                            "채팅에서 감지된 링크입니다. Ctrl+C (Cmd+C) 로 복사하세요.",
                            tostring(h.urls[1])
                        )
                    end or nil,
                }
            end
        end
        local kw = ns.Api.ProfileStore:GetState("chatAlertKeywords") or "미설정"
        summary = "최근 채팅 " .. tostring(#hist) .. "/100건 · 현재 알림 키워드: " .. tostring(kw)
        emptyTitle = "수집된 채팅 내역이 없습니다"
        emptyDesc = "위 입력창에 알림 키워드를 쉼표(,)로 등록하면 해당 단어가 채팅에 뜰 때 토스트로 알려줍니다."

    elseif self.activeSub == "alts" then
        self:RecordCurrentCharacter()
        local store = ns.Api.ProfileStore:GetState("altLedger") or {}
        local sum = ns.Domain.AltInventoryModel.Summarize(store, q)
        for _, r in ipairs(sum.rows) do
            local lvTxt = (type(r.level) == "number") and ("Lv." .. tostring(r.level)) or "Lv.-"
            local clsTxt = (type(r.class) == "string" and r.class ~= "") and r.class or "-"
            local goldTxt = (type(r.gold) == "number") and ns.Domain.LedgerModel.FormatCopper(r.gold) or "-"
            local hay = string.lower(tostring(r.name or "") .. " " .. clsTxt .. " " .. tostring(r.zone or ""))
            if q == "" or string.find(hay, q, 1, true) then
                lines[#lines + 1] = {
                    title = r.name .. " (" .. lvTxt .. " " .. clsTxt .. ")",
                    subtitle = tostring(r.zone or ""),
                    right = goldTxt,
                    color = (r.class and T.CLASS_COLORS[r.class]) or T.TEXT.PRIMARY,
                    rightCol = T.TEXT.GOLD,
                    icon = r.class and T.ICON.CLASS_TEX[r.class] or nil,
                    borderCol = (r.class and T.CLASS_COLORS[r.class]) or T.BORDER.HAIRLINE,
                }
            end
        end
        summary = "등록 캐릭터 " .. tostring(sum.charCount) .. "명 · 통합 골드 합계 " .. ns.Domain.LedgerModel.FormatCopper(sum.totalGold)
        emptyTitle = "기록된 부캐릭터가 없습니다"
        emptyDesc = "각 캐릭터로 한 번씩 접속하면 렐름 내 레벨·위치·골드가 자동으로 통합됩니다."

    elseif self.activeSub == "gdkp" then
        local split = ns.Domain.GdkpModel.ComputeSplit(self.gdkpSales, self.gdkpMembers, self.gdkpCutPct)
        for i = #self.gdkpSales, 1, -1 do
            local s = self.gdkpSales[i]
            local hay = string.lower(tostring(s.item or "") .. " " .. tostring(s.buyer or ""))
            if q == "" or string.find(hay, q, 1, true) then
                local capturedSale = s
                lines[#lines + 1] = {
                    title = (s.paid and "[V입금] " or "[미수] ") .. tostring(s.item or ""),
                    subtitle = "낙찰자: " .. tostring(s.buyer or "미상") .. " (클릭하여 입금 토글 · 거래 시 자동 체크)",
                    right = ns.Domain.LedgerModel.FormatCopper(s.copper),
                    color = s.paid and T.SEMANTIC.SUCCESS or T.TEXT.GOLD,
                    rightCol = s.paid and T.SEMANTIC.SUCCESS or T.SEMANTIC.WARN,
                    icon = "Interface\\Icons\\INV_Misc_Coin_02",
                    borderCol = s.paid and T.SEMANTIC.SUCCESS or T.BORDER.GOLD_SOFT,
                    onClick = function()
                        capturedSale.paid = not capturedSale.paid
                        UtilitiesPage:SaveGdkp()
                        UtilitiesPage:Render(UtilitiesPage.lastQuery)
                    end,
                }
            end
        end
        local paidMemCount = 0
        for mName, pRec in pairs(self.gdkpPayouts or {}) do
            if type(pRec) == "table" and pRec.paid then
                paidMemCount = paidMemCount + 1
                lines[#lines + 1] = {
                    title = "[V분배] " .. tostring(mName),
                    subtitle = "분배금 지급 완료",
                    right = ns.Domain.LedgerModel.FormatCopper(pRec.copper or 0),
                    color = T.SEMANTIC.SUCCESS,
                    rightCol = T.SEMANTIC.SUCCESS,
                    glyph = "V",
                }
            end
        end
        for _, ar in ipairs(self.lootArchive or {}) do
            lines[#lines + 1] = {
                title = "[아카이브] " .. tostring(ar.label or "골팟 기록"),
                subtitle = tostring(ar.saleCount or 0) .. "건 · " .. tostring(ar.memberCount or 1) .. "인 분배",
                right = ns.Domain.LedgerModel.FormatCopper(ar.totalPot or 0),
                color = T.TEXT.SECONDARY,
                rightCol = T.TEXT.GOLD,
                glyph = "▣",
            }
        end
        if split then
            summary = "총액 " .. ns.Domain.LedgerModel.FormatCopper(split.totalPot)
                .. " · " .. tostring(split.memberCount) .. "명 1인당 " .. ns.Domain.LedgerModel.FormatCopper(split.perMember)
                .. " (진행 " .. tostring(split.organizerCutPct) .. "%, 잔여 " .. ns.Domain.LedgerModel.FormatCopper(split.remainder) .. ")"
        end
        emptyTitle = "등록된 골드팟 낙찰 내역이 없습니다"
        emptyDesc = "위 입력창에 아이템명과 시작골드를 입력해 경매를 시작하거나 수동 등록하세요."

    elseif self.activeSub == "character" then
        local pts = ns.Api.GameAdapters.GetUnspentTalentPoints()
        local stats = ns.Api.GameAdapters.GetExtendedCharacterStats()
        for _, sl in ipairs(ns.Domain.PowerQoLModel.FormatExtendedStatsLines(stats)) do
            local hay = string.lower(tostring(sl.left or "") .. " " .. tostring(sl.right or ""))
            if q == "" or string.find(hay, q, 1, true) then
                lines[#lines + 1] = {
                    title = sl.left,
                    right = sl.right,
                    color = T.TEXT.GOLD,
                    rightCol = T.TEXT.PRIMARY,
                    glyph = "★",
                    borderCol = T.BORDER.GOLD_SOFT,
                }
            end
        end
        local assist = ns.Features and ns.Features.CharacterAssistModule
        local learnable, st = {}, "UNAVAILABLE"
        if assist and type(assist.GetLearnableSpells) == "function" then
            learnable, st = assist:GetLearnableSpells()
        end
        if st == "OK" then
            for _, sp in ipairs(learnable) do
                if q == "" or string.find(string.lower(tostring(sp.name or "")), q, 1, true) then
                    lines[#lines + 1] = {
                        title = tostring(sp.name) .. " (Lv." .. tostring(sp.level) .. ")",
                        right = (sp.cost and sp.cost > 0) and ns.Domain.LedgerModel.FormatCopper(sp.cost) or "상급자 확인",
                        color = T.TEXT.PRIMARY,
                        icon = sp.spellID and ns.Api.GameAdapters.GetSpellIconSafe(sp.spellID) or "Interface\\Icons\\INV_Misc_Book_07",
                    }
                end
            end
        end
        summary = "미사용 특성: " .. (pts ~= nil and (tostring(pts) .. "점") or "확인 불가")
            .. " · 습득 가능 스킬: " .. (st == "OK" and (tostring(#learnable) .. "개") or tostring(st))

    elseif self.activeSub == "trade" then
        local tlog = (ns.Features.TradeLogModule and ns.Features.TradeLogModule.log) or {}
        for _, r in ipairs(tlog) do
            local itemNote = (r.givenItems ~= "" or r.receivedItems ~= "")
                and ("[" .. tostring(r.givenItems) .. " <-> " .. tostring(r.receivedItems) .. "]")
                or "골드 거래"
            local hay = string.lower(tostring(r.partner or "") .. " " .. itemNote)
            if q == "" or string.find(hay, q, 1, true) then
                lines[#lines + 1] = {
                    title = tostring(r.partner),
                    subtitle = itemNote,
                    right = "-" .. ns.Domain.LedgerModel.FormatCopper(r.givenCopper) .. " / +" .. ns.Domain.LedgerModel.FormatCopper(r.receivedCopper),
                    color = T.TEXT.PRIMARY,
                    rightCol = T.TEXT.GOLD,
                    icon = "Interface\\Icons\\INV_Misc_Coin_05",
                }
            end
        end
        local farm = ns.Features.TradeLogModule and ns.Features.TradeLogModule:GetFarmSummary()
        local gphTxt = (farm and farm.gph) and (ns.Domain.LedgerModel.FormatCopper(farm.gph) .. "/h") or "측정 대기"
        summary = "거래 기록 " .. tostring(#tlog) .. "/50건 · 현재 파밍 시급(GPH): " .. gphTxt
        emptyTitle = "완료된 거래 기록이 없습니다"
        emptyDesc = "플레이어와 거래를 완료하면 상대방·아이템·골드가 자동으로 여기에 기록됩니다."

    elseif self.activeSub == "bookmarks" then
        for idx, b in ipairs(self.bookmarks) do
            if q == "" or string.find(string.lower(tostring(b.label or "")), q, 1, true) then
                local capturedIdx = idx
                lines[#lines + 1] = {
                    title = "#" .. tostring(idx) .. " " .. tostring(b.label),
                    subtitle = "좌클릭: /way 길안내  ·  우클릭: 삭제",
                    right = ns.Domain.WorldMapModel.FormatCoordPair(b.x, b.y) .. " · /way",
                    color = T.TEXT.GOLD,
                    rightCol = T.SEMANTIC.INFO,
                    icon = "Interface\\Icons\\INV_Misc_Map_01",
                    borderCol = T.BORDER.GOLD_SOFT,
                    onClick = function()
                        if ns.Features.NavigationHud then
                            ns.Features.NavigationHud:SetTarget(b.mapID, b.x, b.y, b.label)
                        end
                        ns.Api.SafeAPI.Print("즐겨찾기 안내: " .. tostring(b.label))
                    end,
                    onRightClick = function()
                        UtilitiesPage:HandleFavCommand("del " .. tostring(capturedIdx))
                    end,
                }
            end
        end
        summary = "즐겨찾기 " .. tostring(#self.bookmarks) .. "/30개 (좌클릭 길안내 · 우클릭 삭제)"
        emptyTitle = "저장된 위치 북마크가 없습니다"
        emptyDesc = "위 입력창에 장소 이름을 입력하고 [현재 위치 저장]을 눌러 나만의 웨이포인트를 저장하세요."

    elseif self.activeSub == "protect" then
        local prot = ns.Api.ProfileStore and ns.Api.ProfileStore.db and ns.Api.ProfileStore.db.v2
            and ns.Api.ProfileStore.db.v2.protectedItems or {}
        local ids = {}
        for id, flag in pairs(prot) do
            if flag == true and type(id) == "number" and id > 0 then
                ids[#ids + 1] = id
            end
        end
        table.sort(ids)
        for _, id in ipairs(ids) do
            local capturedId = id
            local link = ns.Api.GameAdapters.GetItemLinkSafe(id)
            local label = (type(link) == "string" and link ~= "") and link or ("보호 아이템 #" .. tostring(id))
            local hay = string.lower(label .. " " .. tostring(id))
            if q == "" or string.find(hay, q, 1, true) then
                lines[#lines + 1] = {
                    title = label,
                    subtitle = "아이템 ID #" .. tostring(id) .. " · 상점 잡템 자동 판매에서 제외됨",
                    right = "우클릭 해제",
                    color = T.TEXT.GOLD,
                    rightCol = T.SEMANTIC.DANGER,
                    icon = ns.Api.GameAdapters.GetItemIconSafe(id) or "Interface\\Icons\\INV_Misc_Bag_08",
                    borderCol = T.BORDER.GOLD_SOFT,
                    onRightClick = function()
                        if ns.Features.MerchantModule then
                            ns.Features.MerchantModule:ToggleProtectItem(tostring(capturedId))
                            UtilitiesPage:Render(UtilitiesPage.lastQuery)
                        end
                    end,
                }
            end
        end
        summary = "판매 보호 아이템 " .. tostring(#ids) .. "개 (우클릭 또는 /fs protect <ID> 로 해제)"
        emptyTitle = "등록된 판매 보호 아이템이 없습니다"
        emptyDesc = "위 입력창에 아이템 ID 또는 아이템 링크를 입력해 상점 자동 판매에서 제외할 아이템을 보호하세요."
    end

    -- Top offset depends on active subpanel height
    local listTopY = (self.activeSub == "gdkp") and ((self.activeAuction and self.activeAuction.status == "OPEN") and 190 or 154) or 106
    local rowH = 34
    local maxRows = (self.activeSub == "gdkp") and ((self.activeAuction and self.activeAuction.status == "OPEN") and 8 or 9) or VISIBLE_ROWS
    local total = #lines
    local maxOff = math_max(0, total - maxRows)
    self.scrollOffset = math_max(0, math_min(maxOff, self.scrollOffset))

    for i = 1, #self.rowPool do
        self.rowPool[i]:Hide()
    end

    if total == 0 then
        if self.emptyState then
            self.emptyState:ClearAllPoints()
            self.emptyState:SetPoint("TOPLEFT", self.host, "TOPLEFT", 0, -listTopY)
            self.emptyState:SetPoint("BOTTOMRIGHT", self.host, "BOTTOMRIGHT", 0, 26)
            self.emptyState:SetMessage(emptyTitle, emptyDesc)
            self.emptyState:Show()
        end
        if self.scrollBar then self.scrollBar:SetMetrics(0, maxRows, 0) end
    else
        if self.emptyState then self.emptyState:Hide() end
        local rightMargin = (total > maxRows) and -14 or 0
        for i = 1, maxRows do
            local item = lines[self.scrollOffset + i]
            local row = self:EnsureRow(i)
            if item then
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", self.host, "TOPLEFT", 0, -(listTopY + (i - 1) * rowH))
                row:SetPoint("TOPRIGHT", self.host, "TOPRIGHT", rightMargin, -(listTopY + (i - 1) * rowH))
                row:SetData({
                    icon = item.icon,
                    fallbackGlyph = item.glyph,
                    borderCol = item.borderCol,
                    title = item.title,
                    subtitle = item.subtitle,
                    titleCol = item.color,
                    rightText = item.right,
                    rightCol = item.rightCol or T.TEXT.SECONDARY,
                    sepCol = T.BORDER.SUBTLE,
                })
                row._onActivate = item.onClick
                row._onRightClick = item.onRightClick
                row:Show()
            else
                row:Hide()
            end
        end
        if self.scrollBar then
            self.scrollBar:ClearAllPoints()
            self.scrollBar:SetPoint("TOPRIGHT", self.host, "TOPRIGHT", -2, -listTopY)
            self.scrollBar:SetPoint("BOTTOMRIGHT", self.host, "BOTTOMRIGHT", -2, 26)
            self.scrollBar:SetMetrics(self.scrollOffset, maxRows, total)
        end
    end

    if self.summaryLbl then
        self.summaryLbl:SetText(summary)
    end
end

function UtilitiesPage:Build(parent)
    self.host = parent
    if type(parent.EnableMouseWheel) == "function" then
        parent:EnableMouseWheel(true)
        parent:SetScript("OnMouseWheel", function(_, delta)
            if not delta or delta == 0 then return end
            UtilitiesPage.scrollOffset = UtilitiesPage.scrollOffset + (delta > 0 and -2 or 2)
            UtilitiesPage:Render(UtilitiesPage.lastQuery)
        end)
    end

    local hdr = W.SectionHeader(parent, "유틸리티 · 골드팟(GDKP) · 북마크 · 부캐 · 거래 (Zero-Slash GUI)")
    hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    local bar = W.FlowPillGroup(parent, {
        { value = "gdkp",      label = "골드팟 경매", width = 88 },
        { value = "bookmarks", label = "즐겨찾기",   width = 76 },
        { value = "protect",   label = "보호목록",   width = 76 },
        { value = "chat",      label = "채팅 · URL", width = 84 },
        { value = "alts",      label = "부캐 현황",  width = 78 },
        { value = "trade",     label = "거래 · 파밍", width = 84 },
        { value = "character", label = "스탯 · 스킬", width = 84 },
    }, self.activeSub, 750, function(v)
        UtilitiesPage.activeSub = v
        UtilitiesPage.scrollOffset = 0
        UtilitiesPage:Render(UtilitiesPage.lastQuery)
    end)
    bar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -30)
    self.subBar = bar

    self.subPanels = {}

    -- Sub-panel: GDKP (Zero-Slash member/cut steppers + live auction bar + active auction banner)
    local gdkpPanel = W.Card(parent, 760, 88)
    gdkpPanel:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -60)
    gdkpPanel:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -60)

    local memMinus = W.MiniButton(gdkpPanel, "-", 22, 22, function()
        UtilitiesPage:HandleGdkpCommand("members " .. tostring(math_max(1, UtilitiesPage.gdkpMembers - 1)))
    end, "분배 인원 -1")
    memMinus:SetPoint("TOPLEFT", gdkpPanel, "TOPLEFT", 8, -8)

    local memLbl = W.Label(gdkpPanel, "10명", "mono", T.TEXT.GOLD, { justifyH = "CENTER", wordWrap = false })
    memLbl:SetPoint("LEFT", memMinus, "RIGHT", 6, 0)
    memLbl:SetWidth(42)

    local memPlus = W.MiniButton(gdkpPanel, "+", 22, 22, function()
        UtilitiesPage:HandleGdkpCommand("members " .. tostring(math_min(40, UtilitiesPage.gdkpMembers + 1)))
    end, "분배 인원 +1")
    memPlus:SetPoint("LEFT", memLbl, "RIGHT", 6, 0)

    local syncRaidBtn = W.MiniButton(gdkpPanel, "인원동기화", 72, 22, function()
        local inGroup = ns.Api.GameAdapters.IsInRaidSafe() or ns.Api.GameAdapters.IsInGroupSafe()
        local units = ns.Api.GameAdapters.GetRosterUnitTokens()
        if (not inGroup) or type(units) ~= "table" or #units < 2 then
            ns.Api.SafeAPI.Print("현재 파티/공격대에 소속되어 있지 않아 인원을 변경하지 않았습니다.")
            return
        end
        local cnt = math_max(1, math_min(40, #units))
        UtilitiesPage:HandleGdkpCommand("members " .. tostring(cnt))
    end, "현재 파티/공대 인원 수로 자동 설정")
    syncRaidBtn:SetPoint("LEFT", memPlus, "RIGHT", 6, 0)

    local cutMinus = W.MiniButton(gdkpPanel, "-", 22, 22, function()
        UtilitiesPage:HandleGdkpCommand("cut " .. tostring(math_max(0, UtilitiesPage.gdkpCutPct - 5)))
    end, "진행 몫 -5%")
    cutMinus:SetPoint("LEFT", syncRaidBtn, "RIGHT", 12, 0)

    local cutLbl = W.Label(gdkpPanel, "진행 0%", "mono", T.TEXT.PRIMARY, { justifyH = "CENTER", wordWrap = false })
    cutLbl:SetPoint("LEFT", cutMinus, "RIGHT", 6, 0)
    cutLbl:SetWidth(60)

    local cutPlus = W.MiniButton(gdkpPanel, "+", 22, 22, function()
        UtilitiesPage:HandleGdkpCommand("cut " .. tostring(math_min(50, UtilitiesPage.gdkpCutPct + 5)))
    end, "진행 몫 +5%")
    cutPlus:SetPoint("LEFT", cutLbl, "RIGHT", 6, 0)

    local potLbl = W.Label(gdkpPanel, "", "small", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    potLbl:SetPoint("LEFT", cutPlus, "RIGHT", 12, 0)

    local resetBtn
    resetBtn = W.MiniButton(gdkpPanel, "초기화", 68, 22, function()
        local now = ns.Api.GameAdapters.GetMonotonicTime()
        if type(now) ~= "number" or now <= 0 then
            UtilitiesPage._resetArmedUntil = nil
            resetBtn:SetLabel("초기화")
            resetBtn:SetActive(false)
            ns.Api.SafeAPI.Print("타이머를 확인할 수 없어 안전을 위해 초기화를 취소했습니다.")
            return
        end
        if UtilitiesPage._resetArmedUntil and now <= UtilitiesPage._resetArmedUntil then
            UtilitiesPage._resetArmedUntil = nil
            resetBtn:SetLabel("초기화")
            resetBtn:SetActive(false)
            UtilitiesPage:HandleGdkpCommand("reset")
            return
        end
        UtilitiesPage._resetArmedUntil = now + 5
        local armedUntil = UtilitiesPage._resetArmedUntil
        resetBtn:SetLabel("재클릭확인")
        resetBtn:SetActive(true)
        ns.Api.SafeAPI.Print("5초 내에 [재클릭확인]을 한 번 더 누르면 골드팟 장부가 초기화됩니다.")
        if ns.Api.GameAdapters and type(ns.Api.GameAdapters.RunAfter) == "function" then
            local scheduled = ns.Api.GameAdapters.RunAfter(5.1, function()
                if UtilitiesPage._resetArmedUntil == armedUntil then
                    UtilitiesPage._resetArmedUntil = nil
                    resetBtn:SetLabel("초기화")
                    resetBtn:SetActive(false)
                end
            end)
            if not scheduled then
                UtilitiesPage._resetArmedUntil = nil
                resetBtn:SetLabel("초기화")
                resetBtn:SetActive(false)
            end
        end
    end, "골드팟 장부 초기화 (2회 클릭 확인)")
    resetBtn:SetPoint("TOPRIGHT", gdkpPanel, "TOPRIGHT", -8, -8)

    local annBtn = W.Button(gdkpPanel, "정산 공지", 74, 22, function()
        UtilitiesPage:HandleGdkpCommand("announce")
    end, true)
    annBtn:SetPoint("RIGHT", resetBtn, "LEFT", -6, 0)

    local archBtn = W.MiniButton(gdkpPanel, "장부보관", 62, 22, function()
        UtilitiesPage:HandleGdkpCommand("archive")
    end, "현재 골드팟 정산 내역을 영구 아카이브에 보관")
    archBtn:SetPoint("RIGHT", annBtn, "LEFT", -6, 0)
    potLbl:SetPoint("RIGHT", archBtn, "LEFT", -8, 0)

    local aucBar = W.ActionInputBar(gdkpPanel, {
        { key = "item",  width = 230, placeholder = "아이템명 입력" },
        { key = "gold",  width = 96,  placeholder = "시작가(g)" },
        { key = "buyer", width = 120, placeholder = "낙찰자 (수동등록용)" },
    }, "경매 시작", function(vals)
        local item = string.match(vals.item or "", "^%s*(.-)%s*$") or ""
        local g = tonumber(string.match(vals.gold or "", "^%s*(%d+)%s*$"))
        local buyer = string.match(vals.buyer or "", "^%s*(.-)%s*$") or ""
        if item == "" or not g then
            ns.Api.SafeAPI.Print("아이템명과 골드(정수)를 입력하세요.")
            return false
        end
        if buyer ~= "" then
            return UtilitiesPage:AddGdkpSaleDirect(item, buyer, g)
        end
        return UtilitiesPage:StartGdkpAuctionDirect(item, g)
    end)
    aucBar:SetPoint("TOPLEFT", gdkpPanel, "TOPLEFT", 8, -42)
    aucBar:SetPoint("TOPRIGHT", gdkpPanel, "TOPRIGHT", -8, -42)
    self.gdkpInputBar = aucBar

    -- Active Auction Banner (sibling of gdkpPanel inside parent so it never overflows gdkpPanel bounds)
    local banner = W.Card(parent, 760, 30)
    banner:SetPoint("TOPLEFT", gdkpPanel, "BOTTOMLEFT", 0, -4)
    banner:SetPoint("TOPRIGHT", gdkpPanel, "BOTTOMRIGHT", 0, -4)
    W.SetBorderColor(banner, T.SEMANTIC.WARN)
    local bannerLbl = W.Label(banner, "", "small", T.SEMANTIC.WARN, { justifyH = "LEFT", wordWrap = false })
    bannerLbl:SetPoint("LEFT", banner, "LEFT", 10, 0)
    local cancelAucBtn = W.MiniButton(banner, "× 유찰", 56, 20, function()
        UtilitiesPage:HandleGdkpCommand("cancel")
    end, "경매 취소/유찰")
    cancelAucBtn:SetPoint("RIGHT", banner, "RIGHT", -8, 0)
    local closeAucBtn = W.Button(banner, "V 낙찰 마감", 88, 20, function()
        UtilitiesPage:HandleGdkpCommand("close")
    end, true)
    closeAucBtn:SetPoint("RIGHT", cancelAucBtn, "LEFT", -6, 0)
    bannerLbl:SetPoint("RIGHT", closeAucBtn, "LEFT", -8, 0)
    banner:Hide()

    self.gdkpMeta = { memLbl = memLbl, cutLbl = cutLbl, potLbl = potLbl, banner = banner, bannerLbl = bannerLbl }
    self.subPanels.gdkp = gdkpPanel

    -- Sub-panel: Protect List (Zero-Slash GUI for /fs protect)
    local protPanel = W.Card(parent, 760, 40)
    protPanel:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -60)
    protPanel:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -60)
    local protBar = W.ActionInputBar(protPanel, {
        { key = "item", width = 340, placeholder = "보호할 아이템 ID 또는 아이템 링크 입력 (예: 6948)" },
    }, "보호 등록/해제", function(vals)
        if ns.Features.MerchantModule then
            local ok = ns.Features.MerchantModule:ToggleProtectItem(vals.item or "")
            UtilitiesPage:Render(UtilitiesPage.lastQuery)
            return ok
        end
        return false
    end)
    protBar:SetPoint("LEFT", protPanel, "LEFT", 8, 0)
    protBar:SetPoint("RIGHT", protPanel, "RIGHT", -8, 0)
    self.protectInputBar = protBar
    self.subPanels.protect = protPanel

    -- Sub-panel: Bookmarks (Zero-Slash save current location)
    local bmPanel = W.Card(parent, 760, 40)
    bmPanel:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -60)
    bmPanel:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -60)
    local bmBar = W.ActionInputBar(bmPanel, {
        { key = "label", width = 320, placeholder = "장소 별칭 (비워두면 현재 지역+좌표 자동 입력)" },
    }, "현재 위치 저장", function(vals)
        return UtilitiesPage:QuickSaveCurrentLocation(vals.label)
    end)
    bmBar:SetPoint("LEFT", bmPanel, "LEFT", 8, 0)
    bmBar:SetPoint("RIGHT", bmPanel, "RIGHT", -8, 0)
    self.bookmarkInputBar = bmBar
    self.subPanels.bookmarks = bmPanel

    -- Sub-panel: Chat / URL (Zero-Slash keyword editor)
    local chatPanel = W.Card(parent, 760, 40)
    chatPanel:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -60)
    chatPanel:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -60)
    local kwBar = W.ActionInputBar(chatPanel, {
        { key = "kw", width = 360, placeholder = "알림 키워드 쉼표 구분 (예: 오닉,화심,마부)" },
    }, "키워드 저장", function(vals)
        if ns.Features.ChatToolsModule then
            ns.Features.ChatToolsModule:SetKeywords(vals.kw or "")
            UtilitiesPage:Render(UtilitiesPage.lastQuery)
        end
        return false
    end)
    kwBar:SetPoint("LEFT", chatPanel, "LEFT", 8, 0)
    kwBar:SetPoint("RIGHT", chatPanel, "RIGHT", -8, 0)
    self.keywordInputBar = kwBar
    self.subPanels.chat = chatPanel

    -- Sub-panel: Trade & Farm GPH
    local tradePanel = W.Card(parent, 760, 40)
    tradePanel:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -60)
    tradePanel:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -60)
    local trLbl = W.Label(tradePanel, "거래 완료 시 자동 기록 · 파밍 GPH는 접속 이후 골드 변화율로 실시간 계산됩니다.", "small", T.TEXT.SECONDARY, { justifyH = "LEFT", wordWrap = false })
    trLbl:SetPoint("LEFT", tradePanel, "LEFT", 12, 0)
    local farmResetBtn = W.Button(tradePanel, "파밍 측정 초기화", 124, 24, function()
        if ns.Features.TradeLogModule then
            ns.Features.TradeLogModule:HandleFarmCommand("reset")
            UtilitiesPage:Render(UtilitiesPage.lastQuery)
        end
    end, true)
    farmResetBtn:SetPoint("RIGHT", tradePanel, "RIGHT", -10, 0)
    trLbl:SetPoint("RIGHT", farmResetBtn, "LEFT", -8, 0)
    self.subPanels.trade = tradePanel

    -- Sub-panel: Alts
    local altPanel = W.Card(parent, 760, 40)
    altPanel:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -60)
    altPanel:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -60)
    local altLbl = W.Label(altPanel, "동일 렐름 내 캐릭터 골드·레벨·위치를 자동 기록합니다 (가방 애드온 공존 시 비간섭).", "small", T.TEXT.SECONDARY, { justifyH = "LEFT", wordWrap = false })
    altLbl:SetPoint("LEFT", altPanel, "LEFT", 12, 0)
    local altSyncBtn = W.Button(altPanel, "현재 캐릭터 갱신", 124, 24, function()
        UtilitiesPage:RecordCurrentCharacter()
        UtilitiesPage:Render(UtilitiesPage.lastQuery)
    end)
    altSyncBtn:SetPoint("RIGHT", altPanel, "RIGHT", -10, 0)
    altLbl:SetPoint("RIGHT", altSyncBtn, "LEFT", -8, 0)
    self.subPanels.alts = altPanel

    -- Sub-panel: Character Stats & Trainable Skills
    local charPanel = W.Card(parent, 760, 40)
    charPanel:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -60)
    charPanel:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -60)
    local charLbl = W.Label(charPanel, "확장 전투 스탯(전투력·치명타·주문력·방어도·이속) 및 미습득 직업 스킬 안내", "small", T.TEXT.SECONDARY, { justifyH = "LEFT", wordWrap = false })
    charLbl:SetPoint("LEFT", charPanel, "LEFT", 12, 0)
    local shareBtn = W.Button(charPanel, "프로필 백업·복원", 124, 24, function()
        ns.UI.CommandHub:OpenProfileShareModal("export")
    end, true)
    shareBtn:SetPoint("RIGHT", charPanel, "RIGHT", -10, 0)
    charLbl:SetPoint("RIGHT", shareBtn, "LEFT", -8, 0)
    self.subPanels.character = charPanel

    self.scrollBar = W.ScrollBar(parent, 320, function(newOff)
        UtilitiesPage.scrollOffset = newOff
        UtilitiesPage:Render(UtilitiesPage.lastQuery)
    end)

    self.emptyState = W.EmptyState(parent, {
        title = "표시할 항목이 없습니다",
        desc = "",
    })

    local sum = W.Label(parent, "", "small", T.TEXT.MUTED, { justifyH = "LEFT", wordWrap = false })
    sum:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 4)
    sum:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 4)
    self.summaryLbl = sum
end

function UtilitiesPage:OnShow()
    self:Render("")
end

function UtilitiesPage:OnSearch(query)
    self.scrollOffset = 0
    self:Render(query)
end
