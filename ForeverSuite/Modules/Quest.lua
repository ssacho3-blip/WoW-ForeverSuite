-- Module: Modules/Quest.lua
-- Responsibility: Safe quest auto-accept/turn-in (Shift bypass, multi-choice pause), SuperTrack on accept, and /fs quest slash dispatcher.
-- Dependencies: Core/Init.lua, Core/MoneyLedgerQueue.lua, Core/ProfileManager.lua, Core/ModuleManager.lua, UI/QuestTracker.lua.
-- Public API: Quest (OnQuestDetail, OnQuestProgress, OnQuestComplete, OnQuestAccepted, HandleSlash).
-- Combat/Secret Safety: Yields to Questie when loaded; guards secret questID/choice counts; delegates HUD rendering to ns.QuestTracker.
local _, ns = ...

local type = type
local pcall = pcall
local tonumber = tonumber
local tostring = tostring
local math_floor = math.floor
local string_lower = string.lower
local string_match = string.match

local Quest = {
    title = "퀘스트 및 동선 보조 (Quest)",
    priority = "P1",
    description = "지역별·레벨별 퀘스트 추적창 HUD, 안전 자동 수락·완료(Shift 우회), SuperTrack 연동",
    yieldTo = { "Questie" },
    active = false,
    settingListenerBound = false,
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
    local numChoices = _G.GetNumQuestChoices()
    if ns.IsSecret(numChoices) or type(numChoices) ~= "number" then
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
        if not ns.IsSecret(rewardCopper) and type(rewardCopper) == "number" and rewardCopper > 0 then
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

local function SafeQuestID(val)
    if ns.IsSecret(val) then
        return nil
    end
    local num = (type(val) == "number") and val or ((type(val) == "string") and tonumber(val) or nil)
    if not num or num ~= num or num < 1 or num >= 2147483648 then
        return nil
    end
    local floored = math_floor(num)
    return (floored == num) and floored or nil
end

local function ResolveAcceptedQuestID(arg1, arg2)
    local q2 = SafeQuestID(arg2)
    if q2 then
        return q2
    end
    local q1 = SafeQuestID(arg1)
    if not q1 then
        return nil
    end
    if arg2 ~= nil then
        if C_QuestLog and C_QuestLog.GetInfo then
            local okInfo, info = pcall(C_QuestLog.GetInfo, q1)
            if okInfo and not ns.IsSecret(info) and type(info) == "table" then
                return SafeQuestID(info.questID)
            end
        end
        return nil
    end
    return q1
end

function Quest:OnQuestAccepted(_, arg1, arg2)
    local questID = ResolveAcceptedQuestID(arg1, arg2)
    if questID then
        if ns.SafeGetCVar("autoQuestWatch") ~= "0" and C_QuestLog and C_QuestLog.AddQuestWatch then
            local alreadyWatched = false
            if C_QuestLog.GetQuestWatchType then
                local okW, wType = pcall(C_QuestLog.GetQuestWatchType, questID)
                alreadyWatched = okW and (not ns.IsSecret(wType)) and (wType ~= nil)
            end
            if not alreadyWatched then
                pcall(C_QuestLog.AddQuestWatch, questID)
            end
        end
        if ns.ProfileManager:Get("quest", "autoSuperTrack") and C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID then
            pcall(C_SuperTrack.SetSuperTrackedQuestID, questID)
        end
    end
    self:OnTrackerRefreshEvent()
end

function Quest:OnTrackerRefreshEvent()
    if not self.active or not ns.QuestTracker then
        return
    end
    ns.QuestTracker:Refresh()
end

function Quest:OnInitialize()
    if not self.settingListenerBound then
        self.settingListenerBound = true
        ns.ProfileManager:OnSettingChanged(function(section, key)
            if section ~= "quest" or not Quest.active or not ns.QuestTracker then
                return
            end
            if ns.QuestTracker._suppressAutoRefresh then
                return
            end
            if key == "trackerPoint" or key == "trackerRelPoint" or key == "trackerX" or key == "trackerY" then
                return
            end
            ns.QuestTracker:Refresh()
        end)
    end
end

function Quest:HandleSlash(rawSub)
    if not self.active or not ns.QuestTracker then
        ns.Warn("Quest 모듈이 비활성화 또는 외부 애드온(Questie) 양보 상태입니다.")
        return false
    end
    local cleanSub = ns.IsSecret(rawSub) and "" or tostring(rawSub or "")
    local trimmed = string_match(cleanSub, "^%s*(.-)%s*$") or ""
    local sub = string_lower(trimmed)

    if sub == "" or sub == "mode" then
        local ok, nextMode = ns.QuestTracker:ToggleGroupMode()
        if not ok then
            return false
        end
        ns.Print("퀘스트 추적창 분류 모드: " .. ((nextMode == "level") and "레벨별" or "지역별"))
        return true
    elseif sub == "zone" or trimmed == "지역" or trimmed == "지역별" then
        local ok = ns.QuestTracker:SetGroupMode("zone")
        if not ok then
            return false
        end
        ns.Print("퀘스트 추적창 분류 모드: 지역별 (현재 지역 상단 고정)")
        return true
    elseif sub == "level" or sub == "lvl" or trimmed == "레벨" or trimmed == "레벨별" then
        local ok = ns.QuestTracker:SetGroupMode("level")
        if not ok then
            return false
        end
        ns.Print("퀘스트 추적창 분류 모드: 레벨별 (수월·적정·도전 난이도 순)")
        return true
    elseif sub == "here" or sub == "current" or trimmed == "현지역" or trimmed == "현재지역" then
        local ok, enabled = ns.QuestTracker:ToggleCurrentZoneFilter()
        if not ok then
            return false
        end
        ns.Print("현재 지역 퀘스트 필터: " .. (enabled and "켜짐 (현재 지역 + 완료 퀘스트)" or "꺼짐 (전체 지역 표시)"))
        return true
    elseif sub == "lock" or trimmed == "잠금" then
        local ok, locked = ns.QuestTracker:ToggleLocked()
        if not ok then
            return false
        end
        ns.Print("퀘스트 추적창 위치 잠금: " .. (locked and "켜짐 (드래그 이동 차단 · 클릭 유지)" or "꺼짐 (드래그 이동 가능)"))
        return true
    elseif sub == "all" or trimmed == "전체" then
        local ok = ns.ProfileManager:Set("quest", "watchedOnly", false, "account")
        if not ok then
            ns.Warn("읽기 전용 프로필(미래 스키마)에서는 설정을 저장할 수 없습니다.")
            return false
        end
        ns.Print("퀘스트 표시 범위: 수락한 전체 퀘스트 표시")
        return true
    elseif sub == "watched" or sub == "watch" or trimmed == "추적" or trimmed == "추적만" then
        local watchedOnly = ns.ProfileManager:Get("quest", "watchedOnly") and true or false
        local ok = ns.ProfileManager:Set("quest", "watchedOnly", not watchedOnly, "account")
        if not ok then
            ns.Warn("읽기 전용 프로필(미래 스키마)에서는 설정을 저장할 수 없습니다.")
            return false
        end
        ns.Print("퀘스트 표시 범위: " .. ((not watchedOnly) and "추적 중인 퀘스트만 표시" or "수락한 전체 퀘스트 표시"))
        return true
    elseif sub == "toggle" then
        local cur = ns.ProfileManager:Get("quest", "trackerEnabled") and true or false
        local ok = ns.ProfileManager:Set("quest", "trackerEnabled", not cur, "account")
        if not ok then
            ns.Warn("읽기 전용 프로필(미래 스키마)에서는 설정을 저장할 수 없습니다.")
            return false
        end
        ns.Print("ForeverSuite 퀘스트 추적창: " .. ((not cur) and "표시" or "숨김"))
        return true
    elseif sub == "show" or sub == "on" then
        local ok = ns.ProfileManager:Set("quest", "trackerEnabled", true, "account")
        if not ok then
            ns.Warn("읽기 전용 프로필(미래 스키마)에서는 설정을 저장할 수 없습니다.")
            return false
        end
        ns.Print("ForeverSuite 퀘스트 추적창: 표시")
        return true
    elseif sub == "hide" or sub == "off" then
        local ok = ns.ProfileManager:Set("quest", "trackerEnabled", false, "account")
        if not ok then
            ns.Warn("읽기 전용 프로필(미래 스키마)에서는 설정을 저장할 수 없습니다.")
            return false
        end
        ns.Print("ForeverSuite 퀘스트 추적창: 숨김 (기본 추적기 복원)")
        return true
    elseif sub == "default" or sub == "blizzard" then
        local hideDef = ns.ProfileManager:Get("quest", "hideDefaultTracker") and true or false
        local ok = ns.ProfileManager:Set("quest", "hideDefaultTracker", not hideDef, "account")
        if not ok then
            ns.Warn("읽기 전용 프로필(미래 스키마)에서는 설정을 저장할 수 없습니다.")
            return false
        end
        ns.Print("기본 퀘스트 추적기 숨김: " .. ((not hideDef) and "켜짐" or "꺼짐 (동시 표시)"))
        return true
    elseif sub == "min" or sub == "minimize" then
        local ok, minimized = ns.QuestTracker:ToggleMinimized()
        if not ok then
            return false
        end
        ns.Print("퀘스트 추적창 최소화: " .. (minimized and "접힘" or "펼침"))
        return true
    elseif sub == "reset" then
        local ok = ns.QuestTracker:ResetLayout()
        if not ok then
            return false
        end
        ns.Print("퀘스트 추적창 위치 및 그룹 접힘 상태를 초기화했습니다.")
        return true
    end

    ns.Print("사용법: /fs quest [zone | level | here | all | watched | lock | toggle | default | reset]")
    return false
end

function Quest:OnEnable(ctx)
    self.active = true
    ctx:RegisterEvent("QUEST_DETAIL", Quest.OnQuestDetail)
    ctx:RegisterEvent("QUEST_PROGRESS", Quest.OnQuestProgress)
    ctx:RegisterEvent("QUEST_COMPLETE", Quest.OnQuestComplete)
    ctx:RegisterEvent("QUEST_ACCEPTED", Quest.OnQuestAccepted)

    ctx:RegisterBucketEvent("QUEST_LOG_UPDATE", 0.15, Quest.OnTrackerRefreshEvent)
    ctx:RegisterEvent("QUEST_WATCH_LIST_CHANGED", Quest.OnTrackerRefreshEvent)
    ctx:RegisterEvent("QUEST_TURNED_IN", Quest.OnTrackerRefreshEvent)
    ctx:RegisterEvent("QUEST_REMOVED", Quest.OnTrackerRefreshEvent)
    ctx:RegisterEvent("PLAYER_ENTERING_WORLD", Quest.OnTrackerRefreshEvent)
    ctx:RegisterEvent("ZONE_CHANGED_NEW_AREA", Quest.OnTrackerRefreshEvent)
    ctx:RegisterEvent("ZONE_CHANGED", Quest.OnTrackerRefreshEvent)
    ctx:RegisterEvent("PLAYER_LEVEL_UP", Quest.OnTrackerRefreshEvent)
    ctx:RegisterEvent("SUPER_TRACKING_CHANGED", Quest.OnTrackerRefreshEvent)

    if ns.QuestTracker then
        ns.QuestTracker:Enable(ctx)
    end
end

function Quest:OnDisable()
    self.active = false
    if ns.QuestTracker then
        ns.QuestTracker:Disable()
    end
end

ns.ModuleManager:Register("Quest", Quest)
