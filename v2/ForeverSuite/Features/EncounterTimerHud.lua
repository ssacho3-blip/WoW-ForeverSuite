-- Module: Features/EncounterTimerHud.lua
-- Responsibility: L0 Combat/Boss/Instance Run Timer HUD + /fs2 pull <3..30|0> countdown bar (active-only ticker).
-- Layer: Features (uses UI/Widgets + Domain/EncounterTimerModel + Api/GameAdapters).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local tostring = tostring
local string_format = string.format

local EncounterTimerHud = {
    card = nil,
    label = nil,
    detailLabel = nil,
    activeBossTip = nil,
    state = nil,
    ticker = nil,
    lastView = nil,
}
ns.Features.EncounterTimerHud = EncounterTimerHud

local function FindBossTip(encounterName)
    if type(encounterName) ~= "string" or encounterName == "" then return nil end
    local pack = _G.ForeverSuiteData and _G.ForeverSuiteData.packs and _G.ForeverSuiteData.packs.dungeon_bosses
    if type(pack) ~= "table" or type(pack.entries) ~= "table" then return nil end
    for _, b in ipairs(pack.entries) do
        if type(b) == "table" and b.title == encounterName and type(b.tip) == "string" and b.tip ~= "" then
            return b.tip
        end
    end
    return nil
end

local function ToneColor(tone)
    if tone == "GOLD" then return T.TEXT.GOLD, T.BORDER.GOLD end
    if tone == "WARN" then return T.SEMANTIC.WARN, T.SEMANTIC.WARN end
    if tone == "SUCCESS" then return T.SEMANTIC.SUCCESS, T.SEMANTIC.SUCCESS end
    if tone == "PRIMARY" then return T.TEXT.PRIMARY, T.BORDER.HAIRLINE end
    return T.TEXT.SECONDARY, T.BORDER.HAIRLINE
end

function EncounterTimerHud:EnsureState()
    if not self.state then
        self.state = ns.Domain.EncounterTimerModel.CreateState()
    end
    return self.state
end

function EncounterTimerHud:Init()
    if self.card then
        return self.card
    end
    self:EnsureState()
    local card = W.HudFloating(nil, 248, 26, "ForeverSuiteV2EncounterTimer", T.ELEVATION.L0_HUD)
    card:SetRibbon({ 0.04, 0.036, 0.048 }, 0.68, 0, 0)
    local lbl = W.Label(card, "", "mono", T.TEXT.PRIMARY, { justifyH = "CENTER", wordWrap = false, outline = "OUTLINE" })
    lbl:SetPoint("TOP", card, "TOP", 0, -5)
    local dLbl = W.Label(card, "", "small", T.TEXT.SECONDARY, { justifyH = "CENTER", wordWrap = false, outline = "OUTLINE" })
    dLbl:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 8, 4)
    dLbl:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -8, 4)
    dLbl:Hide()
    self.card = card
    self.label = lbl
    self.detailLabel = dLbl

    ns.UI.HudLayout:Register("encounterTimer", card, {
        point = "TOP",
        relPoint = "TOP",
        x = 0,
        y = -48,
    }, "전투·인던 타이머")

    card:Hide()
    return card
end

function EncounterTimerHud:StopTicker()
    if self.ticker then
        ns.Api.GameAdapters.CancelTicker(self.ticker)
        self.ticker = nil
    end
end

function EncounterTimerHud:SyncTicker()
    local st = self:EnsureState()
    local enabled = ns.Api.ProfileStore:Get("combat", "showEncounterTimer") ~= false
    if enabled and ns.Domain.EncounterTimerModel.NeedsTicker(st) then
        if not self.ticker then
            self.ticker = ns.Api.GameAdapters.StartTicker(0.2, function()
                EncounterTimerHud:Refresh()
            end)
        end
    else
        self:StopTicker()
    end
end

function EncounterTimerHud:Refresh()
    self:Init()
    local st = self:EnsureState()
    if ns.Api.ProfileStore:Get("combat", "showEncounterTimer") == false then
        self:StopTicker()
        self.card:Hide()
        return nil
    end
    local now = ns.Api.GameAdapters.GetMonotonicTime()
    if not now then
        self.card:Hide()
        return nil
    end
    local view = ns.Domain.EncounterTimerModel.EvaluateDisplay(st, now)
    self.lastView = view
    if view.visible then
        local txtCol, borderCol = ToneColor(view.tone)
        self.label:SetText(view.text)
        self.label:SetTextColor(txtCol[1], txtCol[2], txtCol[3], 1)
        if type(self.card.SetRibbon) == "function" then
            self.card:SetRibbon({ borderCol[1] * 0.25, borderCol[2] * 0.25, borderCol[3] * 0.25 }, 0.72, 0, 0)
        end
        if self.detailLabel and self.activeBossTip and self:IsBossActive() then
            self.detailLabel:SetText(self.activeBossTip)
            self.detailLabel:Show()
            self.card:SetHeight(44)
        else
            if self.detailLabel then self.detailLabel:Hide() end
            self.card:SetHeight(26)
        end
        self.card:Show()
    else
        self.card:Hide()
    end
    if view.expiredPull then
        ns.Api.SafeAPI.Print("풀링 카운트다운 종료 — 시작!")
    end
    self:SyncTicker()
    return view
end

function EncounterTimerHud:OnCombatStart()
    local now = ns.Api.GameAdapters.GetMonotonicTime()
    if now then
        ns.Domain.EncounterTimerModel.OnCombatStart(self:EnsureState(), now)
    end
    self:Refresh()
end

function EncounterTimerHud:OnCombatEnd()
    local now = ns.Api.GameAdapters.GetMonotonicTime()
    ns.Domain.EncounterTimerModel.OnCombatEnd(self:EnsureState(), now)
    self:Refresh()
end

function EncounterTimerHud:OnEncounterStart(encounterName)
    local now = ns.Api.GameAdapters.GetMonotonicTime()
    if now then
        local clean = (not ns.Api.SafeAPI.IsSecret(encounterName) and type(encounterName) == "string") and encounterName or nil
        self.activeBossTip = FindBossTip(clean)
        ns.Domain.EncounterTimerModel.OnEncounterStart(self:EnsureState(), clean, now)
    end
    self:Refresh()
end

function EncounterTimerHud:OnEncounterEnd(encounterName, success)
    self.activeBossTip = nil
    local now = ns.Api.GameAdapters.GetMonotonicTime()
    local clean = (not ns.Api.SafeAPI.IsSecret(encounterName) and type(encounterName) == "string") and encounterName or nil
    local cleanOk = (not ns.Api.SafeAPI.IsSecret(success)) and success or false
    local res = ns.Domain.EncounterTimerModel.OnEncounterEnd(self:EnsureState(), clean, cleanOk, now)
    if res and res.elapsed then
        local verdict = res.success and "처치" or "종료"
        ns.Api.SafeAPI.Print(string_format(
            "[보스 %s] %s (%s)",
            verdict,
            res.name,
            ns.Domain.EncounterTimerModel.FormatMMSS(res.elapsed)
        ))
    end
    self:Refresh()
end

function EncounterTimerHud:IsBossActive()
    return self.state ~= nil and self.state.bossStart ~= nil
end

function EncounterTimerHud:OnZoneOrInstanceChanged()
    local now = ns.Api.GameAdapters.GetMonotonicTime()
    if not now then
        return
    end
    local inInst, instType, instName = ns.Api.GameAdapters.GetInstanceContext()
    local deadOrGhostState = ns.Api.GameAdapters.IsPlayerDeadOrGhostState()
    local finished = ns.Domain.EncounterTimerModel.OnInstanceChange(self:EnsureState(), inInst, instType, instName, now, deadOrGhostState)
    if finished then
        ns.Api.SafeAPI.Print(string_format(
            "인스턴스 기록 [%s]: 경과 %s · 보스 처치 %d · 사망 %d",
            finished.name,
            ns.Domain.EncounterTimerModel.FormatMMSS(finished.elapsed),
            finished.bossKills,
            finished.deaths
        ))
    end
    self:Refresh()
end

function EncounterTimerHud:OnPlayerDead()
    ns.Domain.EncounterTimerModel.OnPlayerDead(self:EnsureState())
    self:Refresh()
end

function EncounterTimerHud:HandlePullCommand(rawArg)
    if ns.Api.ProfileStore:Get("combat", "showEncounterTimer") == false then
        ns.Api.SafeAPI.Print("전투·인던 타이머 HUD가 비활성화되어 있습니다(/fs settings에서 활성화).")
        return false, "HUD_DISABLED"
    end
    local now = ns.Api.GameAdapters.GetMonotonicTime()
    if not now then
        ns.Api.SafeAPI.Print("타이머 시계를 읽을 수 없습니다.")
        return false, "NO_CLOCK"
    end
    local ok, action, dur = ns.Domain.EncounterTimerModel.StartPull(self:EnsureState(), rawArg, now)
    if not ok then
        ns.Api.SafeAPI.Print("사용법: /fs pull <3~30> (취소: /fs pull 0)")
        return false, action
    end
    if action == "CANCELLED" then
        ns.Api.SafeAPI.Print("풀링 카운트다운을 취소했습니다.")
    else
        ns.Api.SafeAPI.Print("풀링 카운트다운 시작: " .. tostring(dur) .. "초")
    end
    self:Refresh()
    return true, action
end

function EncounterTimerHud:PrintStatus()
    local st = self:EnsureState()
    local now = ns.Api.GameAdapters.GetMonotonicTime() or 0
    if st.instance then
        local elapsed = ns.Domain.EncounterTimerModel.FormatMMSS(now - st.instance.startedAt)
        ns.Api.SafeAPI.Print(string_format(
            "현재 인스턴스 [%s]: 경과 %s · 보스 %d · 사망 %d",
            st.instance.name,
            elapsed,
            st.instance.bossKills,
            st.instance.deaths
        ))
    elseif st.lastCombatElapsed then
        ns.Api.SafeAPI.Print("최근 전투 시간: " .. ns.Domain.EncounterTimerModel.FormatMMSS(st.lastCombatElapsed))
    else
        ns.Api.SafeAPI.Print("활성 전투/인스턴스 타이머 기록이 없습니다. (/fs pull 10 으로 풀링 타이머 시작)")
    end
end
