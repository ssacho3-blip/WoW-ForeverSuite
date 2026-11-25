-- Module: Features/QuestAutomation.lua
-- Responsibility: Safe quest auto-accept/turn-in (Shift bypass, multi-choice pause, v1 yield) + NavPort auto-SuperTrack.
-- Layer: Features (zero direct C_* calls).
local _, ns = ...
ns.Features = ns.Features or {}

local QuestAutomation = {}
ns.Features.QuestAutomation = QuestAutomation

local function CanAutomate(settingKey)
    if ns.Api.SafeAPI.IsV1Loaded() then
        return false
    end
    if ns.Api.GameAdapters.IsShiftDown() then
        return false
    end
    return ns.Api.ProfileStore:Get("quest", settingKey) == true
end

function QuestAutomation:OnQuestDetail()
    if not CanAutomate("autoAccept") then
        return false
    end
    return ns.Api.GameAdapters.AcceptQuestSafe()
end

function QuestAutomation:OnQuestProgress()
    if not CanAutomate("autoTurnIn") then
        return false
    end
    return ns.Api.GameAdapters.CompleteQuestSafe()
end

function QuestAutomation:OnQuestComplete()
    if not CanAutomate("autoTurnIn") then
        return false
    end
    local ok, reason = ns.Api.GameAdapters.TurnInQuestSafe()
    if (not ok) and reason == "MULTIPLE_CHOICES" then
        ns.Api.SafeAPI.Print("보상 선택지가 2개 이상이므로 수동 선택을 위해 자동 완료를 일시 중지했습니다.")
    end
    return ok, reason
end

function QuestAutomation:OnQuestAccepted(questID)
    if ns.Api.SafeAPI.IsV1Loaded() then
        return false
    end
    if ns.Api.ProfileStore:Get("quest", "autoSuperTrack") ~= true then
        return false
    end
    if type(questID) ~= "number" or questID <= 0 then
        return false
    end
    local ok, status = ns.Api.NavPort.RequestSuperTrack(questID)
    return ok, status
end
