-- Module: Features/CharacterAssistModule.lua
-- Responsibility: Talent Point Reminder & Learnable Class Training Spell advisor (backed by ForeverSuite_Data_Atlas).
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local ipairs = ipairs
local tostring = tostring

local CharacterAssistModule = {
    lastRemindedPoints = 0,
}
ns.Features.CharacterAssistModule = CharacterAssistModule

function CharacterAssistModule:CheckTalents(forceNotify)
    if ns.Api.ProfileStore:Get("qol", "talentReminder") == false then
        return nil
    end
    local pts = ns.Api.GameAdapters.GetUnspentTalentPoints()
    local lvl = ns.Api.GameAdapters.GetPlayerLevel()
    local info = ns.Domain.CharacterGuideModel.EvaluateTalentReminder(pts, lvl)
    if not info then
        self.lastRemindedPoints = 0
        return nil
    end
    if forceNotify or info.points ~= self.lastRemindedPoints then
        self.lastRemindedPoints = info.points
        ns.Api.SafeAPI.Print(info.message)
    end
    return info
end

function CharacterAssistModule:GetLearnableSpells()
    local cls = ns.Api.GameAdapters.GetPlayerClass()
    local lvl = ns.Api.GameAdapters.GetPlayerLevel()
    if not (cls and lvl) then
        return {}, "UNAVAILABLE"
    end
    local ok, st = ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_Atlas")
    if not ok then
        return {}, st
    end
    local pack = _G.ForeverSuiteData and _G.ForeverSuiteData.packs and _G.ForeverSuiteData.packs.training_spells
    if type(pack) ~= "table" or type(pack.entries) ~= "table" or pack._complete == false then
        return {}, "NO_PACK"
    end
    local candidateIDs = {}
    for _, sp in ipairs(pack.entries) do
        if sp.class == cls and type(sp.level) == "number" and sp.level <= lvl and type(sp.spellID) == "number" then
            candidateIDs[#candidateIDs + 1] = sp.spellID
        end
    end
    local known = ns.Api.GameAdapters.GetKnownSpellSet(candidateIDs)
    local learnable = ns.Domain.CharacterGuideModel.FindLearnableSpells(pack.entries, cls, lvl, known, 20)
    for _, item in ipairs(learnable) do
        item.name = ns.Api.GameAdapters.GetSpellName(item.spellID) or ("주문 #" .. tostring(item.spellID))
    end
    return learnable, "OK"
end

function CharacterAssistModule:PrintTrainableSummary()
    local list, status = self:GetLearnableSpells()
    if status ~= "OK" then
        ns.Api.SafeAPI.Print("스킬 습득 정보를 불러올 수 없습니다 (" .. tostring(status) .. ").")
        return
    end
    if #list == 0 then
        ns.Api.SafeAPI.Print("현재 레벨에서 새로 배울 수 있는 직업 스킬이 없습니다.")
        return
    end
    local preview = {}
    for i = 1, (#list > 5 and 5 or #list) do
        preview[#preview + 1] = list[i].name .. "(Lv." .. tostring(list[i].level) .. ")"
    end
    ns.Api.SafeAPI.Print("습득 가능 스킬 " .. tostring(#list) .. "개: " .. table.concat(preview, ", "))
end
