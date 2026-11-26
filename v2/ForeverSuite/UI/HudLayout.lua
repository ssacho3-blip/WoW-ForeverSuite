-- Module: UI/HudLayout.lua
-- Responsibility: Unified L0/L1 HUD anchor registry, /fs move drag-overlay unlock, 4px grid snap & drag persistence.
-- Layer: UI
local _, ns = ...
ns.UI = ns.UI or {}

local T = ns.UI.Tokens
local pairs = pairs
local math_floor = math.floor

local GRID_STEP = 4

local HudLayout = {
    unlocked = false,
    registry = {},
    controlBar = nil,
}
ns.UI.HudLayout = HudLayout

local function Snap(v)
    return math_floor(((v or 0) / GRID_STEP) + 0.5) * GRID_STEP
end

local function EnsureControlBar()
    if HudLayout.controlBar then
        return HudLayout.controlBar
    end
    local W = ns.UI.Widgets
    local bar = W.Card(_G.UIParent, 464, 42, "ForeverSuiteV3HudEditBar", T.ELEVATION.L3_OVERLAY)
    bar:SetPoint("TOP", _G.UIParent, "TOP", 0, -24)
    W.SetBorderColor(bar, T.BORDER.GOLD)

    local lbl = W.Label(bar, "✦ HUD 배치 편집 모드 · 드래그하여 4px 그리드 정렬", "small", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    lbl:SetPoint("LEFT", bar, "LEFT", 12, 0)

    local doneBtn = W.Button(bar, "✓ 저장 및 잠금", 104, 24, function()
        HudLayout:SetUnlocked(false)
        ns.Api.SafeAPI.Print("HUD 위치를 저장하고 잠갔습니다.")
    end, true)
    doneBtn:SetPoint("RIGHT", bar, "RIGHT", -8, 0)

    local resetBtn = W.Button(bar, "기본 초기화", 84, 24, function()
        HudLayout:ResetAll()
        ns.Api.SafeAPI.Print("모든 HUD 위치를 기본 그리드로 초기화했습니다.")
    end)
    resetBtn:SetPoint("RIGHT", doneBtn, "LEFT", -6, 0)

    bar._label = lbl
    bar._doneBtn = doneBtn
    bar._resetBtn = resetBtn
    bar:Hide()
    HudLayout.controlBar = bar
    return bar
end

local function EnsureDragOverlay(rec)
    if rec.overlay then
        return rec.overlay
    end
    local ov = CreateFrame("Frame", nil, rec.frame)
    ov:SetAllPoints(rec.frame)
    ov:SetFrameStrata("HIGH")
    local bg = ov:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(ov)
    bg:SetColorTexture(T.SURFACE.GOLD_TINT[1], T.SURFACE.GOLD_TINT[2], T.SURFACE.GOLD_TINT[3], 0.55)
    local lbl = ov:CreateFontString(nil, "OVERLAY", T.GetFont("small"))
    lbl:SetPoint("CENTER", ov, "CENTER", 0, 0)
    lbl:SetText("이동: " .. rec.label)
    lbl:SetTextColor(T.TEXT.GOLD[1], T.TEXT.GOLD[2], T.TEXT.GOLD[3], 1)

    ov:EnableMouse(true)
    ov:RegisterForDrag("LeftButton")
    ov:SetScript("OnDragStart", function()
        rec.frame:StartMoving()
    end)
    ov:SetScript("OnDragStop", function()
        rec.frame:StopMovingOrSizing()
        HudLayout:SaveCurrentPosition(rec.id)
    end)
    ov:Hide()
    rec.overlay = ov
    return ov
end

function HudLayout:Register(id, frame, defaultAnchor, label, onMoved)
    if not (id and frame and defaultAnchor) then
        return false
    end
    self.registry[id] = {
        id = id,
        frame = frame,
        defaultAnchor = defaultAnchor,
        label = label or id,
        onMoved = onMoved,
        overlay = nil,
    }
    self:ApplySavedAnchor(id)
    return true
end

function HudLayout:ApplySavedAnchor(id)
    local rec = self.registry[id]
    if not rec then
        return false
    end
    local saved = ns.Api and ns.Api.ProfileStore and ns.Api.ProfileStore:GetLayout(id)
    local a = (type(saved) == "table") and saved or rec.defaultAnchor
    local snapped = {
        point = a.point or "CENTER",
        relPoint = a.relPoint or a.point or "CENTER",
        x = Snap(a.x),
        y = Snap(a.y),
    }
    rec.frame:ClearAllPoints()
    rec.frame:SetPoint(snapped.point, _G.UIParent, snapped.relPoint, snapped.x, snapped.y)
    if type(rec.onMoved) == "function" then
        rec.onMoved(snapped)
    end
    return true
end

function HudLayout:SaveCurrentPosition(id)
    local rec = self.registry[id]
    if not (rec and type(rec.frame.GetPoint) == "function") then
        return false
    end
    local point, _, relPoint, x, y = rec.frame:GetPoint(1)
    local anchor = {
        point = point or rec.defaultAnchor.point,
        relPoint = relPoint or rec.defaultAnchor.relPoint,
        x = Snap(x),
        y = Snap(y),
    }
    if ns.Api.ProfileStore then
        ns.Api.ProfileStore:SetLayout(id, anchor)
    end
    self:ApplySavedAnchor(id)
    return true
end

function HudLayout:Nudge(id, dx, dy)
    local rec = self.registry[id]
    if not rec then
        return false
    end
    local saved = (ns.Api.ProfileStore and ns.Api.ProfileStore:GetLayout(id)) or rec.defaultAnchor
    local nextAnchor = {
        point = saved.point or rec.defaultAnchor.point,
        relPoint = saved.relPoint or rec.defaultAnchor.relPoint,
        x = Snap((saved.x or 0) + (dx or 0)),
        y = Snap((saved.y or 0) + (dy or 0)),
    }
    if ns.Api.ProfileStore then
        ns.Api.ProfileStore:SetLayout(id, nextAnchor)
    end
    self:ApplySavedAnchor(id)
    return true
end

function HudLayout:IsUnlocked()
    return self.unlocked == true
end

function HudLayout:SetUnlocked(flag)
    local nextState = flag and true or false
    if nextState and ns.Api and ns.Api.SafeAPI and ns.Api.SafeAPI.InCombat() then
        return false, "IN_COMBAT"
    end
    local wasUnlocked = self.unlocked
    self.unlocked = nextState
    local bar = EnsureControlBar()
    if self.unlocked then
        bar:Show()
    else
        bar:Hide()
    end
    for _, rec in pairs(self.registry) do
        local f = rec.frame
        if f.SetMovable then f:SetMovable(self.unlocked) end
        local ov = EnsureDragOverlay(rec)
        if self.unlocked then
            if not wasUnlocked then
                rec._wasShownBeforeUnlock = (type(f.IsShown) == "function" and f:IsShown()) and true or false
            end
            -- Preview-show inactive/hidden HUDs so users can position every HUD cleanly
            if type(f.IsShown) == "function" and not f:IsShown() then
                f:Show()
            end
            ov:Show()
        else
            if type(f.StopMovingOrSizing) == "function" then f:StopMovingOrSizing() end
            ov:Hide()
            if wasUnlocked and rec._wasShownBeforeUnlock == false then
                f:Hide()
            end
            rec._wasShownBeforeUnlock = nil
        end
    end
    if wasUnlocked and (not self.unlocked) and ns.Api and ns.Api.EventBus then
        ns.Api.EventBus:Publish("hud:layout_locked")
    end
    return self.unlocked
end

function HudLayout:ToggleUnlock()
    return self:SetUnlocked(not self.unlocked)
end

function HudLayout:ResetAll()
    for id, rec in pairs(self.registry) do
        if ns.Api.ProfileStore then
            ns.Api.ProfileStore:SetLayout(id, {
                point = rec.defaultAnchor.point,
                relPoint = rec.defaultAnchor.relPoint,
                x = rec.defaultAnchor.x,
                y = rec.defaultAnchor.y,
            })
        end
        self:ApplySavedAnchor(id)
    end
    self:SetUnlocked(false)
    return true
end
