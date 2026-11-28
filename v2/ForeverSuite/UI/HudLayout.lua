-- Module: UI/HudLayout.lua
-- Responsibility: Unified L0/L1 HUD anchor registry, /fs move drag-overlay unlock, 4px grid snap,
--                 per-HUD selection, 4-way nudge, per-HUD scale (70%-150%), live overlap detection,
--                 and 1-click Auto-Separate Overlaps.
-- Layer: UI
local _, ns = ...
ns.UI = ns.UI or {}

local T = ns.UI.Tokens
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local math_floor = math.floor
local math_max = math.max
local math_min = math.min

local GRID_STEP = 4
local SCALE_MIN = 0.70
local SCALE_MAX = 1.50

local HudLayout = {
    unlocked = false,
    registry = {},
    selectedId = nil,
    overlapMap = {},
    controlBar = nil,
}
ns.UI.HudLayout = HudLayout

local function Snap(v)
    return math_floor(((v or 0) / GRID_STEP) + 0.5) * GRID_STEP
end

local function ClampScale(s)
    local n = tonumber(s) or 1.0
    if n < SCALE_MIN then n = SCALE_MIN end
    if n > SCALE_MAX then n = SCALE_MAX end
    return math_floor(n * 100 + 0.5) / 100
end

local function GetViewportSize()
    local w = (_G.UIParent and type(_G.UIParent.GetWidth) == "function") and _G.UIParent:GetWidth() or 1366
    local h = (_G.UIParent and type(_G.UIParent.GetHeight) == "function") and _G.UIParent:GetHeight() or 768
    if type(w) ~= "number" or w <= 0 then w = 1366 end
    if type(h) ~= "number" or h <= 0 then h = 768 end
    return w, h
end

local function GetScaleRatioToUIParent(frame)
    local uiScale = (_G.UIParent and type(_G.UIParent.GetEffectiveScale) == "function") and _G.UIParent:GetEffectiveScale() or 1.0
    local fScale = (frame and type(frame.GetEffectiveScale) == "function") and frame:GetEffectiveScale() or nil
    if type(uiScale) == "number" and uiScale > 0 and type(fScale) == "number" and fScale > 0 then
        local ratio = fScale / uiScale
        -- In headless mock where GetEffectiveScale always returns 1.0, respect applied _fsHudScale
        if ratio == 1.0 and type(frame._fsHudScale) == "number" and frame._fsHudScale > 0 then
            return frame._fsHudScale
        end
        return ratio
    end
    return (frame and type(frame._fsHudScale) == "number" and frame._fsHudScale > 0) and frame._fsHudScale or 1.0
end

local function ResolveAnchorRect(frame, anchor, useFallbackOnly)
    local liveScale = GetScaleRatioToUIParent(frame)
    if (not useFallbackOnly) and type(frame.GetLeft) == "function" and type(frame.GetRight) == "function"
        and type(frame.GetBottom) == "function" and type(frame.GetTop) == "function"
    then
        local l, r, b, t = frame:GetLeft(), frame:GetRight(), frame:GetBottom(), frame:GetTop()
        if type(l) == "number" and type(r) == "number" and type(b) == "number" and type(t) == "number" and r > l and t > b then
            return { left = l * liveScale, right = r * liveScale, bottom = b * liveScale, top = t * liveScale }
        end
    end
    local scale = (type(anchor) == "table" and tonumber(anchor.scale)) or liveScale
    local sw, sh = GetViewportSize()
    local w = ((type(frame.GetWidth) == "function" and frame:GetWidth()) or 120) * scale
    local h = ((type(frame.GetHeight) == "function" and frame:GetHeight()) or 26) * scale
    local pt = (type(anchor) == "table" and anchor.point) or "CENTER"
    local rp = (type(anchor) == "table" and anchor.relPoint) or pt
    local ox = ((type(anchor) == "table" and tonumber(anchor.x)) or 0) * scale
    local oy = ((type(anchor) == "table" and tonumber(anchor.y)) or 0) * scale
    local ax, ay = sw * 0.5, sh * 0.5
    if rp == "TOPLEFT" then ax, ay = 0, sh
    elseif rp == "TOP" then ax, ay = sw * 0.5, sh
    elseif rp == "TOPRIGHT" then ax, ay = sw, sh
    elseif rp == "LEFT" then ax, ay = 0, sh * 0.5
    elseif rp == "RIGHT" then ax, ay = sw, sh * 0.5
    elseif rp == "BOTTOMLEFT" then ax, ay = 0, 0
    elseif rp == "BOTTOM" then ax, ay = sw * 0.5, 0
    elseif rp == "BOTTOMRIGHT" then ax, ay = sw, 0
    end
    local tx, ty = ax + ox, ay + oy
    local left, right, bottom, top
    if pt == "TOPLEFT" then left, top = tx, ty; right, bottom = tx + w, ty - h
    elseif pt == "TOP" then left, right, top, bottom = tx - w * 0.5, tx + w * 0.5, ty, ty - h
    elseif pt == "TOPRIGHT" then right, top = tx, ty; left, bottom = tx - w, ty - h
    elseif pt == "LEFT" then left, right, bottom, top = tx, tx + w, ty - h * 0.5, ty + h * 0.5
    elseif pt == "RIGHT" then left, right, bottom, top = tx - w, tx, ty - h * 0.5, ty + h * 0.5
    elseif pt == "BOTTOMLEFT" then left, bottom = tx, ty; right, top = tx + w, ty + h
    elseif pt == "BOTTOM" then left, right, bottom, top = tx - w * 0.5, tx + w * 0.5, ty, ty + h
    elseif pt == "BOTTOMRIGHT" then right, bottom = tx, ty; left, top = tx - w, ty + h
    else left, right, bottom, top = tx - w * 0.5, tx + w * 0.5, ty - h * 0.5, ty + h * 0.5
    end
    -- Clamp simulated rect to viewport bounds matching SetClampedToScreen(true)
    if left < 0 then right = right - left; left = 0 end
    if right > sw then left = left - (right - sw); right = sw end
    if bottom < 0 then top = top - bottom; bottom = 0 end
    if top > sh then bottom = bottom - (top - sh); top = sh end
    return { left = left, right = right, bottom = bottom, top = top }
end

function HudLayout:GetEffectiveAnchor(id)
    local rec = self.registry[id]
    if not rec then return nil end
    local saved = ns.Api and ns.Api.ProfileStore and ns.Api.ProfileStore:GetLayout(id)
    local src = (type(saved) == "table" and type(saved.point) == "string") and saved or rec.defaultAnchor
    return {
        point = src.point or "CENTER",
        relPoint = src.relPoint or src.point or "CENTER",
        x = Snap(src.x),
        y = Snap(src.y),
        scale = ClampScale(src.scale or 1.0),
    }
end

local function GetBlizzardProtectedRects()
    local sw, sh = GetViewportSize()
    local mm = _G.MinimapCluster or _G.Minimap
    if type(mm) == "table" and type(mm.GetLeft) == "function" and type(mm.GetRight) == "function"
        and type(mm.GetBottom) == "function" and type(mm.GetTop) == "function"
    then
        local okL, l = pcall(mm.GetLeft, mm)
        local okR, r = pcall(mm.GetRight, mm)
        local okB, b = pcall(mm.GetBottom, mm)
        local okT, t = pcall(mm.GetTop, mm)
        local isSec = ns.Api and ns.Api.SafeAPI and ns.Api.SafeAPI.IsSecret
        local valid = okL and okR and okB and okT
            and type(l) == "number" and type(r) == "number" and type(b) == "number" and type(t) == "number"
            and (not (isSec and (isSec(l) or isSec(r) or isSec(b) or isSec(t))))
            and r > l and t > b
        if valid then
            local scale = GetScaleRatioToUIParent(mm)
            return {
                { id = "BlizzMinimap", rect = { left = l * scale, right = r * scale, bottom = b * scale, top = t * scale } },
            }
        end
    end
    return {
        { id = "BlizzMinimap", rect = { left = sw - 196, right = sw, bottom = sh - 204, top = sh } },
    }
end

function HudLayout:FindOverlaps()
    local items = {}
    for id, rec in pairs(self.registry) do
        local a = self:GetEffectiveAnchor(id)
        local r = ResolveAnchorRect(rec.frame, a)
        items[#items + 1] = { id = id, rect = r }
    end
    table.sort(items, function(a, b) return a.id < b.id end)
    local blizzProtected = GetBlizzardProtectedRects()
    local pairsOut = {}
    local map = {}
    for i = 1, #items do
        local a = items[i]
        for k = 1, #blizzProtected do
            local bz = blizzProtected[k]
            local ox = math_min(a.rect.right, bz.rect.right) - math_max(a.rect.left, bz.rect.left)
            local oy = math_min(a.rect.top, bz.rect.top) - math_max(a.rect.bottom, bz.rect.bottom)
            if ox > 1.5 and oy > 1.5 then
                pairsOut[#pairsOut + 1] = { a = a.id, b = bz.id, ox = ox, oy = oy }
                map[a.id] = true
            end
        end
        for j = i + 1, #items do
            local b = items[j]
            local ox = math_min(a.rect.right, b.rect.right) - math_max(a.rect.left, b.rect.left)
            local oy = math_min(a.rect.top, b.rect.top) - math_max(a.rect.bottom, b.rect.bottom)
            if ox > 1.5 and oy > 1.5 then
                pairsOut[#pairsOut + 1] = { a = a.id, b = b.id, ox = ox, oy = oy }
                map[a.id] = true
                map[b.id] = true
            end
        end
    end
    self.overlapMap = map
    return pairsOut
end

local function CountOverlapsWithOverride(overrideId, overrideAnchor)
    local items = {}
    for id, rec in pairs(HudLayout.registry) do
        local a = (id == overrideId and overrideAnchor) or HudLayout:GetEffectiveAnchor(id)
        local r = ResolveAnchorRect(rec.frame, a, id == overrideId)
        items[#items + 1] = { id = id, rect = r }
    end
    local blizzProtected = GetBlizzardProtectedRects()
    local count = 0
    local area = 0
    for i = 1, #items do
        local a = items[i]
        for k = 1, #blizzProtected do
            local bz = blizzProtected[k]
            local ox = math_min(a.rect.right, bz.rect.right) - math_max(a.rect.left, bz.rect.left)
            local oy = math_min(a.rect.top, bz.rect.top) - math_max(a.rect.bottom, bz.rect.bottom)
            if ox > 1.5 and oy > 1.5 then
                count = count + 1
                area = area + (ox * oy)
            end
        end
        for j = i + 1, #items do
            local b = items[j]
            local ox = math_min(a.rect.right, b.rect.right) - math_max(a.rect.left, b.rect.left)
            local oy = math_min(a.rect.top, b.rect.top) - math_max(a.rect.bottom, b.rect.bottom)
            if ox > 1.5 and oy > 1.5 then
                count = count + 1
                area = area + (ox * oy)
            end
        end
    end
    return count, area
end

function HudLayout:ResolveOverlaps()
    local moved = 0
    local sw, sh = GetViewportSize()
    for _ = 1, 16 do
        local overlaps = self:FindOverlaps()
        if #overlaps == 0 then break end
        local pair = overlaps[1]
        local curCount, curArea = CountOverlapsWithOverride(nil, nil)
        local bestId, bestAnchor, bestCount, bestArea = nil, nil, curCount, curArea
        local stepY = math_max(8, Snap(pair.oy + 8))
        local stepX = math_max(8, Snap(pair.ox + 8))

        for _, candId in ipairs({ pair.b, pair.a }) do
            local rec = self.registry[candId]
            if rec then
                local a = self:GetEffectiveAnchor(candId)
                local preferUp = (a.point == "BOTTOM" or a.point == "BOTTOMLEFT" or a.point == "BOTTOMRIGHT")
                local dirs = preferUp
                    and { { 0, stepY }, { 0, -stepY }, { -stepX, 0 }, { stepX, 0 } }
                    or { { 0, -stepY }, { 0, stepY }, { -stepX, 0 }, { stepX, 0 } }
                for _, d in ipairs(dirs) do
                    local scale = (a.scale and a.scale > 0) and a.scale or 1.0
                    local cand = {
                        point = a.point,
                        relPoint = a.relPoint,
                        x = Snap((a.x or 0) + (d[1] / scale)),
                        y = Snap((a.y or 0) + (d[2] / scale)),
                        scale = scale,
                    }
                    -- Reject candidates that would push raw anchor outside screen bounds
                    local rawW = ((type(rec.frame.GetWidth) == "function" and rec.frame:GetWidth()) or 120) * scale
                    local rawH = ((type(rec.frame.GetHeight) == "function" and rec.frame:GetHeight()) or 26) * scale
                    local ax, ay = sw * 0.5, sh * 0.5
                    if cand.relPoint == "TOPLEFT" then ax, ay = 0, sh
                    elseif cand.relPoint == "TOP" then ax, ay = sw * 0.5, sh
                    elseif cand.relPoint == "TOPRIGHT" then ax, ay = sw, sh
                    elseif cand.relPoint == "LEFT" then ax, ay = 0, sh * 0.5
                    elseif cand.relPoint == "RIGHT" then ax, ay = sw, sh * 0.5
                    elseif cand.relPoint == "BOTTOMLEFT" then ax, ay = 0, 0
                    elseif cand.relPoint == "BOTTOM" then ax, ay = sw * 0.5, 0
                    elseif cand.relPoint == "BOTTOMRIGHT" then ax, ay = sw, 0
                    end
                    local tx, ty = ax + cand.x * scale, ay + cand.y * scale
                    local inBounds = (tx >= -rawW and tx <= sw + rawW and ty >= -rawH and ty <= sh + rawH)
                    if inBounds then
                        local cCount, cArea = CountOverlapsWithOverride(candId, cand)
                        if cCount < bestCount or (cCount == bestCount and cArea < bestArea - 1.0) then
                            bestId, bestAnchor, bestCount, bestArea = candId, cand, cCount, cArea
                        end
                    end
                end
            end
        end

        if not (bestId and bestAnchor) then
            break
        end
        if ns.Api.ProfileStore then
            if ns.Api.ProfileStore:SetLayout(bestId, bestAnchor) == false then
                break
            end
        end
        self:ApplySavedAnchor(bestId)
        moved = moved + 1
    end
    local remaining = self:FindOverlaps()
    self:RefreshEditUI()
    return moved, #remaining
end

local function UpdateOverlayStyle(rec)
    if not rec or not rec.overlay then return end
    local isOver = HudLayout.overlapMap[rec.id] == true
    local isSel = (HudLayout.selectedId == rec.id)
    local bg = isOver and { 0.55, 0.10, 0.10, 0.72 }
        or (isSel and { 0.34, 0.27, 0.08, 0.75 } or { T.SURFACE.GOLD_TINT[1], T.SURFACE.GOLD_TINT[2], T.SURFACE.GOLD_TINT[3], 0.55 })
    local tc = isOver and T.SEMANTIC.DANGER or (isSel and T.TEXT.PRIMARY or T.TEXT.GOLD)
    if rec.overlay._bg then
        rec.overlay._bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
    end
    if rec.overlay._lbl then
        rec.overlay._lbl:SetText((isOver and "[!] 겹침: " or (isSel and "★ " or "이동: ")) .. rec.label)
        rec.overlay._lbl:SetTextColor(tc[1], tc[2], tc[3], 1)
    end
end

function HudLayout:RefreshEditUI()
    local overlaps = self:FindOverlaps()
    for _, rec in pairs(self.registry) do
        UpdateOverlayStyle(rec)
    end
    local bar = self.controlBar
    if not bar then return end
    local sel = self.selectedId and self.registry[self.selectedId] or nil
    if sel then
        local a = self:GetEffectiveAnchor(sel.id)
        local pct = math_floor(((a and a.scale or 1.0) * 100) + 0.5)
        bar._selLbl:SetText(
            "선택: " .. sel.label .. " (" .. tostring(a.x) .. ", " .. tostring(a.y) .. " · " .. tostring(pct) .. "%)"
        )
        bar._scaleLbl:SetText(tostring(pct) .. "%")
    else
        bar._selLbl:SetText("HUD를 클릭/드래그해 선택하세요 (화살표 4px · Shift+20px)")
        bar._scaleLbl:SetText("100%")
    end
    if #overlaps > 0 then
        bar._label:SetText("[!] HUD 겹침 " .. tostring(#overlaps) .. "건 감지 · 드래그 또는 [겹침 자동정렬]")
        bar._label:SetTextColor(T.SEMANTIC.DANGER[1], T.SEMANTIC.DANGER[2], T.SEMANTIC.DANGER[3], 1)
    else
        bar._label:SetText("★ HUD 배치 편집 모드 · 겹침 0건 · 드래그 4px 스냅")
        bar._label:SetTextColor(T.TEXT.GOLD[1], T.TEXT.GOLD[2], T.TEXT.GOLD[3], 1)
    end
end

function HudLayout:Select(id)
    if id and self.registry[id] then
        self.selectedId = id
    else
        self.selectedId = nil
    end
    self:RefreshEditUI()
    return self.selectedId
end

local function EnsureControlBar()
    if HudLayout.controlBar then
        return HudLayout.controlBar
    end
    local W = ns.UI.Widgets
    local bar = W.Card(_G.UIParent, 568, 72, "ForeverSuiteV3HudEditBar", T.ELEVATION.L3_OVERLAY)
    bar:SetPoint("TOP", _G.UIParent, "TOP", 0, -14)
    W.SetBorderColor(bar, T.BORDER.GOLD)
    if type(W.MakeDraggable) == "function" then
        W.MakeDraggable(bar, "hudEditBar", { point = "TOP", relPoint = "TOP", x = 0, y = -14 })
    end

    -- Row 1: status + Auto-Separate + Reset All + Save & Lock
    local lbl = W.Label(bar, "★ HUD 배치 편집 모드 · 겹침 0건 · 드래그 4px 스냅", "small", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    lbl:SetPoint("TOPLEFT", bar, "TOPLEFT", 12, -10)
    lbl:SetPoint("TOPRIGHT", bar, "TOPRIGHT", -294, -10)

    local doneBtn = W.Button(bar, "V 저장 및 잠금", 96, 22, function()
        HudLayout:SetUnlocked(false)
        ns.Api.SafeAPI.Print("HUD 위치와 크기를 저장하고 잠갔습니다.")
    end, true)
    doneBtn:SetPoint("TOPRIGHT", bar, "TOPRIGHT", -8, -6)

    local resetBtn = W.Button(bar, "전체 초기화", 82, 22, function()
        HudLayout:ResetAll()
        ns.Api.SafeAPI.Print("모든 HUD 위치를 4K/Blizzard 안전 기본 그리드로 초기화했습니다.")
    end)
    resetBtn:SetPoint("RIGHT", doneBtn, "LEFT", -6, 0)

    local sepBtn = W.Button(bar, "겹침 자동정렬", 90, 22, function()
        local moved, rem = HudLayout:ResolveOverlaps()
        if moved > 0 then
            ns.Api.SafeAPI.Print("HUD 겹침 자동 정렬 완료 (" .. tostring(moved) .. "회 보정 · 잔여 겹침 " .. tostring(rem) .. "건)")
        else
            ns.Api.SafeAPI.Print("현재 겹치는 HUD가 없습니다.")
        end
    end)
    sepBtn:SetPoint("RIGHT", resetBtn, "LEFT", -6, 0)

    -- Row 2: Selected HUD indicator + 4-way nudge + per-HUD scale + individual reset
    local selLbl = W.Label(bar, "HUD를 클릭/드래그해 선택하세요", "small", T.TEXT.SECONDARY, { justifyH = "LEFT", wordWrap = false })
    selLbl:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 12, 12)
    selLbl:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -286, 12)

    local function NudgeStep()
        return (ns.Api.GameAdapters and ns.Api.GameAdapters.IsShiftDown()) and 20 or GRID_STEP
    end

    local resetOneBtn = W.MiniButton(bar, "개별복원", 58, 20, function()
        if HudLayout.selectedId then
            HudLayout:ResetOne(HudLayout.selectedId)
        end
    end, "선택한 HUD만 기본 위치/크기로 복원")
    resetOneBtn:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -8, 8)

    local scalePlusBtn = W.MiniButton(bar, "+", 22, 20, function()
        if HudLayout.selectedId then
            local a = HudLayout:GetEffectiveAnchor(HudLayout.selectedId)
            HudLayout:SetScale(HudLayout.selectedId, (a and a.scale or 1.0) + 0.10)
        end
    end, "선택 HUD 크기 +10%")
    scalePlusBtn:SetPoint("RIGHT", resetOneBtn, "LEFT", -6, 0)

    local scaleLbl = W.MiniButton(bar, "100%", 42, 20, function()
        if HudLayout.selectedId then
            HudLayout:SetScale(HudLayout.selectedId, 1.0)
        end
    end, "클릭하여 선택 HUD 크기 100% 초기화")
    scaleLbl:SetPoint("RIGHT", scalePlusBtn, "LEFT", -2, 0)

    local scaleMinusBtn = W.MiniButton(bar, "-", 22, 20, function()
        if HudLayout.selectedId then
            local a = HudLayout:GetEffectiveAnchor(HudLayout.selectedId)
            HudLayout:SetScale(HudLayout.selectedId, (a and a.scale or 1.0) - 0.10)
        end
    end, "선택 HUD 크기 -10%")
    scaleMinusBtn:SetPoint("RIGHT", scaleLbl, "LEFT", -2, 0)

    local rightBtn = W.MiniButton(bar, "▶", 22, 20, function()
        if HudLayout.selectedId then HudLayout:Nudge(HudLayout.selectedId, NudgeStep(), 0) end
    end, "오른쪽으로 이동 (4px / Shift 20px)")
    rightBtn:SetPoint("RIGHT", scaleMinusBtn, "LEFT", -8, 0)

    local downBtn = W.MiniButton(bar, "▼", 22, 20, function()
        if HudLayout.selectedId then HudLayout:Nudge(HudLayout.selectedId, 0, -NudgeStep()) end
    end, "아래로 이동 (4px / Shift 20px)")
    downBtn:SetPoint("RIGHT", rightBtn, "LEFT", -2, 0)

    local upBtn = W.MiniButton(bar, "▲", 22, 20, function()
        if HudLayout.selectedId then HudLayout:Nudge(HudLayout.selectedId, 0, NudgeStep()) end
    end, "위로 이동 (4px / Shift 20px)")
    upBtn:SetPoint("RIGHT", downBtn, "LEFT", -2, 0)

    local leftBtn = W.MiniButton(bar, "◀", 22, 20, function()
        if HudLayout.selectedId then HudLayout:Nudge(HudLayout.selectedId, -NudgeStep(), 0) end
    end, "왼쪽으로 이동 (4px / Shift 20px)")
    leftBtn:SetPoint("RIGHT", upBtn, "LEFT", -2, 0)

    bar._label = lbl
    bar._selLbl = selLbl
    bar._scaleLbl = scaleLbl._label
    bar._doneBtn = doneBtn
    bar._resetBtn = resetBtn
    bar._sepBtn = sepBtn
    bar._nudgeBtns = { left = leftBtn, up = upBtn, down = downBtn, right = rightBtn }
    bar._scaleBtns = { minus = scaleMinusBtn, reset = scaleLbl, plus = scalePlusBtn }
    bar._resetOneBtn = resetOneBtn
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
    ov._bg = bg
    ov._lbl = lbl

    ov:EnableMouse(true)
    ov:RegisterForDrag("LeftButton")
    ov:SetScript("OnMouseDown", function()
        HudLayout:Select(rec.id)
    end)
    ov:SetScript("OnDragStart", function()
        HudLayout:Select(rec.id)
        rec.frame:StartMoving()
    end)
    ov:SetScript("OnDragStop", function()
        rec.frame:StopMovingOrSizing()
        HudLayout:SaveCurrentPosition(rec.id)
        HudLayout:RefreshEditUI()
    end)
    ov:Hide()
    rec.overlay = ov
    return ov
end

function HudLayout:Register(id, frame, defaultAnchor, label, onMoved)
    if not (id and frame and defaultAnchor) then
        return false
    end
    if type(frame.SetClampedToScreen) == "function" then
        frame:SetClampedToScreen(true)
    end
    self.registry[id] = {
        id = id,
        frame = frame,
        defaultAnchor = defaultAnchor,
        label = label or id,
        onMoved = onMoved,
        overlay = nil,
        directDrag = false,
    }
    self:ApplySavedAnchor(id)
    return true
end

function HudLayout:SetDirectDragFlag(id, flag)
    local rec = self.registry[id]
    if not rec then return false end
    rec.directDrag = flag == true
    if rec.directDrag and rec.frame and type(rec.frame.SetMovable) == "function" then
        rec.frame:SetMovable(true)
    end
    return true
end

function HudLayout:EnableDirectDrag(id, handleFrame, opts)
    local rec = self.registry[id]
    if not rec then return false end
    opts = opts or {}
    local target = opts.moveTarget or rec.frame
    local handle = handleFrame or target
    if not (target and handle) then return false end
    local requireShift = (opts.requireShift ~= false)
    rec.directDrag = true
    if type(target.SetMovable) == "function" then target:SetMovable(true) end
    if type(target.SetClampedToScreen) == "function" then target:SetClampedToScreen(true) end
    if type(handle.EnableMouse) == "function" then handle:EnableMouse(true) end
    if type(handle.RegisterForDrag) == "function" then handle:RegisterForDrag("LeftButton") end

    local function OnStart()
        if HudLayout:IsUnlocked() then return end
        if ns.Api and ns.Api.SafeAPI and ns.Api.SafeAPI.InCombat() then return end
        if requireShift and not (ns.Api and ns.Api.GameAdapters and ns.Api.GameAdapters.IsShiftDown()) then
            return
        end
        if type(opts.canDrag) == "function" and not opts.canDrag() then return end
        target._fsDirectDragging = true
        if type(target.SetMovable) == "function" then target:SetMovable(true) end
        if type(target.StartMoving) == "function" then target:StartMoving() end
    end
    local function OnStop()
        if not target._fsDirectDragging then return end
        target._fsDirectDragging = false
        target._fsJustDragged = true
        if type(target.StopMovingOrSizing) == "function" then target:StopMovingOrSizing() end
        HudLayout:SaveCurrentPosition(id)
    end

    if type(handle.HookScript) == "function" and type(handle.GetScript) == "function" then
        if handle:GetScript("OnDragStart") then
            handle:HookScript("OnDragStart", OnStart)
        else
            handle:SetScript("OnDragStart", OnStart)
        end
        if handle:GetScript("OnDragStop") then
            handle:HookScript("OnDragStop", OnStop)
        else
            handle:SetScript("OnDragStop", OnStop)
        end
    elseif type(handle.SetScript) == "function" then
        handle:SetScript("OnDragStart", OnStart)
        handle:SetScript("OnDragStop", OnStop)
    end
    return true
end

function HudLayout:ApplySavedAnchor(id)
    local rec = self.registry[id]
    if not rec then
        return false
    end
    local snapped = self:GetEffectiveAnchor(id)
    rec.frame:ClearAllPoints()
    rec.frame:SetPoint(snapped.point, _G.UIParent, snapped.relPoint, snapped.x, snapped.y)
    local scaleApplied = true
    if type(rec.frame.SetScale) == "function" then
        if ns.Api and ns.Api.SafeAPI and ns.Api.SafeAPI.InCombat() then
            scaleApplied = false
        else
            local ok = pcall(rec.frame.SetScale, rec.frame, snapped.scale)
            scaleApplied = (ok == true)
        end
    end
    if scaleApplied then
        rec.frame._fsHudScale = snapped.scale
    end
    if type(rec.onMoved) == "function" then
        rec.onMoved(snapped)
    end
    return scaleApplied
end

function HudLayout:SaveCurrentPosition(id)
    local rec = self.registry[id]
    if not (rec and type(rec.frame.GetPoint) == "function") then
        return false
    end
    local prev = self:GetEffectiveAnchor(id)
    local point, _, relPoint, x, y = rec.frame:GetPoint(1)
    local anchor = {
        point = point or rec.defaultAnchor.point,
        relPoint = relPoint or rec.defaultAnchor.relPoint,
        x = Snap(x),
        y = Snap(y),
        scale = prev and prev.scale or 1.0,
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
    local saved = self:GetEffectiveAnchor(id)
    local nextAnchor = {
        point = saved.point or rec.defaultAnchor.point,
        relPoint = saved.relPoint or rec.defaultAnchor.relPoint,
        x = Snap((saved.x or 0) + (dx or 0)),
        y = Snap((saved.y or 0) + (dy or 0)),
        scale = saved.scale or 1.0,
    }
    if ns.Api.ProfileStore then
        ns.Api.ProfileStore:SetLayout(id, nextAnchor)
    end
    self:ApplySavedAnchor(id)
    if self.unlocked then
        self:RefreshEditUI()
    end
    return true
end

function HudLayout:SetScale(id, scale)
    local rec = self.registry[id]
    if not rec then
        return false, "NOT_FOUND"
    end
    if ns.Api and ns.Api.SafeAPI and ns.Api.SafeAPI.InCombat() then
        return false, "IN_COMBAT"
    end
    local saved = self:GetEffectiveAnchor(id)
    saved.scale = ClampScale(scale)
    if ns.Api.ProfileStore then
        local wrote = ns.Api.ProfileStore:SetLayout(id, saved)
        if wrote == false then
            return false, "READ_ONLY"
        end
    end
    local applied = self:ApplySavedAnchor(id)
    if not applied then
        return false, "APPLY_FAILED"
    end
    if self.unlocked then
        self:RefreshEditUI()
    end
    return true, saved.scale
end

function HudLayout:ResetOne(id)
    local rec = self.registry[id]
    if not rec then return false end
    if ns.Api.ProfileStore then
        ns.Api.ProfileStore:SetLayout(id, {
            point = rec.defaultAnchor.point,
            relPoint = rec.defaultAnchor.relPoint,
            x = rec.defaultAnchor.x,
            y = rec.defaultAnchor.y,
            scale = 1.0,
        })
    end
    self:ApplySavedAnchor(id)
    if self.unlocked then
        self:RefreshEditUI()
    end
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
        if f.SetMovable then f:SetMovable(self.unlocked or rec.directDrag == true) end
        local ov = EnsureDragOverlay(rec)
        if self.unlocked then
            if not wasUnlocked then
                rec._wasShownBeforeUnlock = (type(f.IsShown) == "function" and f:IsShown()) and true or false
            end
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
    if self.unlocked then
        self:RefreshEditUI()
        if (not wasUnlocked) and ns.Api and ns.Api.EventBus then
            ns.Api.EventBus:Publish("hud:layout_unlocked")
        end
    end
    if wasUnlocked and (not self.unlocked) and ns.Api and ns.Api.EventBus then
        ns.Api.EventBus:Publish("hud:layout_locked")
    end
    if ns.UI and ns.UI.Director and type(ns.UI.Director.SyncFromProvider) == "function" then
        ns.UI.Director:SyncFromProvider(true)
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
                scale = 1.0,
            })
        end
        self:ApplySavedAnchor(id)
    end
    self.selectedId = nil
    self:SetUnlocked(false)
    return true
end
