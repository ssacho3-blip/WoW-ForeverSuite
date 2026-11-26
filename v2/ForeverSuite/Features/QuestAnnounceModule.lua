-- Module: Features/QuestAnnounceModule.lua
-- Responsibility: KPI-11 Opt-In Party Quest Progress Announcer (primes silently on login; announces objective/quest
--                 completions to PARTY only when OOC and chat not locked; zero RAID/SAY spam).
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local QuestAnnounceModule = {
    prevState = nil,
    sentCount = 0,
}
ns.Features.QuestAnnounceModule = QuestAnnounceModule

function QuestAnnounceModule:OnQuestLogUpdate()
    local rawQuests = ns.Api.SafeAPI.CollectQuestLog()
    local msgs, nextState = ns.Domain.TravelQuestModel.DiffQuestProgress(self.prevState, rawQuests)
    self.prevState = nextState

    if #msgs == 0 then
        return 0
    end
    if ns.Api.ProfileStore:Get("social", "questAnnounceParty") ~= true then
        return 0
    end
    if not ns.Api.GameAdapters.IsInGroupSafe() or ns.Api.GameAdapters.IsInRaidSafe() then
        return 0
    end
    local sent = 0
    local cap = (#msgs > 2) and 2 or #msgs
    for i = 1, cap do
        local ok = ns.Api.GameAdapters.SendChatSafe(msgs[i], "PARTY")
        if ok then
            sent = sent + 1
            self.sentCount = self.sentCount + 1
        end
    end
    return sent
end
