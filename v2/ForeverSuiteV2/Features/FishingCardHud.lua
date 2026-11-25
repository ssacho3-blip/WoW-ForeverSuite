-- Module: Features/FishingCardHud.lua
-- Responsibility: L1 context card auto-shown when a fishing pole is equipped, reading current-zone fish from ForeverSuite_Data (LoD).
-- Layer: Features (uses UI/Widgets + Api/GameAdapters; honest empty/unloaded/unknown-zone states).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs
local string_find = string.find

local FishingCardHud = {
    card = nil,
    titleLbl = nil,
    bodyLbl = nil,
    visible = false,
}
ns.Features.FishingCardHud = FishingCardHud

function FishingCardHud:Init()
    if self.card then
        return self.card
    end
    local card = W.Card(nil, 248, 66, "ForeverSuiteV2FishingCard", T.ELEVATION.L1_CARD)
    local title = W.Label(card, "낚시 대상어 가이드", "heading", T.TEXT.GOLD)
    title:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -8)

    local body = W.Label(card, "", "small", T.TEXT.PRIMARY)
    body:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)

    self.card = card
    self.titleLbl = title
    self.bodyLbl = body

    ns.UI.HudLayout:Register("fishingCard", card, {
        point = "BOTTOMRIGHT",
        relPoint = "BOTTOMRIGHT",
        x = -24,
        y = 180,
    }, "낚시 대상어 카드")

    card:Hide()
    return card
end

function FishingCardHud:Refresh()
    self:Init()
    local enabled = ns.Api.ProfileStore:Get("profession", "showFishingCard")
    if enabled == false or not ns.Api.GameAdapters.IsFishingPoleEquipped() then
        self.visible = false
        self.card:Hide()
        return false
    end

    local loaded = ns.Api.SafeAPI.LoadDataPack()
    local pack = _G.ForeverSuiteData and _G.ForeverSuiteData.packs and _G.ForeverSuiteData.packs.fishing
    local zone = ns.Api.GameAdapters.GetPlayerZoneText()
    self.titleLbl:SetText("낚시 가이드" .. (zone ~= "" and (" · " .. zone) or ""))

    if (not loaded) or type(pack) ~= "table" then
        self.bodyLbl:SetText("도감 데이터팩 미로드")
        self.visible = true
        self.card:Show()
        return true
    end

    if zone == "" then
        self.bodyLbl:SetText("현재 지역 집계 없음")
        self.visible = true
        self.card:Show()
        return true
    end

    local matches = {}
    for _, e in ipairs(pack.entries or {}) do
        if type(e.zone) == "string" and string_find(e.zone, zone, 1, true) then
            matches[#matches + 1] = tostring(e.title) .. " (숙련 " .. tostring(e.minSkill or "?") .. ")"
            if #matches >= 2 then break end
        end
    end

    if #matches > 0 then
        self.bodyLbl:SetText(table.concat(matches, " / "))
    else
        self.bodyLbl:SetText("현재 지역 등록 대상어 없음")
    end
    self.visible = true
    self.card:Show()
    return true
end
