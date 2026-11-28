-- Module: Features/QuickDockHud.lua
-- Responsibility: Compact 1-row collapsible Quick Tool Dock surfacing 1-click Fishing, Tracking cycle,
--                 Cheapest bag items, PartyFinder, 10s Pull timer, Chat Quick Bar toggle, and HUD Move mode.
-- Layer: Features (UIParent-owned, Zero-Taint, Shift+Drag direct move via HudLayout).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs

local EXPANDED_W = 314
local COLLAPSED_W = 30
local BAR_H = 26

local QuickDockHud = {
    bar = nil,
    buttons = nil,
    toggleBtn = nil,
    collapsed = false,
}
ns.Features.QuickDockHud = QuickDockHud

local DOCK_ACTIONS = {
    {
        id = "fish",
        label = "낚시",
        tip = "1클릭 낚시 도우미 창 열기/닫기 (/fs fish)",
        run = function()
            if ns.Features.FishingCardHud then
                ns.Features.FishingCardHud:Toggle()
            end
        end,
    },
    {
        id = "track",
        label = "추적",
        tip = "약초·광물·보물 미니맵 추적 순환 (/fs track)",
        run = function()
            if ns.Features.TrackingSwitcher then
                ns.Features.TrackingSwitcher:CycleNext()
            end
        end,
    },
    {
        id = "cheap",
        label = "싼템",
        tip = "가방 최저가 정리 추천 Top 5 출력 (/fs cheap)",
        run = function()
            if ns.Features.MerchantModule then
                ns.Features.MerchantModule:PrintCheapestItems()
            end
        end,
    },
    {
        id = "lfg",
        label = "파찾",
        tip = "파티 찾기 모니터 바로 열기",
        run = function()
            if ns.UI and ns.UI.CommandHub then
                ns.UI.CommandHub:JumpTo("partyfinder")
            end
        end,
    },
    {
        id = "pull",
        label = "풀링",
        tip = "10초 풀링 카운트다운 시작 (/fs pull 10)",
        run = function()
            if ns.Features.EncounterTimerHud then
                ns.Features.EncounterTimerHud:HandlePullCommand("10")
            end
        end,
    },
    {
        id = "chat",
        label = "채팅",
        tip = "채팅 빠른 채널 바 표시/숨김 전환",
        run = function()
            if ns.Api and ns.Api.ProfileStore then
                local cur = ns.Api.ProfileStore:Get("social", "showChatButtons") == true
                ns.Api.ProfileStore:Set("social", "showChatButtons", not cur)
            end
        end,
    },
    {
        id = "move",
        label = "이동",
        tip = "전체 HUD 배치 편집 모드 전환 (/fs move · Shift+드래그는 상시 이동)",
        run = function()
            if ns.UI and ns.UI.HudLayout then
                local unlocked, reason = ns.UI.HudLayout:ToggleUnlock()
                if reason == "IN_COMBAT" then
                    ns.Api.SafeAPI.Print("전투 중에는 HUD 이동 모드를 켤 수 없습니다.")
                else
                    ns.Api.SafeAPI.Print(unlocked and "HUD 이동 모드 활성화" or "HUD 위치 잠금")
                end
            end
        end,
    },
}

function QuickDockHud:Init()
    if self.bar then
        return self.bar
    end
    local bar = W.HudGlass(_G.UIParent, EXPANDED_W, BAR_H, "ForeverSuiteQuickDock", T.ELEVATION.L0_HUD, {
        bg = { 0.048, 0.043, 0.052, 0.78 },
        border = T.BORDER.GOLD_SOFT,
    })

    local buttons = {}
    local x = 6
    for i, spec in ipairs(DOCK_ACTIONS) do
        local captured = spec
        local btn = W.MiniButton(bar, spec.label, 38, 18, function()
            captured.run()
        end, spec.tip, { ghost = true })
        btn:SetPoint("LEFT", bar, "LEFT", x, 0)
        btn._dockId = spec.id
        buttons[i] = btn
        x = x + 41
    end

    local toggleBtn = W.MiniButton(bar, "◀", 18, 18, function()
        QuickDockHud:SetCollapsed(not QuickDockHud.collapsed)
    end, "빠른 도구 바 접기/펼치기 (Shift+드래그로 이동)", { ghost = true })
    toggleBtn:SetPoint("LEFT", bar, "LEFT", 292, 0)

    self.bar = bar
    self.buttons = buttons
    self.toggleBtn = toggleBtn
    self.collapsed = (ns.Api and ns.Api.ProfileStore and ns.Api.ProfileStore:GetState("quickDockCollapsed") == true) or false

    ns.UI.HudLayout:Register("quickDock", bar, {
        point = "TOPLEFT",
        relPoint = "TOPLEFT",
        x = 24,
        y = -188,
    }, "빠른 도구 바")

    if type(ns.UI.HudLayout.EnableDirectDrag) == "function" then
        ns.UI.HudLayout:EnableDirectDrag("quickDock", bar, { requireShift = true })
    end

    self:ApplyCollapsedVisuals()
    self:ApplyVisibility()
    return bar
end

function QuickDockHud:ApplyCollapsedVisuals()
    if not self.bar then return end
    if self.collapsed then
        self.bar:SetSize(COLLAPSED_W, BAR_H)
        for i = 1, #(self.buttons or {}) do
            self.buttons[i]:Hide()
        end
        if self.toggleBtn then
            self.toggleBtn:ClearAllPoints()
            self.toggleBtn:SetPoint("CENTER", self.bar, "CENTER", 0, 0)
            if self.toggleBtn._label then self.toggleBtn._label:SetText("★") end
        end
    else
        self.bar:SetSize(EXPANDED_W, BAR_H)
        for i = 1, #(self.buttons or {}) do
            self.buttons[i]:Show()
        end
        if self.toggleBtn then
            self.toggleBtn:ClearAllPoints()
            self.toggleBtn:SetPoint("LEFT", self.bar, "LEFT", 292, 0)
            if self.toggleBtn._label then self.toggleBtn._label:SetText("◀") end
        end
    end
end

function QuickDockHud:SetCollapsed(flag)
    self:Init()
    self.collapsed = flag == true
    if ns.Api and ns.Api.ProfileStore and ns.Api.ProfileStore:CanWrite() then
        ns.Api.ProfileStore:SetState("quickDockCollapsed", self.collapsed)
    end
    self:ApplyCollapsedVisuals()
    return self.collapsed
end

function QuickDockHud:ApplyVisibility()
    if not self.bar then return end
    if ns.UI.HudLayout and ns.UI.HudLayout:IsUnlocked() then
        self.bar:Show()
        return
    end
    local show = ns.Api.ProfileStore:Get("ui", "showQuickDock")
    if show == false then
        self.bar:Hide()
    else
        self.bar:Show()
    end
end

function QuickDockHud:Toggle()
    self:Init()
    local cur = ns.Api.ProfileStore:Get("ui", "showQuickDock")
    local nextVal = (cur == false)
    ns.Api.ProfileStore:Set("ui", "showQuickDock", nextVal)
    self:ApplyVisibility()
    return nextVal
end
