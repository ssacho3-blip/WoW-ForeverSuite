-- Module: Features/UtilitiesPage.lua
-- Responsibility: CommandHub Utilities tab (Chat/URL History, Cross-Character Alt Gold/Level/Zone Ledger [Contract C3],
--                 Integer-Copper GDKP Split Calculator, and Talent/Training Spell Advisor).
-- Layer: Features (uses UI/Widgets only; zero raw CreateFrame).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
local type = type

local MAX_ROWS = 12

local UtilitiesPage = {
    id = "utilities",
    label = "유틸리티",
    host = nil,
    activeSub = "chat",
    rowPool = {},
    summaryLbl = nil,
    gdkpSales = {},
    gdkpMembers = 10,
    gdkpCutPct = 0,
    activeAuction = nil,
    bookmarks = {},
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

function UtilitiesPage:SaveBookmarks()
    if ns.Api.ProfileStore and ns.Api.ProfileStore:CanWrite() then
        ns.Api.ProfileStore:SetState("wayBookmarks", self.bookmarks)
    end
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
        local ok, st = ns.Domain.PowerQoLModel.AddBookmark(self.bookmarks, label, pos.mapID, pos.x, pos.y)
        if ok then
            self:SaveBookmarks()
            ns.Api.SafeAPI.Print("즐겨찾기 저장: " .. label .. " (" .. ns.Domain.WorldMapModel.FormatCoordPair(pos.x, pos.y) .. ")")
            if self.host and self.host:IsShown() and self.activeSub == "bookmarks" then
                self:Render(ns.UI.CommandHub.lastQuery or "")
            end
            return true
        end
        ns.Api.SafeAPI.Print("즐겨찾기 저장 실패(" .. tostring(st) .. "): /fs fav add <이름>")
        return false
    elseif sub == "del" then
        local idx = tonumber(rest)
        if idx and ns.Domain.PowerQoLModel.RemoveBookmark(self.bookmarks, idx) then
            self:SaveBookmarks()
            ns.Api.SafeAPI.Print("즐겨찾기 #" .. tostring(math.floor(idx)) .. " 삭제됨")
            if self.host and self.host:IsShown() and self.activeSub == "bookmarks" then
                self:Render(ns.UI.CommandHub.lastQuery or "")
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
        -- Strictly validate against declared schemas (fail-closed against unknown keys or wrong types)
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
                    and type(s.copper) == "number" and s.copper > 0 and s.copper == math.floor(s.copper)
                then
                    clean[#clean + 1] = {
                        item = s.item,
                        buyer = (type(s.buyer) == "string" and s.buyer ~= "") and s.buyer or "미상",
                        copper = s.copper,
                    }
                end
            end
            self.gdkpSales = clean
        end
        if type(saved.members) == "number" and saved.members >= 1 and saved.members <= ns.Domain.GdkpModel.MAX_MEMBERS then
            self.gdkpMembers = math.floor(saved.members)
        end
        if type(saved.cutPct) == "number" and saved.cutPct >= 0 and saved.cutPct <= ns.Domain.GdkpModel.MAX_CUT_PCT then
            self.gdkpCutPct = math.floor(saved.cutPct)
        end
    end
end

function UtilitiesPage:SaveGdkp()
    if ns.Api.ProfileStore and ns.Api.ProfileStore:CanWrite() then
        ns.Api.ProfileStore:SetState("gdkpLedger", {
            sales = self.gdkpSales,
            members = self.gdkpMembers,
            cutPct = self.gdkpCutPct,
        })
    end
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
            "[골팟 최고가] " .. tostring(self.activeAuction.item) .. " — "
            .. cleanSender .. " " .. ns.Domain.LedgerModel.FormatCopper(copper)
        )
        if self.host and self.host:IsShown() and self.activeSub == "gdkp" then
            self:Render(ns.UI.CommandHub.lastQuery or "")
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
    -- Contract C3: Only capture bagFree when Syndicator/Baganator is not loaded; NEVER pass fabricated 0/1/"UNKNOWN" (F2)
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
        item = item and string.match(item, "^%s*(.-)%s*$") or nil
        local sGold = tonumber(startStr)
        local iGold = tonumber(incStr) or 10
        local dur = tonumber(durStr) or 20
        local now = ns.Api.GameAdapters.GetMonotonicTime() or 0
        local auc, st = ns.Domain.GdkpModel.StartAuction(item, sGold, iGold, dur, now)
        if auc then
            self.activeAuction = auc
            local ch = ns.Api.GameAdapters.IsInRaidSafe() and "RAID" or (ns.Api.GameAdapters.IsInGroupSafe() and "PARTY" or nil)
            local msg = "[골팟 경매 시작] " .. item .. " · 시작가 " .. tostring(sGold) .. "g (최소 단위 " .. tostring(iGold) .. "g · " .. tostring(dur) .. "초)"
            if ch then ns.Api.GameAdapters.SendChatSafe(msg, ch) end
            ns.Api.SafeAPI.Print(msg)
            self:Render(ns.UI.CommandHub.lastQuery or "")
            return true
        end
        ns.Api.SafeAPI.Print("경매 시작 실패(" .. tostring(st) .. "): /fs gdkp start <아이템명> <시작골드> [단위] [초]")
        return false
    elseif sub == "close" then
        if not self.activeAuction then
            ns.Api.SafeAPI.Print("진행 중인 경매가 없습니다.")
            return false
        end
        local auc = self.activeAuction
        local ok, st = ns.Domain.GdkpModel.CloseAuction(auc, self.gdkpSales)
        self.activeAuction = nil
        self:SaveGdkp()
        local ch = ns.Api.GameAdapters.IsInRaidSafe() and "RAID" or (ns.Api.GameAdapters.IsInGroupSafe() and "PARTY" or nil)
        local msg = (st == "SOLD")
            and ("[골팟 낙찰] " .. auc.item .. " → " .. tostring(auc.highBidder) .. " (" .. ns.Domain.LedgerModel.FormatCopper(auc.highBidCopper) .. ")")
            or ("[골팟 유찰] " .. auc.item)
        if ch then ns.Api.GameAdapters.SendChatSafe(msg, ch) end
        ns.Api.SafeAPI.Print(msg)
        self:Render(ns.UI.CommandHub.lastQuery or "")
        return ok
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
        -- Support multi-word item names & WoW item links with spaces (F6)
        local item, buyer, goldStr = string.match(rest or "", "^(.-)%s+(%S+)%s+(%d+)$")
        item = item and string.match(item, "^%s*(.-)%s*$") or nil
        local g = tonumber(goldStr)
        if item and item ~= "" and buyer and g and g > 0 and g == math.floor(g) then
            local ok, st = ns.Domain.GdkpModel.AddSale(self.gdkpSales, item, buyer, g * 10000)
            if ok then
                self:SaveGdkp()
                ns.Api.SafeAPI.Print("골팟 등록: " .. item .. " (" .. buyer .. ", " .. tostring(g) .. "g)")
                self:Render(ns.UI.CommandHub.lastQuery or "")
                return true
            end
            ns.Api.SafeAPI.Print("골팟 등록 실패: " .. tostring(st))
            return false
        end
        ns.Api.SafeAPI.Print("사용법: /fs gdkp add <아이템명> <낙찰자> <골드정수>")
        return false
    elseif sub == "members" then
        local n = tonumber(rest)
        if n and n == math.floor(n) and n >= 1 and n <= ns.Domain.GdkpModel.MAX_MEMBERS then
            self.gdkpMembers = n
            self:SaveGdkp()
            ns.Api.SafeAPI.Print("골팟 분배 인원: " .. tostring(self.gdkpMembers) .. "명")
            self:Render(ns.UI.CommandHub.lastQuery or "")
            return true
        end
        ns.Api.SafeAPI.Print("분배 인원은 1~40 사이 정수여야 합니다.")
        return false
    elseif sub == "cut" then
        local p = tonumber(rest)
        if p and p == math.floor(p) and p >= 0 and p <= ns.Domain.GdkpModel.MAX_CUT_PCT then
            self.gdkpCutPct = p
            self:SaveGdkp()
            ns.Api.SafeAPI.Print("골팟 공대장/진행 몫: " .. tostring(self.gdkpCutPct) .. "%")
            self:Render(ns.UI.CommandHub.lastQuery or "")
            return true
        end
        ns.Api.SafeAPI.Print("진행 몫은 0~50% 정수여야 합니다.")
        return false
    elseif sub == "reset" then
        self.gdkpSales = {}
        self.activeAuction = nil
        self:SaveGdkp()
        ns.Api.SafeAPI.Print("골팟 장부를 초기화했습니다.")
        self:Render(ns.UI.CommandHub.lastQuery or "")
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

function UtilitiesPage:EnsureRow(idx)
    if self.rowPool[idx] then
        return self.rowPool[idx]
    end
    local row = W.ListRow(self.host, 24, function(btn)
        if type(btn._onActivate) == "function" then
            btn._onActivate()
        end
    end)
    self.rowPool[idx] = row
    return row
end

function UtilitiesPage:Render(query)
    if not self.host then return end
    for i = 1, #self.rowPool do
        self.rowPool[i]:Hide()
    end

    local lines = {}
    local summary = ""
    local q = string.lower(tostring(query or ""))

    if self.activeSub == "chat" then
        local hist = (ns.Features.ChatToolsModule and ns.Features.ChatToolsModule.history) or {}
        for i = #hist, 1, -1 do
            local h = hist[i]
            local left = "[" .. h.channel .. "] " .. h.sender .. ": " .. h.text
            local right = (#(h.urls or {}) > 0) and ("URL " .. tostring(#h.urls) .. "건") or (h.matchedKeyword and ("★ " .. h.matchedKeyword) or "")
            if q == "" or string.find(string.lower(left), q, 1, true) then
                lines[#lines + 1] = {
                    left = left,
                    right = right,
                    color = h.matchedKeyword and T.SEMANTIC.WARN or T.TEXT.PRIMARY,
                    onClick = (#(h.urls or {}) > 0) and function()
                        ns.Api.SafeAPI.Print("URL 복사: " .. tostring(h.urls[1]))
                    end or nil,
                }
            end
            if #lines >= MAX_ROWS then break end
        end
        local kw = ns.Api.ProfileStore:GetState("chatAlertKeywords") or "없음"
        summary = "최근 채팅 " .. tostring(#hist) .. "/100건 (키워드: " .. tostring(kw) .. " · /fs kw 단어1,단어2)"

    elseif self.activeSub == "alts" then
        self:RecordCurrentCharacter()
        local store = ns.Api.ProfileStore:GetState("altLedger") or {}
        local sum = ns.Domain.AltInventoryModel.Summarize(store, q)
        for _, r in ipairs(sum.rows) do
            local lvTxt = (type(r.level) == "number") and ("Lv." .. tostring(r.level)) or "Lv.—"
            local clsTxt = (type(r.class) == "string" and r.class ~= "") and r.class or "—"
            local goldTxt = (type(r.gold) == "number") and ns.Domain.LedgerModel.FormatCopper(r.gold) or "—"
            lines[#lines + 1] = {
                left = r.name .. " (" .. lvTxt .. " " .. clsTxt .. " · " .. tostring(r.zone or "") .. ")",
                right = goldTxt,
                color = T.TEXT.PRIMARY,
            }
            if #lines >= MAX_ROWS then break end
        end
        summary = "등록 캐릭터 " .. tostring(sum.charCount) .. "명 · 합계 " .. ns.Domain.LedgerModel.FormatCopper(sum.totalGold)

    elseif self.activeSub == "gdkp" then
        if self.activeAuction and self.activeAuction.status == "OPEN" then
            local auc = self.activeAuction
            local bidTxt = auc.highBidder
                and (auc.highBidder .. " " .. ns.Domain.LedgerModel.FormatCopper(auc.highBidCopper))
                or ("시작가 " .. ns.Domain.LedgerModel.FormatCopper(auc.startCopper))
            lines[#lines + 1] = {
                left = "[경매중] " .. tostring(auc.item) .. " · " .. bidTxt,
                right = "마감: /fs gdkp close",
                color = T.SEMANTIC.WARN,
                onClick = function()
                    UtilitiesPage:HandleGdkpCommand("close")
                end,
            }
        end
        local split = ns.Domain.GdkpModel.ComputeSplit(self.gdkpSales, self.gdkpMembers, self.gdkpCutPct)
        for i = #self.gdkpSales, 1, -1 do
            if #lines >= MAX_ROWS then break end
            local s = self.gdkpSales[i]
            lines[#lines + 1] = {
                left = tostring(s.item or "") .. " — " .. tostring(s.buyer or "미상"),
                right = ns.Domain.LedgerModel.FormatCopper(s.copper),
                color = T.TEXT.GOLD,
            }
        end
        if split then
            summary = "총액 " .. ns.Domain.LedgerModel.FormatCopper(split.totalPot)
                .. " · " .. tostring(split.memberCount) .. "명 1인당 " .. ns.Domain.LedgerModel.FormatCopper(split.perMember)
                .. " (공대 " .. tostring(split.organizerCutPct) .. "%, 잔여 " .. ns.Domain.LedgerModel.FormatCopper(split.remainder)
                .. ") · /fs gdkp start <템> <시작골드>"
        end

    elseif self.activeSub == "character" then
        local pts = ns.Api.GameAdapters.GetUnspentTalentPoints()
        local stats = ns.Api.GameAdapters.GetExtendedCharacterStats()
        for _, sl in ipairs(ns.Domain.PowerQoLModel.FormatExtendedStatsLines(stats)) do
            lines[#lines + 1] = { left = sl.left, right = sl.right, color = T.TEXT.GOLD }
        end
        local assist = ns.Features and ns.Features.CharacterAssistModule
        local learnable, st = {}, "UNAVAILABLE"
        if assist and type(assist.GetLearnableSpells) == "function" then
            learnable, st = assist:GetLearnableSpells()
        end
        if st == "OK" then
            for _, sp in ipairs(learnable) do
                if #lines >= MAX_ROWS then break end
                lines[#lines + 1] = {
                    left = tostring(sp.name) .. " (Lv." .. tostring(sp.level) .. ")",
                    right = (sp.cost and sp.cost > 0) and ns.Domain.LedgerModel.FormatCopper(sp.cost) or "상급자 확인",
                    color = T.TEXT.PRIMARY,
                }
            end
        end
        summary = "미사용 특성: " .. (pts ~= nil and (tostring(pts) .. "점") or "확인 불가")
            .. " · 습득 가능 스킬: " .. (st == "OK" and (tostring(#learnable) .. "개") or tostring(st))

    elseif self.activeSub == "trade" then
        local tlog = (ns.Features.TradeLogModule and ns.Features.TradeLogModule.log) or {}
        for _, r in ipairs(tlog) do
            if #lines >= MAX_ROWS then break end
            local itemNote = (r.givenItems ~= "" or r.receivedItems ~= "")
                and (" [" .. tostring(r.givenItems) .. " ↔ " .. tostring(r.receivedItems) .. "]")
                or ""
            lines[#lines + 1] = {
                left = tostring(r.partner) .. itemNote,
                right = "-" .. ns.Domain.LedgerModel.FormatCopper(r.givenCopper) .. " / +" .. ns.Domain.LedgerModel.FormatCopper(r.receivedCopper),
                color = T.TEXT.PRIMARY,
            }
        end
        local farm = ns.Features.TradeLogModule and ns.Features.TradeLogModule:GetFarmSummary()
        local gphTxt = (farm and farm.gph) and (ns.Domain.LedgerModel.FormatCopper(farm.gph) .. "/h") or "측정 대기"
        summary = "거래 기록 " .. tostring(#tlog) .. "/50건 · 파밍 GPH: " .. gphTxt .. " (/fs farm reset)"

    elseif self.activeSub == "bookmarks" then
        for idx, b in ipairs(self.bookmarks) do
            if #lines >= MAX_ROWS then break end
            lines[#lines + 1] = {
                left = "#" .. tostring(idx) .. " " .. tostring(b.label),
                right = ns.Domain.WorldMapModel.FormatCoordPair(b.x, b.y) .. " · /way",
                color = T.TEXT.GOLD,
                onClick = function()
                    if ns.Features.NavigationHud then
                        ns.Features.NavigationHud:SetTarget(b.mapID, b.x, b.y, b.label)
                    end
                    ns.Api.SafeAPI.Print("즐겨찾기 안내: " .. tostring(b.label))
                end,
            }
        end
        summary = "즐겨찾기 " .. tostring(#self.bookmarks) .. "/30개 · /fs fav add <이름> · /fs profile export"
    end

    local y = 66
    for i, item in ipairs(lines) do
        local row = self:EnsureRow(i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", self.host, "TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", self.host, "TOPRIGHT", 0, -y)
        row._left:SetText(item.left)
        local c = item.color or T.TEXT.PRIMARY
        row._left:SetTextColor(c[1], c[2], c[3], 1)
        row._right:SetText(item.right or "")
        row._onActivate = item.onClick
        row:Show()
        y = y + 26
    end

    if self.summaryLbl then
        self.summaryLbl:SetText(summary)
    end
end

function UtilitiesPage:Build(parent)
    self.host = parent
    local hdr = W.SectionHeader(parent, "채팅 · 부캐 · 골팟(GDKP) · 스킬 도우미")
    hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    local bar = W.PillBar(parent, {
        { value = "chat", label = "채팅·URL", width = 74 },
        { value = "alts", label = "부캐 현황", width = 74 },
        { value = "gdkp", label = "골팟 경매", width = 74 },
        { value = "character", label = "스탯·스킬", width = 74 },
        { value = "trade", label = "거래·파밍", width = 74 },
        { value = "bookmarks", label = "즐겨찾기", width = 74 },
    }, self.activeSub, function(v)
        UtilitiesPage.activeSub = v
        UtilitiesPage:Render(ns.UI.CommandHub.lastQuery or "")
    end)
    bar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -30)
    bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -30)

    local sum = W.Label(parent, "", "small", T.TEXT.MUTED, { justifyH = "LEFT", wordWrap = false })
    sum:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 4)
    sum:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 4)
    self.summaryLbl = sum
end

function UtilitiesPage:OnShow()
    self:Render(ns.UI.CommandHub.lastQuery or "")
end

function UtilitiesPage:OnSearch(query)
    self:Render(query)
end
