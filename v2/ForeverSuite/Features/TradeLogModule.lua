-- Module: Features/TradeLogModule.lua
-- Responsibility: KPI-12 Safe Read-Only Trade History Logger (zero auto-trade taint) & Gold Farm GPH Session Tracker.
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local TradeLogModule = {
    log = {},
    pending = nil,
    lastClosed = nil,
    hadAccept = false,
    recordedCurrent = false,
    farmStartTime = nil,
    farmStartMoney = nil,
}
ns.Features.TradeLogModule = TradeLogModule

local CLOSE_GRACE_SEC = 2.0

function TradeLogModule:LoadSaved()
    local saved = ns.Api.ProfileStore and ns.Api.ProfileStore:GetState("tradeLog")
    if type(saved) == "table" then
        local clean = {}
        for _, r in ipairs(saved) do
            if type(r) == "table" and type(r.partner) == "string" then
                clean[#clean + 1] = {
                    partner = r.partner,
                    givenCopper = (type(r.givenCopper) == "number" and r.givenCopper >= 0) and r.givenCopper or 0,
                    receivedCopper = (type(r.receivedCopper) == "number" and r.receivedCopper >= 0) and r.receivedCopper or 0,
                    givenItems = type(r.givenItems) == "string" and r.givenItems or "",
                    receivedItems = type(r.receivedItems) == "string" and r.receivedItems or "",
                    timestamp = type(r.timestamp) == "number" and r.timestamp or 0,
                }
            end
        end
        self.log = clean
    end
end

function TradeLogModule:Save()
    if ns.Api.ProfileStore and ns.Api.ProfileStore:CanWrite() then
        ns.Api.ProfileStore:SetState("tradeLog", self.log)
    end
end

function TradeLogModule:OnTradeShow()
    self.recordedCurrent = false
    self.hadAccept = false
    self.lastClosed = nil
    self:OnTradeUpdated()
end

function TradeLogModule:OnTradeUpdated()
    self.pending = ns.Api.GameAdapters.GetTradeSnapshot()
end

function TradeLogModule:OnTradeAcceptUpdate(pAcc, tAcc)
    if pAcc == 1 or pAcc == true or tAcc == 1 or tAcc == true then
        self.hadAccept = true
    end
    self:OnTradeUpdated()
end

function TradeLogModule:CommitSnapshot(snap)
    if type(snap) ~= "table" then
        return false
    end
    snap.timestamp = ns.Api.GameAdapters.GetEpochTimestamp()
    if ns.Domain.PowerQoLModel.RecordTrade(self.log, snap) then
        self.recordedCurrent = true
        self.hadAccept = false
        self.pending = nil
        self.lastClosed = nil
        self:Save()
        ns.Api.SafeAPI.Print(
            "[거래 기록] " .. tostring(snap.partner)
            .. " (지급 " .. ns.Domain.LedgerModel.FormatCopper(snap.givenCopper)
            .. " / 수령 " .. ns.Domain.LedgerModel.FormatCopper(snap.receivedCopper) .. ")"
        )
        return true
    end
    return false
end

-- Authoritative completion ONLY on UI_INFO_MESSAGE (ERR_TRADE_COMPLETE):
-- handles both (ERR_TRADE_COMPLETE -> TRADE_CLOSED) and (TRADE_CLOSED[x1..2] -> ERR_TRADE_COMPLETE within 2s),
-- requires hadAccept (prevents delayed completion from mis-attributing a newly opened unaccepted trade B),
-- requires valid numeric monotonic timestamp (never substitutes 0), and NEVER fabricates a trade on cancel.
function TradeLogModule:OnInfoMessage(msg)
    if ns.Api.SafeAPI.IsSecret(msg) or type(msg) ~= "string" then
        return false
    end
    local completeMsg = _G.ERR_TRADE_COMPLETE
    local isComplete = (type(completeMsg) == "string" and msg == completeMsg)
        or msg == "거래가 완료되었습니다."
        or msg == "Trade complete."
    if not isComplete then
        return false
    end
    if self.recordedCurrent then
        return false
    end
    if self.pending then
        if not self.hadAccept then
            return false
        end
        return self:CommitSnapshot(self.pending)
    end
    if type(self.lastClosed) == "table" and self.lastClosed.snap then
        local now = ns.Api.GameAdapters.GetMonotonicTime()
        local closedAt = self.lastClosed.closedAt
        local fresh = (type(now) == "number" and type(closedAt) == "number")
            and ((now - closedAt) >= 0 and (now - closedAt) <= CLOSE_GRACE_SEC)
        if fresh then
            return self:CommitSnapshot(self.lastClosed.snap)
        end
        self.lastClosed = nil
    end
    return false
end

function TradeLogModule:OnTradeClosed()
    if (not self.recordedCurrent) and self.pending and self.hadAccept then
        local closedAt = ns.Api.GameAdapters.GetMonotonicTime()
        if type(closedAt) == "number" and closedAt == closedAt then
            self.lastClosed = {
                snap = self.pending,
                closedAt = closedAt,
            }
        else
            self.lastClosed = nil
        end
    end
    self.pending = nil
    self.hadAccept = false
end

function TradeLogModule:ResetFarm()
    self.farmStartTime = ns.Api.GameAdapters.GetMonotonicTime()
    self.farmStartMoney = ns.Api.SafeAPI.GetPlayerMoney()
end

function TradeLogModule:GetFarmSummary()
    local now = ns.Api.GameAdapters.GetMonotonicTime()
    local cur = ns.Api.SafeAPI.GetPlayerMoney()
    if not (self.farmStartTime and self.farmStartMoney and now and cur) then
        return nil
    end
    local elapsed = now - self.farmStartTime
    local delta = cur - self.farmStartMoney
    local gph = ns.Domain.PowerQoLModel.ComputeFarmGph(delta, elapsed)
    return { elapsed = elapsed, delta = delta, gph = gph }
end

function TradeLogModule:HandleFarmCommand(rest)
    if rest == "reset" then
        self:ResetFarm()
        ns.Api.SafeAPI.Print("골드 파밍 GPH 세션을 초기화했습니다.")
        return true
    end
    local s = self:GetFarmSummary()
    if not s or not s.gph then
        ns.Api.SafeAPI.Print("골드 파밍 기록이 아직 충분하지 않습니다 (최소 1초 경과 필요 · /fs farm reset).")
        return false
    end
    ns.Api.SafeAPI.Print(
        "골드 파밍: 변화 " .. ns.Domain.LedgerModel.FormatCopper(s.delta)
        .. " · 시간당 " .. ns.Domain.LedgerModel.FormatCopper(s.gph) .. "/h"
    )
    return true
end
