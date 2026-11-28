-- Module: Bridges/DialogueUI.lua
-- Responsibility: Official DialogueUIAPI bridge — reward card BiS/+iLvl evaluator, English-only Korean
--                 translator (preserves native Korean quests & existing translators), and QuestAutomation yield.
-- Layer: Bridges (Rank 3: OOC registration only; never auto-accepts/turns-in quests).
local _, ns = ...
ns.Bridges = ns.Bridges or {}

local type = type
local pcall = pcall
local string_find = string.find

local DialogueUIBridge = {
    registered = false,
    translatorRegistered = false,
    evaluatorProvider = nil,  -- function(itemLink) -> isUpgradeBool, noteText
    translatorProvider = nil, -- function(questID, rawText) -> { title, description, objective } | nil
}
ns.Bridges.DialogueUI = DialogueUIBridge

-- UTF-8 Hangul Syllable range (U+AC00..U+D7A3 -> leading bytes 0xEA..0xED, trail 0x80..0xBF)
function DialogueUIBridge.ContainsHangul(text)
    if type(text) ~= "string" or text == "" then
        return false
    end
    return string_find(text, "[\234-\237][\128-\191][\128-\191]") ~= nil
end

function DialogueUIBridge:SetProviders(providers)
    if type(providers) ~= "table" then
        return
    end
    if type(providers.evaluator) == "function" then
        self.evaluatorProvider = providers.evaluator
    end
    if type(providers.translator) == "function" then
        self.translatorProvider = providers.translator
    end
end

function DialogueUIBridge:EvaluateQuestReward(itemLink)
    if ns.Api.SafeAPI.IsSecret(itemLink) or type(itemLink) ~= "string" or itemLink == "" then
        return false, nil
    end
    if type(self.evaluatorProvider) == "function" then
        local ok, isUp, note = pcall(self.evaluatorProvider, itemLink)
        if ok then
            return isUp == true, note
        end
    end
    return false, nil
end

local function FetchLiveQuestText(questID)
    if _G.C_QuestLog and type(_G.C_QuestLog.GetTitleForQuestID) == "function" then
        local title = ns.Api.SafeAPI.SafeRead(_G.C_QuestLog.GetTitleForQuestID, questID)
        if title ~= ns.Api.SafeAPI.UNAVAILABLE and type(title) == "string" and title ~= "" then
            return title
        end
    end
    if type(_G.GetTitleText) == "function" then
        local title = ns.Api.SafeAPI.SafeRead(_G.GetTitleText)
        if title ~= ns.Api.SafeAPI.UNAVAILABLE and type(title) == "string" and title ~= "" then
            return title
        end
    end
    return nil
end

function DialogueUIBridge:QueryTranslation(questID, liveText)
    if ns.Api.SafeAPI.IsSecret(questID) or type(questID) ~= "number" or questID <= 0 then
        return nil
    end
    -- DialogueUI's Translator.lua calls questDataGetter(questID) with 1 arg; fetch live quest title when omitted.
    local sampleText = (type(liveText) == "string" and liveText ~= "") and liveText or FetchLiveQuestText(questID)
    -- Preserve 85%+ native Korean quests untouched
    if DialogueUIBridge.ContainsHangul(sampleText) then
        return nil
    end
    if type(self.translatorProvider) == "function" then
        local ok, data = pcall(self.translatorProvider, questID, sampleText)
        if ok and type(data) == "table" then
            return data
        end
    end
    return nil
end

function DialogueUIBridge:IsWindowShown()
    local api = ns.Api.AddonProbe.GetGlobal("DialogueUIAPI")
    if type(api) ~= "table" or type(api.IsAnyDUIWindowShown) ~= "function" then
        return false
    end
    local ok, shown = pcall(api.IsAnyDUIWindowShown)
    return ok and shown == true
end

function DialogueUIBridge:Init()
    local api = ns.Api.AddonProbe.GetGlobal("DialogueUIAPI")
    if type(api) ~= "table" then
        return "WARMING"
    end
    if self.registered then
        return "OK"
    end

    if type(api.AddItemEvaluator) == "function" then
        pcall(api.AddItemEvaluator, "ForeverSuite", function(itemLink)
            local isUp = DialogueUIBridge:EvaluateQuestReward(itemLink)
            return isUp
        end, function(tooltip, itemLink)
            local isUp, note = DialogueUIBridge:EvaluateQuestReward(itemLink)
            if isUp and tooltip and type(tooltip.AddLine) == "function" then
                pcall(tooltip.AddLine, tooltip, note or "ForeverSuite: 장비 업그레이드 추천", 0.33, 0.83, 0.42)
            end
        end)
    end

    -- Respect any pre-existing user translator; only register when no active translator exists
    if type(api.SetTranslator) == "function" then
        local hasExisting = false
        if type(api.GetActiveTranslator) == "function" then
            local ok, existing = pcall(api.GetActiveTranslator)
            if ok and existing ~= nil and existing ~= "" and existing ~= "ForeverSuite" then
                hasExisting = true
            end
        end
        if not hasExisting then
            local ok = pcall(api.SetTranslator, {
                name = "ForeverSuite",
                questDataGetter = function(questID, liveText)
                    return DialogueUIBridge:QueryTranslation(questID, liveText)
                end,
            })
            self.translatorRegistered = ok == true
        end
    end

    self.registered = true
    return "OK"
end

ns.Bridges.BridgeHost:Register({
    id = "dialogue_ui",
    target = "DialogueUI",
    mode = "bridge",
    protected = true,
    yields = { "quest_automation" },
    init = function()
        return DialogueUIBridge:Init()
    end,
    teardown = function()
        DialogueUIBridge.registered = false
        DialogueUIBridge.translatorRegistered = false
    end,
})
