-- Module: Core/ModuleManager.lua
-- Responsibility: Module lifecycle state machine (REGISTERED -> INITIALIZED -> ENABLED/DISABLED/YIELDED/FAULTED) & ctx sandbox.
-- Dependencies: Core/Init.lua (ns.CombatQueue, ns.IsExternalAddonLoaded), Core/EventBus.lua, Core/ProfileManager.lua.
-- Public API: ns.ModuleManager (Register, BootstrapAll, EnableModule, DisableModule, GetModule, ListModules, TotalActiveTickers).
-- Combat/Secret Safety: Reclaims frames via CombatQueue:RunOrDefer when disabling/faulting during InCombatLockdown().
local _, ns = ...

local type = type
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local xpcall = xpcall

local STATE_REGISTERED = "REGISTERED"
local STATE_INITIALIZED = "INITIALIZED"
local STATE_ENABLED = "ENABLED"
local STATE_DISABLED = "DISABLED"
local STATE_YIELDED = "YIELDED"
local STATE_FAULTED = "FAULTED"

local ERROR_WINDOW_SEC = 60
local MAX_ERRORS_IN_WINDOW = 3

local ModuleManager = {
    STATES = {
        REGISTERED = STATE_REGISTERED,
        INITIALIZED = STATE_INITIALIZED,
        ENABLED = STATE_ENABLED,
        DISABLED = STATE_DISABLED,
        YIELDED = STATE_YIELDED,
        FAULTED = STATE_FAULTED,
    },
    order = {},
    modules = {},
    bootstrapped = false,
}
ns.ModuleManager = ModuleManager

local function BuildModuleContext(rec)
    local ctx = {
        name = rec.name,
        tickers = {},
        frames = {},
        namedFrames = {},
        cleanups = {},
    }

    function ctx:OnError(summary)
        ModuleManager:HandleModuleError(rec.name, summary)
    end

    local errCallback = function(_, summary)
        ModuleManager:HandleModuleError(rec.name, summary)
    end

    function ctx:RegisterEvent(event, handler)
        return ns.EventBus:RegisterEvent(rec.name, event, function(ev, a1, a2, a3, a4, a5)
            handler(rec.definition, ev, a1, a2, a3, a4, a5)
        end, errCallback)
    end

    function ctx:RegisterUnitEvent(event, unit, handler)
        return ns.EventBus:RegisterUnitEvent(rec.name, event, unit, function(ev, a1, a2, a3, a4, a5)
            handler(rec.definition, ev, a1, a2, a3, a4, a5)
        end, errCallback)
    end

    function ctx:RegisterBucketEvent(event, intervalSec, handler, unitFilter)
        return ns.EventBus:RegisterBucketEvent(rec.name, event, intervalSec, function(ev, a1, count)
            handler(rec.definition, ev, a1, count)
        end, errCallback, unitFilter)
    end

    function ctx:NewTicker(intervalSec, callback)
        local handle = { cancelled = false, ticker = nil }
        local safeTick = function()
            if handle.cancelled or rec.state ~= STATE_ENABLED then
                return
            end
            xpcall(function()
                callback(rec.definition)
            end, function(err)
                ModuleManager:HandleModuleError(rec.name, ns.SummarizeStack(err))
            end)
        end
        if C_Timer and C_Timer.NewTicker then
            handle.ticker = C_Timer.NewTicker(intervalSec, safeTick)
        end
        function handle:Cancel()
            self.cancelled = true
            if self.ticker and self.ticker.Cancel then
                self.ticker:Cancel()
            end
        end
        function handle:IsActive()
            return (not self.cancelled) and (rec.state == STATE_ENABLED)
        end
        self.tickers[#self.tickers + 1] = handle
        return handle
    end

    function ctx:After(delaySec, callback)
        local cancelled = false
        local runner = function()
            if cancelled or rec.state ~= STATE_ENABLED then
                return
            end
            xpcall(function()
                callback(rec.definition)
            end, function(err)
                ModuleManager:HandleModuleError(rec.name, ns.SummarizeStack(err))
            end)
        end
        if C_Timer and C_Timer.After then
            C_Timer.After(delaySec, runner)
        else
            runner()
        end
        return {
            Cancel = function()
                cancelled = true
            end,
        }
    end

    function ctx:CreateFrame(frameType, frameName, parent, template)
        if not _G.CreateFrame then
            return nil, false
        end
        if type(frameName) == "string" and frameName ~= "" then
            local existing = self.namedFrames[frameName] or _G[frameName]
            if type(existing) == "table" then
                self.namedFrames[frameName] = existing
                self.frames[#self.frames + 1] = existing
                if existing.Show and not ns.InCombat() then
                    existing:Show()
                end
                return existing, false
            end
        end
        local f = _G.CreateFrame(frameType, frameName, parent or _G.UIParent, template)
        if f and type(frameName) == "string" and frameName ~= "" then
            self.namedFrames[frameName] = f
        end
        self.frames[#self.frames + 1] = f
        return f, true
    end

    function ctx:AddCleanup(fn)
        if type(fn) == "function" then
            self.cleanups[#self.cleanups + 1] = fn
        end
    end

    function ctx:ReclaimAll()
        ns.EventBus:UnregisterOwner(rec.name)
        for i = 1, #self.tickers do
            local t = self.tickers[i]
            if t and t.Cancel then
                t:Cancel()
            end
        end
        ns.WipeTable(self.tickers)

        local cleanupSnap = {}
        for i = 1, #self.cleanups do
            cleanupSnap[i] = self.cleanups[i]
        end
        ns.WipeTable(self.cleanups)
        for i = 1, #cleanupSnap do
            local fn = cleanupSnap[i]
            if fn then
                pcall(fn)
            end
        end

        for i = 1, #self.frames do
            local f = self.frames[i]
            if f then
                if f.UnregisterAllEvents then
                    pcall(function() f:UnregisterAllEvents() end)
                end
                if f.SetScript then
                    pcall(function() f:SetScript("OnUpdate", nil) end)
                    pcall(function() f:SetScript("OnEvent", nil) end)
                end
                if f.Hide then
                    ns.CombatQueue:RunOrDefer("hide:" .. rec.name .. ":" .. tostring(i), function()
                        f:Hide()
                    end)
                end
            end
        end
        ns.WipeTable(self.frames)
    end

    function ctx:ActiveTickerCount()
        local active = 0
        for i = 1, #self.tickers do
            if self.tickers[i]:IsActive() then
                active = active + 1
            end
        end
        return active
    end

    return ctx
end

function ModuleManager:Register(name, definition)
    if type(name) ~= "string" or type(definition) ~= "table" then
        return nil
    end
    if self.modules[name] then
        return self.modules[name]
    end
    definition.name = name
    local rec = {
        name = name,
        title = definition.title or name,
        priority = definition.priority or "P1",
        description = definition.description or "",
        yieldTo = definition.yieldTo or {},
        yieldedBy = nil,
        state = STATE_REGISTERED,
        definition = definition,
        errorTimestamps = {},
        errorCount = 0,
        lastError = nil,
        ctx = nil,
    }
    rec.ctx = BuildModuleContext(rec)
    self.modules[name] = rec
    self.order[#self.order + 1] = name
    return rec
end

function ModuleManager:CheckYieldCondition(rec)
    if type(rec.yieldTo) ~= "table" then
        return nil
    end
    for _, extName in ipairs(rec.yieldTo) do
        if ns.IsExternalAddonLoaded(extName) then
            return extName
        end
    end
    return nil
end

function ModuleManager:InitializeModule(rec)
    if rec.state ~= STATE_REGISTERED then
        return rec.state == STATE_INITIALIZED
    end
    if type(rec.definition.OnInitialize) == "function" then
        local ok = xpcall(function()
            rec.definition:OnInitialize(rec.ctx)
        end, function(err)
            rec.lastError = ns.SummarizeStack(err)
        end)
        if not ok then
            rec.state = STATE_FAULTED
            rec.errorCount = rec.errorCount + 1
            rec.ctx:ReclaimAll()
            ns.ErrorMsg("모듈 초기화 실패 [" .. rec.name .. "] → FAULTED 격리됨")
            return false
        end
    end
    rec.state = STATE_INITIALIZED
    return true
end

function ModuleManager:EnableModule(name, manualOverride)
    local rec = self.modules[name]
    if not rec then
        return false
    end
    if rec.state == STATE_FAULTED and not manualOverride then
        return false
    end
    if manualOverride then
        ns.WipeTable(rec.errorTimestamps)
        if rec.state == STATE_FAULTED then
            rec.state = STATE_INITIALIZED
        end
    end
    if rec.state == STATE_REGISTERED then
        if not self:InitializeModule(rec) then
            return false
        end
    end
    if rec.state == STATE_ENABLED then
        return true
    end

    local ext = self:CheckYieldCondition(rec)
    if ext then
        rec.yieldedBy = ext
        rec.state = STATE_YIELDED
        rec.ctx:ReclaimAll()
        return false
    end

    rec.yieldedBy = nil
    rec.state = STATE_ENABLED
    if type(rec.definition.OnEnable) == "function" then
        xpcall(function()
            rec.definition:OnEnable(rec.ctx)
        end, function(err)
            self:HandleModuleError(rec.name, ns.SummarizeStack(err))
        end)
    end
    return rec.state == STATE_ENABLED
end

function ModuleManager:DisableModule(name, targetState)
    local rec = self.modules[name]
    if not rec then
        return false
    end
    local wasEnabled = (rec.state == STATE_ENABLED)
    rec.state = targetState or STATE_DISABLED
    if wasEnabled and type(rec.definition.OnDisable) == "function" then
        xpcall(function()
            rec.definition:OnDisable(rec.ctx)
        end, function(err)
            rec.lastError = ns.SummarizeStack(err)
        end)
    end
    rec.ctx:ReclaimAll()
    if ns.SettingsPanel and ns.SettingsPanel.frame and ns.SettingsPanel.frame.IsShown and ns.SettingsPanel.frame:IsShown() then
        ns.SettingsPanel:Refresh()
    end
    return true
end

function ModuleManager:HandleModuleError(name, stackSummary)
    local rec = self.modules[name]
    if not rec then
        return
    end
    rec.lastError = stackSummary
    rec.errorCount = rec.errorCount + 1

    local now = ns.GetNow()
    local recent = {}
    for i = 1, #rec.errorTimestamps do
        local ts = rec.errorTimestamps[i]
        if (now - ts) <= ERROR_WINDOW_SEC then
            recent[#recent + 1] = ts
        end
    end
    recent[#recent + 1] = now
    rec.errorTimestamps = recent

    if #recent >= MAX_ERRORS_IN_WINDOW and rec.state ~= STATE_FAULTED then
        self:DisableModule(name, STATE_FAULTED)
        ns.ErrorMsg("모듈 [" .. name .. "] 60초 내 오류 " .. tostring(#recent) .. "회 감지 → FAULTED 자동 격리 (타 모듈 정상 유지)")
    end
end

function ModuleManager:BootstrapAll()
    for _, name in ipairs(self.order) do
        local rec = self.modules[name]
        if rec and rec.state == STATE_REGISTERED then
            self:InitializeModule(rec)
        end
    end
    for _, name in ipairs(self.order) do
        local rec = self.modules[name]
        if rec and rec.state ~= STATE_FAULTED then
            if ns.ProfileManager:IsModuleEnabled(name) then
                self:EnableModule(name, false)
            else
                rec.state = STATE_DISABLED
            end
        end
    end
    self.bootstrapped = true
end

function ModuleManager:OnExternalAddonLoaded(loadedAddonName)
    if not self.bootstrapped or type(loadedAddonName) ~= "string" then
        return
    end
    for _, name in ipairs(self.order) do
        local rec = self.modules[name]
        if rec and rec.state == STATE_ENABLED and type(rec.yieldTo) == "table" then
            for _, extName in ipairs(rec.yieldTo) do
                if extName == loadedAddonName then
                    rec.yieldedBy = extName
                    self:DisableModule(name, STATE_YIELDED)
                    ns.Print("외부 애드온 [" .. extName .. "] 로드 감지 → [" .. name .. "] 모듈 자동 양보(YIELDED)")
                    break
                end
            end
        end
    end
end

function ModuleManager:GetModule(name)
    return self.modules[name]
end

function ModuleManager:ListModules()
    local out = {}
    for i = 1, #self.order do
        out[i] = self.modules[self.order[i]]
    end
    return out
end

function ModuleManager:TotalActiveTickers()
    local count = 0
    for _, name in ipairs(self.order) do
        local rec = self.modules[name]
        if rec and rec.ctx then
            count = count + rec.ctx:ActiveTickerCount()
        end
    end
    return count
end
