-- Module: Domain/AutoGreetingModel.lua
-- Responsibility: Pure Auto Greeting state machine (join / welcome / buff-thank), template expansion,
--                 strict cooldown boundary (now < expiresAt), and login/reload/raid burst suppression (Invariant I4).
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local tostring = tostring
local string_gsub = string.gsub

local AutoGreetingModel = {
    DEFAULTS = {
        join = "안녕하세요. {레벨}렙 {직업} 입니다.",
        welcome = "{이름}님 어서오세요!",
        buff = "{이름}님 {버프} 감사합니다!",
    },
    COOLDOWN_SEC = {
        join = 45,
        welcome = 15,
        buff = 60,
    },
}
ns.Domain.AutoGreetingModel = AutoGreetingModel

function AutoGreetingModel.FormatTemplate(template, vars)
    local raw = (type(template) == "string" and template ~= "") and template or ""
    if raw == "" then
        return ""
    end
    local v = type(vars) == "table" and vars or {}
    local out = raw
    out = string_gsub(out, "{이름}", tostring(v.name or ""))
    out = string_gsub(out, "{레벨}", tostring(v.level or ""))
    out = string_gsub(out, "{직업}", tostring(v.className or ""))
    out = string_gsub(out, "{버프}", tostring(v.buffName or ""))
    -- Strip pipe escapes to prevent chat link/color injection
    out = string_gsub(out, "|", "")
    return out
end

-- Decides whether an auto-greeting is allowed right now (Fail-Closed on combat/lockdown/uninitialized/cooldown).
-- Cooldown boundary: blocked while now < expiresAt; allowed once now >= expiresAt.
function AutoGreetingModel.CanSend(kind, ctx, state)
    if type(ctx) ~= "table" or type(state) ~= "table" then
        return false, "INVALID_CTX"
    end
    if ctx.enabled ~= true then
        return false, "DISABLED"
    end
    if ctx.inCombat == true or ctx.chatLockdown == true then
        return false, "LOCKED"
    end
    if ctx.rosterSynced ~= true then
        return false, "ROSTER_NOT_SYNCED"
    end
    if type(ctx.now) ~= "number" then
        return false, "NO_CLOCK"
    end
    local cd = AutoGreetingModel.COOLDOWN_SEC[kind] or 30
    local key = (kind == "welcome" or kind == "buff")
        and (kind .. ":" .. tostring(ctx.targetKey or "")) or kind
    local expiresAt = state.cooldowns and state.cooldowns[key]
    if type(expiresAt) == "number" and ctx.now < expiresAt then
        return false, "COOLDOWN"
    end
    -- Suppress join/welcome burst inside raids unless explicitly allowed
    if (kind == "join" or kind == "welcome") and ctx.isRaid == true and ctx.allowInRaid ~= true then
        return false, "RAID_SUPPRESSED"
    end
    return true, "OK", key, ctx.now + cd
end
