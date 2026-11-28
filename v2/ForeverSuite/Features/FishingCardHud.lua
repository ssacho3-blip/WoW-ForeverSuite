-- Module: Features/FishingCardHud.lua
-- Responsibility: F2 Enhanced L1 1-Click Fishing Helper Window - visible OOC 1-click Fishing & Lure secure dock
--                 (delegated to Secure/FishingCastButton), 1-click Fishing Pole <-> Combat Weapon swap,
--                 double-right-click toggle, manual pin (/fs fish), crash-safe fishing sound boost,
--                 session catch counter, and clickable zone fish guide.
-- Layer: Features (uses UI/Widgets + Api/GameAdapters + Secure/FishingCastButton; zero SecureActionButtonTemplate here).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs
local tostring = tostring
local string_find = string.find
local string_format = string.format
local string_lower = string.lower
local math_floor = math.floor

local MAX_FISH_ROWS = 3

-- Classic / Forever key profitable fish item IDs (prefix-matched when entry.itemID is absent)
local FISH_ITEM_IDS = {
    { prefix = "빛깔좋은 망둥어", itemID = 6291 },
    { prefix = "비단잉어", itemID = 6303 },
    { prefix = "돌연변이 물고기", itemID = 6522 },
    { prefix = "긴주둥이 진흙퉁돔", itemID = 6289 },
    { prefix = "무지개날개 다랑어", itemID = 6308 },
    { prefix = "기름기 많은 아귀", itemID = 6358 },
    { prefix = "검은아귀", itemID = 6358 },
    { prefix = "민물 표범송어", itemID = 6361 },
    { prefix = "불지느러미 통돔", itemID = 6359 },
    { prefix = "돌비늘 뱀장어", itemID = 13422 },
    { prefix = "밤비늘 통돔", itemID = 13759 },
    { prefix = "겨울 오징어", itemID = 13755 },
    { prefix = "여름 농어", itemID = 13756 },
    { prefix = "붉은 아가미", itemID = 13758 },
    { prefix = "광택나는 작은물고기", itemID = 13754 },
    { prefix = "해비늘 연어", itemID = 13760 },
    { prefix = "흰비늘 연어", itemID = 13889 },
    { prefix = "거대 조개", itemID = 7973 },
}

local function ResolveFishItemID(entry)
    if type(entry) ~= "table" then return nil end
    if type(entry.itemID) == "number" and entry.itemID > 0 then
        return entry.itemID
    end
    local title = entry.title
    if type(title) ~= "string" or title == "" then return nil end
    for i = 1, #FISH_ITEM_IDS do
        if string_find(title, FISH_ITEM_IDS[i].prefix, 1, true) then
            return FISH_ITEM_IDS[i].itemID
        end
    end
    return nil
end

local function LookupFishAuctionPrice(entry)
    local auc = ns.Bridges and ns.Bridges.Auctionator
    if not (auc and type(auc.GetAuctionPrice) == "function") then return nil end
    local itemID = ResolveFishItemID(entry)
    if not itemID then return nil end
    return auc:GetAuctionPrice(itemID)
end

local FishingCardHud = {
    card = nil,
    headerBar = nil,
    titleLbl = nil,
    metaLbl = nil,
    bodyLbl = nil,
    fishRows = nil,
    pinBtn = nil,
    oneKeyBtn = nil,
    soundBtn = nil,
    closeBtn = nil,
    swapBtn = nil,
    dblBtn = nil,
    ticker = nil,
    visible = false,
    pinned = false,
    dismissedForPole = false,
    soundBoost = false,
    oneKeyInteract = false,
    sessionCatches = 0,
    sessionLootValueCopper = 0,
}
ns.Features.FishingCardHud = FishingCardHud

local function StopTicker()
    if FishingCardHud.ticker then
        ns.Api.GameAdapters.CancelTicker(FishingCardHud.ticker)
        FishingCardHud.ticker = nil
    end
end

local function SyncSecureDock(visible)
    if not (ns.Secure and ns.Secure.FishingCastButton and type(ns.Secure.FishingCastButton.SyncDock) == "function") then
        return
    end
    local lure = visible and ns.Api.GameAdapters.FindBestFishingLureInBags and ns.Api.GameAdapters.FindBestFishingLureInBags() or nil
    ns.Secure.FishingCastButton:SyncDock(FishingCardHud.card, visible, lure)
end

local function NotifyDirector()
    if ns.UI and ns.UI.Director and type(ns.UI.Director.SyncFromProvider) == "function" then
        ns.UI.Director:SyncFromProvider(true)
    end
end

function FishingCardHud:Init()
    if self.card then
        return self.card
    end
    local card = W.HudGlass(nil, 292, 174, "ForeverSuiteV2FishingCard", T.ELEVATION.L1_CARD, {
        bg = { 0.048, 0.043, 0.052, 0.84 },
        border = T.BORDER.GOLD_SOFT,
        accentBar = true,
    })

    local hdr = W.HudGlass(card, 290, 24, nil, T.ELEVATION.L1_CARD, {
        bg = { 0.11, 0.09, 0.06, 0.86 },
        border = { 0.65, 0.50, 0.20, 0.40 },
    })
    hdr:SetPoint("TOPLEFT", card, "TOPLEFT", 1, -1)
    hdr:SetPoint("TOPRIGHT", card, "TOPRIGHT", -1, -1)

    local closeBtn = W.MiniButton(hdr, "×", 20, 18, function()
        FishingCardHud:Close()
    end, "낚시 도우미 닫기", { ghost = true })
    closeBtn:SetPoint("RIGHT", hdr, "RIGHT", -4, 0)

    local soundBtn = W.MiniButton(hdr, "음향", 34, 18, function()
        FishingCardHud:ToggleSoundBoost()
    end, "낚시 입질 효과음 강조 ON/OFF (비전투 안전 복원)", { ghost = true })
    soundBtn:SetPoint("RIGHT", closeBtn, "LEFT", -3, 0)

    local oneKeyBtn = W.MiniButton(hdr, "원키", 34, 18, function()
        FishingCardHud:ToggleOneKeyInteract()
    end, "상호작용 키(F 등) 1타로 찌 낚아채기 ON/OFF (SoftTargetInteract)", { ghost = true })
    oneKeyBtn:SetPoint("RIGHT", soundBtn, "LEFT", -3, 0)

    local pinBtn = W.MiniButton(hdr, "고정", 34, 18, function()
        FishingCardHud:TogglePin()
    end, "낚싯대 미착용 시에도 낚시 창 항상 표시", { ghost = true })
    pinBtn:SetPoint("RIGHT", oneKeyBtn, "LEFT", -3, 0)

    local title = W.Label(hdr, "★ 낚시 도우미", "heading", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false, outline = "OUTLINE" })
    title:SetPoint("LEFT", hdr, "LEFT", 8, 0)
    title:SetPoint("RIGHT", pinBtn, "LEFT", -6, 0)

    local meta = W.Label(card, "", "small", T.SEMANTIC.INFO, { justifyH = "LEFT", wordWrap = false })
    meta:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -30)
    meta:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -30)

    local fishRows = {}
    for i = 1, MAX_FISH_ROWS do
        local row = W.ListRow(card, 18, function(btn)
            local entry = btn._fishEntry
            if not entry then return end
            if type(entry.x) == "number" and type(entry.y) == "number" and ns.Features.NavigationHud then
                ns.Features.NavigationHud:SetWaypoint(entry.x, entry.y, entry.title or "낚시 포인트")
            else
                ns.Api.SafeAPI.Print("낚시 대상어: " .. tostring(entry.title or "?") .. " · " .. tostring(entry.zone or "") .. " (숙련 " .. tostring(entry.minSkill or "?") .. ")")
            end
        end)
        row:SetPoint("TOPLEFT", card, "TOPLEFT", 8, -(48 + (i - 1) * 20))
        row:SetPoint("TOPRIGHT", card, "TOPRIGHT", -8, -(48 + (i - 1) * 20))
        row:Hide()
        fishRows[i] = row
    end

    local body = W.Label(card, "", "small", T.TEXT.SECONDARY, { justifyH = "LEFT", wordWrap = true })
    body:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -50)
    body:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -50)
    body:SetHeight(56)

    local swapBtn = W.Button(card, "낚싯대 장착", 134, 22, function()
        FishingCardHud:SwapFishingPole()
    end)
    swapBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 8, -112)

    local dblBtn = W.Button(card, "우클릭: OFF", 134, 22, function()
        local cur = ns.Api.ProfileStore:Get("profession", "fishingDoubleClick") == true
        ns.Api.ProfileStore:Set("profession", "fishingDoubleClick", not cur)
        FishingCardHud:Refresh()
    end)
    dblBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", -8, -112)

    self.card = card
    self.headerBar = hdr
    self.titleLbl = title
    self.metaLbl = meta
    self.bodyLbl = body
    self.fishRows = fishRows
    self.pinBtn = pinBtn
    self.oneKeyBtn = oneKeyBtn
    self.soundBtn = soundBtn
    self.closeBtn = closeBtn
    self.swapBtn = swapBtn
    self.dblBtn = dblBtn

    ns.UI.HudLayout:Register("fishingCard", card, {
        point = "BOTTOMLEFT",
        relPoint = "BOTTOMLEFT",
        x = 24,
        y = 356,
    }, "낚시 원클릭 도우미", function()
        SyncSecureDock(FishingCardHud.visible and not (ns.UI.HudLayout and ns.UI.HudLayout:IsUnlocked()))
    end)

    if type(ns.UI.HudLayout.EnableDirectDrag) == "function" then
        ns.UI.HudLayout:EnableDirectDrag("fishingCard", hdr, { requireShift = false, moveTarget = card })
        ns.UI.HudLayout:EnableDirectDrag("fishingCard", card, { requireShift = true, moveTarget = card })
    end

    card:Hide()
    return card
end

function FishingCardHud:TogglePin(forceVal)
    if forceVal ~= nil then
        self.pinned = forceVal == true
    else
        self.pinned = not self.pinned
    end
    self:Refresh()
    NotifyDirector()
    return self.pinned
end

function FishingCardHud:Open()
    self.dismissedForPole = false
    self.pinned = true
    self:Refresh()
    NotifyDirector()
    return true
end

function FishingCardHud:Close()
    self.pinned = false
    self.dismissedForPole = ns.Api.GameAdapters.IsFishingPoleEquipped() == true
    if self.soundBoost then
        self:ToggleSoundBoost(false)
    end
    if self.oneKeyInteract then
        self:ToggleOneKeyInteract(false)
    end
    StopTicker()
    self.visible = false
    if self.card then
        self.card:Hide()
    end
    SyncSecureDock(false)
    NotifyDirector()
    return true
end

function FishingCardHud:Toggle()
    if self.visible and self.pinned then
        return self:Close()
    end
    return self:Open()
end

function FishingCardHud:ToggleOneKeyInteract(forceVal)
    local want = (forceVal ~= nil) and (forceVal == true) or (not self.oneKeyInteract)
    local ok, reason = ns.Api.GameAdapters.SetFishingOneKeyInteractSafe(want)
    if not ok then
        ns.Api.SafeAPI.Print("전투 중에는 원키 상호작용 낚시를 전환할 수 없습니다 (" .. tostring(reason) .. ").")
        return false, reason
    end
    self.oneKeyInteract = want
    ns.Api.SafeAPI.Print(want
        and "원키 찌 낚아채기 ON (입질 시 상호작용 키 1타로 즉시 획득 · 창 닫으면 자동 복원)"
        or "원키 찌 낚아채기 OFF (원래 SoftTarget 설정 복원)")
    self:Refresh()
    return true, reason
end

function FishingCardHud:ToggleSoundBoost(forceVal)
    local want = (forceVal ~= nil) and (forceVal == true) or (not self.soundBoost)
    local ok, reason = ns.Api.GameAdapters.SetFishingSoundBoostSafe(want)
    if not ok then
        ns.Api.SafeAPI.Print("전투 중에는 낚시 음향 강조를 전환할 수 없습니다 (" .. tostring(reason) .. ").")
        return false, reason
    end
    self.soundBoost = want
    ns.Api.SafeAPI.Print(want and "낚시 음향 강조 ON (입질 효과음 100% · 배경음 축소)" or "낚시 음향 강조 OFF (원래 볼륨 복원)")
    self:Refresh()
    return true, reason
end

function FishingCardHud:SwapFishingPole()
    if ns.Api.SafeAPI.InCombat() then
        ns.Api.SafeAPI.Print("전투 중에는 낚싯대를 교체할 수 없습니다.")
        return false, "IN_COMBAT"
    end
    local poleEquipped = ns.Api.GameAdapters.IsFishingPoleEquipped()
    if not poleEquipped then
        local pole = ns.Api.GameAdapters.FindFishingPoleInBags()
        if not pole then
            ns.Api.SafeAPI.Print("가방에서 낚싯대를 찾지 못했습니다.")
            return false, "NO_POLE"
        end
        local mh, oh = ns.Api.GameAdapters.GetEquippedWeaponsSafe()
        if mh and ns.Api.ProfileStore and ns.Api.ProfileStore:CanWrite() then
            ns.Api.ProfileStore:SetState("fishingSavedWeapons", { mh = mh, oh = oh })
        end
        local ok, reason = ns.Api.GameAdapters.EquipItemByIDSafe(pole.itemID)
        if ok then
            ns.Api.SafeAPI.Print("낚싯대 장착: " .. tostring(pole.name))
            self:Refresh()
            NotifyDirector()
            return true, "EQUIPPED_POLE"
        end
        return false, reason
    else
        local saved = ns.Api.ProfileStore and ns.Api.ProfileStore:GetState("fishingSavedWeapons")
        if type(saved) ~= "table" or type(saved.mh) ~= "number" then
            ns.Api.SafeAPI.Print("복원할 이전 무기 기록이 없습니다. 먼저 [낚싯대 장착]으로 전환하면 이전 무기를 자동 기억합니다.")
            return false, "NO_SAVED_WEAPONS"
        end
        local okMh, rMh = ns.Api.GameAdapters.EquipItemByIDSafe(saved.mh)
        if okMh and type(saved.oh) == "number" and saved.oh > 0 then
            ns.Api.GameAdapters.EquipItemByIDSafe(saved.oh)
        end
        if okMh then
            ns.Api.SafeAPI.Print("이전 전투 무기로 복원했습니다.")
            self:Refresh()
            NotifyDirector()
            return true, "RESTORED_WEAPONS"
        end
        return false, rMh
    end
end

function FishingCardHud:OnCombatEntered()
    -- Hide insecure card immediately so an alpha-0 frame NEVER swallows combat mouse clicks
    if self.card and type(self.card.Hide) == "function" then
        self.card:Hide()
    end
end

function FishingCardHud:OnLootMessage(msg)
    if not self.visible then return false end
    if type(msg) ~= "string" or msg == "" then return false end
    if not (ns.Api.GameAdapters.IsFishingPoleEquipped() or self.pinned) then
        return false
    end
    -- Filter strictly to player self-loot so party/raid loot never inflates fishing catch count
    local itemID, count
    if ns.Domain and ns.Domain.PowerQoLModel and type(ns.Domain.PowerQoLModel.ParseSelfLootItem) == "function" then
        itemID, count = ns.Domain.PowerQoLModel.ParseSelfLootItem(msg)
    end
    if itemID then
        local qty = (type(count) == "number" and count > 0) and count or 1
        self.sessionCatches = (self.sessionCatches or 0) + qty
        local auc = ns.Bridges and ns.Bridges.Auctionator
        if auc and type(auc.GetAuctionPrice) == "function" then
            local unitPrice = auc:GetAuctionPrice(itemID)
            if type(unitPrice) == "number" and unitPrice > 0 then
                self.sessionLootValueCopper = (self.sessionLootValueCopper or 0) + (unitPrice * qty)
            end
        end
        self:Refresh()
        return true
    end
    local isSelfLoot = (string_find(msg, "획득했습니다", 1, true) ~= nil and string_find(msg, "님이", 1, true) == nil)
        or string_find(msg, "You receive loot", 1, true) == 1
    if isSelfLoot and string_find(msg, "|Hitem:", 1, true) then
        self.sessionCatches = (self.sessionCatches or 0) + 1
        self:Refresh()
        return true
    end
    return false
end

function FishingCardHud:HandleCommand(raw)
    local arg = string_lower(tostring(raw or "")):match("^%s*(%S*)") or ""
    if arg == "on" or arg == "open" then
        self:Open()
        ns.Api.SafeAPI.Print("낚시 원클릭 도우미 창을 열었습니다.")
    elseif arg == "off" or arg == "close" then
        self:Close()
        ns.Api.SafeAPI.Print("낚시 원클릭 도우미 창을 닫았습니다.")
    elseif arg == "pin" then
        local p = self:TogglePin()
        ns.Api.SafeAPI.Print(p and "낚시 도우미 고정 ON" or "낚시 도우미 고정 OFF")
    elseif arg == "swap" or arg == "pole" then
        self:SwapFishingPole()
    elseif arg == "sound" then
        self:ToggleSoundBoost()
    elseif arg == "onekey" or arg == "interact" then
        self:ToggleOneKeyInteract()
    else
        self:Toggle()
    end
    return true
end

function FishingCardHud:Refresh()
    self:Init()
    if ns.UI.HudLayout and ns.UI.HudLayout:IsUnlocked() then
        SyncSecureDock(false)
        return false
    end
    local enabled = ns.Api.ProfileStore:Get("profession", "showFishingCard")
    local poleEquipped = ns.Api.GameAdapters.IsFishingPoleEquipped()
    if not poleEquipped then
        self.dismissedForPole = false
    end
    local doubleCast = ns.Api.ProfileStore:Get("profession", "fishingDoubleClick") == true
    if ns.Secure and ns.Secure.FishingCastButton then
        if poleEquipped and doubleCast and not ns.Api.SafeAPI.InCombat() then
            ns.Secure.FishingCastButton:SetActive(true)
        else
            ns.Secure.FishingCastButton:SetActive(false)
        end
    end

    local shouldShow = self.pinned or (enabled ~= false and poleEquipped and not self.dismissedForPole)
    if not shouldShow then
        StopTicker()
        self.visible = false
        self.card:Hide()
        SyncSecureDock(false)
        return false
    end
    if ns.Api.SafeAPI.InCombat() then
        self.visible = true
        self.card:Hide()
        return false
    end

    local loaded = ns.Api.SafeAPI.LoadDataPack()
    local pack = _G.ForeverSuiteData and _G.ForeverSuiteData.packs and _G.ForeverSuiteData.packs.fishing
    local zone = ns.Api.GameAdapters.GetPlayerZoneText()
    local fStat = ns.Api.GameAdapters.GetFishingStatusSafe()
    local skillTxt = (fStat and fStat.skill) and ("숙련 " .. tostring(fStat.skill) .. "/" .. tostring(fStat.maxSkill or 300)) or "숙련 -"
    local lureTxt
    if fStat and fStat.hasLure and fStat.lureSec > 0 then
        local m = math_floor(fStat.lureSec / 60)
        local s = fStat.lureSec - m * 60
        lureTxt = string_format("미끼 %02d:%02d", m, s)
        self.metaLbl:SetTextColor(T.SEMANTIC.SUCCESS[1], T.SEMANTIC.SUCCESS[2], T.SEMANTIC.SUCCESS[3], 1)
    else
        lureTxt = "[!] 미끼 없음"
        self.metaLbl:SetTextColor(T.SEMANTIC.WARN[1], T.SEMANTIC.WARN[2], T.SEMANTIC.WARN[3], 1)
    end
    local catchValTxt = ""
    if type(self.sessionLootValueCopper) == "number" and self.sessionLootValueCopper > 0 and ns.Domain and ns.Domain.LedgerModel then
        catchValTxt = " (" .. ns.Domain.LedgerModel.FormatCopper(self.sessionLootValueCopper) .. ")"
    end
    self.titleLbl:SetText("★ 낚시 도우미" .. (zone ~= "" and (" · " .. zone) or ""))
    self.metaLbl:SetText(skillTxt .. " | " .. lureTxt .. " | 어획 " .. tostring(self.sessionCatches or 0) .. catchValTxt)

    if self.pinBtn and self.pinBtn._label then
        self.pinBtn._label:SetText(self.pinned and "고정*" or "고정")
    end
    if self.oneKeyBtn and self.oneKeyBtn._label then
        self.oneKeyBtn._label:SetText(self.oneKeyInteract and "원키*" or "원키")
    end
    if self.soundBtn and self.soundBtn._label then
        self.soundBtn._label:SetText(self.soundBoost and "음향*" or "음향")
    end
    if self.swapBtn and self.swapBtn._label then
        self.swapBtn._label:SetText(poleEquipped and "전투 무기 복원" or "낚싯대 장착")
    end
    if self.dblBtn and self.dblBtn._label then
        self.dblBtn._label:SetText(doubleCast and "우클릭 낚시: ON" or "우클릭 낚시: OFF")
    end

    local matches = {}
    if loaded and type(pack) == "table" and zone ~= "" then
        for _, e in ipairs(pack.entries or {}) do
            if type(e.zone) == "string" and string_find(e.zone, zone, 1, true) then
                matches[#matches + 1] = e
                if #matches >= MAX_FISH_ROWS then break end
            end
        end
    end

    if #matches > 0 then
        local summary = {}
        for i = 1, MAX_FISH_ROWS do
            local row = self.fishRows[i]
            local e = matches[i]
            if e then
                local ahPrice = LookupFishAuctionPrice(e)
                local priceSuffix = (type(ahPrice) == "number" and ahPrice > 0 and ns.Domain and ns.Domain.LedgerModel)
                    and (" · " .. ns.Domain.LedgerModel.FormatCopper(ahPrice)) or ""
                summary[#summary + 1] = tostring(e.title) .. " (숙련 " .. tostring(e.minSkill or "?") .. priceSuffix .. ")"
                row._fishEntry = e
                row._left:SetText("· " .. tostring(e.title))
                row._right:SetText("숙련 " .. tostring(e.minSkill or "?") .. priceSuffix)
                row:Show()
            else
                row._fishEntry = nil
                row:Hide()
            end
        end
        self.bodyLbl:SetText(table.concat(summary, " / "))
        self.bodyLbl:Hide()
    else
        for i = 1, MAX_FISH_ROWS do
            self.fishRows[i]._fishEntry = nil
            self.fishRows[i]:Hide()
        end
        self.bodyLbl:Show()
        if (not loaded) or type(pack) ~= "table" then
            self.bodyLbl:SetText("도감 데이터팩 미로드 (낚싯대·미끼 원클릭 사용 가능)")
        elseif zone == "" then
            self.bodyLbl:SetText("현재 지역 집계 없음 (드래그 이동 가능)")
        else
            self.bodyLbl:SetText("현재 지역 등록 대상어 없음 (Shift+드래그 또는 헤더 드래그 이동)")
        end
    end

    self.visible = true
    self.card:Show()
    SyncSecureDock(true)
    if not self.ticker then
        self.ticker = ns.Api.GameAdapters.StartTicker(1.0, function()
            FishingCardHud:Refresh()
        end)
    end
    return true
end
