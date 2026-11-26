-- Module: Features/HomePage.lua
-- Responsibility: ForeverSuite v3.0 Default Home Dashboard (character hero card, 4 live StatCards,
--                 level-aware briefing, 6 quick-launch tiles, and one-click utility strip).
-- Layer: Features (zero raw CreateFrame; NEVER force-loads LoD packs on login/open!).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs
local pairs = pairs
local tostring = tostring

local HomePage = {
    id = "home",
    label = "홈",
    group = "now",
    host = nil,
    heroIcon = nil,
    heroTitle = nil,
    heroSub = nil,
    statCards = {},
    briefDungeonLbl = nil,
    briefTipLbl = nil,
    quickTiles = {},
}
ns.Features.HomePage = HomePage

local function ToneColor(tone)
    if tone == "SUCCESS" then return T.SEMANTIC.SUCCESS end
    if tone == "WARN" then return T.SEMANTIC.WARN end
    if tone == "DANGER" then return T.SEMANTIC.DANGER end
    if tone == "INFO" then return T.SEMANTIC.INFO end
    if tone == "MUTED" then return T.TEXT.MUTED end
    return T.TEXT.GOLD
end

local function CountLoadedPacks()
    local n = 0
    if type(_G.ForeverSuiteData) == "table" and type(_G.ForeverSuiteData.packs) == "table" then
        for _, p in pairs(_G.ForeverSuiteData.packs) do
            if type(p) == "table" then n = n + 1 end
        end
    end
    return n
end

function HomePage:Build(parent)
    self.host = parent

    -- 1. Hero Character Card (top 68px)
    local hero = W.Card(parent, 760, 66)
    hero:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    hero:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    W.SetBorderColor(hero, T.BORDER.GOLD_SOFT)

    local heroIcon = W.IconFrame(hero, T.ICON.LG)
    heroIcon:SetPoint("LEFT", hero, "LEFT", 14, 0)
    self.heroIcon = heroIcon

    local heroTitle = W.Label(hero, "✦ ForeverSuite " .. tostring(ns.Api.SafeAPI.GetAddonVersion() or "4.0.0"), "title", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    heroTitle:SetPoint("TOPLEFT", hero, "TOPLEFT", 14 + T.ICON.LG + 12, -11)
    heroTitle:SetPoint("TOPRIGHT", hero, "TOPRIGHT", -148, -11)
    self.heroTitle = heroTitle

    local heroSub = W.Label(hero, "", "small", T.TEXT.SECONDARY, { justifyH = "LEFT", wordWrap = false })
    heroSub:SetPoint("TOPLEFT", hero, "TOPLEFT", 14 + T.ICON.LG + 12, -39)
    heroSub:SetPoint("TOPRIGHT", hero, "TOPRIGHT", -148, -39)
    self.heroSub = heroSub

    local hudBtn = W.Button(hero, "HUD 배치 편집", 120, 26, function()
        local unlocked, reason = ns.UI.HudLayout:ToggleUnlock()
        if reason == "IN_COMBAT" then
            ns.Api.SafeAPI.Print("전투 중에는 HUD 배치 편집 모드를 켤 수 없습니다.")
        else
            ns.Api.SafeAPI.Print(unlocked and "HUD 배치 편집 모드 활성화" or "HUD 위치 잠금 완료")
        end
    end, true)
    hudBtn:SetPoint("RIGHT", hero, "RIGHT", -12, 0)

    -- 2. Four Live KPI StatCards (row at y = -76, height = 74; exact 765px = 4*186 + 3*7)
    self.statCards = {}
    local cardW = 186
    local cardGap = 7
    local overview0 = ns.Domain.HomeDashboardModel.BuildOverview({})
    for i, cdef in ipairs(overview0.cards) do
        local sc = W.StatCard(parent, cardW, 74, {
            caption = cdef.caption,
            value = cdef.value,
            sub = cdef.sub,
            icon = cdef.icon,
            onClick = function()
                if cdef.targetPage then
                    ns.UI.CommandHub:SelectPage(cdef.targetPage)
                end
            end,
        })
        sc:SetPoint("TOPLEFT", parent, "TOPLEFT", (i - 1) * (cardW + cardGap), -76)
        self.statCards[cdef.id] = sc
    end

    -- 3. Middle 2-Column Area (y = -164 .. -488 -> 324px tall)
    -- Left: Current Zone & Growth Recommendation Card (width 310)
    local leftCard = W.Card(parent, 310, 324)
    leftCard:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -164)

    local leftHdr = W.SectionHeader(leftCard, "현재 추천 성장 · 활동 브리핑")
    leftHdr:SetPoint("TOPLEFT", leftCard, "TOPLEFT", 12, -10)
    leftHdr:SetPoint("TOPRIGHT", leftCard, "TOPRIGHT", -12, -10)

    local dunCaption = W.Label(leftCard, "추천 던전 구간", "small", T.TEXT.MUTED, { justifyH = "LEFT", wordWrap = false })
    dunCaption:SetPoint("TOPLEFT", leftCard, "TOPLEFT", 12, -46)

    local briefDungeon = W.Label(leftCard, "", "heading", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = true })
    briefDungeon:SetPoint("TOPLEFT", dunCaption, "BOTTOMLEFT", 0, -4)
    briefDungeon:SetWidth(286)
    self.briefDungeonLbl = briefDungeon

    local tipCaption = W.Label(leftCard, "성장 팁", "small", T.TEXT.MUTED, { justifyH = "LEFT", wordWrap = false })
    tipCaption:SetPoint("TOPLEFT", leftCard, "TOPLEFT", 12, -124)

    local briefTip = W.Label(leftCard, "", "body", T.TEXT.PRIMARY, { justifyH = "LEFT", wordWrap = true })
    briefTip:SetPoint("TOPLEFT", tipCaption, "BOTTOMLEFT", 0, -4)
    briefTip:SetWidth(286)
    self.briefTipLbl = briefTip

    local openDunBtn = W.Button(leftCard, "던전 도감 열기", 136, 26, function()
        ns.UI.CommandHub:SelectPage("dungeons")
    end, true)
    openDunBtn:SetPoint("BOTTOMLEFT", leftCard, "BOTTOMLEFT", 12, 46)

    local openBisBtn = W.Button(leftCard, "BiS 장비 비교", 136, 26, function()
        ns.UI.CommandHub:SelectPage("bis")
    end)
    openBisBtn:SetPoint("LEFT", openDunBtn, "RIGHT", 10, 0)

    local presetBtn = W.Button(leftCard, "원클릭 설정 프리셋", 282, 26, function()
        ns.UI.CommandHub:SelectPage("settings")
    end)
    presetBtn:SetPoint("BOTTOMLEFT", leftCard, "BOTTOMLEFT", 12, 12)

    -- Right: 8 Quick-Launch Workspace Tiles (2 cols x 4 rows, x = 322, exact 443px = 2*217 + 9)
    local rightHdr = W.SectionHeader(parent, "빠른 실행 (클릭 즉시 이동)")
    rightHdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 322, -164)
    rightHdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -164)

    self.quickTiles = {}
    local tiles = ns.Domain.HomeDashboardModel.GetQuickTiles()
    local tileW = 217
    local tileH = 66
    for idx, tdef in ipairs(tiles) do
        local col = (idx - 1) % 2
        local row = math.floor((idx - 1) / 2)
        local tile = W.StatCard(parent, tileW, tileH, {
            caption = "바로가기",
            value = tdef.title,
            sub = tdef.sub,
            icon = tdef.icon,
            onClick = function()
                ns.UI.CommandHub:SelectPage(tdef.id)
            end,
        })
        tile:SetPoint("TOPLEFT", parent, "TOPLEFT", 322 + col * (tileW + 9), -(198 + row * (tileH + 8)))
        self.quickTiles[idx] = tile
    end

    -- 4. Bottom One-Click Utility Strip (y = -500, height = 44)
    local strip = W.Card(parent, 760, 44)
    strip:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 2)
    strip:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 2)

    local stripLbl = W.Label(strip, "빠른 도구", "small", T.TEXT.MUTED)
    stripLbl:SetPoint("LEFT", strip, "LEFT", 12, 0)

    local saveLocBtn = W.Button(strip, "★ 현재 위치 북마크", 136, 24, function()
        if ns.Features.UtilitiesPage and ns.Features.UtilitiesPage.QuickSaveCurrentLocation then
            ns.Features.UtilitiesPage:QuickSaveCurrentLocation()
        else
            ns.UI.CommandHub:JumpTo("utilities", { subTab = "bookmarks" })
        end
    end)
    saveLocBtn:SetPoint("LEFT", stripLbl, "RIGHT", 12, 0)

    local gdkpBtn = W.Button(strip, "골드팟 경매·분배", 124, 24, function()
        ns.UI.CommandHub:JumpTo("utilities", { subTab = "gdkp" })
    end)
    gdkpBtn:SetPoint("LEFT", saveLocBtn, "RIGHT", 8, 0)

    local shareBtn = W.Button(strip, "프로필 백업·복원", 124, 24, function()
        ns.UI.CommandHub:OpenProfileShareModal()
    end)
    shareBtn:SetPoint("LEFT", gdkpBtn, "RIGHT", 8, 0)

    local diagBtn = W.Button(strip, "진단 · 12 LoD", 112, 24, function()
        ns.UI.CommandHub:SelectPage("diagnostics")
    end)
    diagBtn:SetPoint("LEFT", shareBtn, "RIGHT", 8, 0)

    self:OnShow()
end

function HomePage:OnShow()
    if not self.heroTitle then return end
    local ga = ns.Api.GameAdapters
    local locCls, engCls = ga.GetPlayerClassLocalized()
    local durSlots = ga.GetDurabilitySlots()
    local durPct = ns.Domain.MerchantModel and ns.Domain.MerchantModel.ComputeDurabilityPct(durSlots) or nil
    local curMoney = ns.Api.SafeAPI.GetPlayerMoney()
    local goldText = (type(curMoney) == "number") and ns.Domain.LedgerModel.FormatCopper(curMoney) or nil
    local qSnap = ns.Features.QuestTrackerView and ns.Features.QuestTrackerView.lastSnapshot
    local qCount = (type(qSnap) == "table" and type(qSnap.questCount) == "number") and qSnap.questCount or nil
    local xpSnap = type(ga.GetPlayerXPSnapshot) == "function" and ga.GetPlayerXPSnapshot() or nil
    local eqMap = type(ga.GetEquippedItemInfoMap) == "function" and ga.GetEquippedItemInfoMap() or {}
    local ilvlSum, ilvlCnt = 0, 0
    for _, info in pairs(eqMap) do
        if type(info.ilvl) == "number" and info.ilvl > 0 then
            ilvlSum = ilvlSum + info.ilvl
            ilvlCnt = ilvlCnt + 1
        end
    end
    local avgIlvl = (ilvlCnt > 0) and math.floor((ilvlSum / ilvlCnt) + 0.5) or nil

    local ov = ns.Domain.HomeDashboardModel.BuildOverview({
        name = ga.GetPlayerName(),
        level = ga.GetPlayerLevel(),
        classLoc = locCls,
        classEng = engCls,
        zone = ga.GetPlayerZoneText(),
        realm = ns.Api.SafeAPI.GetCanonicalRealm(),
        freeSlots = ns.Api.SafeAPI.GetBagFreeSlots(),
        durPct = durPct,
        goldText = goldText,
        questCount = qCount,
        unspentTalents = ga.GetUnspentTalentPoints(),
        loadedPacksCount = CountLoadedPacks(),
        xpPct = xpSnap and xpSnap.xpPct or nil,
        restedPct = xpSnap and xpSnap.restedPct or nil,
        avgIlvl = avgIlvl,
    })

    local clsTex = (ov.classEng and T.ICON.CLASS_TEX[ov.classEng]) or T.ICON.FALLBACK
    local clsCol = (ov.classEng and T.CLASS_COLORS[ov.classEng]) or T.BORDER.GOLD
    self.heroIcon:SetIcon(clsTex, clsCol, "✦")
    self.heroTitle:SetText(ov.heroTitle)
    self.heroTitle:SetTextColor(clsCol[1], clsCol[2], clsCol[3], 1)
    self.heroSub:SetText(ov.heroSub)

    for _, c in ipairs(ov.cards) do
        local sc = self.statCards[c.id]
        if sc then
            sc:SetMetrics(c.value, c.sub, ToneColor(c.tone), c.icon)
        end
    end

    self.briefDungeonLbl:SetText(ov.recommendedDungeon)
    self.briefTipLbl:SetText(ov.recommendedTip)
end
