-- Module: Features/QuestTrackerView.lua
-- Responsibility: L0 chrome-free quest tracker view bound to live SafeAPI.CollectQuestLog, QuestItemDock (9-anchor clamped), and NavPort.
-- Layer: Features (uses UI/Widgets only; zero raw CreateFrame; zero direct C_SuperTrack/SetSelectedQuest).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs

local TRACKER_WIDTH = 312
local TRACKER_HEIGHT = 360

local QuestTrackerView = {
    container = nil,
    rowPool = {},
    lastSnapshot = nil,
    lastQuests = nil,
    lastOpts = nil,
}
ns.Features.QuestTrackerView = QuestTrackerView

local function ComputeRectFromAnchor(anchor, screenW, screenH)
    local pt = (anchor and anchor.point) or "TOPRIGHT"
    local x = (anchor and anchor.x) or 0
    local y = (anchor and anchor.y) or 0
    local left, top
    if pt == "TOPLEFT" then
        left, top = x, screenH + y
    elseif pt == "TOP" then
        left, top = (screenW - TRACKER_WIDTH) * 0.5 + x, screenH + y
    elseif pt == "TOPRIGHT" then
        left, top = screenW + x - TRACKER_WIDTH, screenH + y
    elseif pt == "LEFT" then
        left, top = x, (screenH + TRACKER_HEIGHT) * 0.5 + y
    elseif pt == "CENTER" then
        left, top = (screenW - TRACKER_WIDTH) * 0.5 + x, (screenH + TRACKER_HEIGHT) * 0.5 + y
    elseif pt == "RIGHT" then
        left, top = screenW + x - TRACKER_WIDTH, (screenH + TRACKER_HEIGHT) * 0.5 + y
    elseif pt == "BOTTOMLEFT" then
        left, top = x, y + TRACKER_HEIGHT
    elseif pt == "BOTTOM" then
        left, top = (screenW - TRACKER_WIDTH) * 0.5 + x, y + TRACKER_HEIGHT
    else -- BOTTOMRIGHT
        left, top = screenW + x - TRACKER_WIDTH, y + TRACKER_HEIGHT
    end
    return left, left + TRACKER_WIDTH, top
end

function QuestTrackerView:SyncDockAnchor(anchor)
    local screenW = (_G.UIParent and _G.UIParent.GetWidth and _G.UIParent:GetWidth()) or 1920
    local screenH = (_G.UIParent and _G.UIParent.GetHeight and _G.UIParent:GetHeight()) or 1080
    local left, right, top
    if self.container and type(self.container.GetLeft) == "function" then
        local l = self.container:GetLeft()
        local r = self.container:GetRight()
        local t = self.container:GetTop()
        if type(l) == "number" and type(r) == "number" and type(t) == "number" then
            left, right, top = l, r, t
        end
    end
    if not left then
        left, right, top = ComputeRectFromAnchor(anchor, screenW, screenH)
    end
    ns.Secure.QuestItemDock:SetAnchorFromRect(left, right, top, screenW, screenH)
end

function QuestTrackerView:Init()
    if self.container then
        return self.container
    end
    local box = W.HudContainer("ForeverSuiteV2QuestTracker", TRACKER_WIDTH, TRACKER_HEIGHT)
    self.container = box
    ns.UI.HudLayout:Register("questTracker", box, {
        point = "TOPRIGHT",
        relPoint = "TOPRIGHT",
        x = -24,
        y = -216,
    }, "퀘스트 추적기", function(anchor)
        QuestTrackerView:SyncDockAnchor(anchor)
    end)
    return box
end

function QuestTrackerView:EnsureRow(idx)
    if self.rowPool[idx] then
        return self.rowPool[idx]
    end
    local row = W.ListRow(self.container, 22, function(btn)
        local qid = btn._questID
        if type(qid) ~= "number" or qid <= 0 then
            return
        end
        local cur = ns.Api.SafeAPI.GetSuperTrackedQuestID()
        local nextQID = (cur == qid) and 0 or qid
        local ok, status = ns.Api.NavPort.RequestSuperTrack(nextQID)
        if not ok and status == "DEFERRED" then
            ns.Api.SafeAPI.Print("전투 또는 지도 종료 후 퀘스트 포커스를 전환합니다.")
        end
    end)
    self.rowPool[idx] = row
    return row
end

function QuestTrackerView:RefreshLive()
    local quests = ns.Api.SafeAPI.CollectQuestLog()
    return self:Render(quests, {
        superTrackedQuestID = ns.Api.SafeAPI.GetSuperTrackedQuestID(),
    })
end

function QuestTrackerView:ReRenderLast()
    if not self._needsPostCombatReRender then
        return nil
    end
    self._needsPostCombatReRender = false
    if self.lastQuests then
        local opts = self.lastOpts or {}
        opts.superTrackedQuestID = ns.Api.SafeAPI.GetSuperTrackedQuestID()
        return self:Render(self.lastQuests, opts)
    end
    return self:RefreshLive()
end

function QuestTrackerView:Render(quests, opts)
    self:Init()
    self.lastQuests = quests
    self.lastOpts = opts
    local snap = ns.Domain.QuestTrackerModel.BuildSnapshot(quests, opts)
    self.lastSnapshot = snap

    local dockApplied = ns.Secure.QuestItemDock:ApplySlots(snap.dockSlots)
    self._needsPostCombatReRender = not dockApplied

    local y = 0
    for i, item in ipairs(snap.rows) do
        local row = self:EnsureRow(i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", self.container, "TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", self.container, "TOPRIGHT", 0, -y)
        row._questID = item.questID

        if item.kind == "header" then
            row._left:SetText(item.text)
            row._left:SetTextColor(T.TEXT.GOLD[1], T.TEXT.GOLD[2], T.TEXT.GOLD[3], 1)
            row._right:SetText("")
        elseif item.kind == "quest" then
            local title = item.title
            if not dockApplied then
                local liveSlot = ns.Secure.QuestItemDock:GetActiveSlotForQuest(item.questID)
                title = (liveSlot and ("[" .. tostring(liveSlot) .. "] ") or "") ..
                    tostring(item.title):gsub("^%[%d+%] ", "")
            end
            row._left:SetText(title)
            local col = item.isComplete and T.SEMANTIC.SUCCESS or (item.isSuperTracked and T.TEXT.GOLD or T.TEXT.PRIMARY)
            row._left:SetTextColor(col[1], col[2], col[3], 1)
            row._right:SetText(item.level > 0 and ("Lv." .. tostring(item.level)) or "")
        else
            row._left:SetText("  • " .. item.text)
            local col = item.finished and T.SEMANTIC.SUCCESS or T.TEXT.SECONDARY
            row._left:SetTextColor(col[1], col[2], col[3], 1)
            row._right:SetText("")
        end
        row:Show()
        y = y + 22
    end

    for i = #snap.rows + 1, #self.rowPool do
        self.rowPool[i]:Hide()
    end

    return snap
end
