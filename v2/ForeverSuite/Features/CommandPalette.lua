-- Module: Features/CommandPalette.lua
-- Responsibility: Independent L3_OVERLAY Command Palette (/fs k, /fs palette) searching Features, Settings,
--                 Loaded Codex Packs, and 1-Click Quick Actions without opening CommandHub (0ms idle when hidden).
-- Layer: Features (uses UI/Widgets + UI/Motion + Domain/GlobalSearchModel + Api/SafeAPI).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local Motion = ns.UI.Motion
local ipairs = ipairs
local tostring = tostring
local string_lower = string.lower
local string_find = string.find

local MAX_RESULTS = 8

local QUICK_ACTIONS = {
    {
        id = "act_fish",
        title = "낚시 원클릭 도우미 열기/닫기",
        sub = "/fs fish · 어종 시세 · 미끼 · 우클릭 낚시",
        keywords = "낚시 어종 미끼 시세 fish",
        run = function()
            if ns.Features.FishingCardHud then ns.Features.FishingCardHud:Toggle() end
        end,
    },
    {
        id = "act_track",
        title = "채집 추적 전환 (약초/광맥/보물)",
        sub = "/fs track · 비전투 1클릭 추적 전환",
        keywords = "채집 약초 광맥 보물 추적 track",
        run = function()
            if ns.Features.TrackingSwitcher then ns.Features.TrackingSwitcher:CycleNext(false) end
        end,
    },
    {
        id = "act_track_auto",
        title = "채집 추적 비전투 자동 교대 토글",
        sub = "/fs track auto · 약초<->광맥 4초 자동 교대",
        keywords = "채집 자동 교대 약초 광맥 auto track",
        run = function()
            if ns.Features.TrackingSwitcher then ns.Features.TrackingSwitcher:HandleCommand("auto") end
        end,
    },
    {
        id = "act_shop",
        title = "부족 전문기술 재료 Auctionator 쇼핑리스트 생성",
        sub = "Syndicator 부캐 재고 차감 후 원클릭 경매장 목록",
        keywords = "쇼핑리스트 부족 재료 경매장 auctionator shop",
        run = function()
            if ns.Features.ProfessionPage then ns.Features.ProfessionPage:CreateMissingShoppingList() end
        end,
    },
    {
        id = "act_gph",
        title = "현재 파밍 시급(GPH) 확인",
        sub = "/fs farm · 순골드 + 경매품 합산 시급",
        keywords = "파밍 시급 골드 경매 gph farm",
        run = function()
            if ns.Features.TradeLogModule then ns.Features.TradeLogModule:HandleFarmCommand("") end
        end,
    },
    {
        id = "act_move",
        title = "HUD 배치 편집 모드 전환",
        sub = "/fs move · 모든 HUD 위치 드래그 편집",
        keywords = "hud 배치 이동 편집 move",
        run = function()
            if ns.UI and ns.UI.HudLayout then ns.UI.HudLayout:ToggleUnlock() end
        end,
    },
    {
        id = "act_cd",
        title = "부캐 전문기술 다일 쿨다운 즉시 동기화",
        sub = "연금술 변환(48h)·소금(72h)·달빛옷감(96h)",
        keywords = "부캐 쿨다운 변환 소금 달빛옷감 cooldown",
        run = function()
            if ns.Features.ProfessionPage then ns.Features.ProfessionPage:SyncAltCooldowns(true, true) end
        end,
    },
    {
        id = "act_setup",
        title = "초기 연출 마법사 열기 (/fs setup)",
        sub = "테마 정렬 · 외부 브리지 점검 · 3기기 프로필",
        keywords = "마법사 초기 설정 setup wizard",
        run = function()
            if ns.Features.SetupWizard then ns.Features.SetupWizard:Open(1) end
        end,
    },
}

local CommandPalette = {
    frame = nil,
    inputBox = nil,
    rows = {},
    results = {},
    statusLbl = nil,
    visible = false,
}
ns.Features.CommandPalette = CommandPalette

local function BuildResultList(query)
    local q = string_lower(tostring(query or "")):match("^%s*(.-)%s*$") or ""
    local out = {}

    -- 1. Quick Actions (default suggestions when query is empty)
    for _, act in ipairs(QUICK_ACTIONS) do
        local hay = string_lower(act.title .. " " .. act.sub .. " " .. act.keywords)
        if q == "" or string_find(hay, q, 1, true) then
            out[#out + 1] = {
                kind = "action",
                badge = "[실행]",
                title = act.title,
                sub = act.sub,
                run = act.run,
            }
            if #out >= (q == "" and MAX_RESULTS or 3) then break end
        end
    end
    if q == "" then
        return out
    end

    -- 2. GlobalSearchModel across Features, Settings, Loaded Codex Packs
    local schemas = (ns.Api.ProfileStore and ns.Api.ProfileStore.schemas) or {}
    local loadedPacks = (_G.ForeverSuiteData and _G.ForeverSuiteData.packs) or {}
    local res = ns.Domain.GlobalSearchModel.Search(q, schemas, loadedPacks, { features = 3, settings = 3, codex = 3 })
    for _, f in ipairs(res.features or {}) do
        if #out >= MAX_RESULTS then break end
        out[#out + 1] = {
            kind = "feature",
            badge = "[기능]",
            title = f.title,
            sub = f.sub,
            pageId = f.pageId,
            subTab = f.subTab,
        }
    end
    for _, s in ipairs(res.settings or {}) do
        if #out >= MAX_RESULTS then break end
        out[#out + 1] = {
            kind = "setting",
            badge = "[설정]",
            title = s.title,
            sub = s.sub,
            pageId = "settings",
            query = s.key,
        }
    end
    for _, c in ipairs(res.codex or {}) do
        if #out >= MAX_RESULTS then break end
        out[#out + 1] = {
            kind = "codex",
            badge = "[도감]",
            title = c.title,
            sub = c.sub,
            pageId = c.pageId,
            query = c.query,
        }
    end
    return out
end

function CommandPalette:ExecuteItem(item)
    if type(item) ~= "table" then return false end
    self:Hide()
    if item.kind == "action" and type(item.run) == "function" then
        local ok = pcall(item.run)
        return ok
    end
    if ns.UI and ns.UI.CommandHub then
        if item.subTab and type(ns.UI.CommandHub.JumpTo) == "function" then
            ns.UI.CommandHub:JumpTo(item.pageId, { subTab = item.subTab, query = item.query })
        elseif item.pageId then
            ns.UI.CommandHub:OpenPage(item.pageId, item.query)
        end
        return true
    end
    return false
end

function CommandPalette:RenderResults(query)
    if not self.frame then return 0 end
    local list = BuildResultList(query)
    self.results = list
    for i = 1, MAX_RESULTS do
        local row = self.rows[i]
        local d = list[i]
        if d then
            row._item = d
            row._left:SetText(d.badge .. " " .. tostring(d.title))
            row._right:SetText(tostring(d.sub or ""))
            row:Show()
        else
            row._item = nil
            row:Hide()
        end
    end
    if self.statusLbl then
        self.statusLbl:SetText(tostring(#list) .. "개 결과 · 클릭 즉시 실행 · ESC 닫기")
    end
    return #list
end

local function EnsureUI()
    if CommandPalette.frame then return CommandPalette.frame end
    local win = W.PopupCard(_G.UIParent, 480, 344, "ForeverSuiteCommandPalette", T.ELEVATION.L3_OVERLAY)
    win:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 80)

    local hdr = W.Label(win, "★ ForeverSuite 빠른 명령 팔레트 (/fs k)", "heading", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    hdr:SetPoint("TOPLEFT", win, "TOPLEFT", 14, -12)

    local closeBtn = W.MiniButton(win, "×", 22, 20, function()
        CommandPalette:Hide()
    end, "팔레트 닫기", { ghost = true })
    closeBtn:SetPoint("TOPRIGHT", win, "TOPRIGHT", -10, -10)

    local box = W.SearchBox(win, 452, "기능 · 설정 · 도감 · 빠른 명령 검색...", function(text)
        CommandPalette:RenderResults(text)
    end)
    box:SetPoint("TOPLEFT", win, "TOPLEFT", 14, -38)
    if type(box.SetScript) == "function" then
        box:SetScript("OnEscapePressed", function()
            CommandPalette:Hide()
        end)
        box:SetScript("OnEnterPressed", function()
            if type(CommandPalette.results) == "table" and CommandPalette.results[1] then
                CommandPalette:ExecuteItem(CommandPalette.results[1])
            end
        end)
    end

    local rows = {}
    for i = 1, MAX_RESULTS do
        local row = W.ListRow(win, 28, function(btn)
            if btn._item then
                CommandPalette:ExecuteItem(btn._item)
            end
        end)
        row:SetPoint("TOPLEFT", win, "TOPLEFT", 14, -(74 + (i - 1) * 30))
        row:SetPoint("TOPRIGHT", win, "TOPRIGHT", -14, -(74 + (i - 1) * 30))
        row:Hide()
        rows[i] = row
    end

    local st = W.Label(win, "", "small", T.TEXT.MUTED, { justifyH = "LEFT", wordWrap = false })
    st:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 14, 10)
    st:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -14, 10)

    CommandPalette.frame = win
    CommandPalette.inputBox = box
    CommandPalette.rows = rows
    CommandPalette.statusLbl = st
    win:Hide()
    return win
end

function CommandPalette:Open(initialQuery)
    EnsureUI()
    local q = tostring(initialQuery or "")
    if self.inputBox and type(self.inputBox.SetText) == "function" then
        self.inputBox:SetText(q)
    end
    self:RenderResults(q)
    self.visible = true
    if Motion and type(Motion.FadeIn) == "function" then
        Motion.FadeIn(self.frame, 0.12)
    else
        self.frame:Show()
    end
    if self.inputBox and type(self.inputBox.SetFocus) == "function" then
        pcall(self.inputBox.SetFocus, self.inputBox)
    end
    return true
end

function CommandPalette:Hide()
    self.visible = false
    if self.frame then
        if Motion and type(Motion.InstantHide) == "function" then
            Motion.InstantHide(self.frame)
        else
            self.frame:Hide()
        end
    end
end

function CommandPalette:Toggle(initialQuery)
    if self.visible then
        self:Hide()
        return false
    end
    return self:Open(initialQuery)
end
