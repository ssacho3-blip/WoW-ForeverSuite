-- Module: Features/FishingCardHud.lua
-- Responsibility: F2 Enhanced L1 Fishing Helper Card — skill tracker, lure countdown/reminder, zone fish list,
--                 and safe OOC double-right-click cast toggle (delegated to Secure/FishingCastButton).
-- Layer: Features (uses UI/Widgets + Api/GameAdapters + Secure/FishingCastButton).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs
local string_find = string.find
local string_format = string.format
local math_floor = math.floor

local FishingCardHud = {
    card = nil,
    titleLbl = nil,
    metaLbl = nil,
    bodyLbl = nil,
    ticker = nil,
    visible = false,
}
ns.Features.FishingCardHud = FishingCardHud

local function StopTicker()
    if FishingCardHud.ticker then
        ns.Api.GameAdapters.CancelTicker(FishingCardHud.ticker)
        FishingCardHud.ticker = nil
    end
end

function FishingCardHud:Init()
    if self.card then
        return self.card
    end
    local card = W.HudGlass(nil, 268, 86, "ForeverSuiteV2FishingCard", T.ELEVATION.L1_CARD, {
        bg = { 0.048, 0.043, 0.052, 0.72 },
        border = T.BORDER.GOLD_SOFT,
        accentBar = true,
    })
    local title = W.Label(card, "낚시 대상어 가이드", "heading", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false, outline = "OUTLINE" })
    title:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -8)
    title:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -8)

    local meta = W.Label(card, "", "small", T.SEMANTIC.INFO, { justifyH = "LEFT", wordWrap = false })
    meta:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    meta:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -26)

    local body = W.Label(card, "", "small", T.TEXT.PRIMARY, { justifyH = "LEFT", wordWrap = true })
    body:SetPoint("TOPLEFT", meta, "BOTTOMLEFT", 0, -4)
    body:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -10, 6)

    self.card = card
    self.titleLbl = title
    self.metaLbl = meta
    self.bodyLbl = body

    ns.UI.HudLayout:Register("fishingCard", card, {
        point = "BOTTOMLEFT",
        relPoint = "BOTTOMLEFT",
        x = 24,
        y = 356,
    }, "낚시 대상어 카드")

    card:Hide()
    return card
end

function FishingCardHud:Refresh()
    self:Init()
    if ns.UI.HudLayout and ns.UI.HudLayout:IsUnlocked() then
        return false
    end
    local enabled = ns.Api.ProfileStore:Get("profession", "showFishingCard")
    local poleEquipped = ns.Api.GameAdapters.IsFishingPoleEquipped()
    local doubleCast = ns.Api.ProfileStore:Get("profession", "fishingDoubleClick") == true
    if ns.Secure and ns.Secure.FishingCastButton then
        if poleEquipped and doubleCast and not ns.Api.SafeAPI.InCombat() then
            ns.Secure.FishingCastButton:SetActive(true)
        else
            ns.Secure.FishingCastButton:SetActive(false)
        end
    end

    if enabled == false or not poleEquipped then
        StopTicker()
        self.visible = false
        self.card:Hide()
        return false
    end

    local loaded = ns.Api.SafeAPI.LoadDataPack()
    local pack = _G.ForeverSuiteData and _G.ForeverSuiteData.packs and _G.ForeverSuiteData.packs.fishing
    local zone = ns.Api.GameAdapters.GetPlayerZoneText()
    local fStat = ns.Api.GameAdapters.GetFishingStatusSafe()
    local skillTxt = (fStat and fStat.skill) and ("숙련 " .. tostring(fStat.skill) .. "/" .. tostring(fStat.maxSkill or 300)) or "숙련 —"
    local lureTxt
    if fStat and fStat.hasLure and fStat.lureSec > 0 then
        local m = math_floor(fStat.lureSec / 60)
        local s = fStat.lureSec - m * 60
        lureTxt = string_format("미끼 %02d:%02d", m, s)
        self.metaLbl:SetTextColor(T.SEMANTIC.SUCCESS[1], T.SEMANTIC.SUCCESS[2], T.SEMANTIC.SUCCESS[3], 1)
    else
        lureTxt = "⚠ 미끼 없음"
        self.metaLbl:SetTextColor(T.SEMANTIC.WARN[1], T.SEMANTIC.WARN[2], T.SEMANTIC.WARN[3], 1)
    end
    self.titleLbl:SetText("낚시 가이드" .. (zone ~= "" and (" · " .. zone) or ""))
    self.metaLbl:SetText(skillTxt .. "  |  " .. lureTxt .. (doubleCast and "  |  우클릭 낚시 ON" or ""))

    if (not loaded) or type(pack) ~= "table" then
        self.bodyLbl:SetText("도감 데이터팩 미로드")
    elseif zone == "" then
        self.bodyLbl:SetText("현재 지역 집계 없음")
    else
        local matches = {}
        for _, e in ipairs(pack.entries or {}) do
            if type(e.zone) == "string" and string_find(e.zone, zone, 1, true) then
                matches[#matches + 1] = tostring(e.title) .. " (숙련 " .. tostring(e.minSkill or "?") .. ")"
                if #matches >= 3 then break end
            end
        end
        if #matches > 0 then
            self.bodyLbl:SetText(table.concat(matches, " / "))
        else
            self.bodyLbl:SetText("현재 지역 등록 대상어 없음")
        end
    end
    self.visible = true
    self.card:Show()
    if not self.ticker then
        self.ticker = ns.Api.GameAdapters.StartTicker(1.0, function()
            FishingCardHud:Refresh()
        end)
    end
    return true
end
