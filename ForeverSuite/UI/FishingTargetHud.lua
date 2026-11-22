-- Module: UI/FishingTargetHud.lua
-- Responsibility: Non-secure dark-slate & gold HUD View showing current-zone fishing target species, recommended skill, quest targets, and tooltips.
-- Dependencies: Core/Init.lua, Core/ProfileManager.lua, UI/Framework.lua, UI/FishingTargetModel.lua.
-- Public API: ns.FishingTargetHud (EnsureFrame, ApplyAnchor, SyncLockState, ShouldShow, Refresh, TogglePin, SetAutoMode, ResetLayout, Hide).
-- Combat/Secret Safety: Uses only non-secure Frame/Button widgets; zero protected frame mutations; safe GameTooltip ownership cleanup.
local _, ns = ...

local type = type
local tonumber = tonumber
local tostring = tostring
local math_floor = math.floor
local string_format = string.format

local HUD_WIDTH = 256
local HEADER_HEIGHT = 40
local ROW_HEIGHT = 20
local FOOTER_HEIGHT = 18
local PADDING_X = 10
local PADDING_BOTTOM = 8
local MAX_ROWS = 8

local FishingTargetHud = {
    frame = nil,
    titleLabel = nil,
    skillLabel = nil,
    modeLabel = nil,
    emptyLabel = nil,
    footerLabel = nil,
    rowButtons = {},
    pinned = false,
    lastViewModel = nil,
}
ns.FishingTargetHud = FishingTargetHud

local function ShowFishRowTooltip(rowBtn)
    local gt = _G.GameTooltip
    local data = rowBtn and rowBtn._fsFishData or nil
    if not (gt and gt.SetOwner and data) then
        return
    end
    if gt.ClearLines then
        gt:ClearLines()
    end
    gt:SetOwner(rowBtn, "ANCHOR_LEFT")
    gt:AddLine(tostring(data.name or "알 수 없는 어종"), 1.0, 0.85, 0.35)
    if data.isQuestTarget then
        gt:AddLine("★ 진행 중 퀘스트 대상어: " .. tostring(data.questReason or "현재 퀘스트 목표"), 0.30, 0.92, 0.55)
    end
    if data.waterNote and data.waterNote ~= "" then
        gt:AddLine("수역/참고: " .. data.waterNote, 0.85, 0.90, 0.96)
    end
    if data.use and data.use ~= "" and data.use ~= data.waterNote then
        gt:AddLine("활용: " .. data.use, 0.78, 0.84, 0.90)
    end
    if data.levelNote and data.levelNote ~= "" then
        gt:AddLine("단계: " .. data.levelNote, 0.70, 0.76, 0.84)
    end
    if data.hasSchool then
        gt:AddLine(string_format("기록된 물고기 떼(어군): %d곳", data.schoolPointCount or 0), 0.45, 0.82, 1.0)
    end
    if (data.caughtCount or 0) > 0 then
        gt:AddLine(string_format("이번 세션 획득: %d마리", data.caughtCount), 0.35, 0.90, 0.52)
    end
    gt:AddLine("명령어: /fs fish (고정/자동) · /fs move (위치 이동)", 0.58, 0.64, 0.72)
    gt:Show()
end

local function HideFishRowTooltip()
    if _G.GameTooltip and _G.GameTooltip.Hide then
        _G.GameTooltip:Hide()
    end
end

local function FiniteNumber(val, fallback)
    if ns.IsSecret(val) then
        return fallback
    end
    local n = tonumber(val)
    if type(n) ~= "number" or n ~= n or n < -10000 or n > 10000 then
        return fallback
    end
    return n
end

function FishingTargetHud:ApplyAnchor()
    if not self.frame or not self.frame.SetPoint then
        return
    end
    local pt = ns.ProfileManager:Get("ui", "fishHudPoint")
    if type(pt) ~= "string" or pt == "" then
        pt = "BOTTOMRIGHT"
    end
    local relPt = ns.ProfileManager:Get("ui", "fishHudRelPoint")
    if type(relPt) ~= "string" or relPt == "" then
        relPt = "BOTTOMRIGHT"
    end
    local x = FiniteNumber(ns.ProfileManager:Get("ui", "fishHudX"), -16)
    local y = FiniteNumber(ns.ProfileManager:Get("ui", "fishHudY"), 86)
    if self.frame.ClearAllPoints then
        self.frame:ClearAllPoints()
    end
    self.frame:SetPoint(pt, _G.UIParent, relPt, x, y)
end

function FishingTargetHud:HasTrackedItem(itemID)
    if type(itemID) ~= "number" or not self.lastViewModel or type(self.lastViewModel.allRows) ~= "table" then
        return false
    end
    local all = self.lastViewModel.allRows
    for i = 1, #all do
        if all[i] and all[i].itemID == itemID then
            return true
        end
    end
    return false
end

function FishingTargetHud:EnsureFrame()
    if self.frame then
        return self.frame
    end
    if not (_G.CreateFrame and ns.UI and ns.UI.CreatePanel) then
        return nil
    end

    local f = ns.UI.CreatePanel("ForeverSuiteFishingTargetHUD", _G.UIParent, HUD_WIDTH, 110, false)
    if not f then
        return nil
    end
    if f.SetClampedToScreen then
        f:SetClampedToScreen(true)
    end
    if f.SetMovable then
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", function(sf)
            if ns.ProfileManager:Get("ui", "hudUnlocked") and not ns.InCombat() and sf.StartMoving then
                sf:StartMoving()
            end
        end)
        f:SetScript("OnDragStop", function(sf)
            if sf.StopMovingOrSizing then
                sf:StopMovingOrSizing()
            end
            if ns.ProfileManager:CanWrite() and sf.GetPoint then
                local pt, _, relPt, x, y = sf:GetPoint()
                if type(pt) == "string" and type(x) == "number" and type(y) == "number" then
                    ns.ProfileManager:Set("ui", "fishHudPoint", pt, "account")
                    ns.ProfileManager:Set("ui", "fishHudRelPoint", relPt or pt, "account")
                    ns.ProfileManager:Set("ui", "fishHudX", math_floor(x + 0.5), "account")
                    ns.ProfileManager:Set("ui", "fishHudY", math_floor(y + 0.5), "account")
                end
            end
        end)
    end

    local title = ns.UI.CreateLabel(f, "낚시 대상어", "GameFontNormalSmall", ns.UI.COLORS.ACCENT)
    if title then
        title:SetPoint("TOPLEFT", f, "TOPLEFT", PADDING_X, -7)
        if title.SetJustifyH then
            title:SetJustifyH("LEFT")
        end
        self.titleLabel = title
    end

    local modeLbl = ns.UI.CreateLabel(f, "", "GameFontHighlightSmall", ns.UI.COLORS.MUTED)
    if modeLbl then
        modeLbl:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PADDING_X, -7)
        self.modeLabel = modeLbl
    end

    local skillLbl = ns.UI.CreateLabel(f, "", "GameFontHighlightSmall", ns.UI.COLORS.MUTED)
    if skillLbl then
        skillLbl:SetPoint("TOPLEFT", f, "TOPLEFT", PADDING_X, -23)
        if skillLbl.SetJustifyH then
            skillLbl:SetJustifyH("LEFT")
        end
        self.skillLabel = skillLbl
    end

    local emptyLbl = ns.UI.CreateLabel(f, "이 지역의 대상어 기록이 없습니다.", "GameFontHighlightSmall", ns.UI.COLORS.MUTED)
    if emptyLbl then
        emptyLbl:SetPoint("TOPLEFT", f, "TOPLEFT", PADDING_X, -(HEADER_HEIGHT + 4))
        emptyLbl:Hide()
        self.emptyLabel = emptyLbl
    end

    for i = 1, MAX_ROWS do
        local row = _G.CreateFrame("Button", nil, f)
        row:SetSize(HUD_WIDTH - (PADDING_X * 2), ROW_HEIGHT)
        row:SetPoint("TOPLEFT", f, "TOPLEFT", PADDING_X, -(HEADER_HEIGHT + (i - 1) * ROW_HEIGHT))
        local nameLbl = ns.UI.CreateLabel(row, "", "GameFontHighlightSmall", ns.UI.COLORS.TEXT)
        if nameLbl then
            nameLbl:SetPoint("LEFT", row, "LEFT", 2, 0)
            if nameLbl.SetJustifyH then
                nameLbl:SetJustifyH("LEFT")
            end
            row._fsName = nameLbl
        end
        local badgeLbl = ns.UI.CreateLabel(row, "", "GameFontHighlightSmall", ns.UI.COLORS.MUTED)
        if badgeLbl then
            badgeLbl:SetPoint("RIGHT", row, "RIGHT", -2, 0)
            if badgeLbl.SetJustifyH then
                badgeLbl:SetJustifyH("RIGHT")
            end
            row._fsBadge = badgeLbl
        end
        row:SetScript("OnEnter", ShowFishRowTooltip)
        row:SetScript("OnLeave", HideFishRowTooltip)
        row:Hide()
        self.rowButtons[i] = row
    end

    local footerLbl = ns.UI.CreateLabel(f, "", "GameFontHighlightSmall", ns.UI.COLORS.MUTED)
    if footerLbl then
        footerLbl:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PADDING_X, PADDING_BOTTOM)
        footerLbl:Hide()
        self.footerLabel = footerLbl
    end

    f:Hide()
    self.frame = f
    self:ApplyAnchor()
    return f
end

function FishingTargetHud:ShouldShow(poleEquipped)
    if not ns.ProfileManager:Get("profession", "showFishingTargetHUD") then
        return false
    end
    local profRec = ns.ModuleManager and ns.ModuleManager:GetModule("Profession") or nil
    if profRec and profRec.state ~= "ENABLED" then
        return false
    end
    if self.pinned then
        return true
    end
    if ns.ProfileManager:Get("ui", "hudUnlocked") then
        return true
    end
    return poleEquipped and true or false
end

function FishingTargetHud:Hide()
    if self.frame and self.frame.Hide then
        self.frame:Hide()
    end
end

local function FormatRowBadge(r)
    local parts = {}
    if r.isQuestTarget then
        parts[#parts + 1] = "|cffffd23f[퀘스트]|r"
    end
    if r.hasSchool then
        parts[#parts + 1] = "|cff60a5fa어군|r"
    end
    if (r.caughtCount or 0) > 0 then
        parts[#parts + 1] = "|cff4ade80x" .. tostring(r.caughtCount) .. "|r"
    end
    return table.concat(parts, " ")
end

function FishingTargetHud:Refresh(opts)
    opts = type(opts) == "table" and opts or {}
    local poleEquipped = opts.poleEquipped
    if poleEquipped == nil then
        local profRec = ns.ModuleManager and ns.ModuleManager:GetModule("Profession") or nil
        if profRec and profRec.definition and profRec.definition.IsFishingPoleEquipped then
            poleEquipped = profRec.definition:IsFishingPoleEquipped()
        else
            poleEquipped = false
        end
    end

    if not self:ShouldShow(poleEquipped) then
        self:Hide()
        return nil
    end

    local f = self:EnsureFrame()
    if not f then
        return nil
    end

    local vm = opts.viewModel
    if not vm and ns.FishingTargetModel then
        local profRec = ns.ModuleManager and ns.ModuleManager:GetModule("Profession") or nil
        local sessionItems = (profRec and profRec.definition and profRec.definition.sessionByItemID) or {}
        vm = ns.FishingTargetModel:BuildViewModel({
            sessionByItemID = sessionItems,
            maxVisible = MAX_ROWS,
        })
    end
    self.lastViewModel = vm
    if not vm then
        self:Hide()
        return nil
    end

    local movePrefix = ns.ProfileManager:Get("ui", "hudUnlocked") and "|cffffd23f✥ |r" or ""
    if self.titleLabel then
        self.titleLabel:SetText(movePrefix .. "낚시 대상어 · " .. tostring(vm.zoneName))
    end
    if self.modeLabel then
        self.modeLabel:SetText(self.pinned and "|cffffd23f[고정]|r" or "|cff94a3b8[자동]|r")
    end
    if self.skillLabel and ns.FishingTargetModel then
        self.skillLabel:SetText(ns.FishingTargetModel:FormatSkillBadge(vm))
    end

    local shownRows = #vm.rows
    for i = 1, MAX_ROWS do
        local row = self.rowButtons[i]
        local data = vm.rows[i]
        if row then
            if data then
                row._fsFishData = data
                if row._fsName then
                    local prefix = data.isQuestTarget and "|cffffd23f★ |r" or "• "
                    row._fsName:SetText(prefix .. tostring(data.name))
                end
                if row._fsBadge then
                    row._fsBadge:SetText(FormatRowBadge(data))
                end
                row:Show()
            else
                row._fsFishData = nil
                row:Hide()
            end
        end
    end

    if self.emptyLabel then
        if shownRows == 0 then
            self.emptyLabel:Show()
        else
            self.emptyLabel:Hide()
        end
    end

    local hasFooter = (vm.hiddenCount or 0) > 0
    if self.footerLabel then
        if hasFooter then
            self.footerLabel:SetText(string_format("|cff94a3b8+%d종 더 있음 (/fs fish list)|r", vm.hiddenCount))
            self.footerLabel:Show()
        else
            self.footerLabel:Hide()
        end
    end

    local bodyRows = shownRows > 0 and shownRows or 1
    local totalHeight = HEADER_HEIGHT + (bodyRows * ROW_HEIGHT) + (hasFooter and FOOTER_HEIGHT or 0) + PADDING_BOTTOM
    if f.SetSize then
        f:SetSize(HUD_WIDTH, totalHeight)
    end
    if f.Show then
        f:Show()
    end
    return vm
end

function FishingTargetHud:SyncLockState()
    if self.frame then
        self:ApplyAnchor()
    end
    self:Refresh()
end

function FishingTargetHud:TogglePin()
    self.pinned = not self.pinned
    self:Refresh()
    return self.pinned
end

function FishingTargetHud:SetAutoMode()
    self.pinned = false
    self:Refresh()
end

function FishingTargetHud:ResetLayout()
    if not ns.ProfileManager:CanWrite() then
        return false, "READ_ONLY"
    end
    ns.ProfileManager:Set("ui", "fishHudPoint", "BOTTOMRIGHT", "account")
    ns.ProfileManager:Set("ui", "fishHudRelPoint", "BOTTOMRIGHT", "account")
    ns.ProfileManager:Set("ui", "fishHudX", -16, "account")
    ns.ProfileManager:Set("ui", "fishHudY", 86, "account")
    self:ApplyAnchor()
    self:Refresh()
    return true
end
