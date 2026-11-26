-- Module: Features/AutoGreetingModule.lua
-- Responsibility: Fail-Closed Auto Greeting (party join / member welcome / opt-in buff thank) with login/reload/raid
--                 burst suppression, strict cooldown boundary, tri-state group/raid checks, and UNKNOWN/Secret guards (I4, F3, F5).
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local ipairs = ipairs
local type = type

local AutoGreetingModule = {
    state = {
        cooldowns = {},
        rosterSynced = false,
        wasInGroup = false,
        knownMembers = {},
        seenAuras = {},
        aurasPrimed = false,
    },
}
ns.Features.AutoGreetingModule = AutoGreetingModule

function AutoGreetingModule:SetCustomMessage(kind, text)
    if (kind ~= "join" and kind ~= "welcome") or type(text) ~= "string" then return false end
    local key = (kind == "join") and "autoGreetJoinMsg" or "autoGreetWelcomeMsg"
    return ns.Api.ProfileStore and ns.Api.ProfileStore:SetState(key, text) == true
end

function AutoGreetingModule:GetCustomMessage(kind)
    local key = (kind == "join") and "autoGreetJoinMsg" or "autoGreetWelcomeMsg"
    local saved = ns.Api.ProfileStore and ns.Api.ProfileStore:GetState(key)
    if type(saved) == "string" and saved ~= "" then return saved end
    return ns.Domain.AutoGreetingModel.DEFAULTS[kind]
end

function AutoGreetingModule:SetExcludedBuffs(csv)
    return ns.Api.ProfileStore and ns.Api.ProfileStore:SetState("autoGreetExcludedBuffs", tostring(csv or "")) == true
end

function AutoGreetingModule:IsBuffExcluded(buffName)
    if type(buffName) ~= "string" or buffName == "" then return false end
    local csv = ns.Api.ProfileStore and ns.Api.ProfileStore:GetState("autoGreetExcludedBuffs") or ""
    if csv == "" then return false end
    local low = string.lower(buffName)
    for tok in string.gmatch(csv, "[^,]+") do
        local t = string.match(tok, "^%s*(.-)%s*$") or ""
        if t ~= "" and string.find(low, string.lower(t), 1, true) then
            return true
        end
    end
    return false
end

function AutoGreetingModule:SyncInitialRoster()
    local inGroup = ns.Api.GameAdapters.IsInGroupState()
    if inGroup == nil then
        self.state.rosterSynced = false
        return false
    end
    local units, rosterOk = ns.Api.GameAdapters.GetRosterUnitTokens()
    if not rosterOk then
        self.state.rosterSynced = false
        return false
    end
    local members = {}
    for _, u in ipairs(units) do
        local n, st = ns.Api.GameAdapters.GetUnitNameSafe(u)
        if st ~= "OK" or not n then
            -- F3: Do NOT finalize baseline while any member is UNKNOWN/SECRET; retry on next clean update without greeting
            self.state.rosterSynced = false
            return false
        end
        members[n] = true
    end
    self.state.wasInGroup = inGroup
    self.state.knownMembers = members
    self.state.rosterSynced = true
    return true
end

function AutoGreetingModule:OnGroupRosterUpdate()
    if not self.state.rosterSynced then
        self:SyncInitialRoster()
        return false, "INITIAL_SYNC"
    end
    -- F3: Fail-Closed on nil clock, nil group state, or nil raid state
    local now = ns.Api.GameAdapters.GetMonotonicTime()
    local inGroup = ns.Api.GameAdapters.IsInGroupState()
    local isRaid = ns.Api.GameAdapters.IsInRaidState()
    if inGroup == nil or isRaid == nil then
        return false, "STATE_UNAVAILABLE"
    end
    local inCombat = ns.Api.SafeAPI.InCombat()
    local locked = ns.Api.GameAdapters.IsChatMessagingLocked()

    if not inGroup then
        self.state.wasInGroup = false
        self.state.knownMembers = {}
        return false, "NOT_IN_GROUP"
    end

    -- Case 1: Player just joined a party
    if not self.state.wasInGroup then
        self.state.wasInGroup = true
        -- Capture baseline only if all current members are already resolved; otherwise leave rosterSynced=false so
        -- next update establishes baseline without falsely welcoming existing party members (F3).
        local baselineOk = self:SyncInitialRoster()
        self.state.wasInGroup = true
        local enabled = ns.Api.ProfileStore:Get("social", "autoGreetJoin") == true
        local ok, reason, key, exp = ns.Domain.AutoGreetingModel.CanSend("join", {
            enabled = enabled,
            inCombat = inCombat,
            chatLockdown = locked,
            rosterSynced = true,
            isRaid = isRaid,
            now = now,
        }, self.state)
        if not ok then
            return false, baselineOk and reason or "ROSTER_PENDING"
        end
        local locClass = ns.Api.GameAdapters.GetPlayerClassLocalized()
        local lvl = ns.Api.GameAdapters.GetPlayerLevel()
        if not (locClass and locClass ~= "" and lvl) then
            return false, "MISSING_PLAYER_META"
        end
        local msg = ns.Domain.AutoGreetingModel.FormatTemplate(self:GetCustomMessage("join"), {
            level = lvl,
            className = locClass,
        })
        local sent, sStatus = ns.Api.GameAdapters.SendChatSafe(msg, "PARTY")
        if sent then
            self.state.cooldowns[key] = exp
        end
        return sent, sStatus
    end

    -- Case 2: New member joined existing party.
    -- F3: If roster size unreadable OR ANY unit name is SECRET/UNKNOWN, abort BOTH knownMembers overwrite AND send!
    local units, rosterOk = ns.Api.GameAdapters.GetRosterUnitTokens()
    if not rosterOk then
        return false, "ROSTER_UNREADABLE"
    end
    local newNames = {}
    local selfName = ns.Api.GameAdapters.GetPlayerName()
    local currentSet = {}
    for _, u in ipairs(units) do
        local n, st = ns.Api.GameAdapters.GetUnitNameSafe(u)
        if st ~= "OK" or not n then
            return false, "UNRESOLVED_OR_SECRET_MEMBER"
        end
        currentSet[n] = true
        if n ~= selfName and not self.state.knownMembers[n] then
            newNames[#newNames + 1] = n
        end
    end
    self.state.knownMembers = currentSet

    if #newNames ~= 1 then
        return false, "BURST_OR_NONE"
    end
    local newcomer = newNames[1]
    local enabled = ns.Api.ProfileStore:Get("social", "autoGreetWelcome") == true
    local ok, reason, key, exp = ns.Domain.AutoGreetingModel.CanSend("welcome", {
        enabled = enabled,
        inCombat = inCombat,
        chatLockdown = locked,
        rosterSynced = true,
        isRaid = isRaid,
        targetKey = newcomer,
        now = now,
    }, self.state)
    if not ok then
        return false, reason
    end
    local msg = ns.Domain.AutoGreetingModel.FormatTemplate(self:GetCustomMessage("welcome"), {
        name = newcomer,
    })
    local sent, sStatus = ns.Api.GameAdapters.SendChatSafe(msg, "PARTY")
    if sent then
        self.state.cooldowns[key] = exp
    end
    return sent, sStatus
end

-- F5: Runtime consumer wired to UNIT_AURA ("player"); only primes when scan status == "OK"
function AutoGreetingModule:OnPlayerAuraChanged()
    local caster, buff, status = ns.Api.GameAdapters.ScanNewExternalBuff(self.state.seenAuras)
    if status ~= "OK" then
        return false, "UNREADABLE"
    end
    if not self.state.aurasPrimed then
        self.state.aurasPrimed = true
        return false, "PRIMED"
    end
    if caster and buff then
        return self:OnExternalBuffReceived(caster, buff)
    end
    return false, "NO_NEW_BUFF"
end

function AutoGreetingModule:OnExternalBuffReceived(casterName, buffName)
    -- Invariant I4: Default OFF; Fail-Closed on secret caster/buff, combat, chat lockdown, or missing clock
    if ns.Api.ProfileStore:Get("social", "autoThankBuff") ~= true then
        return false, "DISABLED"
    end
    if ns.Api.SafeAPI.IsSecret(casterName) or ns.Api.SafeAPI.IsSecret(buffName) then
        return false, "SECRET"
    end
    if type(casterName) ~= "string" or casterName == "" or casterName == ns.Api.GameAdapters.GetPlayerName() then
        return false, "SELF_OR_EMPTY"
    end
    if self:IsBuffExcluded(buffName) then
        return false, "BUFF_EXCLUDED"
    end
    local now = ns.Api.GameAdapters.GetMonotonicTime()
    local ok, reason, key, exp = ns.Domain.AutoGreetingModel.CanSend("buff", {
        enabled = true,
        inCombat = ns.Api.SafeAPI.InCombat(),
        chatLockdown = ns.Api.GameAdapters.IsChatMessagingLocked(),
        rosterSynced = self.state.rosterSynced,
        targetKey = casterName,
        now = now,
    }, self.state)
    if not ok then
        return false, reason
    end
    local sent, sStatus = ns.Api.GameAdapters.DoEmoteSafe("THANK", casterName)
    if sent then
        self.state.cooldowns[key] = exp
    end
    return sent, sStatus
end
