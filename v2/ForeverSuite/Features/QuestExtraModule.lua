-- Module: Features/QuestExtraModule.lua
-- Responsibility: D6/D7/J6 Full Parity - Quest Collection Completion Banner, Party Quest Sync (C_ChatInfo addon msgs),
--                 Proximity Quest/Escort Alerts, Starter/Turn-in Hints, and Growth Milestone Alerts.
-- Layer: Features (uses UI/Widgets + Api/SafeAPI/GameAdapters; zero raw CreateFrame / C_*).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local tonumber = tonumber
local type = type
local math_sqrt = math.sqrt

local SYNC_PREFIX = "FSQuest4"
local MILESTONE_HINTS = {
    [10] = "Lv.10 달성! 직업 핵심 퀘스트 · 특성 포인트 개방 · 전문기술 시작을 확인하세요.",
    [15] = "Lv.15 달성! 성난불길 협곡 / 죽음의 폐광 던전 퀘스트 준비 시점입니다.",
    [20] = "Lv.20 달성! 직업 핵심 기술 습득 · 그림자송곳니 성채 / 통곡의 동굴 구간 진입!",
    [30] = "Lv.30 달성! 붉은십자군 수도원 · 직업 전용 30레벨 퀘스트를 확인하세요.",
    [40] = "Lv.40 달성! 탈것(기수 숙련) 습득 · 크롤도크 보루 / 줄파락 / 마라우돈 진입!",
    [50] = "Lv.50 달성! 50레벨 직업 퀘스트 · 가라앉은 사원 / 검은바위 나락 준비 시점입니다.",
    [60] = "Lv.60 만렙 달성! BiS 장비 비교 & 공격대(화산 심장부/오닉시아) 준비를 시작하세요.",
}

local QuestExtraModule = {
    initialized = false,
    prefixRegistered = false,
    notifiedCollections = {},
    notifiedCollectionItems = {},
    notifiedProximity = {},
    partyProgress = {}, -- [sender] = { [questID] = progressStr }
    proximityTicker = nil,
    lastSyncSentAt = 0,
    lastGrowthLevel = nil,
    lastCompletionSoundAt = -999,
    xpBuffPrimed = false,
    activeXpBuffs = nil,
    lastXpAlertAt = -999,
}
ns.Features.QuestExtraModule = QuestExtraModule

function QuestExtraModule:PrimeCompletedQuests()
    local quests = ns.Api.SafeAPI.CollectQuestLog()
    for _, q in ipairs(quests) do
        if q.isComplete and type(q.questID) == "number" and q.questID > 0 then
            self.notifiedCollections[q.questID] = true
        end
    end
end

function QuestExtraModule:PlayCompletionChime(forceBypassThrottle)
    if ns.Api.ProfileStore:Get("quest", "completionSound") == false then
        return false, "DISABLED"
    end
    local snd = ns.Api.ProfileStore:Get("ui", "alertSoundKey") or "dingdong"
    if snd == "none" or snd == "" then
        return false, "MUTED"
    end
    local now = ns.Api.GameAdapters.GetMonotonicTime() or 0
    if (not forceBypassThrottle) and (now - (self.lastCompletionSoundAt or -999)) < 0.8 then
        return false, "THROTTLED"
    end
    local ok = ns.Api.GameAdapters.PlayNotificationSound(snd, 75, "Master", false)
    if ok then
        self.lastCompletionSoundAt = now
    end
    return ok, snd
end

function QuestExtraModule:OnQuestTurnedIn(questID)
    if ns.Api.SafeAPI.IsSecret(questID) then
        return false, "SECRET"
    end
    if type(questID) == "number" and questID > 0 then
        self.notifiedCollections[questID] = nil
    end
    return self:PlayCompletionChime(false)
end

-- Lv<60 XP Buff Expiry Alert (food "포만감", sleeping bag "충분한 휴식", Darkmoon "야호!", etc.)
function QuestExtraModule:CheckXpBuffExpiry()
    if ns.Api.ProfileStore:Get("quest", "xpBuffExpiryAlert") == false then
        return 0, "DISABLED"
    end
    local lvl = ns.Api.GameAdapters.GetPlayerLevel()
    if type(lvl) ~= "number" or lvl < 1 then
        return 0, "LEVEL_UNKNOWN"
    end
    if lvl >= 60 then
        self.xpBuffPrimed = false
        self.activeXpBuffs = nil
        return 0, "MAX_LEVEL"
    end
    local auras, readable = ns.Api.GameAdapters.ScanPlayerHelpfulAuras()
    if not readable then
        -- Fail-Closed: preserve prior activeXpBuffs across transient Secret/unreadable scans
        return 0, "UNREADABLE"
    end
    local curMap = {}
    for _, a in ipairs(auras) do
        if ns.Domain.CombatAlertModel.IsXpBuffAura(a.spellId, a.name) then
            curMap[a.name] = true
        end
    end
    local isDeadOrGhost = ns.Api.GameAdapters.IsPlayerDeadOrGhost()
    local expired, nextMap = ns.Domain.CombatAlertModel.DiffExpiredXpBuffs(
        self.xpBuffPrimed and self.activeXpBuffs or nil,
        curMap,
        lvl,
        isDeadOrGhost
    )
    self.activeXpBuffs = nextMap
    self.xpBuffPrimed = true
    if #expired == 0 then
        return 0, "OK"
    end
    local names = table.concat(expired, ", ")
    W.Toast("경험치 버프 만료! (Lv." .. tostring(lvl) .. ")", "[" .. names .. "] 버프가 사라졌습니다! 음식·침낭을 다시 챙기세요.", "WARN", 6.0)
    ns.Api.SafeAPI.Print("[경험치 버프 알림] [" .. names .. "] 만료! (60레벨 미만 육성 중 - 음식/침낭 버프를 다시 적용하세요)")
    local now = ns.Api.GameAdapters.GetMonotonicTime() or 0
    if (now - (self.lastXpAlertAt or -999)) >= 1.5 then
        local snd = ns.Api.ProfileStore:Get("ui", "alertSoundKey") or "dingdong"
        if snd ~= "none" and snd ~= "" then
            if ns.Api.GameAdapters.PlayNotificationSound(snd, 75, "Master", false) then
                self.lastXpAlertAt = now
            end
        end
    end
    return #expired, expired
end

function QuestExtraModule:EnsureExtraData()
    if not ns.Api.SafeAPI.InCombat() then
        ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_QuestExtra")
    end
    local packs = _G.ForeverSuiteData and _G.ForeverSuiteData.packs
    return type(packs) == "table" and packs or {}
end

-- D6: Quest collection completion banner + "dingdong" chime when active quest OR quest_collection bag drop items reach completion
function QuestExtraModule:CheckCollectionAlerts()
    local showBanner = (ns.Api.ProfileStore:Get("quest", "collectionAlerts") ~= false)
    local wantSound = (ns.Api.ProfileStore:Get("quest", "completionSound") ~= false)
    if (not showBanner) and (not wantSound) then return 0 end
    local quests = ns.Api.SafeAPI.CollectQuestLog()
    local triggered = 0
    local completedAny = false
    for _, q in ipairs(quests) do
        if q.isComplete and (not self.notifiedCollections[q.questID]) then
            self.notifiedCollections[q.questID] = true
            triggered = triggered + 1
            completedAny = true
            if showBanner then
                W.Toast("퀘스트 수집 완료!", tostring(q.title) .. " - 보고할 준비가 되었습니다.", "SUCCESS", 4.5)
            end
        end
    end
    if completedAny and wantSound then
        self:PlayCompletionChime(false)
    end
    if not showBanner then return triggered end
    -- Also inspect ForeverSuite_Data_QuestExtra quest_collection items (63 curated dungeon/world collection drops)
    local packs = self:EnsureExtraData()
    local colRows = packs.quest_collection and packs.quest_collection.entries
    if type(colRows) == "table" and #colRows > 0 then
        local bagCounts = ns.Api.GameAdapters.ScanBagsAndBankCounts(false)
        for _, item in ipairs(colRows) do
            if type(item.itemID) == "number" and (bagCounts[item.itemID] or 0) > 0 then
                local prev = self.notifiedCollectionItems[item.itemID] or 0
                local cur = bagCounts[item.itemID]
                if cur > prev then
                    self.notifiedCollectionItems[item.itemID] = cur
                    if prev > 0 or #quests > 0 then
                        triggered = triggered + 1
                        W.Toast("퀘스트 수집품 획득", tostring(item.title) .. " (보유 " .. tostring(cur) .. "개)", "INFO", 3.5)
                    end
                end
            end
        end
    end
    return triggered
end

-- D6: Lookup quest starter item or turn-in dialogue route by itemID / questID
function QuestExtraModule:GetStarterHintForItem(itemID)
    if type(itemID) ~= "number" or itemID <= 0 then return nil end
    local packs = self:EnsureExtraData()
    local rows = packs.quest_starters and packs.quest_starters.entries or {}
    for _, r in ipairs(rows) do
        if r.itemID == itemID then return r end
    end
    return nil
end

function QuestExtraModule:GetDialogueRouteForQuest(questID)
    if type(questID) ~= "number" or questID <= 0 then return nil end
    local packs = self:EnsureExtraData()
    local rows = packs.quest_routes and packs.quest_routes.entries or {}
    for _, r in ipairs(rows) do
        if r.questID == questID and r.kind == "dialogue" then return r end
    end
    return nil
end

-- D7: Party Quest Progress Sync via C_ChatInfo.SendAddonMessage (throttled OOC, secret-safe)
function QuestExtraModule:BroadcastPartyQuestSync(force)
    if ns.Api.ProfileStore:Get("quest", "partyQuestSync") == false then return false, "DISABLED" end
    if ns.Api.SafeAPI.InCombat() then return false, "IN_COMBAT" end
    if not ns.Api.GameAdapters.IsInGroupSafe() then return false, "NOT_IN_GROUP" end
    local now = ns.Api.GameAdapters.GetMonotonicTime() or 0
    if (not force) and (now - self.lastSyncSentAt) < 15 then return false, "COOLDOWN" end

    local quests = ns.Api.SafeAPI.CollectQuestLog()
    local parts = {}
    for i = 1, (#quests > 10 and 10 or #quests) do
        local q = quests[i]
        local done = 0
        for _, o in ipairs(q.objectives or {}) do
            if o.finished then done = done + 1 end
        end
        local tot = #(q.objectives or {})
        parts[#parts + 1] = tostring(q.questID) .. ":" .. (q.isComplete and "C" or (tostring(done) .. "/" .. tostring(tot)))
    end
    if #parts == 0 then return false, "EMPTY" end
    local payload = "Q|" .. table.concat(parts, ",")
    local ok, st = ns.Api.GameAdapters.SendAddonMessageSafe(SYNC_PREFIX, payload)
    if ok then self.lastSyncSentAt = now end
    return ok, st
end

function QuestExtraModule:OnAddonMessage(prefix, msg, dist, sender)
    if ns.Api.SafeAPI.IsSecret(prefix) or ns.Api.SafeAPI.IsSecret(msg) or ns.Api.SafeAPI.IsSecret(dist) or ns.Api.SafeAPI.IsSecret(sender) then
        return false, "SECRET"
    end
    if ns.Api.SafeAPI.InCombat() then
        return false, "IN_COMBAT"
    end
    if prefix ~= SYNC_PREFIX or type(msg) ~= "string" or type(sender) ~= "string" or sender == "" then
        return false, "IGNORED"
    end
    if dist ~= "PARTY" and dist ~= "RAID" then
        return false, "INVALID_CHANNEL"
    end
    if #msg > 240 or string.sub(msg, 1, 2) ~= "Q|" then
        return false, "BAD_FMT"
    end
    local senderCount = 0
    for _ in pairs(self.partyProgress) do senderCount = senderCount + 1 end
    if senderCount >= 40 and not self.partyProgress[sender] then
        return false, "CAP_REACHED"
    end
    local rec = {}
    local parsedCount = 0
    for tok in string.gmatch(string.sub(msg, 3), "[^,]+") do
        if parsedCount >= 25 then break end
        local qidStr, prog = string.match(tok, "^(%d+):(.+)$")
        local qid = tonumber(qidStr)
        local validProg = (prog == "C") or (type(prog) == "string" and string.match(prog, "^%d+/%d+$") ~= nil)
        if qid and qid > 0 and validProg and #prog <= 12 then
            rec[qid] = prog
            parsedCount = parsedCount + 1
        end
    end
    self.partyProgress[sender] = rec
    return true, rec
end

function QuestExtraModule:GetPartySummaryForQuest(questID)
    local out = {}
    for sender, map in pairs(self.partyProgress) do
        if map[questID] then
            out[#out + 1] = sender .. "(" .. tostring(map[questID]) .. ")"
        end
    end
    return table.concat(out, ", ")
end

-- D7: Proximity alert for nearby quest routes / unaccepted starters (distance <= 0.035 map units)
function QuestExtraModule:CheckProximityAlerts()
    if ns.Api.ProfileStore:Get("quest", "proximityAlerts") == false then return 0 end
    if ns.Api.SafeAPI.InCombat() then return 0 end
    if ns.Bridges and ns.Bridges.BridgeHost and ns.Bridges.BridgeHost:IsFeatureYielded("rare_alerts") then
        return 0
    end
    local pos = ns.Api.GameAdapters.GetPlayerPosition()
    if not pos then return 0 end
    local packs = self:EnsureExtraData()
    local routes = packs.quest_routes and packs.quest_routes.entries or {}
    local alerted = 0
    for _, r in ipairs(routes) do
        if r.kind == "dialogue" and r.mapID == pos.mapID and type(r.x) == "number" and type(r.y) == "number"
            and type(r.questID) == "number" and not self.notifiedProximity[r.questID]
        then
            if ns.Api.SafeAPI.IsQuestInLog(r.questID) then
                local dx, dy = r.x - pos.x, r.y - pos.y
                if math_sqrt(dx * dx + dy * dy) <= 0.035 then
                    self.notifiedProximity[r.questID] = true
                    alerted = alerted + 1
                    W.Toast("근처 퀘스트 목표 감지", tostring(r.title or ("퀘스트 #" .. tostring(r.questID))), "INFO", 4.0)
                    break
                end
            end
        end
    end
    return alerted
end

function QuestExtraModule:SyncProximityTicker(forceStop)
    local yieldedToRare = ns.Bridges and ns.Bridges.BridgeHost
        and ns.Bridges.BridgeHost:IsFeatureYielded("rare_alerts") or false
    local enabled = (not forceStop) and (not yieldedToRare) and (not ns.Api.SafeAPI.InCombat()) and (ns.Api.ProfileStore:Get("quest", "proximityAlerts") ~= false)
    local quests = enabled and ns.Api.SafeAPI.CollectQuestLog() or {}
    if enabled and #quests > 0 then
        if not self.proximityTicker then
            self.proximityTicker = ns.Api.GameAdapters.StartTicker(2.0, function()
                QuestExtraModule:CheckProximityAlerts()
            end)
        end
    elseif self.proximityTicker then
        ns.Api.GameAdapters.CancelTicker(self.proximityTicker)
        self.proximityTicker = nil
    end
end

-- J6: Growth Milestone Alert on level-up
function QuestExtraModule:CheckGrowthMilestone(newLevel)
    if ns.Api.ProfileStore:Get("qol", "growthAlerts") == false then return false end
    local lvl = tonumber(newLevel) or ns.Api.GameAdapters.GetPlayerLevel()
    if not lvl or lvl == self.lastGrowthLevel then return false end
    self.lastGrowthLevel = lvl
    local hint = MILESTONE_HINTS[lvl]
    if not hint then
        hint = "Lv." .. tostring(lvl) .. " 달성! 상급자 스킬 및 추천 육성 지역을 퀘스트 가이드에서 확인하세요."
    end
    W.Toast("성장 이정표 · Lv." .. tostring(lvl), hint, "GOLD", 6.0)
    ns.Api.SafeAPI.Print("[성장 알림] " .. hint)
    return true
end

function QuestExtraModule:Init()
    if self.initialized then return true end
    self.initialized = true
    self:PrimeCompletedQuests()
    self:CheckXpBuffExpiry()
    self.prefixRegistered = ns.Api.GameAdapters.RegisterAddonPrefixSafe(SYNC_PREFIX)
    ns.Api.EventBus:OnEvent("v4:addonMsg", "CHAT_MSG_ADDON", function(_, prefix, msg, dist, sender)
        QuestExtraModule:OnAddonMessage(prefix, msg, dist, sender)
    end)
    self:SyncProximityTicker()
    return true
end
