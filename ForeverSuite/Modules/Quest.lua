local _, ns = ...

local type = type
local tonumber = tonumber

local Quest = {
    title = "퀘스트 및 동선 보조 (Quest)",
    priority = "P1",
    description = "Questie 공존, 안전 자동 수락·완료(복수 보상 시 정지·Shift 우회), SuperTrack 포커스",
    yieldTo = { "Questie" },
}

local function IsShiftHeld()
    return (_G.IsShiftKeyDown and _G.IsShiftKeyDown()) and true or false
end

function Quest:OnQuestDetail()
    if ns.IsFeatureYielded("questAuto") then
        return
    end
    if not ns.ProfileManager:Get("quest", "autoAccept") or IsShiftHeld() then
        return
    end
    if _G.QuestGetAutoAccept and _G.QuestGetAutoAccept() then
        return
    end
    if _G.AcceptQuest then
        _G.AcceptQuest()
    end
end

function Quest:OnQuestProgress()
    if ns.IsFeatureYielded("questAuto") then
        return
    end
    if not ns.ProfileManager:Get("quest", "autoTurnIn") or IsShiftHeld() then
        return
    end
    if _G.IsQuestCompletable and _G.IsQuestCompletable() and _G.CompleteQuest then
        _G.CompleteQuest()
    end
end

function Quest:OnQuestComplete()
    if ns.IsFeatureYielded("questAuto") then
        return
    end
    if not ns.ProfileManager:Get("quest", "autoTurnIn") or IsShiftHeld() then
        return
    end
    if not _G.GetNumQuestChoices or not _G.GetQuestReward then
        return
    end
    local numChoices = _G.GetNumQuestChoices() or 0
    if type(numChoices) ~= "number" or ns.IsSecret(numChoices) then
        return
    end
    if numChoices > 1 then
        ns.Print("보상 선택지가 " .. tostring(numChoices) .. "개입니다. 원하는 보상을 직접 선택해 주세요.")
        return
    end
    local shouldQueueMoney = true
    local expectedReward = nil
    if type(_G.GetRewardMoney) == "function" then
        local rewardCopper = _G.GetRewardMoney()
        if type(rewardCopper) == "number" and not ns.IsSecret(rewardCopper) and rewardCopper > 0 then
            shouldQueueMoney = true
            expectedReward = rewardCopper
        else
            shouldQueueMoney = false
        end
    end
    if shouldQueueMoney then
        ns.SetPendingMoneyReason("QUEST", 1.5, 1, expectedReward)
    end
    if numChoices == 1 then
        _G.GetQuestReward(1)
    else
        _G.GetQuestReward()
    end
end

function Quest:OnQuestAccepted(_, arg1, arg2)
    if not ns.ProfileManager:Get("quest", "autoSuperTrack") then
        return
    end
    local questID = tonumber(arg2) or tonumber(arg1)
    if questID and questID > 0 and C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID then
        C_SuperTrack.SetSuperTrackedQuestID(questID)
    end
end

function Quest:OnEnable(ctx)
    ctx:RegisterEvent("QUEST_DETAIL", Quest.OnQuestDetail)
    ctx:RegisterEvent("QUEST_PROGRESS", Quest.OnQuestProgress)
    ctx:RegisterEvent("QUEST_COMPLETE", Quest.OnQuestComplete)
    ctx:RegisterEvent("QUEST_ACCEPTED", Quest.OnQuestAccepted)
end

ns.ModuleManager:Register("Quest", Quest)
